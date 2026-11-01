# Folio

A native iPhone RSS reader that sets your feeds like a book and reads them aloud, offline, highlighting every word as it is spoken. It syncs with your own FreshRSS server.

**Status:** Milestone 1 (working reader) and Milestone 2 (voice) are built and pass CI. Physical-iPhone checks are next. See [docs/STATUS.md](docs/STATUS.md) for what was tested where and what is still open.

## What it does

- **FreshRSS sync** through the Google Reader API: subscriptions, categories, unread / starred / all, mark read and star, incremental sync, offline queue, retries. Credentials in the iOS Keychain.
- **Offline first.** Articles live in SQLite on the phone. Reading, starring, marking read and listening all work without a connection; changes sync later.
- **A calm reader.** Articles are parsed into a clean document and re-rendered: Warm Paper, Classic White, Midnight and OLED Black themes, serif or sans, size, spacing, margins, scroll or paginated, reading position restore. Publisher scripts never run.
- **Read along.** On-device narration with Apple voices (AVSpeechSynthesizer). The word being spoken is highlighted and the page follows along; tap a paragraph to continue from there. Paragraph pauses, abbreviation handling in English, German, Spanish and Slovak, speed, sleep timer, a listening queue, lock-screen controls.
- **News Radio.** A spoken bulletin from your unread articles, with an opening, story introductions in each story's language, and a closing. Filter by source, category, language and length. Stories you finish are marked read. See [docs/NEWS_RADIO.md](docs/NEWS_RADIO.md).

## Repository

| Path | What |
|---|---|
| `Package.swift` | One Swift package (`FolioKit`) with every module below. Builds on macOS, Linux and Windows. |
| `Packages/FolioCore` | Models, text normalization, entities, language guessing, premium entitlements, retry policy |
| `Packages/FolioFreshRSS` | Google Reader API client, DTOs, Keychain store, in-memory demo server |
| `Packages/FolioReader` | HTML tokenizer and sanitizing parser, article document, themes, HTML renderer, reader script, reading progress |
| `Packages/FolioAudio` | Speech scripts, offset maps, pronunciation, sentence splitting, `SpeechEngine` protocol, read-along controller, `AppleSpeechEngine`, playback session |
| `Packages/FolioStorage` | SQLite (vendored amalgamation 3.54.1), article store, offline change queue |
| `Packages/FolioSync` | Sync engine |
| `Apps/FolioiOS` | SwiftUI app (XcodeGen spec `project.yml`) |
| `Tests/` | End-to-end tests across modules |
| `MockServer/` | Stateful FreshRSS API mock (Python, stdlib) and the shared demo articles |
| `Tools/FolioDev` | `folio-dev`: render reader pages for a browser, sync a real server from the command line |
| `docs/` | Status, decision record, FreshRSS guide, voice, News Radio, TestFlight |

## Build

Portable packages (any OS with Swift 6):

```bash
swift test
```

On Windows from Git Bash, `scripts/swift-windows.sh test` finds the toolchain without PATH changes.

iOS app (macOS with Xcode 16 or newer):

```bash
brew install xcodegen
```

```bash
xcodegen generate --spec Apps/FolioiOS/project.yml && open Apps/FolioiOS/Folio.xcodeproj
```

CI builds and tests the app on GitHub's macOS runners (`.github/workflows/ios.yml`). Signed TestFlight builds come from `.github/workflows/testflight.yml`, without a Mac. See [docs/TESTFLIGHT.md](docs/TESTFLIGHT.md).

## Try it without a server

The app has a built-in demo library (no network needed). For the real HTTP path, run the mock server and connect to `http://127.0.0.1:8787` with user `demo`, API password `folio-demo`:

```bash
python -I MockServer/mock_freshrss.py
```

## License

Code: [Functional Source License 1.1, ALv2 Future License](LICENSE) (FSL-1.1-ALv2), a "Fair Source" licence: the source is public, but it is not OSI-approved open source. You may read, use, modify and self-host Folio for any purpose except offering a competing commercial product or service. Each version becomes Apache 2.0 two years after its release. The Folio name and app icon are not covered by the licence. See [NOTICE](NOTICE) for third-party components.
