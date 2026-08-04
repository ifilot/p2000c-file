from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools import cpm_disk


ROOT = Path(__file__).resolve().parents[1]
ASM_SOURCE = ROOT / "src" / "P2FILE.ASM"
VERSION = (ROOT / "VERSION").read_text(encoding="ascii").strip()


def first_executable(*candidates: Path | None) -> Path | None:
    for candidate in candidates:
        if candidate is not None and candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


def environment_path(name: str) -> Path | None:
    value = os.environ.get(name)
    return Path(value) if value else None


ASSEMBLER = first_executable(
    environment_path("P2000C_ASSEMBLER"),
    ROOT.parent / "p2000c-asm" / "build" / "p2000c-asm",
    ROOT.parent / "p2000c-asm" / "build" / "p2000c-asm.exe",
)
EMULATOR_ROOT = Path(
    os.environ.get("P2000C_EMULATOR_DIR", ROOT.parent / "p2000c-emulator")
)
EMULATOR = first_executable(
    environment_path("P2000C_CLI"),
    EMULATOR_ROOT / "build" / "p2000c_cli",
    EMULATOR_ROOT / "build" / "p2000c_cli.exe",
)
IPL = EMULATOR_ROOT / "tools" / "ipldump" / "IPLDUMP.BIN"
SYSTEM_DISK = EMULATOR_ROOT / "assets" / "images" / "cpm" / "system.flp"


class SourceTests(unittest.TestCase):
    def test_startup_updates_right_panel_without_second_shell_clear(self) -> None:
        source = ASM_SOURCE.read_text(encoding="ascii", errors="ignore")
        startup = source.split("START:", 1)[1].split("MAIN:", 1)[0]
        self.assertEqual(startup.count("CALL    DRAWSHELL"), 1)
        self.assertIn("CALL    DRAWR", startup)
        self.assertIn("CALL    DRAWFOOT", startup)
        self.assertIn("JMP     KEYLOOP", startup)

    def test_cursor_is_hidden_on_entry_and_restored_on_quit(self) -> None:
        source = ASM_SOURCE.read_text(encoding="ascii", errors="ignore")
        startup = source.split("START:", 1)[1].split("MAIN:", 1)[0]
        quit_path = source.split("KQUIT:", 1)[1].split(
            "; ---------------------------------------------------------------------------",
            1,
        )[0]
        self.assertIn("CALL    CURSOFF", startup)
        self.assertIn("CALL    CURSON", quit_path)
        self.assertIn("CURSOFF:MVI     A,1BH", source)
        self.assertIn("MVI     A,'c'", source)
        self.assertIn("CURSON: MVI     A,1BH", source)
        self.assertIn("MVI     A,'C'", source)

    def test_rename_input_shows_and_then_hides_cursor(self) -> None:
        source = ASM_SOURCE.read_text(encoding="ascii", errors="ignore")
        rename_input = source.split("GETNEW:", 1)[1].split("PARSENEW:", 1)[0]
        self.assertIn("CALL    CURSON\nGNKEY:", rename_input)
        self.assertIn("GNDONE: CALL    CURSOFF", rename_input)
        self.assertIn("GNCANCEL:\n        CALL    CURSOFF", rename_input)

    def test_shared_modal_uses_normal_video_mosaic_outline(self) -> None:
        source = ASM_SOURCE.read_text(encoding="ascii", errors="ignore")
        modal = source.split("MODBOX:", 1)[1].split("SHOWCOPY:", 1)[0]
        self.assertIn("MVI     A,NORMATT", modal)
        self.assertNotIn("INVATT", modal)
        for glyph in (
            "BOXTL",
            "BOXH",
            "BOXTR",
            "BOXL",
            "BOXR",
            "BOXBL",
            "BOXB",
            "BOXBR",
        ):
            with self.subTest(glyph=glyph):
                self.assertIn(f"MVI     A,{glyph}", modal)
        self.assertEqual(source.count("CALL    MODBOX"), 5)

    def test_embedded_versions_match_version_file(self) -> None:
        source = ASM_SOURCE.read_text(encoding="ascii", errors="ignore")
        for declaration in (
            f"APPVER: DB      '{VERSION}',0",
            f"DB      'v{VERSION}',0",
            f"TOPVER: DB      '{VERSION}',0",
            f"APPNAME:DB      'P2FILE v{VERSION}',0",
        ):
            with self.subTest(declaration=declaration):
                self.assertIn(declaration, source)


@unittest.skipUnless(ASSEMBLER, "p2000c-asm is not available")
class AssemblyTests(unittest.TestCase):
    def test_program_assembles_and_has_safe_runtime_headroom(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "P2FILE.COM"
            subprocess.run(
                [
                    str(ASSEMBLER),
                    "--keep-intermediates",
                    "-o",
                    str(output),
                    str(ASM_SOURCE),
                ],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            listing = output.with_suffix(".PRN").read_text(
                encoding="ascii", errors="ignore"
            )
            matches = re.findall(
                r"^\s*([0-9A-F]{4})\s+END\s+START", listing, re.MULTILINE
            )
            self.assertEqual(len(matches), 1)
            runtime_end = int(matches[0], 16)
            self.assertLess(runtime_end, 0xE000)
            self.assertGreaterEqual(0xE000 - runtime_end, 24 * 1024)
            self.assertGreater(output.stat().st_size, 0)


@unittest.skipUnless(
    ASSEMBLER and EMULATOR and IPL.is_file() and SYSTEM_DISK.is_file(),
    "p2000c assembler/emulator integration dependencies are not available",
)
class EmulatorIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary_directory = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temporary_directory.name)
        cls.program = cls.root / "P2FILE.COM"
        subprocess.run(
            [str(ASSEMBLER), "-o", str(cls.program), str(ASM_SOURCE)],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary_directory.cleanup()

    def make_file(self, name: str, size: int, fill: int = 0x5A) -> Path:
        path = self.root / name
        path.write_bytes(bytes([fill]) * size)
        return path

    def make_disk(self, name: str, files: list[Path]) -> Path:
        disk = self.root / name
        cpm_disk.build_floppy(disk, files)
        return disk

    def run_app(self, disk: Path, *actions: str) -> dict[str, object]:
        command = [
            str(EMULATOR),
            "--ipl",
            str(IPL),
            "--floppy-a",
            str(SYSTEM_DISK),
            "--floppy-b",
            str(disk),
            "--fast-storage",
            "--wait-for",
            "A>",
            "--send",
            "B:P2FILE\\r",
            "--wait-for",
            f"P2FILE v{VERSION}",
            # The footer appears while DRAW is still completing. Let the app
            # reach GETKEY before injecting an operation.
            "--run",
            "10000000",
        ]
        command.extend(actions)
        command.extend(("--output", "json"))
        result = subprocess.run(
            command,
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(result.stdout)

    def screen(self, result: dict[str, object]) -> str:
        return "\n".join(result["screen"])

    def assert_modal_outline(self, result: dict[str, object]) -> None:
        screen = result["screen"]
        self.assertEqual(ord(screen[8][20]), 0x17)
        self.assertEqual({ord(value) for value in screen[8][21:59]}, {0x03})
        self.assertEqual(ord(screen[8][59]), 0x8B)
        for row in range(9, 13):
            self.assertEqual(ord(screen[row][20]), 0x15)
            self.assertEqual(ord(screen[row][59]), 0x8A)
        self.assertEqual(ord(screen[13][20]), 0x95)
        self.assertEqual({ord(value) for value in screen[13][21:59]}, {0x90})
        self.assertEqual(ord(screen[13][59]), 0x9A)

    def test_single_scan_aggregates_hash_collisions_and_extents(self) -> None:
        files = [
            self.program,
            self.make_file("ABC.BIN", 1, 1),
            self.make_file("ACB.BIN", 16 * 1024, 2),
            self.make_file("MULTI.BIN", 70 * 1024, 3),
            self.make_file("TWOEXT.BIN", 128 * 1024, 4),
        ]
        result = self.run_app(self.make_disk("sizes.flp", files))
        screen = self.screen(result)

        self.assertIn("DRIVE B:    5 FILES", screen)
        self.assertRegex(screen, r"ABC\s+\.BIN\s+1K")
        self.assertRegex(screen, r"ACB\s+\.BIN\s+16K")
        self.assertRegex(screen, r"MULTI\s+\.BIN\s+70K")
        self.assertRegex(screen, r"TWOEXT\s+\.BIN\s+128K")
        self.assertNotIn("?K", screen)

    def test_cursor_is_hidden_in_app_and_restored_for_cpm(self) -> None:
        disk = self.make_disk("cursor.flp", [self.program])
        running = self.run_app(disk)
        self.assertFalse(running["cursor"]["visible"])

        exited = self.run_app(
            disk,
            "--send",
            "Q",
            "--wait-for",
            "A>",
        )
        self.assertTrue(exited["cursor"]["visible"])

    def test_cursor_is_visible_only_while_entering_rename(self) -> None:
        disk = self.make_disk("rename-cursor.flp", [self.program])
        editing = self.run_app(
            disk,
            "--send",
            "R",
            "--wait-for",
            "New name (ESC cancels):",
            "--run",
            "1000000",
        )
        self.assertTrue(editing["cursor"]["visible"])

        cancelled = self.run_app(
            disk,
            "--send",
            "R",
            "--wait-for",
            "New name (ESC cancels):",
            "--run",
            "1000000",
            "--send",
            "\\x1b",
            "--run",
            "5000000",
        )
        self.assertFalse(cancelled["cursor"]["visible"])

    def test_raw_scan_excludes_other_cpm_users(self) -> None:
        visible = self.make_file("VISIBLE.BIN", 1, 1)
        disk = self.make_disk("users.flp", [self.program, visible])
        logical = bytearray(cpm_disk.raw_to_logical(disk.read_bytes()))
        source_offset = cpm_disk.DIRECTORY_OFFSET + cpm_disk.DIRECTORY_ENTRY_SIZE
        hidden_offset = source_offset + cpm_disk.DIRECTORY_ENTRY_SIZE
        logical[hidden_offset : hidden_offset + cpm_disk.DIRECTORY_ENTRY_SIZE] = (
            logical[source_offset : source_offset + cpm_disk.DIRECTORY_ENTRY_SIZE]
        )
        logical[hidden_offset] = 1
        logical[hidden_offset + 1 : hidden_offset + 9] = b"HIDDEN  "
        disk.write_bytes(cpm_disk.logical_to_raw(logical))

        screen = self.screen(self.run_app(disk))
        self.assertIn("DRIVE B:    2 FILES", screen)
        self.assertRegex(screen, r"VISIBLE\s+\.BIN\s+1K")
        self.assertNotIn("HIDDEN", screen)

    def test_panels_share_catalog_but_keep_independent_marks(self) -> None:
        disk = self.make_disk("shared.flp", [self.program])
        screen = self.screen(
            self.run_app(
                disk,
                "--send",
                "V",
                "--wait-for",
                "SELECT DRIVE",
                "--run",
                "1000000",
                "--send",
                "B",
                "--run",
                "10000000",
                "--send",
                " ",
                "--run",
                "5000000",
            )
        )
        self.assertIn("* DRIVE B:    1 FILES", screen)
        first_file_row = screen.splitlines()[1]
        self.assertRegex(first_file_row[:40], r">\* P2FILE\s+\.COM")
        self.assertNotIn("* P2FILE", first_file_row[40:])

    def test_drive_dialog_uses_mosaic_outline(self) -> None:
        disk = self.make_disk("dialog.flp", [self.program])
        result = self.run_app(
            disk,
            "--send",
            "V",
            "--wait-for",
            "SELECT DRIVE",
            "--run",
            "1000000",
        )
        self.assert_modal_outline(result)
        self.assertIn("SELECT DRIVE", self.screen(result))

    def test_catalog_accepts_all_128_directory_entries(self) -> None:
        files = [self.program]
        files.extend(
            self.make_file(f"F{index:07d}.BIN", 0, index & 0xFF)
            for index in range(127)
        )
        actions = [
            "--wait-for",
            "F0000019.BIN",
            "--run",
            "10000000",
            "--send",
            "\\t",
            "--run",
            "10000000",
        ]
        # The emulated keyboard interface has a deliberately shallow FIFO.
        # Pace navigation keys so a long burst cannot be dropped.
        for _ in range(127):
            actions.extend(("--send", "S", "--run", "4000000"))
        actions.extend(("--run", "10000000"))
        result = self.run_app(
            self.make_disk("full-directory.flp", files), *actions
        )
        screen = self.screen(result)

        self.assertIn("DRIVE B:  128 FILES 128/128", screen)
        self.assertIn("F0000126.BIN", screen.replace(" ", ""))

    def test_cache_is_refreshed_after_copy_delete_and_rename(self) -> None:
        disk = self.make_disk("operations.flp", [self.program])

        copied_result = self.run_app(
            disk,
            "--send",
            "C",
            "--run",
            "10000000",
        )
        copied = self.screen(copied_result)
        self.assert_modal_outline(copied_result)
        self.assertIn("DRIVE B:    2 FILES", copied)
        self.assertRegex(copied, r"CPM61\s+\.COM\s+6K")
        self.assertIn("Copy complete.", copied)

        deleted = self.screen(
            self.run_app(
                disk,
                "--send",
                "D",
                "--run",
                "3000000",
                "--send",
                "Y",
                "--run",
                "10000000",
            )
        )
        self.assertIn("DRIVE A:   15 FILES", deleted)
        self.assertNotRegex(deleted, r"CPM61\s+\.COM")
        self.assertIn("Delete complete.", deleted)

        rename_actions = [
            "--send",
            "R",
            "--wait-for",
            "New name (ESC cancels):",
            "--run",
            "1000000",
        ]
        for character in "RENAMED.COM":
            rename_actions.extend(("--send", character, "--run", "500000"))
        rename_actions.extend(("--send", "\\r", "--run", "10000000"))
        renamed_result = self.run_app(disk, *rename_actions)
        renamed = self.screen(renamed_result)
        self.assertRegex(renamed, r"RENAMED\s+\.COM\s+6K")
        self.assertNotRegex(renamed, r"CPM61\s+\.COM")
        self.assertIn("Rename complete.", renamed)
        self.assertFalse(renamed_result["cursor"]["visible"])


if __name__ == "__main__":
    unittest.main()
