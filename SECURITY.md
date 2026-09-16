# Security Policy

## Supported versions

Only the latest release on `main` receives security fixes.

## What counts as a security issue

Dropwheel processes untrusted files (images, PDFs, DOCX, archives, media) and runs
entirely offline. Issues we consider security-relevant include:

- A crafted input file that causes code execution, writes outside the output
  directory, or reads files it should not (for example via archive path
  traversal or a malicious Markdown/HTML document).
- Any code path that sends data off the user's Mac.
- Problems with how external tools such as ffmpeg or bsdtar are located or
  invoked (for example argument injection through file names).
- Weaknesses in the build scripts that could let a tampered binary pass as a
  release.

Crashes on malformed input that do not cross a trust boundary are ordinary bugs;
please file them as regular issues.

## Reporting a vulnerability

Please do not open a public issue. Email **hello@ksahoo.com** with:

- A description of the issue and its impact
- Steps to reproduce, ideally with a sample file
- The Dropwheel version, macOS version and `ffmpeg -version` output if relevant

You should receive an acknowledgement within a few days. Once the issue is
confirmed, a fix will be prepared and released, and you will be credited in the
changelog unless you prefer otherwise.
