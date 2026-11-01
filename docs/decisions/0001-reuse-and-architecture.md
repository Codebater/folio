# 0001: What we reuse, what we build ourselves

Date: 2026-11-01. Status: accepted.

## Context

Folio is a native iOS RSS reader with FreshRSS sync, an ebook-quality reading view and offline narration with word highlighting. Its code is public under FSL-1.1-ALv2 (MPL-2.0 until 2026-11-01, see [0002](0002-licence.md)), and it ships on the App Store with an optional Premium purchase. Development happens on Windows; iOS builds run on GitHub's macOS runners.

Before writing code we checked the actual repositories (licence file, last push, relevant source files) on 2026-10-31. The full notes, including the exact FreshRSS API contract, are in the maintainers' research notes.

| Project | Licence | Activity | Relevant to us |
|---|---|---|---|
| BookOrbit | AGPL-3.0 + extra terms | very active (v3.6.0, 2026-10-28) | Reading progress, Read Along concept. No iOS source in the repo; its iPhone app is closed source. |
| Readest | AGPL-3.0 | very active | Themes, typography, TTS marks to page ranges |
| foliate-js | MIT | active | CSS multi-column pagination |
| NetNewsWire | MIT | active | Reader API sync order, offline sync-status queue |
| FreshRSS | AGPL-3.0 | very active (1.30.4) | The server. Used only through its Google Reader API |
| FluidAudio | Apache-2.0 | very active | Kokoro TTS (EN/ES) with token durations, PocketTTS (DE). Candidate for Milestone 4 |
| WhisperKit (argmax-oss-swift) | MIT | active | Word timestamps for recorded audio; not needed for TTS |
| whisper.cpp | MIT | very active | Same; optional alignment |
| Piper (rhasspy) | archived; successor piper1-gpl is GPL-3.0 and embeds espeak-ng (GPL) | inactive | Licence trap; only some voice files (e.g. Slovak `sk_SK-lili`, CC0) are usable |
| sherpa-onnx | Apache-2.0 | very active (v2.0.1) | iOS TTS runtime (VITS/Piper, Kokoro, Matcha). No word timing. GPL-free since v2.0.0 |

## Decisions

1. **No AGPL or GPL code in Folio.** BookOrbit, Readest, FreshRSS and Piper's current code are study-only. Their ideas shaped the design; none of their code or assets are copied.
2. **FreshRSS through its public API only.** We implement our own Google Reader client in Swift. FreshRSS is not forked or modified.
3. **NetNewsWire's sync design, our own code.** NNW is MIT, but its modules target iOS 18 and depend on each other. We reimplemented its proven flow independently: push queued changes, refresh subscriptions, fetch id lists (unread, starred, recent), download only missing articles in batches, reconcile flags, and local changes win until confirmed. It is credited in `NOTICE`.
4. **SQLite amalgamation instead of GRDB/FMDB.** GRDB is excellent, but it doesn't build on Windows, and portable testing on Windows is a hard requirement here. The public-domain amalgamation (3.54.1) compiles on all three platforms with FTS5, and a 250-line wrapper covers what Folio needs.
5. **Own HTML parser and renderer.** A small tokenizer plus an allow-list parser produce a block document with stable ids and UTF-16 spans. The renderer emits fresh HTML from that document, so publisher markup never reaches the web view, and the web view runs with `allowsContentJavaScript = false` and a CSP without script sources. The reader script runs in WebKit's isolated content world.
6. **WKWebView for the reading surface.** It gives us real typography (hyphenation, `text-wrap: pretty`, CSS columns for pages, figures and tables) and native text selection. Word highlighting uses the CSS Custom Highlight API (iOS 17.2+), with a `<mark>` fallback on 17.0/17.1. Offsets are UTF-16 everywhere, the unit shared by Swift's `utf16` view, `NSRange` from AVSpeechSynthesizer and JavaScript strings. This lets one range travel from engine to page without conversion.
7. **AVSpeechSynthesizer first.** It is offline, already installed, supports EN/DE/ES/SK voices and reports the exact range it is about to speak. Engine-reported ranges are labelled `engineReported`. Anything estimated is labelled `estimated` and only tints the paragraph, never a word.
8. **Neural voices later, behind the same protocol.** FluidAudio (Apache-2.0) is the leading candidate: Kokoro covers English and Spanish with per-token durations, and PocketTTS covers German (CC-BY-4.0 attribution required). Kokoro has no German or Slovak voices. For Slovak, the options are sherpa-onnx with a CC0 Piper voice plus a phonemizer we write ourselves, or staying on Apple voices. Nothing is picked before it is benchmarked on a physical iPhone (Milestone 4).
9. **No transcription for TTS alignment.** WhisperKit and whisper.cpp only matter for aligning recorded audio. Apple's callbacks already give exact ranges.

## Consequences

- All non-UI logic (sync, storage, parsing, rendering, speech mapping, read-along control) is testable on Windows and Linux. 118 tests run there today.
- The SwiftUI app and the Apple-only engine are compiled only on macOS CI.
- Adding a neural engine means implementing `SpeechEngine` and, if it has no timing output, providing alignment or reporting `estimated` ranges.
