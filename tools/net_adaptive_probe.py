#!/usr/bin/env python3
"""
Lean BBR Assist for BBR/fq kernels.

This tool does not change TCP congestion-control code. It applies a
near-bare-kernel BBR/fq profile and uses a small P=1/2/4 probe to recommend
application-level parallelism.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Sample:
    parallel: int
    throughput_mbps: float
    retransmits: int
    rtt_ms: float | None
    rto_ms: float | None
    cwnd: int | None
    pacing_mbps: float | None
    cpu_idle: float | None
    score: float
    verdict: str


def run(cmd: list[str], timeout: int | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)


def require_binary(name: str) -> None:
    if shutil.which(name) is None:
        raise SystemExit(f"missing required binary: {name}")


def read_sysctl(name: str) -> str:
    proc = run(["sysctl", "-n", name])
    return proc.stdout.strip() if proc.returncode == 0 else ""


def parse_iperf3_json(raw: str) -> tuple[float, int]:
    data = json.loads(raw)
    end = data.get("end", {})
    summaries = [end.get("sum"), end.get("sum_sent"), end.get("sum_received")]
    valid = [item for item in summaries if isinstance(item, dict)]
    summary = max(valid, key=lambda item: float(item.get("bits_per_second", 0.0) or 0.0), default={})
    bps = float(summary.get("bits_per_second", 0.0) or 0.0)
    retransmits = max(int(item.get("retransmits", 0) or 0) for item in valid) if valid else 0
    return bps / 1_000_000.0, retransmits


@dataclass
class TcpSnapshot:
    rtt_ms: float | None
    rto_ms: float | None
    cwnd: int | None
    pacing_mbps: float | None


def parse_rate_to_mbps(value: str, unit: str) -> float:
    scale = {
        "bps": 0.000001,
        "Kbps": 0.001,
        "Mbps": 1.0,
        "Gbps": 1000.0,
    }.get(unit, 1.0)
    return float(value) * scale


def collect_tcp_snapshot() -> TcpSnapshot:
    proc = run(["ss", "-tin"])
    if proc.returncode != 0:
        return TcpSnapshot(None, None, None, None)
    rtts: list[float] = []
    rtos: list[float] = []
    cwnds: list[int] = []
    pacings: list[float] = []
    for match in re.finditer(r"rtt:([0-9.]+)/", proc.stdout):
        try:
            rtts.append(float(match.group(1)))
        except ValueError:
            pass
    for match in re.finditer(r"\brto:([0-9.]+)", proc.stdout):
        try:
            # ss prints rto in seconds on this Debian build.
            rtos.append(float(match.group(1)) * 1000.0)
        except ValueError:
            pass
    for match in re.finditer(r"\bcwnd:(\d+)", proc.stdout):
        try:
            cwnds.append(int(match.group(1)))
        except ValueError:
            pass
    for match in re.finditer(r"\bpacing_rate ([0-9.]+)([KMG]?bps)", proc.stdout):
        try:
            pacings.append(parse_rate_to_mbps(match.group(1), match.group(2)))
        except ValueError:
            pass
    return TcpSnapshot(
        statistics.median(rtts) if rtts else None,
        statistics.median(rtos) if rtos else None,
        int(statistics.median(cwnds)) if cwnds else None,
        statistics.median(pacings) if pacings else None,
    )


def median_snapshot(snapshots: list[TcpSnapshot]) -> TcpSnapshot:
    rtts = [item.rtt_ms for item in snapshots if item.rtt_ms is not None]
    rtos = [item.rto_ms for item in snapshots if item.rto_ms is not None]
    cwnds = [item.cwnd for item in snapshots if item.cwnd is not None]
    pacings = [item.pacing_mbps for item in snapshots if item.pacing_mbps is not None]
    return TcpSnapshot(
        statistics.median(rtts) if rtts else None,
        statistics.median(rtos) if rtos else None,
        int(statistics.median(cwnds)) if cwnds else None,
        statistics.median(pacings) if pacings else None,
    )


def collect_cpu_idle() -> float | None:
    if shutil.which("mpstat") is None:
        return None
    proc = run(["mpstat", "1", "1"], timeout=3)
    if proc.returncode != 0:
        return None
    for line in reversed(proc.stdout.splitlines()):
        parts = line.split()
        if parts and parts[0] in {"Average:", "平均时间:"}:
            try:
                return float(parts[-1])
            except ValueError:
                return None
    return None


def score_sample(throughput: float, retransmits: int, rtt_ms: float | None, min_rtt: float | None, cpu_idle: float | None) -> float:
    score = throughput
    if min_rtt and rtt_ms:
        growth = max(0.0, (rtt_ms - min_rtt) / min_rtt)
        score -= throughput * min(growth, 2.0) * 0.35
    if retransmits:
        score -= min(throughput * 0.85, retransmits * 0.75)
    if cpu_idle is not None:
        cpu_used = 100.0 - cpu_idle
        if cpu_used > 80.0:
            score -= throughput * 0.25
        elif cpu_used > 70.0:
            score -= throughput * 0.10
    return max(0.0, score)


def is_usable_sample(sample: Sample, args: argparse.Namespace) -> bool:
    if sample.throughput_mbps <= 0.0:
        return False
    if sample.retransmits > 0:
        return False
    if sample.cpu_idle is not None and sample.cpu_idle < 20.0:
        return False
    return True


def best_sample(samples: list[Sample], args: argparse.Namespace) -> Sample | None:
    if not samples:
        return None
    best = samples[0]
    if best.throughput_mbps <= 0.0:
        usable = [sample for sample in samples if is_usable_sample(sample, args)]
        return max(usable, key=lambda item: item.score) if usable else samples[0]
    for sample in samples[1:]:
        if not is_usable_sample(sample, args):
            break
        gain = (sample.throughput_mbps - best.throughput_mbps) / best.throughput_mbps
        if gain >= args.min_gain:
            best = sample
            continue
        break
    return best


def verdict_for(sample: Sample, previous: Sample | None, min_rtt: float | None) -> str:
    warnings: list[str] = []
    if previous and previous.throughput_mbps > 0:
        gain = (sample.throughput_mbps - previous.throughput_mbps) / previous.throughput_mbps
        if gain < 0.05:
            warnings.append("throughput_gain_flat")
    if min_rtt and sample.rtt_ms and sample.rtt_ms > min_rtt * 1.4:
        warnings.append("rtt_queue_growth")
    if sample.retransmits > 0:
        warnings.append("retransmits_seen")
    if sample.cpu_idle is not None and sample.cpu_idle < 30.0:
        warnings.append("cpu_pressure")
    return "ok" if not warnings else ",".join(warnings)


def run_iperf_probe(host: str, port: int, duration: int, parallel: int, reverse: bool) -> tuple[float, int, TcpSnapshot]:
    cmd = ["iperf3", "-c", host, "-p", str(port), "-t", str(duration), "-P", str(parallel), "-J", "--get-server-output"]
    if reverse:
        cmd.append("-R")
    proc = subprocess.Popen(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    snapshots: list[TcpSnapshot] = []
    deadline = time.monotonic() + duration + 20
    while proc.poll() is None:
        if time.monotonic() > deadline:
            proc.kill()
            raise RuntimeError("iperf3 timed out")
        snapshots.append(collect_tcp_snapshot())
        time.sleep(0.5)
    stdout, stderr = proc.communicate()
    if proc.returncode != 0:
        raise RuntimeError(stderr.strip() or stdout.strip() or "iperf3 failed")
    throughput, retransmits = parse_iperf3_json(stdout)
    return throughput, retransmits, median_snapshot(snapshots)


def probe(args: argparse.Namespace) -> list[Sample]:
    require_binary("iperf3")
    samples: list[Sample] = []
    min_rtt: float | None = None

    candidates = args.parallel
    if args.lean:
        candidates = [1, 2, 4]
    elif args.auto:
        candidates = []
        value = 1
        while value <= args.max_parallel:
            candidates.append(value)
            value *= 2

    for parallel in candidates:
        throughput, retransmits, tcp = run_iperf_probe(args.host, args.port, args.duration, parallel, args.reverse)
        if throughput <= 0.0 and args.retry_zero:
            time.sleep(args.cooldown)
            throughput, retransmits, tcp = run_iperf_probe(args.host, args.port, args.duration, parallel, args.reverse)
        time.sleep(args.cooldown)
        cpu_idle = collect_cpu_idle()
        if tcp.rtt_ms is not None:
            min_rtt = tcp.rtt_ms if min_rtt is None else min(min_rtt, tcp.rtt_ms)
        score = score_sample(throughput, retransmits, tcp.rtt_ms, min_rtt, cpu_idle)
        sample = Sample(parallel, throughput, retransmits, tcp.rtt_ms, tcp.rto_ms, tcp.cwnd, tcp.pacing_mbps, cpu_idle, score, "pending")
        sample.verdict = verdict_for(sample, samples[-1] if samples else None, min_rtt)
        samples.append(sample)

        if args.lean and len(samples) >= 2:
            current_best = best_sample(samples[:-1], args)
            if current_best and current_best.throughput_mbps > 0:
                gain = (sample.throughput_mbps - current_best.throughput_mbps) / current_best.throughput_mbps
                if sample.retransmits > 0 or sample.throughput_mbps <= 0.0 or gain < args.min_gain:
                    break
        elif args.auto and len(samples) >= 2:
            previous = samples[-2]
            if previous.throughput_mbps > 0:
                gain = (sample.throughput_mbps - previous.throughput_mbps) / previous.throughput_mbps
                if gain < args.min_gain:
                    break
            if sample.retransmits > args.max_retransmits:
                break

        if args.stop_on_overload and sample.parallel > 1 and sample.verdict != "ok":
            if "rtt_queue_growth" in sample.verdict or "cpu_pressure" in sample.verdict:
                break

    return samples


def print_environment() -> None:
    print("kernel:", os.uname().release)
    print("tcp_congestion_control:", read_sysctl("net.ipv4.tcp_congestion_control"))
    print("tcp_available_congestion_control:", read_sysctl("net.ipv4.tcp_available_congestion_control"))
    print("default_qdisc:", read_sysctl("net.core.default_qdisc"))


def print_samples(samples: list[Sample]) -> None:
    print()
    print("parallel  mbps       retrans  rtt_ms  rto_ms  cwnd    pacing_mbps  cpu_idle  score      verdict")
    for s in samples:
        rtt = "-" if s.rtt_ms is None else f"{s.rtt_ms:.1f}"
        rto = "-" if s.rto_ms is None else f"{s.rto_ms:.0f}"
        cwnd = "-" if s.cwnd is None else str(s.cwnd)
        pacing = "-" if s.pacing_mbps is None else f"{s.pacing_mbps:.1f}"
        cpu = "-" if s.cpu_idle is None else f"{s.cpu_idle:.1f}"
        print(f"{s.parallel:<8}  {s.throughput_mbps:<9.2f}  {s.retransmits:<7}  {rtt:<6}  {rto:<6}  {cwnd:<6}  {pacing:<11}  {cpu:<8}  {s.score:<9.2f}  {s.verdict}")
    if samples:
        best = best_sample(samples, ARGS)
        print()
        if best:
            print(f"recommended_parallel={best.parallel}")
            print(f"recommended_reason=best score {best.score:.2f} at {best.throughput_mbps:.2f} Mbps")


def build_tuning(best: Sample) -> dict[str, str]:
    return {
        "net.core.default_qdisc": "fq",
        "net.ipv4.tcp_congestion_control": "bbr",
        "net.ipv4.tcp_mtu_probing": "1",
        "net.core.rmem_max": "16777216",
        "net.core.wmem_max": "16777216",
        "net.ipv4.tcp_rmem": "4096 87380 16777216",
        "net.ipv4.tcp_wmem": "4096 87380 16777216",
    }


def write_kernel_tuning(best: Sample, samples: list[Sample], path: str, recommendation_path: str) -> None:
    if os.geteuid() != 0:
        raise RuntimeError("--apply-kernel-tuning must run as root")

    tuning = build_tuning(best)
    target = Path(path)
    if target.exists():
        backup = target.with_suffix(target.suffix + f".bak.{int(time.time())}")
        backup.write_text(target.read_text())
        print(f"backup_sysctl={backup}")

    lines = [
        "# Managed by net-adaptive-probe.",
        "# Remove this file and run `sysctl --system` to roll back these tunings.",
    ]
    lines.extend(f"{key} = {value}" for key, value in tuning.items())
    target.write_text("\n".join(lines) + "\n")

    proc = run(["sysctl", "--system"], timeout=30)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "sysctl --system failed")

    recommendation = {
        "algorithm": "Lean BBR Assist",
        "recommended_parallel": best.parallel,
        "throughput_mbps": best.throughput_mbps,
        "retransmits": best.retransmits,
        "rto_ms": best.rto_ms,
        "cwnd": best.cwnd,
        "score": best.score,
        "safe": is_usable_sample(best, ARGS),
        "kernel_policy": "bbr+fq+minimal-buffer",
        "sysctl_profile": "minimal",
        "samples": [sample.__dict__ for sample in samples],
        "sysctl_file": str(target),
    }
    Path(recommendation_path).write_text(json.dumps(recommendation, indent=2, sort_keys=True) + "\n")
    print(f"applied_sysctl={target}")
    print(f"recommendation_json={recommendation_path}")


def parse_parallel(value: str) -> list[int]:
    result: list[int] = []
    for item in value.split(","):
        item = item.strip()
        if not item:
            continue
        number = int(item)
        if number < 1:
            raise argparse.ArgumentTypeError("parallel values must be >= 1")
        result.append(number)
    if not result:
        raise argparse.ArgumentTypeError("at least one parallel value is required")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Lean BBR Assist for BBR/fq network kernels.")
    parser.add_argument("--host", help="iperf3 server host. If omitted, only environment is printed.")
    parser.add_argument("--port", type=int, default=5201)
    parser.add_argument("--duration", type=int, default=8)
    parser.add_argument("--parallel", type=parse_parallel, default=[1, 2, 4])
    parser.add_argument("--lean", action="store_true", default=True, help="use Lean BBR Assist P=1/2/4 convergence")
    parser.add_argument("--auto", action="store_true", help="probe by doubling parallelism until gain flattens or loss appears")
    parser.add_argument("--max-parallel", type=int, default=16)
    parser.add_argument("--min-gain", type=float, default=0.10, help="minimum relative gain required to accept a higher parallel level")
    parser.add_argument("--max-retransmits", type=int, default=0, help="stop --auto mode if retransmits exceed this count")
    parser.add_argument("--retry-zero", action="store_true", default=True, help="retry a parallel level once if iperf reports zero throughput")
    parser.add_argument("--cooldown", type=int, default=2)
    parser.add_argument("--reverse", action="store_true", help="test download direction with iperf3 -R")
    parser.add_argument("--stop-on-overload", action="store_true", default=True)
    parser.add_argument("--apply-kernel-tuning", action="store_true", help="apply safe sysctl tunings after probing")
    parser.add_argument("--sysctl-file", default="/etc/sysctl.d/99-lean-bbr-assist.conf")
    parser.add_argument("--recommendation-file", default="/var/lib/lean-bbr-assist/recommendation.json")
    args = parser.parse_args()
    global ARGS
    ARGS = args

    print_environment()
    if not args.host:
        print()
        print("No --host supplied, probe not started.")
        print("Example: net-adaptive-probe --host <iperf3-server> --parallel 1,2,4,8")
        return 0

    try:
        samples = probe(args)
    except Exception as exc:
        print(f"probe_failed: {exc}", file=sys.stderr)
        return 2

    print_samples(samples)
    best = best_sample(samples, args)
    if args.apply_kernel_tuning and best:
        Path(args.recommendation_file).parent.mkdir(parents=True, exist_ok=True)
        write_kernel_tuning(best, samples, args.sysctl_file, args.recommendation_file)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
