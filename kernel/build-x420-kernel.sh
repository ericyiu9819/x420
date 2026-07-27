#!/usr/bin/env bash
# Build the X420 research kernel as Debian packages. This script never installs
# a kernel, changes the boot loader, or activates the experimental algorithms.

set -Eeuo pipefail
umask 022

KERNEL_VERSION="${KERNEL_VERSION:-6.18.39}"
JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BUILD_ROOT="${BUILD_ROOT:-$SCRIPT_DIR/build}"
DOWNLOAD_DIR="$BUILD_ROOT/downloads"
SOURCE_DIR="$BUILD_ROOT/linux-$KERNEL_VERSION"
PACKAGE_DIR="$BUILD_ROOT/packages"
GNUPG_DIR="$BUILD_ROOT/gnupg"
ARCHIVE="$DOWNLOAD_DIR/linux-$KERNEL_VERSION.tar.xz"
SIGNATURE="$DOWNLOAD_DIR/linux-$KERNEL_VERSION.tar.sign"
BASE_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x"
PREPARE_ONLY=0

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }

usage() {
	cat <<EOF
Usage: $0 [--prepare-only] [--jobs N] [--build-root DIR]

Builds Linux $KERNEL_VERSION with X420-CC and X420-Q as modules.
It produces Debian packages but deliberately does not install them.

Environment:
  KERNEL_VERSION=6.18.39   Only this audited baseline is accepted.
  JOBS=N                   Parallel build jobs.
  BUILD_ROOT=DIR           Build/download/output directory.
EOF
}

while (($#)); do
	case "$1" in
		--prepare-only)
			PREPARE_ONLY=1
			shift
			;;
		--jobs)
			[[ $# -ge 2 ]] || fail "--jobs requires a value"
			JOBS="$2"
			shift 2
			;;
		--build-root)
			[[ $# -ge 2 ]] || fail "--build-root requires a value"
			mkdir -p -- "$2"
			BUILD_ROOT="$(cd -- "$2" && pwd -P)"
			DOWNLOAD_DIR="$BUILD_ROOT/downloads"
			SOURCE_DIR="$BUILD_ROOT/linux-$KERNEL_VERSION"
			PACKAGE_DIR="$BUILD_ROOT/packages"
			GNUPG_DIR="$BUILD_ROOT/gnupg"
			ARCHIVE="$DOWNLOAD_DIR/linux-$KERNEL_VERSION.tar.xz"
			SIGNATURE="$DOWNLOAD_DIR/linux-$KERNEL_VERSION.tar.sign"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			fail "Unknown argument: $1"
			;;
	esac
done

[[ "$KERNEL_VERSION" == "6.18.39" ]] ||
	fail "The source modules were audited only for Linux 6.18.39."
[[ "$(uname -s)" == "Linux" ]] ||
	fail "Run the build on Linux; the current host is $(uname -s)."
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || fail "JOBS must be a positive integer."

required_tools=(
	bc bison curl dpkg-buildpackage fakeroot flex gcc gpg make openssl
	pahole patch perl rsync tar xz
)
missing=()
for tool in "${required_tools[@]}"; do
	command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if ((${#missing[@]})); then
	fail "Missing build tools: ${missing[*]}. On Debian/Ubuntu install: build-essential bc bison flex libssl-dev libelf-dev dwarves rsync fakeroot dpkg-dev gnupg curl xz-utils."
fi

mkdir -p "$DOWNLOAD_DIR" "$PACKAGE_DIR" "$GNUPG_DIR"
chmod 700 "$GNUPG_DIR"

note "Downloading Linux $KERNEL_VERSION and its detached signature"
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
	-o "$ARCHIVE" "$BASE_URL/linux-$KERNEL_VERSION.tar.xz"
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
	-o "$SIGNATURE" "$BASE_URL/linux-$KERNEL_VERSION.tar.sign"

note "Locating the official stable-maintainer signing keys"
gpg --batch --homedir "$GNUPG_DIR" \
	--auto-key-locate clear,wkd \
	--locate-keys gregkh@kernel.org || true
gpg --batch --homedir "$GNUPG_DIR" \
	--auto-key-locate clear,wkd \
	--locate-keys sashal@kernel.org || true
if ! gpg --batch --homedir "$GNUPG_DIR" --list-keys \
	647F28654894E3BD457199BE38DBBDC86092693E >/dev/null 2>&1 &&
	! gpg --batch --homedir "$GNUPG_DIR" --list-keys \
	E27E5D8A3403A2EF66873BBCDEA66FF797772CDC >/dev/null 2>&1; then
	fail "Could not locate an allow-listed stable-maintainer key."
fi

note "Verifying the uncompressed kernel tar stream"
STATUS_FILE="$BUILD_ROOT/signature.status"
if ! xz --decompress --stdout "$ARCHIVE" |
	gpg --batch --homedir "$GNUPG_DIR" --status-fd 1 \
		--verify "$SIGNATURE" - >"$STATUS_FILE"; then
	fail "Kernel.org signature verification failed."
fi

# Primary fingerprints published by kernel.org for Greg KH and Sasha Levin.
if ! grep -Eq \
	'647F28654894E3BD457199BE38DBBDC86092693E|E27E5D8A3403A2EF66873BBCDEA66FF797772CDC' \
	"$STATUS_FILE"; then
	fail "The signature is valid but not from an allow-listed stable maintainer."
fi

note "Extracting the verified source"
if [[ -e "$SOURCE_DIR" ]]; then
	fail "Source directory already exists: $SOURCE_DIR. Move it aside before rebuilding."
fi
tar --extract --file "$ARCHIVE" --directory "$BUILD_ROOT"
[[ -f "$SOURCE_DIR/Makefile" ]] || fail "Kernel source extraction failed."

note "Adding the X420 congestion-control and queue modules"
install -m 0644 "$SCRIPT_DIR/src/tcp_x420.c" \
	"$SOURCE_DIR/net/ipv4/tcp_x420.c"
install -m 0644 "$SCRIPT_DIR/src/sch_x420q.c" \
	"$SOURCE_DIR/net/sched/sch_x420q.c"
patch --directory "$SOURCE_DIR" --strip=1 --batch --forward \
	<"$SCRIPT_DIR/patches/0001-integrate-x420.patch"

note "Preparing a conservative kernel configuration"
if [[ -r "/boot/config-$(uname -r)" ]]; then
	cp "/boot/config-$(uname -r)" "$SOURCE_DIR/.config"
else
	make --directory "$SOURCE_DIR" defconfig
fi

"$SOURCE_DIR/scripts/config" --file "$SOURCE_DIR/.config" \
	--module TCP_CONG_X420 \
	--module TCP_CONG_BBR \
	--enable NET_SCHED \
	--enable NET_SCH_FQ \
	--module NET_SCH_X420Q \
	--enable CGROUPS \
	--enable CGROUP_BPF \
	--enable BPF \
	--enable BPF_SYSCALL \
	--enable BPF_JIT \
	--enable DEBUG_INFO_BTF \
	--enable TCP_CONG_CUBIC

make --directory "$SOURCE_DIR" olddefconfig

if ((PREPARE_ONLY)); then
	note "Prepared source tree: $SOURCE_DIR"
	exit 0
fi

note "Building Debian packages with $JOBS parallel jobs"
export KBUILD_BUILD_USER=x420
export KBUILD_BUILD_HOST=reproducible-builder
make --directory "$SOURCE_DIR" \
	--jobs "$JOBS" \
	bindeb-pkg \
	LOCALVERSION=-x420 \
	KDEB_PKGVERSION="$KERNEL_VERSION-1"

find "$BUILD_ROOT" -maxdepth 1 -type f \
	\( -name '*.deb' -o -name '*.buildinfo' -o -name '*.changes' \) \
	-exec mv -n {} "$PACKAGE_DIR/" \;

note "Build complete"
printf 'Packages: %s\n' "$PACKAGE_DIR"
printf '%s\n' \
	'No package was installed and no boot-loader entry was changed.' \
	'Install only from a console with a known-good kernel retained.'
