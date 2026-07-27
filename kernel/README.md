# X420 kernel and algorithm prototype

This package turns the earlier design into an auditable Linux 6.18.39 LTS
prototype:

- `tcp_x420.c`: queue-aware delivery-rate TCP congestion control;
- `sch_x420q.c`: mark-aware FQ-derived pacing scheduler;
- `build-x420-kernel.sh`: verifies kernel.org's signature, patches the tree,
  configures modules, and builds Debian packages;
- `apply-x420-profile.sh`: explicitly activates X420 on one interface;
- `rollback-x420-profile.sh`: returns to CUBIC + FQ;
- `install-vless-reality-x420.sh`: the original VLESS/REALITY installer
  refactored to require and use the X420 kernel;
- `xray-sockopt-fragment.json`: minimal Xray integration fragment;
- `ALGORITHM.md`: model, state machine, invariants, and validation matrix.

## Important status

This is a research implementation, not a production-ready congestion-control
algorithm. It has passed source consistency, patch, shell syntax, JSON syntax,
and kernel style checks available in the development workspace. It has not
been compiled or benchmarked on a Linux test machine in this workspace, and
must not be deployed to an unattended or remote-only server.

The build host must be Debian or Ubuntu Linux. KVM, VMware, or bare metal is
required to boot the resulting kernel; LXC and OpenVZ guests normally cannot
replace the host kernel.

## Build

Install the build dependencies:

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential bc bison flex libssl-dev libelf-dev dwarves \
  rsync fakeroot dpkg-dev gnupg curl xz-utils patch
```

Prepare and inspect without compiling:

```bash
./build-x420-kernel.sh --prepare-only
```

Build Debian packages:

```bash
./build-x420-kernel.sh --jobs "$(nproc)"
```

The script only accepts Linux 6.18.39, verifies the release signature against
the stable-maintainer fingerprints published by kernel.org, and never installs
or boots the result.

## Safe evaluation order

1. Build on a disposable Linux builder.
2. Confirm both modules compile without warnings.
3. Test in a VM with a serial or provider console.
4. Install the generated kernel packages while retaining the distribution
   kernel.
5. Reboot by selecting the X420 kernel once; do not make it the only boot
   entry.
6. Verify `tcp_x420.ko` and `sch_x420q.ko`.
7. Run controlled namespace/netem tests from `ALGORITHM.md`.
8. Only then activate on a test interface:

```bash
sudo ./apply-x420-profile.sh --iface eth0 --confirm
```

Rollback:

```bash
sudo /var/lib/x420/rollback.sh
```

## Xray integration

Xray's documented Sockopt supports `mark` through `SO_MARK` and
`tcpcongestion` through `TCP_CONGESTION`. Merge the supplied fragment into the
VLESS/REALITY inbound and direct outbound, or use the refactored installer
after booting the test kernel.

The current integration applies steady-flow class `0x04200003` to the proxy
sockets. Dynamic handshake/interactive/bulk transitions require an Xray-core
patch and are intentionally listed as future work rather than silently
simulated in the kernel.

## Known limitations

- Linux 6.18.39 is the only supported source baseline.
- Parameters are hypotheses until measured against a defined path matrix.
- The algorithm has not completed fairness, ECN, policer, or adversarial tests.
- X420-Q uses standard FQ netlink attributes under a new qdisc name; an
  unmodified `tc` can attach it without options but may display its detailed
  options as unknown.
- Changing the global TCP default affects new sockets from other applications;
  prefer Xray's per-socket `tcpcongestion` setting during experiments.
- Existing connections retain their previous congestion controller.

Do not publish performance claims until the four-way baseline comparison in
`ALGORITHM.md` has been completed.
