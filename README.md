# X420

X420 combines a TCP-only VLESS + REALITY installer with an experimental,
queue-aware Linux networking stack.

The repository has two independent parts:

- [`SpeaceX`](./SpeaceX) deploys a single-VPS VLESS + REALITY service over
  RAW/TCP.
- [`kernel/`](./kernel/) contains the X420 congestion controller, the X420Q
  mark-aware fair-queue scheduler, a Linux 6.18.39 integration patch, build and
  rollback scripts, and reproducible smoke-test evidence.

## Reality installer

Run the installer on a supported Debian or Ubuntu VPS:

```bash
sudo bash SpeaceX <VPS_IP> <REALITY_SNI>
```

Review the script before running it. It installs Xray, writes its systemd unit
and configuration, and applies conservative BBR + FQ tuning when BBR is
available.

## Experimental kernel stack

Start with [`kernel/README.md`](./kernel/README.md). The stack is split into
three cooperating layers:

1. Xray socket marks identify traffic classes.
2. X420Q isolates and schedules the marked flows.
3. X420 TCP uses delivery rate, minimum RTT, queue delay, and loss signals to
   control congestion.

The supplied patch targets the exact upstream Linux 6.18.39 source tree.
Building and installing a custom kernel are separate operations; the build
script does not install, change GRUB, or reboot the host.

## Validation status

The prototype has completed:

- an upstream-signature-verified Linux 6.18.39 build;
- Debian image and headers package generation;
- a one-time boot on an x86_64 KVM VPS with XFS and Virtio;
- module registration and an isolated 8 MiB X420 + X420Q data-path test with
  zero drops, overlimits, or requeues.

See [`kernel/docs/BUILD-RESULT.md`](./kernel/docs/BUILD-RESULT.md) and
[`kernel/docs/INSTALL-TEST-RESULT.md`](./kernel/docs/INSTALL-TEST-RESULT.md).

These are functional results, not proof of a performance advantage. Keep
official BBR + FQ as the production baseline until controlled A/B tests show
better throughput, loaded latency, and retransmission behavior on the target
route.

## Binary packages

Generated `.deb` files and full build logs are intentionally excluded from Git
history. Release binaries should be published as checksummed GitHub Release
assets after review.
