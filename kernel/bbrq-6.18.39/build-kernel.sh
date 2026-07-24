#!/usr/bin/env bash
set -euo pipefail

KERNEL_VERSION=6.18.39
KERNEL_SHA256=a7a7e3d2ae9d95e74197223a8d4eb5f6be7aac21b6e6de27e9685d001c1f8cb0
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${BUILD_ROOT:-${SCRIPT_DIR}/build}"
SOURCE_DIR="${BUILD_ROOT}/linux-${KERNEL_VERSION}"
TARBALL="${BUILD_ROOT}/linux-${KERNEL_VERSION}.tar.xz"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/artifacts}"
JOBS="${JOBS:-$(nproc)}"

if [[ "$(uname -s)" != Linux ]]; then
	echo "This reproducible build must run on Linux." >&2
	exit 1
fi

case "${ARCH:-$(uname -m)}" in
	x86_64|x86)
		KARCH=x86
		BUILD_TARGET=bzImage
		IMAGE_PATH=arch/x86/boot/bzImage
		;;
	aarch64|arm64)
		KARCH=arm64
		BUILD_TARGET=Image
		IMAGE_PATH=arch/arm64/boot/Image
		;;
	*)
		echo "Unsupported ARCH. Set ARCH=x86_64 or ARCH=arm64." >&2
		exit 1
		;;
esac

for command in curl sha256sum tar patch make gcc bc bison flex perl openssl; do
	command -v "${command}" >/dev/null ||
		{ echo "Missing build dependency: ${command}" >&2; exit 1; }
done

mkdir -p "${BUILD_ROOT}" "${OUTPUT_DIR}"

if [[ ! -f "${TARBALL}" ]]; then
	curl --fail --location --retry 3 \
		-o "${TARBALL}" \
		"https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"
fi
printf '%s  %s\n' "${KERNEL_SHA256}" "${TARBALL}" | sha256sum --check -

if [[ ! -d "${SOURCE_DIR}" ]]; then
	mkdir -p "${SOURCE_DIR}"
	tar -xJf "${TARBALL}" -C "${SOURCE_DIR}" --strip-components=1
fi

cd "${SOURCE_DIR}"
if [[ ! -f net/ipv4/tcp_bbrq.c ]]; then
	patch -p1 < "${SCRIPT_DIR}/0001-net-add-experimental-BBRQ-congestion-control.patch"
fi

if [[ -n "${BASE_CONFIG:-}" ]]; then
	cp "${BASE_CONFIG}" .config
elif [[ -r "/boot/config-$(uname -r)" ]]; then
	cp "/boot/config-$(uname -r)" .config
else
	make ARCH="${KARCH}" defconfig
fi

scripts/config \
	--enable TCP_CONG_ADVANCED \
	--module TCP_CONG_BBR \
	--module TCP_CONG_BBRQ \
	--enable NET_SCH_FQ \
	--enable BQL \
	--enable RPS \
	--enable XPS \
	--enable NET_RX_BUSY_POLL \
	--enable PREEMPT_DYNAMIC \
	--enable HZ_250 \
	--disable WERROR \
	--enable DEBUG_INFO_NONE \
	--disable DEBUG_INFO_DWARF4 \
	--disable DEBUG_INFO_DWARF5 \
	--disable DEBUG_INFO_BTF \
	--set-str SYSTEM_TRUSTED_KEYS "" \
	--set-str SYSTEM_REVOCATION_KEYS ""

make ARCH="${KARCH}" olddefconfig
make ARCH="${KARCH}" -j"${JOBS}" LOCALVERSION=-bbrq \
	"${BUILD_TARGET}" modules

PACKAGE_ROOT="${OUTPUT_DIR}/linux-${KERNEL_VERSION}-bbrq-${KARCH}"
mkdir -p "${PACKAGE_ROOT}/boot" "${PACKAGE_ROOT}/root"
make ARCH="${KARCH}" LOCALVERSION=-bbrq \
	INSTALL_MOD_PATH="${PACKAGE_ROOT}/root" modules_install
cp "${IMAGE_PATH}" "${PACKAGE_ROOT}/boot/"
cp System.map .config "${PACKAGE_ROOT}/boot/"

echo "Build complete: ${PACKAGE_ROOT}"
echo "Install with your distribution's kernel packaging process; do not copy it over the running kernel."
