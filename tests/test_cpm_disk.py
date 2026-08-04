from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from tools import cpm_disk


class CpmNameTests(unittest.TestCase):
    def test_name_is_uppercased_and_padded(self) -> None:
        self.assertEqual(
            cpm_disk.cpm_name("read.me"),
            (b"READ    ", b"ME "),
        )

    def test_invalid_names_are_rejected(self) -> None:
        for filename in ("", ".COM", "TOO-LONG-NAME.COM", "FILE.LONG", "A.B.C"):
            with self.subTest(filename=filename):
                with self.assertRaises(cpm_disk.CpmDiskError):
                    cpm_disk.cpm_name(filename)

    def test_non_ascii_name_is_rejected(self) -> None:
        with self.assertRaises(cpm_disk.CpmDiskError):
            cpm_disk.cpm_name("CAFÉ.TXT")


class SectorTranslationTests(unittest.TestCase):
    def test_translation_round_trip(self) -> None:
        logical = bytes(
            index % 251 for index in range(cpm_disk.FLOPPY_SIZE)
        )
        self.assertEqual(
            cpm_disk.raw_to_logical(cpm_disk.logical_to_raw(logical)),
            logical,
        )

    def test_raw_image_size_is_validated(self) -> None:
        with self.assertRaises(cpm_disk.CpmDiskError):
            cpm_disk.raw_to_logical(b"short")


class FloppyImageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)

    def source(self, name: str, data: bytes) -> Path:
        path = self.root / name
        path.write_bytes(data)
        return path

    def directory_entries(self, image_path: Path) -> list[bytes]:
        image = cpm_disk.raw_to_logical(image_path.read_bytes())
        return [
            image[offset : offset + cpm_disk.DIRECTORY_ENTRY_SIZE]
            for offset in range(
                cpm_disk.DIRECTORY_OFFSET,
                cpm_disk.DIRECTORY_OFFSET
                + cpm_disk.DIRECTORY_ENTRIES * cpm_disk.DIRECTORY_ENTRY_SIZE,
                cpm_disk.DIRECTORY_ENTRY_SIZE,
            )
            if image[offset] != cpm_disk.FILL
        ]

    def test_build_is_deterministic_and_extract_preserves_records(self) -> None:
        source = self.source("EXAMPLE.BIN", bytes(range(255)) * 3)
        first = self.root / "first.flp"
        second = self.root / "second.flp"
        extracted = self.root / "extracted.bin"

        cpm_disk.build_floppy(first, [source])
        cpm_disk.build_floppy(second, [source])
        cpm_disk.extract_file(first, source.name, extracted)

        self.assertEqual(first.read_bytes(), second.read_bytes())
        expected_size = (
            (source.stat().st_size + cpm_disk.RECORD_SIZE - 1)
            // cpm_disk.RECORD_SIZE
            * cpm_disk.RECORD_SIZE
        )
        self.assertEqual(extracted.stat().st_size, expected_size)
        self.assertEqual(
            extracted.read_bytes()[: source.stat().st_size], source.read_bytes()
        )

    def test_multi_extent_metadata_encodes_total_record_count(self) -> None:
        sizes = (1, 16 * 1024, 70 * 1024, 128 * 1024)
        sources = [
            self.source(f"SIZE{index}.BIN", bytes([index + 1]) * size)
            for index, size in enumerate(sizes)
        ]
        image = self.root / "sizes.flp"
        cpm_disk.build_floppy(image, sources)

        totals: dict[bytes, int] = {}
        for entry in self.directory_entries(image):
            filename = bytes(value & 0x7F for value in entry[1:12])
            extent = entry[12] | (entry[14] << 5)
            ending_record = extent * 128 + entry[15]
            totals[filename] = max(totals.get(filename, 0), ending_record)

        for source, size in zip(sources, sizes):
            name, extension = cpm_disk.cpm_name(source.name)
            expected_records = max(
                1, (size + cpm_disk.RECORD_SIZE - 1) // cpm_disk.RECORD_SIZE
            )
            self.assertEqual(totals[name + extension], expected_records)

    def test_duplicate_names_and_full_media_are_rejected(self) -> None:
        upper = self.source("DUP.BIN", b"one")
        lower = self.source("dup.bin", b"two")
        with self.assertRaises(cpm_disk.CpmDiskError):
            cpm_disk.build_floppy(self.root / "duplicate.flp", [upper, lower])

        huge = self.source(
            "HUGE.BIN", bytes(cpm_disk.FLOPPY_SIZE)
        )
        with self.assertRaises(cpm_disk.CpmDiskError):
            cpm_disk.build_floppy(self.root / "full.flp", [huge])

    def test_missing_file_cannot_be_extracted(self) -> None:
        source = self.source("FOUND.BIN", b"found")
        image = self.root / "one.flp"
        cpm_disk.build_floppy(image, [source])
        with self.assertRaises(cpm_disk.CpmDiskError):
            cpm_disk.extract_file(image, "MISSING.BIN", self.root / "missing")


if __name__ == "__main__":
    unittest.main()
