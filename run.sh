#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
emulator_root=${P2000C_EMULATOR_DIR:-"${script_dir}/../p2000c-emulator"}
gui=${P2000C_GUI:-}

system_disk="${emulator_root}/images/cpm/system.flp"
app_disk="${script_dir}/dist/p2file.flp"

find_gui() {
  local candidate
  for candidate in \
    "${emulator_root}/build/p2000c" \
    "${emulator_root}/build/p2000c.exe" \
    "${emulator_root}/build/Release/p2000c.exe"; do
    if [[ -x "${candidate}" ]]; then
      gui=${candidate}
      return 0
    fi
  done
  return 1
}

if [[ -z "${gui}" ]] && ! find_gui; then
  printf 'P2000C GUI executable not found under %s/build.\n' \
    "${emulator_root}" >&2
  printf 'Build the emulator or set P2000C_GUI to its executable.\n' >&2
  exit 1
fi

for required_file in "${gui}" "${system_disk}" "${app_disk}"; do
  if [[ ! -f "${required_file}" ]]; then
    printf 'Missing required file: %s\n' "${required_file}" >&2
    if [[ "${required_file}" == "${app_disk}" ]]; then
      printf 'Run ./scripts/build.sh first.\n' >&2
    fi
    exit 1
  fi
done

launch_args=(
  --floppy-a "${system_disk}"
  --floppy-b "${app_disk}"
)

if [[ -n "${P2000C_HARD_DISK_0:-}" ]]; then
  if [[ ! -f "${P2000C_HARD_DISK_0}" ]]; then
    printf 'Missing hard disk image: %s\n' "${P2000C_HARD_DISK_0}" >&2
    exit 1
  fi
  launch_args+=(--hard-disk-0 "${P2000C_HARD_DISK_0}")
fi

if [[ -n "${P2000C_HARD_DISK_1:-}" ]]; then
  if [[ ! -f "${P2000C_HARD_DISK_1}" ]]; then
    printf 'Missing hard disk image: %s\n' "${P2000C_HARD_DISK_1}" >&2
    exit 1
  fi
  launch_args+=(--hard-disk-1 "${P2000C_HARD_DISK_1}")
fi

launch_args+=(--autorun "B:P2FILE")

exec "${gui}" "${launch_args[@]}" "$@"
