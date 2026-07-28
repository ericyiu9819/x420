# CAKE Proxy Kernel

Custom Debian amd64 kernel package set built from stable Linux 7.1.5 with local version `7.1.5-cakeproxy1`.

This build is intended for generic network proxy hosts that need better CAKE/FQ/BBR/IFB/TUN/NFT TPROXY alignment while keeping a general-purpose Debian VPS baseline.

Packages:

- `packages/linux-image-7.1.5-cakeproxy1_7.1.5-1_amd64.deb`
- `packages/linux-headers-7.1.5-cakeproxy1_7.1.5-1_amd64.deb`
- `packages/linux-libc-dev_7.1.5-1_amd64.deb`

Verify:

```sh
shasum -a 256 -c SHA256SUMS
```

Install the runtime kernel package:

```sh
sudo dpkg -i packages/linux-image-7.1.5-cakeproxy1_7.1.5-1_amd64.deb
sudo update-grub
```

Install headers only if DKMS or external kernel modules are needed.
