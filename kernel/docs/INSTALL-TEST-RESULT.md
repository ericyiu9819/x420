# X420 installation and smoke-test result

Test time: 2026-07-27, Asia/Shanghai

## Outcome

- Installed `linux-image-6.18.39-x420` and `linux-headers-6.18.39-x420`.
- Generated `/boot/initrd.img-6.18.39-x420`.
- Successfully performed a one-time GRUB boot into `6.18.39-x420`.
- Root XFS filesystem, Virtio block device, both Virtio network interfaces, SSH, and Xray started normally.
- No failed systemd units and no kernel error-level messages were observed after boot.
- The permanent GRUB saved entry remains `6.12.98-proxymax1`; the next ordinary reboot will return to that kernel unless explicitly changed.

## X420 validation

- `tcp_x420` loaded successfully.
- `sch_x420q` loaded successfully.
- Available TCP congestion controls: `reno cubic bbr x420`.
- A socket selected `x420` through `TCP_CONGESTION`.
- X420Q attached successfully to an isolated veth interface.
- An isolated X420 TCP flow transferred 8,388,608 payload bytes through X420Q.
- X420Q reported 8,772,294 wire bytes and 5,813 packets, with:
  - dropped: 0
  - overlimits: 0
  - requeues: 0

## Production network state

- Xray remained active and listening on TCP port 443.
- SSH remained active on TCP port 22.
- The production egress interface `eth1` was deliberately left on the previous BBR+FQ profile.
- No production-interface queue replacement or Xray restart was performed.

This is a functional smoke test, not a performance benchmark. A performance claim requires controlled A/B testing against BBR+FQ with the same route, workload, concurrency, and measurement window.
