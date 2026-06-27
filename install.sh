#!/usr/bin/env bash
set -Eeuo pipefail

REPO_RAW_BASE="${X420_RAW_BASE:-https://raw.githubusercontent.com/ericyiu9819/x420/main}"
PART_PREFIX="${REPO_RAW_BASE}/dist/c-vless-fastrelay-deploy.sh.b64"
PART_COUNT="${X420_PART_COUNT:-7}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing command: %s\n' "$1" >&2
    exit 1
  }
}

decode_base64() {
  if base64 --help 2>&1 | grep -q -- '--decode'; then
    base64 --decode
  else
    base64 -d
  fi
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

need_cmd curl
need_cmd base64
need_cmd bash

for i in $(seq 0 $((PART_COUNT - 1))); do
  part="$(printf '%02d' "${i}")"
  curl -fsSL "${PART_PREFIX}.${part}" >>"${tmp_dir}/payload.b64"
done

decode_base64 <"${tmp_dir}/payload.b64" >"${tmp_dir}/c-vless-fastrelay-deploy.sh"
chmod 700 "${tmp_dir}/c-vless-fastrelay-deploy.sh"
bash -n "${tmp_dir}/c-vless-fastrelay-deploy.sh"
exec bash "${tmp_dir}/c-vless-fastrelay-deploy.sh" "$@"
