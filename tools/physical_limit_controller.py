#!/usr/bin/env python3
"""
X420 Generic Physical-Limit Controller

Purpose:
  Find the highest stable goodput for a VPS running the BBR/fq kernel base.

Principle:
  P = coarse path filling via application parallelism
  R = fine physical-limit tracking via aggregate rate cap

The script is generic. It does not use any host-specific defaults and does not
modify qdisc, firewall, routing, or proxy configuration. It probes with curl or
iperf3 and writes a state JSON file with the recommended P/R.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import json
import math
import os
import re
import shutil
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urlparse


DEFAULT_STATE = Path("/var/lib/x420/physical-limit-state.json")
DEFAULT_URL = "https://nbg1-speed.hetzner.com/100MB.bin"


@dataclasses.dataclass
class CpuSnap:
    total: int
    idle: int
    steal: int


@dataclasses.dataclass
class Counters:
    out_segs: int = 0
    retrans_segs: int = 0
    lost_retrans: int = 0
    timeouts: int = 0
    rx_drop: int = 0
    tx_drop: int = 0
    rx_errs: int = 0
    tx_errs: int = 0


@dataclasses.dataclass
class Sample:
    p: int
    r_mbps: Optional[float]
    seconds: int
    elapsed_s: float
    bytes_total: int
    throughput_mbps: float
    cost: float
    score: float
    health: str
    reasons: List[str]
    retrans_rate: float
    timeout_delta: int
    lost_retrans_delta: int
    rtt_min_ms: Optional[float]
    rtt_p95_ms: Optional[float]
    rtt_extra_ms: float
    rtt_growth: float
    cpu_idle_pct: float
    cpu_steal_pct: float
    drop_delta: int
    error_delta: int
    ok_transfers: int
    failed_transfers: int
    http_429: int
    raw_tail: List[Dict[str, Any]]


def run(cmd: List[str], timeout: Optional[int] = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=timeout,
    )


def read_text(path: str) -> str:
    try:
        return Path(path).read_text(errors="replace")
    except FileNotFoundError:
        return ""


def sysctl_get(key: str) -> Optional[str]:
    proc = run(["sysctl", "-n", key], timeout=5)
    return proc.stdout.strip() if proc.returncode == 0 else None


def kernel_state() -> Dict[str, Any]:
    qdisc = ""
    if shutil.which("tc"):
        qdisc = run(["tc", "qdisc", "show"], timeout=5).stdout.strip()
    state = {
        "kernel": os.uname().release,
        "tcp_congestion_control": sysctl_get("net.ipv4.tcp_congestion_control"),
        "default_qdisc": sysctl_get("net.core.default_qdisc"),
        "tcp_mtu_probing": sysctl_get("net.ipv4.tcp_mtu_probing"),
        "interface_has_fq": bool(re.search(r"\bqdisc\s+fq\b", qdisc)),
        "qdisc": qdisc,
    }
    state["ready"] = (
        state["tcp_congestion_control"] == "bbr"
        and state["default_qdisc"] == "fq"
        and state["tcp_mtu_probing"] == "1"
    )
    return state


def parse_keyed_table(text: str, prefix: str) -> Dict[str, int]:
    rows = [line.split() for line in text.splitlines() if line.startswith(prefix + ":")]
    if len(rows) < 2:
        return {}
    keys = rows[0][1:]
    vals = rows[1][1:]
    if len(keys) != len(vals):
        return {}
    out: Dict[str, int] = {}
    for key, val in zip(keys, vals):
        try:
            out[key] = int(val)
        except ValueError:
            pass
    return out


def read_counters() -> Counters:
    tcp = parse_keyed_table(read_text("/proc/net/snmp"), "Tcp")
    ext = parse_keyed_table(read_text("/proc/net/netstat"), "TcpExt")
    rx_drop = tx_drop = rx_errs = tx_errs = 0
    for line in read_text("/proc/net/dev").splitlines():
        if ":" not in line:
            continue
        iface, rest = line.split(":", 1)
        if iface.strip() == "lo":
            continue
        fields = rest.split()
        if len(fields) >= 16:
            rx_errs += int(fields[2])
            rx_drop += int(fields[3])
            tx_errs += int(fields[10])
            tx_drop += int(fields[11])
    return Counters(
        out_segs=tcp.get("OutSegs", 0),
        retrans_segs=tcp.get("RetransSegs", 0),
        lost_retrans=ext.get("TCPLostRetransmit", 0),
        timeouts=ext.get("TCPTimeouts", 0),
        rx_drop=rx_drop,
        tx_drop=tx_drop,
        rx_errs=rx_errs,
        tx_errs=tx_errs,
    )


def delta_counters(after: Counters, before: Counters) -> Counters:
    return Counters(
        out_segs=max(0, after.out_segs - before.out_segs),
        retrans_segs=max(0, after.retrans_segs - before.retrans_segs),
        lost_retrans=max(0, after.lost_retrans - before.lost_retrans),
        timeouts=max(0, after.timeouts - before.timeouts),
        rx_drop=max(0, after.rx_drop - before.rx_drop),
        tx_drop=max(0, after.tx_drop - before.tx_drop),
        rx_errs=max(0, after.rx_errs - before.rx_errs),
        tx_errs=max(0, after.tx_errs - before.tx_errs),
    )


def read_cpu() -> CpuSnap:
    vals = [int(x) for x in read_text("/proc/stat").splitlines()[0].split()[1:]]
    idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
    steal = vals[7] if len(vals) > 7 else 0
    return CpuSnap(total=sum(vals), idle=idle, steal=steal)


def delta_cpu(after: CpuSnap, before: CpuSnap) -> Tuple[float, float]:
    total = max(1, after.total - before.total)
    return (
        max(0, after.idle - before.idle) / total * 100.0,
        max(0, after.steal - before.steal) / total * 100.0,
    )


def percentile(values: List[float], pct: float) -> Optional[float]:
    if not values:
        return None
    ordered = sorted(values)
    idx = int(math.ceil(len(ordered) * pct / 100.0)) - 1
    return ordered[max(0, min(idx, len(ordered) - 1))]


def ping_samples(host: str, seconds: int, interval: float = 0.2) -> List[float]:
    if not host or not shutil.which("ping"):
        return []
    count = max(3, int(seconds / interval))
    proc = run(["ping", "-n", "-i", str(interval), "-c", str(count), host], timeout=seconds + 10)
    return [float(m.group(1)) for m in re.finditer(r"time[=<]([0-9.]+)\s*ms", proc.stdout + proc.stderr)]


def resolve_rtt_host(args: argparse.Namespace) -> str:
    if args.rtt_host:
        return args.rtt_host
    if args.url:
        return urlparse(args.url).hostname or "1.1.1.1"
    if args.iperf_host:
        return args.iperf_host
    return "1.1.1.1"


def rate_limit_arg(total_mbps: Optional[float], p: int) -> Optional[str]:
    if total_mbps is None or total_mbps <= 0:
        return None
    per_worker_bytes = max(1, int(total_mbps * 1_000_000 / 8 / max(1, p)))
    return str(per_worker_bytes)


def curl_once(url: str, timeout_s: int, limit_rate: Optional[str]) -> Dict[str, Any]:
    if not shutil.which("curl"):
        raise RuntimeError("curl is required")
    fmt = "size=%{size_download} total=%{time_total} code=%{http_code} err=%{errormsg}\\n"
    cmd = [
        "curl",
        "-L",
        "-sS",
        "--connect-timeout",
        "5",
        "--max-time",
        str(timeout_s),
        "-o",
        os.devnull,
        "-w",
        fmt,
    ]
    if limit_rate:
        cmd.extend(["--limit-rate", limit_rate])
    cmd.append(url)
    proc = run(cmd, timeout=timeout_s + 10)
    text = proc.stdout + proc.stderr
    size = re.search(r"size=([0-9]+)", text)
    total = re.search(r"total=([0-9.]+)", text)
    code = re.search(r"code=([0-9]+)", text)
    return {
        "size": int(size.group(1)) if size else 0,
        "total": float(total.group(1)) if total else 0.0,
        "code": int(code.group(1)) if code else 0,
        "raw": text[-220:].replace("\n", " "),
    }


def curl_worker(stop_at: float, url: str, timeout_s: int, limit_rate: Optional[str]) -> Dict[str, Any]:
    bytes_total = ok = failed = http_429 = 0
    tail: List[Dict[str, Any]] = []
    while time.monotonic() < stop_at:
        item = curl_once(url, timeout_s, limit_rate)
        if item["code"] == 429:
            http_429 += 1
        if 200 <= item["code"] < 400 and item["size"] > 0:
            ok += 1
            bytes_total += item["size"]
        else:
            failed += 1
        tail.append(item)
        tail = tail[-4:]
        if item["total"] <= 0:
            time.sleep(0.2)
    return {"bytes": bytes_total, "ok": ok, "failed": failed, "http_429": http_429, "tail": tail}


def run_curl(args: argparse.Namespace, p: int, r_mbps: Optional[float], seconds: int) -> Dict[str, Any]:
    stop_at = time.monotonic() + seconds
    limit = rate_limit_arg(r_mbps, p)
    with concurrent.futures.ThreadPoolExecutor(max_workers=p) as pool:
        workers = [pool.submit(curl_worker, stop_at, args.url, args.curl_max_time, limit) for _ in range(p)]
        results = [w.result() for w in workers]
    return {
        "bytes": sum(r["bytes"] for r in results),
        "ok": sum(r["ok"] for r in results),
        "failed": sum(r["failed"] for r in results),
        "http_429": sum(r["http_429"] for r in results),
        "tail": [x for r in results for x in r["tail"]][-8:],
    }


def run_iperf(args: argparse.Namespace, p: int, r_mbps: Optional[float], seconds: int) -> Dict[str, Any]:
    if not shutil.which("iperf3"):
        raise RuntimeError("iperf3 is required")
    cmd = ["iperf3", "-J", "-c", args.iperf_host, "-t", str(seconds), "-P", str(p), "-p", str(args.iperf_port)]
    if args.reverse:
        cmd.append("-R")
    if r_mbps and r_mbps > 0:
        cmd.extend(["-b", f"{r_mbps}M"])
    proc = run(cmd, timeout=seconds + 20)
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"iperf3 JSON parse failed: {exc}; output={(proc.stdout + proc.stderr)[-400:]}")
    end = data.get("end", {})
    summary = end.get("sum_received") or end.get("sum") or end.get("sum_sent") or {}
    bytes_total = int(summary.get("bytes", 0))
    return {"bytes": bytes_total, "ok": int(bytes_total > 0), "failed": int(bytes_total <= 0), "http_429": 0, "tail": []}


def compute_cost(
    retrans_rate: float,
    timeout_delta: int,
    rtt_extra_ms: float,
    cpu_idle_pct: float,
    cpu_steal_pct: float,
    drop_delta: int,
    error_delta: int,
) -> float:
    return (
        retrans_rate * 100.0
        + timeout_delta * 8.0
        + max(0.0, rtt_extra_ms - 10.0) * 0.08
        + max(0.0, 25.0 - cpu_idle_pct) * 0.6
        + cpu_steal_pct * 0.5
        + drop_delta * 0.3
        + error_delta * 5.0
    )


def classify(sample: Sample, args: argparse.Namespace) -> Tuple[str, List[str]]:
    reasons: List[str] = []
    if sample.bytes_total <= 0:
        reasons.append("no_successful_transfer")
    if sample.http_429 > 0:
        reasons.append("policer_or_target_429")
    if sample.timeout_delta > 0:
        reasons.append("timeout_delta")
    if sample.error_delta > 0:
        reasons.append("interface_error_delta")
    if sample.retrans_rate > args.hard_retrans_rate:
        reasons.append("hard_retrans_rate")
    elif sample.retrans_rate > args.soft_retrans_rate:
        reasons.append("soft_retrans_rate")
    if sample.cpu_idle_pct < args.hard_cpu_idle_pct:
        reasons.append("hard_cpu_idle")
    elif sample.cpu_idle_pct < args.soft_cpu_idle_pct:
        reasons.append("soft_cpu_idle")
    if sample.cpu_steal_pct > args.hard_cpu_steal_pct:
        reasons.append("hard_cpu_steal")
    elif sample.cpu_steal_pct > args.soft_cpu_steal_pct:
        reasons.append("soft_cpu_steal")
    if sample.rtt_extra_ms > args.hard_rtt_extra_ms and sample.rtt_growth > args.hard_rtt_growth:
        reasons.append("hard_queue_growth")
    elif sample.rtt_extra_ms > args.soft_rtt_extra_ms and sample.rtt_growth > args.soft_rtt_growth:
        reasons.append("soft_queue_growth")
    if sample.drop_delta > 0:
        reasons.append("link_drop_delta")

    hard = {
        "no_successful_transfer",
        "policer_or_target_429",
        "timeout_delta",
        "interface_error_delta",
        "hard_retrans_rate",
        "hard_cpu_idle",
        "hard_cpu_steal",
        "hard_queue_growth",
    }
    if any(r in hard for r in reasons):
        return "HARD_BAD", reasons
    if reasons:
        return "SOFT_BAD", reasons
    return "HEALTHY", ["healthy"]


def take_sample(
    args: argparse.Namespace,
    p: int,
    r_mbps: Optional[float],
    seconds: int,
    baseline_rtt_ms: Optional[float],
) -> Sample:
    rtt_samples: List[float] = []

    def ping_job() -> None:
        nonlocal rtt_samples
        rtt_samples = ping_samples(resolve_rtt_host(args), seconds)

    before_c = read_counters()
    before_cpu = read_cpu()
    start = time.monotonic()
    thread = threading.Thread(target=ping_job, daemon=True)
    thread.start()
    raw = run_iperf(args, p, r_mbps, seconds) if args.iperf_host else run_curl(args, p, r_mbps, seconds)
    thread.join(timeout=2)
    elapsed = time.monotonic() - start
    d = delta_counters(read_counters(), before_c)
    cpu_idle, cpu_steal = delta_cpu(read_cpu(), before_cpu)
    throughput = raw["bytes"] * 8.0 / max(elapsed, 0.001) / 1_000_000
    retrans_rate = d.retrans_segs / max(d.out_segs, 1)
    rtt_min = min(rtt_samples) if rtt_samples else None
    rtt_p95 = percentile(rtt_samples, 95)
    ref_rtt = baseline_rtt_ms or rtt_min
    rtt_extra = max(0.0, (rtt_p95 or 0.0) - (ref_rtt or 0.0)) if ref_rtt and rtt_p95 else 0.0
    rtt_growth = rtt_extra / max(ref_rtt or 1.0, 0.001) if ref_rtt else 0.0
    drop_delta = d.rx_drop + d.tx_drop
    error_delta = d.rx_errs + d.tx_errs
    cost = compute_cost(retrans_rate, d.timeouts, rtt_extra, cpu_idle, cpu_steal, drop_delta, error_delta)
    score = throughput / (1.0 + cost)
    sample = Sample(
        p=p,
        r_mbps=r_mbps,
        seconds=seconds,
        elapsed_s=elapsed,
        bytes_total=raw["bytes"],
        throughput_mbps=throughput,
        cost=cost,
        score=score,
        health="UNKNOWN",
        reasons=[],
        retrans_rate=retrans_rate,
        timeout_delta=d.timeouts,
        lost_retrans_delta=d.lost_retrans,
        rtt_min_ms=rtt_min,
        rtt_p95_ms=rtt_p95,
        rtt_extra_ms=rtt_extra,
        rtt_growth=rtt_growth,
        cpu_idle_pct=cpu_idle,
        cpu_steal_pct=cpu_steal,
        drop_delta=drop_delta,
        error_delta=error_delta,
        ok_transfers=raw["ok"],
        failed_transfers=raw["failed"],
        http_429=raw["http_429"],
        raw_tail=raw["tail"],
    )
    sample.health, sample.reasons = classify(sample, args)
    return sample


def parse_int_list(raw: str) -> List[int]:
    out: List[int] = []
    for part in raw.split(","):
        part = part.strip()
        if part:
            out.append(int(part))
    return out


def print_samples(title: str, samples: List[Sample]) -> None:
    print(f"\n{title}")
    print("P  R(Mbps)  Mbps    cost    score   health     retrans%  tout p95ms  +rtt  idle%  reasons")
    for s in samples:
        r = "-" if s.r_mbps is None else f"{s.r_mbps:.1f}"
        p95 = "-" if s.rtt_p95_ms is None else f"{s.rtt_p95_ms:.1f}"
        print(
            f"{s.p:<2} {r:>7} {s.throughput_mbps:>7.2f} {s.cost:>7.2f} {s.score:>8.3f} "
            f"{s.health:<10} {s.retrans_rate*100:>8.3f} {s.timeout_delta:>5} "
            f"{p95:>6} {s.rtt_extra_ms:>5.1f} {s.cpu_idle_pct:>6.1f} {','.join(s.reasons)}"
        )


def choose_best(samples: List[Sample]) -> Optional[Sample]:
    valid = [s for s in samples if s.health != "HARD_BAD"]
    return max(valid, key=lambda s: s.score) if valid else None


def baseline_rtt(args: argparse.Namespace) -> Optional[float]:
    samples = ping_samples(resolve_rtt_host(args), max(5, min(args.baseline_rtt_sec, 15)))
    return min(samples) if samples else None


def parallel_search(args: argparse.Namespace, base_rtt: Optional[float]) -> Tuple[Optional[Sample], List[Sample], List[str]]:
    samples: List[Sample] = []
    reasons: List[str] = []
    previous: Optional[Sample] = None
    best: Optional[Sample] = None
    candidates = [p for p in parse_int_list(args.p_candidates) if p <= args.max_p and p not in parse_int_list(args.forbidden_p)]
    for p in candidates:
        sample = take_sample(args, p, None, args.parallel_window_sec, base_rtt)
        samples.append(sample)
        if sample.health == "HARD_BAD":
            reasons.append(f"stop_parallel_P{p}_hard_bad:{','.join(sample.reasons)}")
            break
        if best is None or sample.score > best.score:
            best = sample
        if previous:
            gain = (sample.throughput_mbps - previous.throughput_mbps) / max(previous.throughput_mbps, 0.001)
            if gain < args.parallel_min_gain:
                reasons.append(f"stop_parallel_low_gain_P{p}:{gain:.3f}")
                break
            if sample.score < previous.score:
                reasons.append(f"stop_parallel_score_decline_P{p}")
                break
        previous = sample
    return best, samples, reasons


def rate_knee_search(args: argparse.Namespace, p: int, start_r: float, base_rtt: Optional[float]) -> Tuple[Sample, List[Sample], List[str]]:
    reasons: List[str] = []
    samples: List[Sample] = []
    r = max(1.0, start_r)
    last_good: Optional[Sample] = None
    previous: Optional[Sample] = None
    for _ in range(args.rate_steps):
        sample = take_sample(args, p, r, args.rate_window_sec, base_rtt)
        samples.append(sample)
        if sample.health == "HARD_BAD":
            reasons.append(f"stop_rate_hard_bad_R{r:.2f}:{','.join(sample.reasons)}")
            break
        if previous:
            throughput_gain = (sample.throughput_mbps - previous.throughput_mbps) / max(previous.throughput_mbps, 0.001)
            cost_growth = (sample.cost - previous.cost) / max(previous.cost, 0.001)
            if throughput_gain < args.knee_min_throughput_gain and cost_growth > args.knee_cost_growth:
                reasons.append(f"knee_detected_R{r:.2f}_gain_{throughput_gain:.3f}_cost_{cost_growth:.3f}")
                break
        last_good = sample
        previous = sample
        r *= args.rate_growth
    if last_good is None:
        last_good = samples[0]
    return last_good, samples, reasons


def micro_probe(args: argparse.Namespace, p: int, r: float, base_rtt: Optional[float]) -> Tuple[float, List[Sample], List[str]]:
    current = take_sample(args, p, r, args.lock_window_sec, base_rtt)
    test_r = r * args.micro_probe_gain
    test = take_sample(args, p, test_r, args.micro_probe_sec, base_rtt)
    reasons: List[str] = []
    if (
        test.health != "HARD_BAD"
        and test.throughput_mbps >= current.throughput_mbps * (1.0 + args.micro_accept_gain)
        and test.cost <= current.cost * (1.0 + args.micro_accept_cost_growth)
    ):
        reasons.append("micro_probe_accepted")
        return test_r, [current, test], reasons
    reasons.append("micro_probe_rejected")
    return r, [current, test], reasons


def command_discover(args: argparse.Namespace) -> int:
    kstate = kernel_state()
    if not kstate["ready"] and not args.no_kernel_gate:
        state = make_state(
            args,
            kstate,
            None,
            1,
            None,
            [],
            [],
            ["kernel_not_ready_for_physical_limit_inference"],
        )
        write_state(args.state_file, state)
        print("kernel_not_ready_for_physical_limit_inference")
        return 2
    base_rtt = baseline_rtt(args)
    best_p_sample, p_samples, p_reasons = parallel_search(args, base_rtt)
    if best_p_sample is None:
        state = make_state(args, kstate, base_rtt, 1, None, p_samples, [], p_reasons + ["no_valid_parallel_sample"])
        write_state(args.state_file, state)
        print_samples("parallel search", p_samples)
        return 1

    start_r = best_p_sample.throughput_mbps * args.initial_rate_ratio
    best_r_sample, r_samples, r_reasons = rate_knee_search(args, best_p_sample.p, start_r, base_rtt)
    if best_r_sample.health == "HARD_BAD":
        final_r = max(1.0, start_r * args.hard_backoff)
        r_reasons.append("first_rate_sample_hard_bad_use_hard_backoff")
    else:
        final_r = max(1.0, best_r_sample.throughput_mbps * args.final_safety_ratio)
    all_reasons = p_reasons + r_reasons + [f"final_safety_ratio_{args.final_safety_ratio}"]
    state = make_state(args, kstate, base_rtt, best_p_sample.p, final_r, p_samples, r_samples, all_reasons)
    print_samples("parallel search", p_samples)
    print_samples("rate knee search", r_samples)
    print(f"\nrecommendation: P={best_p_sample.p} R={final_r:.2f}Mbps reasons={'; '.join(all_reasons) or '-'}")
    write_state(args.state_file, state)
    return 0


def command_lock(args: argparse.Namespace) -> int:
    kstate = kernel_state()
    if not kstate["ready"] and not args.no_kernel_gate:
        raise SystemExit("kernel_not_ready_for_physical_limit_inference; use --no-kernel-gate to override")
    state = load_state(args.state_file)
    p = args.seed_p or int(state.get("best_p") or 1)
    r = args.seed_rate_mbps if args.seed_rate_mbps is not None else state.get("best_rate_mbps")
    if r is None:
        raise SystemExit("lock needs --seed-rate-mbps or a state file from discover")
    base_rtt = baseline_rtt(args)
    sample = take_sample(args, p, float(r), args.lock_window_sec, base_rtt)
    reasons = [f"lock_observe_{sample.health}"]
    next_p = p
    next_r = float(r)
    if sample.timeout_delta > 0 or sample.health == "HARD_BAD":
        next_r *= args.hard_backoff
        reasons.append("hard_backoff")
        if sample.cpu_idle_pct < args.hard_cpu_idle_pct and p > 1:
            next_p = max(1, p // 2)
            reasons.append("cpu_guard_halved_parallel")
    elif sample.retrans_rate > args.soft_retrans_rate or sample.health == "SOFT_BAD":
        next_r *= args.soft_backoff
        reasons.append("soft_backoff")
    else:
        next_r *= args.lock_increase
        reasons.append("lock_small_increase")
    new_state = make_state(args, kernel_state(), base_rtt, next_p, next_r, [sample], [], reasons)
    print_samples("lock observe", [sample])
    print(f"\nrecommendation: P={next_p} R={next_r:.2f}Mbps reasons={'; '.join(reasons)}")
    write_state(args.state_file, new_state)
    return 0


def command_micro_probe(args: argparse.Namespace) -> int:
    kstate = kernel_state()
    if not kstate["ready"] and not args.no_kernel_gate:
        raise SystemExit("kernel_not_ready_for_physical_limit_inference; use --no-kernel-gate to override")
    state = load_state(args.state_file)
    p = args.seed_p or int(state.get("best_p") or 1)
    r = args.seed_rate_mbps if args.seed_rate_mbps is not None else state.get("best_rate_mbps")
    if r is None:
        raise SystemExit("micro-probe needs --seed-rate-mbps or a state file from discover")
    base_rtt = baseline_rtt(args)
    new_r, samples, reasons = micro_probe(args, p, float(r), base_rtt)
    new_state = make_state(args, kernel_state(), base_rtt, p, new_r, samples, [], reasons)
    print_samples("micro probe", samples)
    print(f"\nrecommendation: P={p} R={new_r:.2f}Mbps reasons={'; '.join(reasons)}")
    write_state(args.state_file, new_state)
    return 0


def load_state(path: Path) -> Dict[str, Any]:
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def write_state(path: Path, state: Dict[str, Any]) -> None:
    if path.is_absolute() and str(path).startswith("/var/") and os.geteuid() != 0:
        path = Path("/tmp/x420-physical-limit-state.json")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    print(f"state_written={path}")


def make_state(
    args: argparse.Namespace,
    kstate: Dict[str, Any],
    base_rtt: Optional[float],
    best_p: int,
    best_r: Optional[float],
    parallel_samples: List[Sample],
    rate_samples: List[Sample],
    reasons: List[str],
) -> Dict[str, Any]:
    return {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "algorithm": "x420-generic-physical-limit-controller",
        "kernel_state": kstate,
        "baseline_rtt_ms": base_rtt,
        "target": {
            "url": args.url,
            "iperf_host": args.iperf_host,
            "rtt_host": resolve_rtt_host(args),
            "reverse": args.reverse,
        },
        "best_p": best_p,
        "best_rate_mbps": None if best_r is None else round(float(best_r), 3),
        "decision_reasons": reasons,
        "parallel_samples": [dataclasses.asdict(s) for s in parallel_samples],
        "rate_samples": [dataclasses.asdict(s) for s in rate_samples],
    }


def add_common(parser: argparse.ArgumentParser) -> None:
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--url", default=DEFAULT_URL)
    target.add_argument("--iperf-host")
    parser.add_argument("--iperf-port", type=int, default=5201)
    parser.add_argument("--reverse", action="store_true")
    parser.add_argument("--rtt-host")
    parser.add_argument("--state-file", type=Path, default=DEFAULT_STATE)
    parser.add_argument("--curl-max-time", type=int, default=90)
    parser.add_argument("--baseline-rtt-sec", type=int, default=8)
    parser.add_argument("--p-candidates", default="1,2,4,8,16")
    parser.add_argument("--max-p", type=int, default=16)
    parser.add_argument("--forbidden-p", default="")
    parser.add_argument("--parallel-window-sec", type=int, default=20)
    parser.add_argument("--rate-window-sec", type=int, default=15)
    parser.add_argument("--lock-window-sec", type=int, default=15)
    parser.add_argument("--micro-probe-sec", type=int, default=10)
    parser.add_argument("--parallel-min-gain", type=float, default=0.05)
    parser.add_argument("--initial-rate-ratio", type=float, default=0.90)
    parser.add_argument("--final-safety-ratio", type=float, default=0.97)
    parser.add_argument("--rate-growth", type=float, default=1.08)
    parser.add_argument("--rate-steps", type=int, default=6)
    parser.add_argument("--knee-min-throughput-gain", type=float, default=0.03)
    parser.add_argument("--knee-cost-growth", type=float, default=0.10)
    parser.add_argument("--micro-probe-gain", type=float, default=1.03)
    parser.add_argument("--micro-accept-gain", type=float, default=0.02)
    parser.add_argument("--micro-accept-cost-growth", type=float, default=0.05)
    parser.add_argument("--lock-increase", type=float, default=1.01)
    parser.add_argument("--soft-backoff", type=float, default=0.95)
    parser.add_argument("--hard-backoff", type=float, default=0.75)
    parser.add_argument("--soft-retrans-rate", type=float, default=0.05)
    parser.add_argument("--hard-retrans-rate", type=float, default=0.10)
    parser.add_argument("--soft-rtt-extra-ms", type=float, default=20.0)
    parser.add_argument("--hard-rtt-extra-ms", type=float, default=40.0)
    parser.add_argument("--soft-rtt-growth", type=float, default=0.40)
    parser.add_argument("--hard-rtt-growth", type=float, default=0.80)
    parser.add_argument("--soft-cpu-idle-pct", type=float, default=25.0)
    parser.add_argument("--hard-cpu-idle-pct", type=float, default=15.0)
    parser.add_argument("--soft-cpu-steal-pct", type=float, default=5.0)
    parser.add_argument("--hard-cpu-steal-pct", type=float, default=15.0)
    parser.add_argument("--no-kernel-gate", action="store_true", help="allow inference even if BBR/fq/MTU probing checks fail")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generic physical-limit controller for BBR/fq VPS kernels.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", required=True)
    discover = sub.add_parser("discover", help="coarse P search then fine R knee search")
    add_common(discover)
    lock = sub.add_parser("lock", help="observe the current P/R and apply one AIMD step")
    add_common(lock)
    lock.add_argument("--seed-p", type=int)
    lock.add_argument("--seed-rate-mbps", type=float)
    micro = sub.add_parser("micro-probe", help="short +3%% R probe around current state")
    add_common(micro)
    micro.add_argument("--seed-p", type=int)
    micro.add_argument("--seed-rate-mbps", type=float)
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    if args.iperf_host:
        args.url = None
    if args.command == "discover":
        return command_discover(args)
    if args.command == "lock":
        return command_lock(args)
    if args.command == "micro-probe":
        return command_micro_probe(args)
    raise SystemExit(f"unknown command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
