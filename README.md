# CAKE Proxy Kernel

Custom Debian amd64 kernel package set built from stable Linux 7.1.5 with local version `7.1.5-cakeproxy1`.

This build is intended for generic network proxy hosts that need better CAKE/FQ/BBR/IFB/TUN/NFT TPROXY alignment while keeping a general-purpose Debian VPS baseline.

Package set:

- `packages/linux-image-7.1.5-cakeproxy1_7.1.5-2_amd64.deb`
- `packages/linux-headers-7.1.5-cakeproxy1_7.1.5-2_amd64.deb`
- `packages/linux-libc-dev_7.1.5-2_amd64.deb`

Verify:

```sh
shasum -a 256 -c SHA256SUMS
```

Install the runtime kernel package:

```sh
sudo dpkg -i packages/linux-image-7.1.5-cakeproxy1_7.1.5-2_amd64.deb
sudo update-grub
```

Install headers only if DKMS or external kernel modules are needed.

The `7.1.5-2` package set was installed and reboot-tested on Debian 12 amd64. The verified booted kernel string is:

```text
Linux racknerd-7c62692 7.1.5-cakeproxy1 #2 SMP PREEMPT_DYNAMIC Wed Jul 29 00:19:45 EDT 2026 x86_64 GNU/Linux
```
