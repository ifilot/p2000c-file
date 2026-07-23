#!/usr/bin/env python3
"""Build and inspect Philips P2000C 640 KiB CP/M data floppies."""

from __future__ import annotations

import argparse
from pathlib import Path


SECTOR_SIZE = 256
FLOPPY_SIZE = 640 * 1024
SYSTEM_SIZE = 8 * 1024
DIRECTORY_OFFSET = SYSTEM_SIZE
DIRECTORY_ENTRIES = 128
DIRECTORY_ENTRY_SIZE = 32
BLOCK_SIZE = 4096
MAX_BLOCK = 157
RECORD_SIZE = 128
RECORDS_PER_DIRECTORY_EXTENT = 512
FILL = 0xE5
RECORD_FILL = 0x1A

# The 640 KiB CBIOS sector-translation table visits odd physical sector IDs
# first, followed by even IDs, for one logical 4 KiB track.
SECTOR_INTERLEAVE = tuple(range(0, 16, 2)) + tuple(range(1, 16, 2))


class CpmDiskError(ValueError):
    """Raised when a file or image cannot use the confirmed P2000C layout."""


def cpm_name(filename: str) -> tuple[bytes, bytes]:
    """Return a padded CP/M 8.3 name."""
    parts = filename.upper().split(".")
    if len(parts) > 2 or not parts[0] or len(parts[0]) > 8:
        raise CpmDiskError(f"{filename!r} is not a CP/M 8.3 filename")
    extension = parts[1] if len(parts) == 2 else ""
    if len(extension) > 3:
        raise CpmDiskError(f"{filename!r} is not a CP/M 8.3 filename")
    try:
        return (
            parts[0].encode("ascii").ljust(8),
            extension.encode("ascii").ljust(3),
        )
    except UnicodeEncodeError as exc:
        raise CpmDiskError(f"{filename!r} is not an ASCII filename") from exc


def logical_to_raw(image: bytes) -> bytes:
    """Apply the P2000C sector translation to a logical data-disk image."""
    raw = bytearray([FILL]) * FLOPPY_SIZE
    track_size = 16 * SECTOR_SIZE
    for track in range(FLOPPY_SIZE // track_size):
        track_start = track * track_size
        for logical_sector, physical_sector in enumerate(SECTOR_INTERLEAVE):
            logical_start = track_start + logical_sector * SECTOR_SIZE
            physical_start = track_start + physical_sector * SECTOR_SIZE
            raw[physical_start : physical_start + SECTOR_SIZE] = image[
                logical_start : logical_start + SECTOR_SIZE
            ]
    return bytes(raw)


def raw_to_logical(raw: bytes) -> bytes:
    """Undo the P2000C sector translation for a data-disk image."""
    if len(raw) != FLOPPY_SIZE:
        raise CpmDiskError(
            f"expected a {FLOPPY_SIZE}-byte image, got {len(raw)} bytes"
        )
    image = bytearray([FILL]) * FLOPPY_SIZE
    track_size = 16 * SECTOR_SIZE
    for track in range(FLOPPY_SIZE // track_size):
        track_start = track * track_size
        for logical_sector, physical_sector in enumerate(SECTOR_INTERLEAVE):
            logical_start = track_start + logical_sector * SECTOR_SIZE
            physical_start = track_start + physical_sector * SECTOR_SIZE
            image[logical_start : logical_start + SECTOR_SIZE] = raw[
                physical_start : physical_start + SECTOR_SIZE
            ]
    return bytes(image)


def build_floppy(output: Path, files: list[Path]) -> None:
    """Build a deterministic 640 KiB CP/M data floppy."""
    image = bytearray([FILL]) * FLOPPY_SIZE
    directory_index = 0
    next_block = 1  # Allocation block zero contains the 4 KiB directory.
    names: set[tuple[bytes, bytes]] = set()

    for source in files:
        name, extension = cpm_name(source.name)
        if (name, extension) in names:
            raise CpmDiskError(f"duplicate CP/M filename {source.name}")
        names.add((name, extension))

        data = source.read_bytes()
        records = max(1, (len(data) + RECORD_SIZE - 1) // RECORD_SIZE)
        record_data = data.ljust(records * RECORD_SIZE, bytes([RECORD_FILL]))
        source_offset = 0
        physical_extent = 0
        records_left = records

        while records_left:
            extent_records = min(records_left, RECORDS_PER_DIRECTORY_EXTENT)
            block_count = (
                extent_records * RECORD_SIZE + BLOCK_SIZE - 1
            ) // BLOCK_SIZE
            if directory_index >= DIRECTORY_ENTRIES:
                raise CpmDiskError("the floppy directory has no free entries")
            if next_block + block_count - 1 > MAX_BLOCK:
                raise CpmDiskError("the floppy has no free allocation blocks")

            logical_extent = physical_extent * 4 + (extent_records - 1) // 128
            record_count = extent_records - (logical_extent & 3) * 128
            entry = bytearray(DIRECTORY_ENTRY_SIZE)
            entry[0] = 0
            entry[1:9] = name
            entry[9:12] = extension
            entry[12] = logical_extent & 0x1F
            entry[14] = logical_extent >> 5
            entry[15] = record_count
            for index in range(block_count):
                entry[16 + index] = next_block + index

            entry_offset = (
                DIRECTORY_OFFSET + directory_index * DIRECTORY_ENTRY_SIZE
            )
            image[entry_offset : entry_offset + DIRECTORY_ENTRY_SIZE] = entry

            byte_count = extent_records * RECORD_SIZE
            allocation_start = DIRECTORY_OFFSET + next_block * BLOCK_SIZE
            image[allocation_start : allocation_start + byte_count] = record_data[
                source_offset : source_offset + byte_count
            ]
            directory_index += 1
            next_block += block_count
            source_offset += byte_count
            records_left -= extent_records
            physical_extent += 1

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(logical_to_raw(image))


def extract_file(image_path: Path, filename: str, output: Path) -> None:
    """Extract one user-zero file, retaining its CP/M record padding."""
    target_name, target_extension = cpm_name(filename)
    image = raw_to_logical(image_path.read_bytes())
    extents: list[tuple[int, bytes]] = []

    for index in range(DIRECTORY_ENTRIES):
        offset = DIRECTORY_OFFSET + index * DIRECTORY_ENTRY_SIZE
        entry = image[offset : offset + DIRECTORY_ENTRY_SIZE]
        if entry[0] != 0:
            continue
        name = bytes(value & 0x7F for value in entry[1:9])
        extension = bytes(value & 0x7F for value in entry[9:12])
        if name != target_name or extension != target_extension:
            continue

        extent_number = entry[12] | (entry[14] << 5)
        extent_records = (extent_number & 3) * 128 + entry[15]
        remaining = extent_records * RECORD_SIZE
        data = bytearray()
        for block in entry[16:32]:
            if block == 0 or remaining == 0:
                break
            if block > MAX_BLOCK:
                raise CpmDiskError(f"{filename} uses invalid block {block}")
            count = min(remaining, BLOCK_SIZE)
            start = DIRECTORY_OFFSET + block * BLOCK_SIZE
            data.extend(image[start : start + count])
            remaining -= count
        if remaining:
            raise CpmDiskError(f"{filename} has an incomplete allocation list")
        extents.append((extent_number, bytes(data)))

    if not extents:
        raise CpmDiskError(f"{filename} was not found in {image_path}")
    extents.sort(key=lambda item: item[0])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(b"".join(data for _, data in extents))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    build = commands.add_parser("build", help="build a CP/M data floppy")
    build.add_argument("output", type=Path)
    build.add_argument("files", nargs="+", type=Path)

    extract = commands.add_parser("extract", help="extract a CP/M file")
    extract.add_argument("image", type=Path)
    extract.add_argument("filename")
    extract.add_argument("output", type=Path)

    arguments = parser.parse_args()
    if arguments.command == "build":
        build_floppy(arguments.output, arguments.files)
    else:
        extract_file(arguments.image, arguments.filename, arguments.output)


if __name__ == "__main__":
    main()
