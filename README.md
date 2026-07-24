# P2000C File Manager

[![Build and release](https://github.com/ifilot/p2000c-file/actions/workflows/build.yml/badge.svg)](https://github.com/ifilot/p2000c-file/actions/workflows/build.yml)
[![Version 0.1.0](https://img.shields.io/badge/version-0.1.0-blue.svg)](VERSION)
[![License: GPL v3](https://img.shields.io/badge/license-GPLv3-blue.svg)](LICENSE)

P2000C File Manager is a compact two-panel file manager for CP/M 2.2 on the
Philips P2000C. The executable is named `P2FILE.COM` to fit CP/M's 8.3
filenames.

P2FILE is written entirely in Intel 8080 assembly and uses only documented
CP/M BDOS calls and Philips P2000C terminal controls.

## Highlights

- Two independently selectable drive panels
- Incrementally resolved file sizes for the visible rows
- Multi-file marking, copying, deleting, and renaming
- Per-file and overall copy progress
- Buffered 4 KiB disk-to-disk transfers
- Explicit overwrite confirmation
- Drives A through F
- Compact 24-row P2000C display
- Built-in help with project and license information

## Keyboard

P2FILE is designed for the P2000C UK/NL keyboard table.

| Key | Action |
| --- | --- |
| Tab | Activate the other panel |
| UK/NL cursor Up / Down (`05h` / `18h`) | Move the cursor |
| W / S | Compatibility aliases for moving up or down |
| Space | Mark or unmark a file |
| C | Copy marked files, or the current file |
| D | Delete marked files, or the current file |
| R | Rename the current file |
| V | Select drive A through F for the active panel |
| H | Open the help screen |
| Q | Return to CP/M |

Copying never silently replaces a file: P2FILE asks for confirmation for each
destination filename that already exists.

## Building

### Automated build

The build uses
[ifilot/p2000c-asm](https://github.com/ifilot/p2000c-asm), a standalone
minimal assembler that runs the original Digital Research `ASM.COM` and
`LOAD.COM` on an emulated Z80 without booting the P2000C emulator. The build
then creates a deterministic CP/M floppy and verifies that extracting
`P2FILE.COM` from it produces the original assembled bytes.

Requirements:

- Bash
- Python 3
- CMake
- A C/C++ compiler
- A checkout of `p2000c-asm`

By default, the build expects `p2000c-asm` beside this repository:

```text
P2000C/
|-- p2000c-asm/
`-- p2000c-file/
```

The script uses an existing `p2000c-asm` build when available. Otherwise, it
builds the assembler from the sibling checkout into `.cache/`.

Run:

```sh
./scripts/build.sh
```

For another checkout location:

```sh
P2000C_ASM_DIR=/path/to/p2000c-asm ./scripts/build.sh
```

An existing assembler executable can be selected directly:

```sh
P2000C_ASSEMBLER=/path/to/p2000c-asm ./scripts/build.sh
```

The script creates `dist/p2file.flp`, `dist/P2FILE.COM`, `dist/SHA256SUMS`,
and `dist/VERSION`.

### Continuous integration and releases

GitHub Actions builds the latest default branch of `ifilot/p2000c-asm`, runs
its tests, and uses it to compile and package P2FILE on every push and pull
request. Every build publishes the generated files as workflow artifacts.

### Running in the graphical emulator

After building P2FILE, launch it directly in the graphical emulator:

```sh
./run.sh
```

The script assumes `p2000c-emulator` is beside this repository. It mounts the
emulator's CP/M system disk as A:, mounts `dist/p2file.flp` as B:, and runs
`B:P2FILE` automatically. Override the sibling checkout or GUI executable with
`P2000C_EMULATOR_DIR` or `P2000C_GUI`.

Hard disks can optionally be mounted at launch:

```sh
P2000C_HARD_DISK_0=/path/to/disk-0.hda \
P2000C_HARD_DISK_1=/path/to/disk-1.hda \
./run.sh
```

Additional arguments supplied to `run.sh` are passed to the emulator.

## Design

### Startup and drive access

The shell and A: panel are drawn before P2FILE reads B:. A status line identifies
the drive currently being accessed. If CP/M or the BIOS stops while accessing
media, the completed panel and last visible drive letter show where it failed.

The drive menu deliberately does not probe every configured drive. Under CP/M
2.2, selecting unreadable or absent media may enter the BIOS disk-error path
instead of returning an error to P2FILE. Insert or mount the desired disk before
selecting its drive letter.

### Incremental file sizes

Both panels appear immediately with `?K` placeholders. Exact sizes are then
resolved and cached one visible row at a time. Only the 21 on-screen rows are
considered. Scrolling resolves newly exposed rows while retaining cached sizes
for rows that remain visible.

### Buffered copying and progress

P2FILE reads up to 32 sequential 128-byte CP/M records into a 4 KiB RAM buffer,
then writes that batch to the destination. This avoids switching source and
destination media after every record. The copy dialog shows the current
filename, its position in the selected batch, and records copied for that file;
it refreshes after every 4 KiB batch and at end-of-file.

### Display updates

Panel headers and the active panel's current row use inverse video. Ordinary
cursor movement updates only the old row, new row, and changing header fields.
Crossing a window boundary redraws only that panel's file rows. The compact
24-row layout provides 21 file rows and reserves the bottom two rows for the
key table, status messages, and application version.

## Emulator integration

The P2000C emulator can embed `dist/p2file.flp` in its application resources.
After rebuilding P2FILE, copy the floppy to the emulator's
`images/cpm/p2file.flp`, then rebuild and fully restart the emulator. An
already-running executable retains its older embedded floppy and writable
session copy.

## License

P2000C File Manager is distributed under the GNU General Public License
version 3. See [LICENSE](LICENSE).
