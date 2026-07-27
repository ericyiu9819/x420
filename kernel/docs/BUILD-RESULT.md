# X420 Linux 6.18.39 VPS build result

- Result: successful full `bindeb-pkg` build
- Architecture: amd64
- Kernel release: `6.18.39-x420`
- Package version: `6.18.39-1`
- Build duration: approximately 4 hours 27 minutes on one virtual CPU
- Source baseline: Linux 6.18.39 LTS; upstream signature verified before extraction
- Configuration:
  - `CONFIG_TCP_CONG_BBR=m`
  - `CONFIG_TCP_CONG_X420=m`
  - `CONFIG_NET_SCH_FQ=y`
  - `CONFIG_NET_SCH_X420Q=m`
- Image package contents verified:
  - `/lib/modules/6.18.39-x420/kernel/net/ipv4/tcp_x420.ko.zst`
  - `/lib/modules/6.18.39-x420/kernel/net/sched/sch_x420q.ko.zst`
- The build did not install the packages, change GRUB, load the modules, reboot the VPS, or modify the active network path.
- The VPS remained on its existing `6.12.98-proxymax1` kernel.
- The temporary 4 GiB build swap file was disabled and removed after the build.

`evidence/` contains the complete build log, final kernel configuration, Debian build metadata, and changes record.
