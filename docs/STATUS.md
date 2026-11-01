# Status

The app is called Paperwire since 2026-11-01; Folio remains the code name used in these docs and in the modules.

Updated 2026-11-01. Everything below says where it was verified. "Not verified" means not verified.

## Built

| Area | State |
|---|---|
| FreshRSS sync (Google Reader API) | Done: login, Keychain, subscriptions and categories, unread / starred / recent, incremental id-first sync, batched read/star writes, offline queue where local changes win, retries, clear errors (wrong password, API off, offline) |
| Offline storage | Done: SQLite (vendored 3.54.1) with articles, positions, highlights, pending changes; pruning of old read articles; offline image cache for downloaded articles |
| Read-aloud quality | Done:
- **The right voice for every article.** The language is decided from the article's own text with its feed as the prior; per-paragraph switching only happens on strong evidence and only into languages you read. This fixes the French accent on English stories.
- **Sentence highlight** under the word.
- **Signposts** for tables, code, quotes, captions and numbered lists.
- **Newsreader wording** for money, ranges and signs.
- **Even loudness** and trimmed silence for neural voices.
- **Paradee Lite:** four small English voices that run on the CPU.
- **Kokoro servers** get the text's pronunciation rules. |
| Everyday time savers | Done: **one card per story** (the same news from several feeds grouped, with its source count; reading one marks the copies read; stations play it once), **Headlines** station (up to 15 stories as two sentences, about 5 minutes), **key points** box on longer articles (on-device; Apple Intelligence summary on supported iPhones), **watch words** leading Today, **"Got a few minutes?"** (unread articles that fit 5/10/20 minutes), **Siri and Shortcuts** (Play Daily Mix, Play Headlines, What's New; usable in automations) |
| Full articles for summary feeds | Done: on-device extraction from the publisher's page (Reader-style plus JSON-LD), stored beside the feed content, fetched on open, before narration, for downloads and after sync on Wi-Fi; video items get a Watch card. 32 of 40 summary pages in a real 86-feed library come back whole |
| Reader | Done: sanitized document re-rendered in WKWebView with page JavaScript off; 4 themes plus "match system" (Warm Paper brightened to a cream page on 2026-11-01); all typefaces free; size, line spacing, margins, justification, hyphenation; scroll and paginated; position restore; publisher link and attribution |
| Read along | Done: clean spoken titles with the source first, smart resume after pauses, section skip (hold), hold-to-close mini player; AVSpeechSynthesizer, one utterance per paragraph or sentence, word highlighting from engine-reported ranges, tap-to-read, paragraph skip, speed, per-language voices, pronunciation rules (en/de/es/sk), sleep timer, queue, background audio, lock-screen controls, interruptions |
| News Radio | Done: bulletins from unread stories with filters and a time budget, introductions in each story's language, mark-read on finish, queue restored paused after relaunch. Listen is a radio page: Daily Mix (two stories per source at most), topic, language and source stations that play on tap, build-your-own, Up Next with an edit sheet |
| Neural voices (Voice Lab) | Natural voices page with one-tap "Use" for every language a voice speaks; the user's own voice server (Kokoro-FastAPI word timing, any OpenAI-compatible server) like BookOrbit. Built as a test feature: Kokoro (English, Spanish; word highlighting) and Supertonic-3 (Czech, Slovak, German, English, Spanish; paragraph tint) on the device through FluidAudio; download, preview, narration through a hybrid engine, blind A/B test, speed check, Kokoro crash guard. Neural voices work without Premium in TestFlight builds. See [VOICE.md](VOICE.md#neural-voices-voice-lab) |
| App-wide theme | Done: Today, Library, Listen, article lists, the mini player and the bulletin builder take page, card, hairline and accent colours from the reading theme; a fixed theme also sets light or dark; generated artwork (stations, sources, articles without images) uses the theme's palette |
| Triage (roadmap phase 1) | Done: Counts or Calm unread style, compact rows, configurable swipes, mark-read-on-scroll, "where you left off" marker, muted words (optionally marked read), storage page with retention and cleanup |
| Voice Library (roadmap phase 2) | Done: voices by language with your library's languages first, search and filters, previews, per-language defaults, favourites, Personal Voice, pitch/speed per voice and voice per feed (Premium), removed-voice warnings, Now Playing voice chip, regex pronunciation rules with live test, speech cleanup (citations, footnote marks, boilerplate), per-paragraph language switching |
| Premium | Entitlement layer and StoreKit 2 store; all typefaces free; Family upgrade for Lifetime owners; Manage subscription in app. Products defined in `Folio.storekit` for local testing; App Store Connect products not created yet |
| TestFlight pipeline | Done: ported from the Codex build; signed archive and export verified for this codebase |

## Verified

| Check | Where | Result |
|---|---|---|
| 216 package tests (article language and voice switching, signposts, sentence ranges, newsreader wording, audio polish, story groups, key points, headlines, full-text extraction, full-text storage and v1→v2 migration, title narration, smart resume, sections, core, FreshRSS, reader, audio, storage, sync, end to end, theme contrast, radio stations, timed and hybrid narration, word alignment, audio cache, voice server) | Windows 11 laptop, Swift 6.4.2 | Pass |
| Neural voices on a Mac: Supertonic-3 renders cs/sk/de through Folio's code; Kokoro crashes on GitHub's virtual Mac (FluidAudio's own CLI too) | GitHub macOS, "Neural voices" workflow | Supertonic pass; Kokoro unverified |
| Same tests | GitHub Linux (Swift 6.2), Windows (Swift 6.2), macOS (Xcode 26.2) | Pass |
| Real-HTTP sync through URLSession against the mock FreshRSS server | Windows laptop and Linux CI | Pass |
| App build, 5 app unit tests, 5 UI tests (demo onboarding, reader + appearance, bulletin queued paused and restored after relaunch, Voice Library opens a voice, themed screens with Daily Mix playing) | iOS Simulator on GitHub macOS, Xcode 26.2 | Pass. The themed-screens test saves Warm Paper and Midnight screenshots of Today, Library and Listen; the iOS workflow uploads them as the `screens` artifact |
| Unsigned device build | GitHub macOS | Pass |
| Signed App Store archive and export (`Folio.ipa`, build 4, upload off) | GitHub macOS, `testflight` environment | Pass |
| Upload to App Store Connect ("Folio Radio", run 41256657240) | GitHub macOS, `altool` | Apple acknowledged: delivery `692bafe2-f2a0-4629-bee3-2062fe2e44a9`. **It arrived as 1.0 (1), not 0.1.0 (5):** XcodeGen had written fixed version numbers into Info.plist. Fixed on 2026-11-01; the workflow now checks the number before uploading |
| Upload of phases 1 and 2 ("Folio Radio", **0.1.0 (7)**, run 41261607355) | GitHub macOS, `altool` | Apple acknowledged: delivery `1a8fa323-6301-4d47-a949-307b4fc71269` |
| Upload of themes, radio stations and Voice Lab (**0.1.0 (9)**, run 41272478055) | GitHub macOS, `altool` | Apple acknowledged: delivery `24519ccb-85af-4509-bb93-c0a42a589924` |
| Upload of smoother Listen, Natural voices page and voice servers (**0.1.0 (10)**, run 41275144960) | GitHub macOS, `altool` | Apple acknowledged: delivery `a2650146-1ccb-435e-804e-4a1a1ae3ee1e` |
| Reader page: themes, paginated mode, word ranges select exactly the right word on all 10 demo articles | Chromium (browser pane) at phone size | Pass |

## Not verified yet

- Anything on a physical iPhone: real speech quality, time to first word, highlight sync with audio, background playback, lock screen, interruptions, battery, memory on long articles. See the plan in [VOICE.md](VOICE.md).
- A live sync from the app against a real FreshRSS server (the dev tool has synced one; run `folio-dev sync` or connect from the app).
- Running 0.1.0 (10) from TestFlight, including the Voice Lab on a real iPhone (see [VOICE.md](VOICE.md#ship-rule)). 0.1.0 (7) was processed and in beta testing on 2026-11-01; the stray 1.0 (1) is expired.
- StoreKit purchases (products must be created in App Store Connect first).
- WebKit specifics that the browser check can't cover: the isolated content world and `allowsContentJavaScript = false` with the injected reader script. The UI test confirms the reader web view loads, not the highlighting itself.

## Next

The product roadmap and the research behind it are kept in the maintainers' private notes.

1. Install the next TestFlight build and run the device checklist in [VOICE.md](VOICE.md), including voice previews, per-feed voices and per-paragraph language switching.
2. Connect the real FreshRSS and measure a first sync with 86 feeds.
3. Create the three Premium products in App Store Connect (`com.codebater.folio.premium.yearly`, `.lifetime`, `.family` with Family Sharing on).
4. Roadmap phase 3: the premium redesign (navigation, design system, Up Next and stats cards, Search, More, reader footer pill and sentence + word highlight, Now Playing with Lyrics view).
5. Milestone 4: benchmark neural voices on device (FluidAudio Kokoro for EN/ES first).
