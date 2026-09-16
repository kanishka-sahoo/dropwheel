# Dropwheel

[![CI](https://github.com/kanishka-sahoo/dropwheel/actions/workflows/ci.yml/badge.svg)](https://github.com/kanishka-sahoo/dropwheel/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: macOS 13+](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)

A zero-click, offline file converter for macOS. Hold **Shift** while dragging a file and a radial wheel of output formats appears at the pointer. Drop the file on a format to convert it. Add **Option** to switch the wheel to file tools (compress, crop, trim, split, merge, redact, metadata and more). Every result is saved as a new copy beside the original, and nothing ever leaves your Mac.

Dropwheel is a from-scratch, open implementation of the Shift-drag converter idea. It is a native Swift/AppKit menu-bar app with no Xcode project: it builds with the Swift toolchain that ships with the Command Line Tools.

## Requirements

- Apple silicon or Intel Mac running macOS 13 or later
- Xcode Command Line Tools (`xcode-select --install`)
- [ffmpeg](https://ffmpeg.org) for audio, video, WebP and AVIF: `brew install ffmpeg`
  (images, PDF, DOCX, text, subtitles and archives work without it)

## Install

Download the latest `Dropwheel-<version>.dmg` or `.zip` from the
[Releases](https://github.com/kanishka-sahoo/dropwheel/releases) page, open it and
drag Dropwheel to Applications. Then install ffmpeg if you want audio and video
conversions:

```sh
brew install ffmpeg
```

## Build from source

```sh
git clone https://github.com/kanishka-sahoo/dropwheel.git
cd dropwheel
./scripts/build_app.sh          # produces build/Dropwheel.app
open build/Dropwheel.app
```

The first launch shows a short explainer. Dropwheel lives in the menu bar; it has no Dock icon.

## Using it

| Gesture | What happens |
| --- | --- |
| Shift + drag a file from Finder | Wheel of output formats opens under the pointer |
| Shift + Option + drag | Wheel switches to advanced tools for that file type |
| Drop on a petal | Job starts; a progress panel appears bottom-right |
| Release Shift while dragging | Wheel closes and the drag behaves normally |
| Select files in Finder, press ⌃⌥⌘C | Wheel opens in keyboard mode |
| Arrow keys / Return / Escape | Choose, apply, cancel (keyboard mode) |
| Option (keyboard mode) | Toggle between formats and tools |

Multi-file drags work too: the wheel shows the formats and batch tools shared by every file.

## Conversions

| Category | Formats |
| --- | --- |
| Images | JPG, PNG, WebP, HEIC, TIFF, SVG (input), AVIF, BMP, plus PDF and DOCX export |
| Audio | MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, WMA |
| Video | MP4, MOV, MKV, WebM, AVI, WMV, GIF, plus MP3 audio export |
| PDF | to DOCX, JPG, PNG (300 DPI, every page), TXT |
| DOCX | to PDF, TXT, HTML, Markdown |
| Text | to PDF, JPG, PNG, DOCX, HTML, SRT, VTT |
| Markdown | rendered (headings, lists, tables, images, code, quotes) to PDF, JPG, PNG, DOCX, HTML, TXT |
| HTML | to PDF, JPG, PNG, DOCX, Markdown, TXT |
| CSV / TSV | as a formatted table to PDF, JPG, PNG, DOCX, HTML; and to JSON |
| JSON | to CSV (array of objects), or pretty-printed to PDF, PNG |
| Source code | with line numbers and highlighting to PDF, JPG, PNG, HTML |
| Subtitles | SRT, VTT, TXT |
| Archives | ZIP, TAR, GZIP, RAR (RAR output is store-only) |

## Smart conversions

These go beyond container swaps and understand the content:

- **Markdown, HTML, CSV and code are laid out**, not dumped: Markdown gets real headings, lists, tables and embedded images; CSV becomes a bordered table; code gets line numbers and keyword/string/comment colouring.
- **Images → TXT runs OCR** with the Vision framework, so a screenshot or scanned photo becomes editable text. Scanned PDF pages without a text layer are OCRed too when exporting to TXT or DOCX.
- **Audio/video → TXT, SRT or VTT transcribes speech** with Apple's on-device speech recognizer, producing timed subtitle cues. macOS asks once for Speech Recognition permission.
- **CSV ↔ JSON** round-trips tabular data with numbers and booleans typed.

## Tools

- **Images:** Compress, Metadata, Edit Photo (light, color, detail, clarity, dehaze, grain, noise reduction, effects), Add Background, Crop, Redact, Annotate (arrows, boxes, ellipses, lines, freehand, text, highlighter); with several images: Create PDF, Collage
- **Audio:** Compress, Metadata (searchable, with per-track and chapter fields), Normalize Volume, Trim (with silence removal), Convert Channels (mono, stereo, left/right to both, swap), Audio Visualizer, Bleep (ranges can be dragged whole or by their edges)
- **Video:** Compress, Metadata, Remove Audio, Trim, Crop, Change Speed, Snapshots, Split (at custom points, every N seconds, or into equal parts), Redact (whole video or a time range per area); with several videos: Join
- **PDF:** Compress, Metadata, Split, Organize (reorder, rotate, duplicate, remove); with several PDFs: Merge
- **Archives:** Extract

Compression strength, optional resizing, the ffmpeg path and launch-at-login live in **Settings…** in the menu.

## How it works

- `DragMonitor` polls the system drag pasteboard and mouse/modifier state (no Accessibility permission needed). When a file drag is in progress with Shift held, it shows a transparent full-screen panel.
- `WheelView` draws the radial menu and is the drop target. Dropping on a petal dispatches to `Actions`.
- Images use ImageIO and Core Image; PDF uses PDFKit; DOCX is written by a small OOXML writer; audio/video go through ffmpeg with progress parsing; archives use the system `bsdtar`.
- Interactive tools (crop, redact, trim, split, snapshots, bleep, edit photo, add background, collage, organize PDF, metadata) open editor windows built on `ToolWindow` in `EditorKit.swift`.

## Testing

`scripts/test_matrix.sh` runs the app headlessly (`Dropwheel --convert <file> <target>` and `Dropwheel --tool <tool> <files…>`) over a fixture set covering every category and tool.

## Notes

- RAR output uses the store method (no compression) since there is no open RAR compressor; the files inside are intact and the archive opens in The Unarchiver, WinRAR and libarchive.
- OGG output uses libvorbis when the installed ffmpeg has it, otherwise ffmpeg's built-in Vorbis encoder.
- Reading the Finder selection for the keyboard shortcut triggers a one-time Automation permission prompt.
- Transcription only works when Dropwheel runs as the app bundle (the permission is attributed to the bundle); it is unavailable from the headless `--convert` test mode launched from a terminal.
- Markdown images must be local files; remote image URLs are skipped so nothing is fetched.

## Contributing

Bug reports, feature requests and pull requests are welcome. Please read
[CONTRIBUTING.md](CONTRIBUTING.md) for the development setup, project layout
and testing notes. Security problems should be reported privately as described
in [SECURITY.md](SECURITY.md).

## Privacy

Dropwheel makes no network connections. Files are read and written only on your
Mac, OCR and transcription use Apple's on-device frameworks, and there is no
telemetry, crash reporting or update check.

## License

Dropwheel is released under the [MIT License](LICENSE).

Dropwheel depends on [ffmpeg](https://ffmpeg.org) for audio and video, which you
install separately and which is licensed under the LGPL or GPL depending on how
it was built. Dropwheel invokes it as an external process and does not bundle it.

## Acknowledgements

The Shift-drag radial converter interaction was popularised by commercial macOS
utilities. Dropwheel is an independent implementation written from scratch, with
its own name, icon and design, and is not affiliated with or endorsed by any of
them.
