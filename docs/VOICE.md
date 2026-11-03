# Voice reader

Download an article, go offline, press play, and hear it read while the word being spoken is highlighted.

## Pipeline

```
ArticleDocument ─► SpeechScript ─► SpeechEngine ─► SpokenRange ─► ReadAlongController ─► reader page
 blocks with ids,   segments,        Apple today,     block id,        block, word, progress,  CSS Highlight API
 UTF-16 text        offset maps      neural later     display range,   queue, sleep timer      on the exact range
                                                      precision
```

1. **Document.** The parser turns article HTML into blocks with stable ids (`b0`, `b1`, …). Block text is normalized exactly as the page renders it: NFC, collapsed whitespace, soft hyphens and zero-width spaces dropped.
2. **Script.** Each speakable block (paragraphs, headings, quotes, list items) becomes one segment, or one per sentence in sentence mode. Code, tables, images and embeds are skipped. Pronunciation rules rewrite text for speech only; each segment keeps an **offset map** from spoken text back to on-screen text. The rules cover:
   - abbreviations per language (*e.g.*, *z. B.*, *p. ej.*, *napr.* and more)
   - dotted acronyms (*U.S.* read as *US*)
   - URLs, read as their host name
   - a user dictionary (Premium)
3. **Engine.** `AppleSpeechEngine` speaks one `AVSpeechUtterance` per segment, keeping two queued so there are no gaps. Short utterances avoid the iOS 17.0 bug where long ones stop early, and give natural paragraph pauses. `willSpeakRangeOfSpeechString` reports the exact UTF-16 range about to be spoken. It is mapped through the offset map and emitted as `engineReported`.
4. **Controller.** `ReadAlongController` turns engine events into UI state. It is portable and unit-tested, and handles:
   - tap-to-read, snapped back to the start of the tapped word
   - paragraph skip
   - speed and voice changes: AVSpeech can't change mid-utterance, so the engine restarts at the last spoken word
   - continuous playback through the queue, News Radio bulletins, and restore after relaunch
   - the sleep timer
   - **titles** read cleanly: the feed's name tacked onto the title, format tags ([Video], (Podcast)), all-capitals and emoji are dropped from speech only (edits keep the highlight on the shown words); the source is said first ("The Margin. Why …", on by default) and the title gets a longer breath (0.9 s) than headings
   - **smart resume:** after a pause of 30 s or more, narration restarts at the start of the sentence; after 10 minutes, at the start of the paragraph
   - **sections:** holding the skip buttons jumps to the next heading, or back to the start of this section (then the previous one)
   - **closing:** holding the mini player turns its play button into a close button; closing stops narration and clears the player (Up Next stays). The player card has the same close button
5. **Page.** The reader script maps `(block id, start, end)` to a DOM range by walking text nodes (`<br>` counts as one character, as in Swift). It highlights the range with the CSS Custom Highlight API and keeps it in view unless you scrolled away; a "Back to narration" button returns you to it.

Precision is explicit. Only `engineReported` ranges become word highlights. An engine without timing reports `estimated` ranges, which only tint the paragraph, so approximate timing is never shown as exact word alignment.

## Verified so far

| Claim | Evidence |
|---|---|
| Spoken ranges map to the right words in en/de/es/sk, including expansions, emoji and diacritics | `FolioAudioTests`, end-to-end test over every demo article |
| Those ranges select exactly the intended word in a real DOM | Browser check on all demo articles: 0 mismatches (spoken *zum Beispiel* intentionally highlights written *z. B.*) |
| Controller, queue, bulletins, restore | Unit tests with a simulated engine; UI tests on the iOS simulator |
| `AppleSpeechEngine` and `PlaybackSession` compile | macOS and iOS CI |
| Real speech, background audio, lock screen, interruptions, battery | **Not verified.** Needs a physical iPhone (plan below) |

## Device test plan

Record results in `docs/benchmarks/<device>-<iOS>.md` with the device model, iOS version, voice name and quality, and the date. Write "not measured" for anything you didn't measure.

1. **Time to first word:** from tap to the first `willSpeakRange`, airplane mode, 10 runs per voice; report median and worst.
2. **Highlight accuracy:** 3 articles per language; compare highlight and audio at 20 points each on a screen recording.
3. **Long article:** 10,000 words; memory at start and after 20 minutes, CPU, stuck highlights.
4. **Battery:** 60 minutes of narration with the screen locked; percentage drop and Energy Log.
5. **Interruptions:** call, Siri, unplugging headphones, Bluetooth disconnect, lock and unlock; expect pause, then resume when iOS allows.
6. **Offline:** airplane mode, force-quit, relaunch, play a downloaded article and a restored bulletin with each installed voice.
7. **Voices:** list installed voices per language and quality, especially which Slovak voices exist.

## Neural voices (Voice Lab)

Natural voices that run on the iPhone itself, so they cost nothing per listener and scale to any number of users. The reasoning (Apple's speech APIs, open models, licences and costs) is in the maintainers' research notes. They are a **test feature** until they pass the ship rule below.

### Models

| Model | Languages in Folio | Word highlighting | Runs on | Licence |
|---|---|---|---|---|
| Kokoro-82M through FluidAudio 0.18.0 (legacy runtime) | English (US, UK), Spanish | Word by word, from Kokoro's own per-token durations | CPU + Neural Engine; noise and tail on the CPU, no Metal (iOS blocks GPU work in the background) | Apache-2.0 code and weights |
| Supertonic-3 through FluidAudio (4-bit, Neural Engine build) | Czech, Slovak, German, English, Spanish | Sentence by sentence: the model reports no word timing, so narration renders one sentence at a time and shades it | CPU + Neural Engine | MIT code, OpenRAIL-M weights (use restrictions passed on; see NOTICE) |
| Paradee-8M v1.2 through FluidAudio (int8, 11 MB), shown as "Paradee Lite" | English (US: Heart Lite, Puck; UK: Isabella, Fable) | Sentence by sentence, as above | CPU only: safe with the screen locked and clear of Kokoro's Neural Engine bug (FluidAudio #1084) | Apache-2.0 code and weights |

Every rendered clip is trimmed to 40 ms of silence at each end and brought to one speech level, about −20 dBFS with peaks under −1 dBFS. Switching voices then doesn't jump in volume, and Folio's own pauses are the only ones.

**Joins.** On the phone, FluidAudio feeds Supertonic at most 70 characters per call: the Core ML model has a fixed 128-token text window, and quality drops near its edge. Each call comes back with about 0.4 s of silence at both ends.
- Left to FluidAudio, a long sentence was split, and the two paddings met as a pause of almost a second in the middle of the sentence.
- Paperwire now splits the text itself, the same way (`SpeechPieces`): sentences, then commas, then words.
- It trims each piece's padding and joins the pieces with the pause the text asks for: 0.18 s after a sentence, 0.10 s at a comma, 0.03 s between words.
- On a test paragraph this removed nine mid-sentence pauses and about 8 s of dead air.
- **Packing.** In sentence-by-sentence mode, neighbouring sentences share one call while together they fit in 64 characters, so the voice joins them itself. Both sentences are shaded.

**Room** (Listening style → Natural voices, on by default):
- Neural clips play through a small room: Apple's small-room reverb at about 6% wet, and a faint room tone 68 dB under the voice.
- Words then ring out softly across the joins between clips instead of stopping in digital silence. The big cloud and server models sound this way because they learned from real recordings.
- A voice can also bring its own studio tone: a low-end lift, and air on top.

**Our own voices.** Orion, Atlas, Vera, Clara, Rowan, Aurora and Theo are Ivy-family voices made in-house for Supertonic-3, each fitted to an original designed voice, never a real person's.
- Like Ivy, they speak all five languages.
- Their style files live in a private repository. The TestFlight workflow copies them into the app, and other builds don't offer them.
- They carry the same OpenRAIL-M terms as Ivy.
- Given the right language, every one of them sounds native. A language identifier (VoxLingua107) heard our seven voices as the intended language with a probability of 0.986 to 1.000 in all five languages, and Supertone's presets with 0.936 to 1.000. English never scored above 0.001 for text in the other languages.

**Numbers.** Supertonic reads digits badly outside English: a year in digits sounds like no particular language (a Slovak "2026" scored 0.01 Slovak in Ivy's voice, against 1.00 in words). So when a Supertonic voice reads German, Spanish, Slovak or Czech, numbers are said as words first (`NumberWording`):
- Dates in their spoken form: "3. novembra 2026" becomes "tretieho novembra dvetisíc dvadsaťšesť", and "am 3. November" becomes "am dritten November".
- Times, decimals, percentages and plain numbers: "o 14:30" becomes "o štrnástej tridsať", and "4,5 %" becomes "vier Komma fünf Prozent".
- English keeps its digits, and Apple voices aren't affected.
- Ordinals before a noun ("21. storočie", "der 3. Platz") stay as written, because their ending depends on the noun.

**Outro.** After an article, the voice says where it was from and what's next, in the article's language: "That was an article from The Margin. Coming up next: …". It is switched on in Listening style. Stations keep their own introductions.

Models download only when the user taps Download (from FluidInference on Hugging Face) into Application Support. Rendered paragraphs are cached as AAC in Caches, per user, never shared, and pruned when least recently used (600 MB cap).

### How narration uses them

```
ReadAlongController ─► HybridSpeechEngine ─┬─► AppleSpeechEngine      (Apple voices, as before)
                                           └─► TimedSpeechEngine      (neural voices)
                                                 ├─ FluidSpeechSynthesizer: Kokoro / Supertonic → AAC + word timings, 2 paragraphs ahead
                                                 └─ ClipOutput: AVAudioEngine + time-pitch, so speed never changes pitch
```

- **Routing.** A paragraph gets a neural voice only if that voice is chosen for its language (or its feed), its model is downloaded, and neural voices are allowed (Premium, or a TestFlight/debug build so they can be tested before the App Store products exist). Everything else is read by Apple's voices. Neural voices are never picked automatically.
- **Mixed articles.** Each run of consecutive paragraphs goes to the engine of its voice, so an English article with a Czech quote can use Apple for English and Supertonic for Czech. Changing a voice mid-article moves narration to the right engine from the current word.
- **Word timing.** `KokoroAlignment` turns Kokoro's predicted frames per phoneme into word times, then matches Kokoro's normalized words to our spoken text. Only certain matches count: identical words, a single word Kokoro read as several ("2026" → "twenty twenty six"), and short equal gaps between them. If phonemes were dropped, the counts differ or nothing matches, the paragraph gets no word timings and is tinted instead. Long paragraphs are rendered in sentence-sized pieces so each stays within Kokoro's single-chunk limit.
- **Failures are visible.** A paragraph that can't be rendered stops narration with a message. Folio never switches to another voice silently.

### Ivy, the default voice

Ivy (Supertonic-3, style F1) comes with the app for everyone. She reads every article in English, German, Spanish, Czech and Slovak unless the user picked another voice for that language. The other natural voices (Nora, Leo, Max, Paradee Lite, Kokoro, voice servers) are part of Premium.

- **Download:** on the first launch Paperwire waits for Wi-Fi, then downloads her once. Until she's ready, Apple's best voice reads. Removing the natural voices in Settings stops the automatic download until the user downloads them again.
- **Quick start:** once she's on the device, her model is loaded at launch, so the first word doesn't wait for it.

### Which language, which voice

The thresholds follow published language-identification accuracy (Lingua's reports: short English is most often mistaken for French, Slovak for Czech) and the FluidAudio and Kokoro documentation.

- **Spoken languages.** English, German, Spanish, Slovak and Czech are always recognised and read in their own language. Other languages are read only when turned on in Settings › Languages; anything else is read in the main language. (Before, a German article with only English and Slovak on was read with the English language tag, so every voice gave it an English accent.)
- **Article language.** Taken from the article's own text before narration starts: the full text when it was fetched, otherwise the feed's version. The feed's usual language is the prior: a feed has one when at least 70% of five or more articles share it.
  - Text of 40 or more words decides on its own (confidence 0.6 or more).
  - Shorter text needs 0.9 to overrule the feed.
  - Under 12 words, the feed decides.
  - The user's language override beats everything.
- **Paragraphs in another language** (a German quote in an English article) switch voice only when all of these hold:
  - the paragraph has 20 or more words;
  - the guess is 0.8 or more;
  - the language is a spoken one.

  Apple's recognizer only chooses among the spoken languages, tipped towards the feed's. Czech and Slovak never switch between each other inside an article. Headings, titles and introductions always use the article's language.
- **Stations** plan each story's introduction in the feed's language, unless the article is long enough to decide for itself. The opening speaks the first story's language and the closing the last story's, never the phone's language: a Spanish phone with English news opens in English.
- **Unknown language.** When nothing tells the language of an article, it is read in the library's most common language, not the phone's.
- **Kokoro servers** get `lang_code` from the text's language, so English is never pronounced through Kokoro's Spanish pipeline.

### Timing (how it flows)

Tuned to how professional newsreaders pause: a Google study of news read aloud found a mean of 190 ms between sentences, with 700 ms as the 99.5th percentile. Uniformly long pauses lost a listening test there, so Paperwire errs short.

| Join | Pause | Note |
|---|---|---|
| Between sentences (sentence-by-sentence voices) | 0.12 s, plus the 2 × 40 ms each clip keeps | About 0.2 s, the newsreader mean |
| Between paragraphs | 0.35 s (Listening style can change it) | Under the 0.7 s ceiling |
| After a heading | 0.6 s | |
| After the title | 0.3 s, then the byline, then 0.6 s | "Why pages feel quiet. The Margin, by Mara Ellison." |
| Around quotes | No extra pause | A quote is read like any paragraph; "Quote … End of quote" is optional |
| Between stories | 2 s | Narrated audio separates sections by 2 to 3 s; the next story is prepared and its first sentences rendered while this one ends |

- **Pauses shrink with speed,** as a fast talker's do: at 1.5× every pause is two thirds as long. They never go below 150 ms, where a join starts to sound like a hiccup. This applies to Apple and natural voices alike.
- **Closing punctuation.** Titles, headings, list items and spoken cues get a full stop if they have none, so the voice closes them instead of trailing up.
- **Short sentences ride along.** In sentence-by-sentence mode, a sentence under 24 characters ("It works.") is read together with its neighbour, so it doesn't sound clipped.
- **Asides.** Dashes and brackets in body text become commas, so voices pause around an aside instead of running clauses together.
- **No clicks, no stalls.** Natural-voice clips fade in and out over 6 ms and are rendered four segments ahead.

### How articles are read

- Tables and code are mentioned once ("Table skipped.", "Code skipped.") rather than skipped in silence. Image captions are optional ("Image: …").
- Quotes get a pause before and after; optionally "Quote." … "End of quote.".
- Numbered list items say their number. Emoji are never read. Text in brackets can be skipped.
- Money and ranges are read like a newsreader would read them: "$4.5bn" → "4.5 billion dollars", "2019–2021" → "2019 to 2021" (bis, a, až), "+5%" → "plus 5%", "#WWDC" → "WWDC".
- The sentence being read is shaded, and the word is marked on top (Listening style → Highlight). The sentence is known exactly: from the word the engine reports, or because the segment is one sentence. It is never estimated from time.

### Natural voices page (Settings → Natural voices, or the first row in Voices)

- **On this iPhone:** download Supertonic-3 or Kokoro. Once a model is there, each of its voices has ▶ and **Use**. Use makes that voice the default for every language it speaks, so one Supertonic voice (Ivy, Nora, Leo or Max) reads Czech, Slovak, German, English and Spanish. Other voices can still be chosen per language in Voices.
- **Your voice server** (below).
- **Voice Lab** (below).

### Your voice server (like BookOrbit)

Users who run their own speech server connect it once: the address (with or without `/v1`, so BookOrbit's format works) and an optional API key, kept in the Keychain. Its voices appear in Voices with a server icon, next to Apple's and the on-device ones, and can be the default per language or per feed. Folio runs no server and pays for none.

- **Kokoro-FastAPI:** `/dev/captioned_speech` returns MP3 plus a word list with start and end times. The words are matched to the spoken text with the same certain-match rules as on-device Kokoro, so highlighting is word by word.
- **Other OpenAI-compatible servers:** `/v1/audio/speech`, paragraph tint. Folio asks for captions once, then remembers that the server has none.
- Audio is cached on the device per user, so a paragraph is fetched once and replays offline. An unreachable server stops narration with a message naming the host.
- Voices are named from Kokoro's convention: `af_heart` is Heart, American English, female; `ef_dora` is Dora, Spanish.

### Voice Lab (Natural voices → Voice Lab)

- **Blind test:** the same passage in a neural voice and in the Apple voice Folio would pick automatically, labelled A and B and shuffled after every vote. Votes are kept per language.
- **Speed check:** renders three passages from scratch on the device and reports model load time, render time against audio length (RTF), word timing coverage and memory headroom, with a Copy button for `docs/benchmarks/`.
- **Storage:** size of models plus rendered narration, and Remove (chosen neural voices go back to automatic).

### Ship rule

A neural voice becomes a normal Premium feature for a language only when, on real iPhones (an iPhone 13 as the floor and a current one):

1. it wins the blind test against the best Apple voice (at least 5 listeners, 3 passages),
2. it renders well ahead of playback (RTF clearly below 1),
3. it keeps playing for 30 minutes with the screen locked, and
4. it survives a 2-hour session on iOS 26 and 27 (FluidAudio documents Core ML crashes in Kokoro on iOS 26.4+ and 27).

Until then it stays labelled as a Lab feature.

### Verified so far (2026-11-01)

| Check | Where | Result |
|---|---|---|
| Timed engine, hybrid routing and re-routing, Kokoro word alignment, chunking, cache | 17 unit tests, Windows (Swift 6.4.2) | Pass |
| FolioNeural and the app compile with FluidAudio 0.18.0 | GitHub macOS, Xcode 26.2 | Pass |
| **Supertonic-3** renders Czech, Slovak and German through Folio's own code | GitHub macOS runner (virtual Mac) | Pass: about 7.5 s of audio in 1.3–1.8 s each; samples in the `neural-samples` artifact of the "Neural voices" workflow |
| The Supertonic samples say the right words | Whisper large-v3-turbo on the Windows laptop | Czech and German transcribed word for word; Slovak with three small differences ("útorok", "tým", "vyržali"). An intelligibility check, not a quality rating |
| **Kokoro** renders | GitHub macOS runner | **Crashes** (bus error) with every routing, and FluidAudio's own CLI crashes the same way there. So it isn't Folio's code, but Kokoro is unverified until it runs on an iPhone |
| Voice server client against a real Kokoro-FastAPI 0.8 (a home server) | `folio-dev voice-server` on the Windows laptop | 68 voices listed; a 15-word sentence rendered in 1.3 s (6.6 s of audio) with all 15 words timed, "2026" spanning Kokoro's "twenty twenty-six"; 7 unit tests with that response as a fixture |
| Anything on an iPhone: speed, memory, lock screen, word highlighting with real Kokoro output, crash rate | — | **Not verified.** Use Voice Lab on a TestFlight build |

Because a Core ML crash can't be caught, the app guards Kokoro: a marker file exists only while Kokoro works, and if the app ends during that time, the next launch switches Kokoro off on that iPhone, resets English and Spanish to automatic voices and says so in the Voice Library.
