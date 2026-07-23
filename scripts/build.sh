#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
emulator_root=${P2000C_EMULATOR_DIR:-"${repo_root}/../p2000c-emulator"}
output=${1:-"${repo_root}/dist/p2file.flp"}
com_output="$(dirname -- "${output}")/P2FILE.COM"

build_dir="${emulator_root}/build"
cli=${P2000C_CLI:-}
ipl="${emulator_root}/tools/ipldump/IPLDUMP.BIN"
system_disk="${emulator_root}/images/cpm/system.flp"
asm_com="${emulator_root}/media/files/core/ASM.COM"
load_com="${emulator_root}/media/files/core/LOAD.COM"
source_asm="${repo_root}/src/P2FILE.ASM"
cpm_tool="${repo_root}/tools/cpm_disk.py"

find_cli() {
  local candidate
  for candidate in \
    "${build_dir}/p2000c_cli" \
    "${build_dir}/p2000c_cli.exe" \
    "${build_dir}/Release/p2000c_cli.exe"; do
    if [[ -x "${candidate}" ]]; then
      cli=${candidate}
      return 0
    fi
  done
  return 1
}

if [[ -z "${cli}" ]] && ! find_cli; then
  if [[ ! -f "${build_dir}/CMakeCache.txt" ]]; then
    cmake -S "${emulator_root}" -B "${build_dir}" -DP2000C_BUILD_APP=OFF
  fi
  cmake --build "${build_dir}" --target p2000c_cli --config Release
  find_cli || true
fi

for required_file in \
  "${cli}" "${ipl}" "${system_disk}" "${asm_com}" "${load_com}" \
  "${source_asm}" "${cpm_tool}"; do
  if [[ ! -f "${required_file}" ]]; then
    printf 'Missing required file: %s\n' "${required_file}" >&2
    exit 1
  fi
done

work_dir="$(mktemp -d)"
trap 'rm -rf -- "${work_dir}"' EXIT
work_disk="${work_dir}/p2file.flp"
build_log="${work_dir}/p2file-build.log"
extracted_com="${work_dir}/P2FILE.COM"

python3 "${cpm_tool}" build "${work_disk}" \
  "${asm_com}" "${load_com}" "${source_asm}"

if ! "${cli}" \
  --ipl "${ipl}" \
  --floppy-a "${system_disk}" \
  --floppy-b "${work_disk}" \
  --write-through \
  --fast-storage \
  --wait-cycles 1000000000 \
  --wait-for 'A>' \
  --send 'B:\rASM P2FILE\r' \
  --wait-for 'END OF ASSEMBLY' \
  --run 5000000 \
  --send 'LOAD P2FILE\r' \
  --wait-for 'FIRST ADDRESS' \
  --run 5000000 \
  --send 'P2FILE\r' \
  --wait-for 'P2FILE: READING DRIVE A:' \
  --wait-for 'P2FILE: READING DRIVE B:' \
  --run 20000000 \
  --wait-for 'DRIVE B:    6 FILES' \
  --wait-for 'Q QUIT' \
  --wait-for 'P2FILE  .COM     5K' \
  --send 'Q' \
  --wait-for 'P2FILE finished.' \
  --wait-for 'B>' \
  --output text >"${build_log}" 2>&1; then
  printf 'P2000C File build or smoke test failed. Emulator output follows:\n' >&2
  sed -n '1,260p' "${build_log}" >&2
  exit 1
fi

python3 "${cpm_tool}" extract "${work_disk}" P2FILE.COM "${extracted_com}"
mkdir -p -- "$(dirname -- "${output}")" "$(dirname -- "${com_output}")"
cp -- "${work_disk}" "${output}"
cp -- "${extracted_com}" "${com_output}"

manifest="$(dirname -- "${output}")/SHA256SUMS"
image_hash="$(sha256sum "${output}")"
com_hash="$(sha256sum "${com_output}")"
{
  printf '%s  %s\n' "${image_hash%% *}" "$(basename -- "${output}")"
  printf '%s  %s\n' "${com_hash%% *}" "$(basename -- "${com_output}")"
} >"${manifest}"

printf 'Created %s\n' "${output}"
printf 'Created %s\n' "${com_output}"
printf 'Smoke tests: CP/M assembly, load, startup, both drive panels, clean exit\n'
