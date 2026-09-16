# Contributing to Dropwheel

Thanks for your interest in Dropwheel. Bug reports, feature requests, documentation fixes and code are all welcome.

## Before you start

- Check the [issue tracker](https://github.com/kanishka-sahoo/dropwheel/issues) for existing reports.
- For anything larger than a small fix, open an issue first so we can agree on the approach before you spend time on it.

## Development setup

Dropwheel is a plain Swift Package. There is no Xcode project, and Xcode itself is not required.

1. Install the Xcode Command Line Tools: `xcode-select --install`
2. Install ffmpeg for audio and video work: `brew install ffmpeg`
3. Build and run:

   ```sh
   ./scripts/build_app.sh          # release build, ad-hoc signed, into build/Dropwheel.app
   ./scripts/build_app.sh debug    # debug build
   open build/Dropwheel.app
   ```

`swift build` on its own also works and is what CI runs, but the menu-bar app only behaves correctly when launched from the `.app` bundle produced by the build script.

### Project layout

| Path | Purpose |
| --- | --- |
| `Sources/Dropwheel/main.swift` | Entry point, menu bar item, headless `--convert` / `--tool` CLI mode |
| `Sources/Dropwheel/DragMonitor.swift` | Detects Shift-drags from Finder and shows the overlay |
| `Sources/Dropwheel/Wheel.swift` | Radial menu drawing and drop handling |
| `Sources/Dropwheel/Formats.swift`, `Actions.swift`, `Jobs.swift` | Format catalogue, dispatch, job queue and progress |
| `Sources/Dropwheel/*Convert.swift` | Converters by category (image, media, PDF, text, archive) |
| `Sources/Dropwheel/Tools.swift`, `ToolWindows.swift`, `EditorKit.swift` | Interactive tools and their editor windows |
| `Sources/Dropwheel/Docx.swift`, `Rar.swift`, `Markdown.swift` | Small self-contained format writers and parsers |
| `Resources/` | `Info.plist` and entitlements for the bundle |
| `scripts/` | Build, icon generation and the headless test matrix |

## Testing

There is no unit test target yet. The regression check is the headless test matrix, which drives the built binary over a set of fixture files:

```sh
# Put fixtures such as photo.png, song.mp3, clip.mp4, notes.txt, notes.pdf,
# subs.srt and project.zip in a directory (default /tmp/dwfix), then:
./scripts/test_matrix.sh /tmp/dwfix
```

Read the top of `scripts/test_matrix.sh` for the full list of expected fixture names. Please run it before opening a pull request that touches a converter, and mention in the PR which categories you exercised.

Speech transcription cannot be tested headlessly because macOS attributes the permission to the app bundle. Test it manually from the built app.

## Making changes

- Keep to the existing style: four-space indentation, `// MARK:` sections, no trailing whitespace. An `.editorconfig` is included.
- Prefer system frameworks (ImageIO, Core Image, PDFKit, AVFoundation, Vision, Speech) over new dependencies. The package currently has no third-party Swift dependencies, and we would like to keep it that way.
- External command-line tools are located through `Shell.find` in `Shell.swift`. Do not hard-code Homebrew paths elsewhere.
- Nothing may leave the user's Mac. Do not add code that makes network requests, including fetching remote images or telemetry.
- Do not add assets, names, screenshots or copy from other commercial products. Dropwheel uses its own name, icon and colours on purpose.
- If you add a conversion or tool, add it to the tables in `README.md` and to `scripts/test_matrix.sh`.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Make your change with a clear commit message describing what and why.
3. Make sure `swift build -c release` succeeds with no new warnings.
4. Fill in the pull request template. Small, focused PRs are much easier to review than large ones.

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).

## Reporting bugs

Use the bug report template. The most useful reports include the macOS version, the Mac's architecture, the output of `ffmpeg -version` if audio or video is involved, the input file type, and the error text from the progress panel or from running the conversion headlessly:

```sh
$(swift build --show-bin-path)/Dropwheel --convert path/to/file.ext target
```

## Security issues

Please do not open public issues for security problems. See [SECURITY.md](SECURITY.md).
