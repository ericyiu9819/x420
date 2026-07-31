#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "kernel packages must be built on Linux" >&2
  exit 1
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kernel_version="${KERNEL_VERSION:-6.18.41}"
base_config="${BASE_CONFIG:-/boot/config-$(uname -r)}"
jobs="${JOBS:-$(nproc)}"
trim_config="${TRIM_CONFIG:-1}"
source_dir="$root_dir/out/linux-$kernel_version"
package_dir="$root_dir/out/packages"
download_dir="$root_dir/out/downloads"
archive="$download_dir/linux-$kernel_version.tar.xz"
checksums="$download_dir/sha256sums.asc"
fragment="$root_dir/kernel/config/vps-proxy.fragment"

for command in curl make rsync sha256sum tar; do
  command -v "$command" >/dev/null || {
    echo "missing build dependency: $command" >&2
    exit 1
  }
done

[[ -r "$base_config" ]] || {
  echo "base kernel config is not readable: $base_config" >&2
  exit 1
}

mkdir -p "$root_dir/out" "$package_dir" "$download_dir"

if [[ ! -f "$source_dir/Makefile" ]]; then
  if [[ -e "$source_dir" ]]; then
    echo "incomplete source directory exists; remove it first: $source_dir" >&2
    exit 1
  fi

  curl --fail --location --retry 4 \
    "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$kernel_version.tar.xz" \
    --output "$archive"
  curl --fail --location --retry 4 \
    "https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc" \
    --output "$checksums"

  expected_checksum="$(
    awk -v file="linux-$kernel_version.tar.xz" \
      '$2 == file { print $1; exit }' \
      "$checksums"
  )"
  [[ "$expected_checksum" =~ ^[0-9a-fA-F]{64}$ ]] || {
    echo "no valid checksum found for linux-$kernel_version.tar.xz" >&2
    exit 1
  }
  printf '%s  %s\n' "$expected_checksum" "$archive" | sha256sum --check -

  tar -xJf "$archive" -C "$root_dir/out"
fi

cp "$base_config" "$source_dir/.config"
make -C "$source_dir" olddefconfig

if [[ "$trim_config" == "1" ]]; then
  make -C "$source_dir" localmodconfig
fi

"$source_dir/scripts/kconfig/merge_config.sh" \
  -m \
  -O "$source_dir" \
  "$source_dir/.config" \
  "$fragment"
make -C "$source_dir" olddefconfig

required=(
  CONFIG_TCP_CONG_BBR=y
  CONFIG_NET_SCH_FQ=y
  CONFIG_DEFAULT_BBR=y
  CONFIG_DEFAULT_FQ=y
  CONFIG_BPF_JIT=y
  CONFIG_XDP_SOCKETS=y
  CONFIG_IO_URING=y
)

for setting in "${required[@]}"; do
  grep -qxF "$setting" "$source_dir/.config" || {
    echo "required kernel setting was not accepted: $setting" >&2
    exit 1
  }
done

make -C "$source_dir" -j"$jobs" \
  LOCALVERSION=-vps-proxy \
  KDEB_PKGVERSION="${kernel_version}-1" \
  bindeb-pkg

find "$root_dir/out" -maxdepth 1 -type f \
  \( -name '*.deb' -o -name '*.buildinfo' -o -name '*.changes' \) \
  -exec mv -f {} "$package_dir/" \;

echo "kernel packages: $package_dir"
