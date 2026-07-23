# P2000C File Manager

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
| Q | Return to CP/M |

Copying never silently replaces a file: P2FILE asks for confirmation for each
destination filename that already exists.

## Building

### Automated build and smoke test

The automated build uses the P2000C emulator to run the original Digital
Research `ASM.COM` and `LOAD.COM` under CP/M. It then launches P2FILE, verifies
that both drive panels appear, and exits cleanly before publishing the
artifacts.

Requirements:

- Bash
- Python 3
- CMake
- A checkout of
  [ifilot/p2000c-emulator](https://github.com/ifilot/p2000c-emulator) containing
  its CP/M system image and original Digital Research tools

By default, the build expects `p2000c-emulator` beside this repository:

```text
P2000C/
|-- p2000c-emulator/
`-- p2000c-file/
```

Run:

```sh
./scripts/build.sh
```

For another checkout location:

```sh
P2000C_EMULATOR_DIR=/path/to/p2000c-emulator ./scripts/build.sh
```

The script creates `dist/p2file.flp`, extracts `dist/P2FILE.COM`, and rewrites
`dist/SHA256SUMS`. An existing emulator CLI can be selected with
`P2000C_CLI=/path/to/p2000c_cli`.

### Build directly under CP/M

Put `src/P2FILE.ASM`, `ASM.COM`, and `LOAD.COM` on a CP/M disk, then run:

```text
B>ASM P2FILE
B>LOAD P2FILE
B>P2FILE
```

`ASM` produces `P2FILE.HEX` and `P2FILE.PRN`; `LOAD` produces `P2FILE.COM`.
The source deliberately uses CP/M CR/LF line endings and ends with a `1Ah`
marker.

## Repository layout

```text
.
|-- dist/               Ready-to-use COM file, floppy, and checksums
|-- scripts/
|   `-- build.sh        Emulator-driven build and smoke test
|-- src/
|   `-- P2FILE.ASM      Canonical Intel 8080 source
|-- tools/
|   `-- cpm_disk.py     Deterministic P2000C CP/M disk builder/extractor
|-- LICENSE
`-- README.md
```

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
resolved and cached one visible row at a time. Only the 22 on-screen rows are
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
24-row layout provides 22 file rows and keeps the key table on the bottom row.

## Emulator integration

The P2000C emulator can embed `dist/p2file.flp` in its application resources.
After rebuilding P2FILE, copy the floppy to the emulator's
`images/cpm/p2file.flp`, then rebuild and fully restart the emulator. An
already-running executable retains its older embedded floppy and writable
session copy.

## License

P2000C File Manager is distributed under the GNU General Public License
version 3. See [LICENSE](LICENSE).
