#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
assembler_root=${P2000C_ASM_DIR:-"${repo_root}/../p2000c-asm"}
output=${1:-"${repo_root}/dist/p2file.flp"}
com_output="$(dirname -- "${output}")/P2FILE.COM"

assembler=${P2000C_ASSEMBLER:-}
fallback_build_dir="${repo_root}/.cache/p2000c-asm-build"
source_asm="${repo_root}/src/P2FILE.ASM"
cpm_tool="${repo_root}/tools/cpm_disk.py"
version_file="${repo_root}/VERSION"

version="$(tr -d '[:space:]' <"${version_file}")"
if [[ ! "${version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
  printf 'VERSION is not a semantic version: %s\n' "${version}" >&2
  exit 1
fi
if ((${#version} > 6)); then
  printf 'VERSION is too long for the fixed 80-column app layout: %s\n' \
    "${version}" >&2
  exit 1
fi
for embedded_version in \
  "APPVER: DB      '${version}',0" \
  "DB      'v${version}',0" \
  "TOPVER: DB      '${version}',0" \
  "APPNAME:DB      'P2FILE v${version}',0"; do
  if ! grep -Fq "${embedded_version}" "${source_asm}"; then
    printf 'App version in %s does not match VERSION (%s).\n' \
      "${source_asm}" "${version}" >&2
    exit 1
  fi
done

find_assembler() {
  local candidate
  for candidate in \
    "${assembler_root}/build/p2000c-asm" \
    "${assembler_root}/build/p2000c-asm.exe" \
    "${assembler_root}/build/Release/p2000c-asm.exe" \
    "${fallback_build_dir}/p2000c-asm" \
    "${fallback_build_dir}/p2000c-asm.exe" \
    "${fallback_build_dir}/Release/p2000c-asm.exe"; do
    if [[ -x "${candidate}" ]]; then
      assembler=${candidate}
      return 0
    fi
  done
  return 1
}

if [[ -z "${assembler}" ]] && ! find_assembler; then
  if [[ ! -f "${assembler_root}/CMakeLists.txt" ]]; then
    printf 'p2000c-asm source not found at %s.\n' "${assembler_root}" >&2
    printf 'Set P2000C_ASM_DIR or P2000C_ASSEMBLER to override it.\n' >&2
    exit 1
  fi
  cmake -S "${assembler_root}" -B "${fallback_build_dir}" \
    -DCMAKE_BUILD_TYPE=Release
  cmake --build "${fallback_build_dir}" --target p2000c-asm --config Release
  find_assembler || true
fi

if [[ ! -x "${assembler}" ]]; then
  printf 'Assembler is not executable: %s\n' "${assembler}" >&2
  exit 1
fi

for required_file in "${source_asm}" "${cpm_tool}"; do
  if [[ ! -f "${required_file}" ]]; then
    printf 'Missing required file: %s\n' "${required_file}" >&2
    exit 1
  fi
done

work_dir="$(mktemp -d)"
trap 'rm -rf -- "${work_dir}"' EXIT
work_disk="${work_dir}/p2file.flp"
compiled_com="${work_dir}/P2FILE.COM"
extracted_com="${work_dir}/extracted-P2FILE.COM"

if ! "${assembler}" -o "${compiled_com}" "${source_asm}"; then
  printf 'P2FILE assembly failed.\n' >&2
  exit 1
fi

python3 "${cpm_tool}" build "${work_disk}" "${compiled_com}"
python3 "${cpm_tool}" extract "${work_disk}" P2FILE.COM "${extracted_com}"
if ! cmp -s "${compiled_com}" "${extracted_com}"; then
  printf 'P2FILE.COM changed while packaging the floppy image.\n' >&2
  exit 1
fi

mkdir -p -- "$(dirname -- "${output}")" "$(dirname -- "${com_output}")"
cp -- "${work_disk}" "${output}"
cp -- "${compiled_com}" "${com_output}"
cp -- "${version_file}" "$(dirname -- "${output}")/VERSION"

manifest="$(dirname -- "${output}")/SHA256SUMS"
image_hash="$(sha256sum "${output}")"
com_hash="$(sha256sum "${com_output}")"
version_hash="$(sha256sum "$(dirname -- "${output}")/VERSION")"
{
  printf '%s  %s\n' "${image_hash%% *}" "$(basename -- "${output}")"
  printf '%s  %s\n' "${com_hash%% *}" "$(basename -- "${com_output}")"
  printf '%s  VERSION\n' "${version_hash%% *}"
} >"${manifest}"

printf 'Created %s\n' "${output}"
printf 'Created %s\n' "${com_output}"
printf 'Version %s\n' "${version}"
printf 'Checks: standalone assembly, floppy packaging, extracted COM match\n'
