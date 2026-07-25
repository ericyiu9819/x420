# Linux 6.12.97 VPSFQ

Backup of the Debian amd64 VPSFQ kernel and its reproducible build kit.

VPSFQ is an in-kernel queue discipline derived from Linux 6.12.97 upstream
FQ. It keeps per-flow fairness and TCP pacing, with conservative defaults for
a single-vCPU, low-memory VPS. This build selects BBR + VPSFQ by default while
retaining upstream FQ, FQ-CoDel, CAKE, and CUBIC for fallback and A/B testing.

Primary files:

- `linux-image-6.12.97-vpsfq_6.12.97-3_amd64.deb`: bootable kernel package.
- `linux-headers-6.12.97-vpsfq_6.12.97-3_amd64.deb`: matching headers.
- `sch_vpsfq.c`: exact scheduler source used for the build.
- `debian-vps-vpsfq-kernel-6.12.97.tar.gz`: reproducible build kit.
- `BUILD-REPORT.md`: design facts, validation, and limitations.
- `BACKUP-SHA256SUMS`: hashes for every backed-up artifact.

The packages were compiled and structurally validated but were not installed
or boot-tested when this backup was created. Keep a known-good distribution
kernel and console/rescue access for the first boot.
