# Changelog

All notable changes to Dropwheel are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-09-16

Initial open-source release.

### Added

- Shift-drag radial wheel for converting files from Finder, with an Option-key
  tools mode and a keyboard shortcut (⌃⌥⌘C) for the current Finder selection.
- Conversions for images, audio, video, PDF, DOCX, plain text, Markdown, HTML,
  CSV/TSV, JSON, source code, subtitles and archives.
- Smart conversions: rendered Markdown/HTML/CSV/code, OCR of images and scanned
  PDFs via Vision, and on-device speech transcription to TXT/SRT/VTT.
- Interactive tools: compress, metadata, crop, redact, annotate, edit photo,
  add background, collage, create PDF, trim, normalize, channels, visualizer,
  bleep, remove audio, change speed, snapshots, split, join, merge, organize,
  extract.
- Headless `--convert` and `--tool` modes plus `scripts/test_matrix.sh` for
  regression testing.
- SwiftPM-only build (`scripts/build_app.sh`).

[Unreleased]: https://github.com/kanishka-sahoo/dropwheel/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/kanishka-sahoo/dropwheel/releases/tag/v1.0.0
