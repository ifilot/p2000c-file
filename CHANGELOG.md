# Changelog

All notable changes to P2FILE are documented here. The project follows
[Semantic Versioning](https://semver.org/).

## [0.2.0]

- Calculate all file sizes during a single raw directory pass and aggregate
  multi-extent files without per-file BDOS size queries.
- Cache compact catalogs for drives A: through F: and refresh affected caches
  after file operations or explicit removable-media selection.
- Add Python unit and headless CP/M integration tests for disk packaging,
  directory limits, extent sizing, collisions, and cache invalidation.
- Update the right panel and footer in place after the startup scan instead of
  clearing and redrawing the complete screen.
- Hide the terminal's blinking cursor during normal operation, show it while a
  rename is being entered, and restore it before returning to CP/M.
- Replace inverse-filled modal dialogs with normal-video dialogs outlined by
  the P2000C character generator's 2x3 mosaic glyphs.
- Support the P2000C cursor Up and Down control codes emitted by the emulator,
  while retaining W/S and the previous control-code aliases.

## [0.1.0]

- Add repository and in-app semantic version metadata.
- Show the version in the main screen and help screen.
- Correct inverse-video rendering of the top panel headers.
- Expand the bottom menu to two rows.
- Add an in-app help screen with the GitHub repository and GPL-3.0 license.
- Build with the standalone `p2000c-asm` tool instead of booting the emulator.
- Add continuous compilation and tagged GitHub releases.

[0.2.0]: https://github.com/ifilot/p2000c-file/releases/tag/v0.2.0
[0.1.0]: https://github.com/ifilot/p2000c-file/releases/tag/v0.1.0
