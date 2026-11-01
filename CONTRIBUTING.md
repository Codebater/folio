# Contributing to Folio

Thanks for helping. A few ground rules keep Folio maintainable and shippable.

- **Licence.** Folio is under FSL-1.1-ALv2 (see `LICENSE`). Code contributions from outside GRAPHIQ Studio aren't accepted yet, because they would need a contributor agreement first; issues and ideas are welcome. Don't paste code from GPL/AGPL projects (FreshRSS, Readest, BookOrbit, Piper's current code). Read them for ideas, then write your own code. Name any MIT/Apache source you adapted in `NOTICE`.
- **Portable first.** Logic that doesn't need UIKit/AVFoundation goes in a package and gets tests that run on Linux and Windows (`swift test`). Apple-only code stays behind `#if canImport(...)`.
- **Offsets are UTF-16** everywhere text ranges cross module boundaries.
- **Be honest in tests and docs.** Don't report a benchmark you didn't measure on a named device. Don't present estimated speech timing as word alignment.
- **Before a pull request:** `swift test` passes. On a Mac, also `xcodegen generate --spec Apps/FolioiOS/project.yml`, then run the app's unit and UI tests. CI does the same.

Useful tools: `python -I MockServer/mock_freshrss.py` (a FreshRSS API mock), `swift run folio-dev render --out .preview/` (reader pages for a browser), and `scripts/swift-windows.sh` (Swift on Windows from Git Bash).
