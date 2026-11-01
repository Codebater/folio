# News Radio

A spoken bulletin made from your unread articles: an opening, then each story with a short introduction in the story's own language, then a closing. The idea comes from the first Codex version of Folio. Here it is rebuilt on the normal listening queue, so a bulletin is just a queue with announcements around its stories. Word highlighting, tap-to-read, speed, voices, the sleep timer and lock-screen controls all work exactly as for single articles.

## Stations

The Listen tab is laid out like a radio page. Every station is a bulletin planned from your unread articles right now, and **tapping one plays it straight away**. If something is already queued, Folio asks before replacing it.

| Station | What it plays |
|---|---|
| **Daily Mix** (Morning, Afternoon, Evening or Late Mix) | Unread stories from every source, newest first, **at most two per source** so one busy feed can't fill it. The hero card shows the lead image of its first story, the length and the sources |
| **Headlines** | Up to 15 of the newest stories, two per source, each read as its introduction plus two sentences: the feed's own summary when it sent one, otherwise key points picked from the article. About 5 minutes. Stories stay unread |
| **Topic stations** | One per FreshRSS category, busiest first |
| **By language** | One per language, only when your unread stories are in more than one. Names are shown in their own language (Deutsch, Español, Slovenčina) |
| **From your sources** | One per feed with at least two unread stories, busiest first, up to 10 |

Stations use your News Radio length, story limit, order and mark-read setting, but not its filters: each station sets its own scope. The same story from several feeds plays once (see story groups in STATUS.md).

Siri and Shortcuts can start them without opening Folio: "Play my Daily Mix in Folio", "Play the headlines in Folio", "What's new in Folio". In the Shortcuts app they work in automations, for example when your AirPods connect or your alarm stops. The lineup is rebuilt whenever articles change. Station artwork is generated in the colours of your reading theme, so it fits every theme.

## Building your own bulletin

Listen → **Build your own station**:

- **Length:** about N minutes (5–90) and at most N stories (1–30). Durations are estimates at your current speed (165 words a minute at 1×), never shown as exact times.
- **Order:** newest or oldest first.
- **Filters:** languages (English, German, Spanish, Slovak), categories and sources. An empty filter means everything. Filters combine, so a story must match all the filters you set.
- **Mark stories read when finished:** stories you hear to the end are marked read and synced. Stories you skip stay unread.

Stories that don't fit the remaining time are skipped rather than cut off, so a shorter story further down can still fill the gap. Building replaces the queue (after asking) and doesn't start playing. Press play when you're ready.

## What you hear

| Part | Example (English bulletin, German story) | Language |
|---|---|---|
| Opening | "Good morning. This is your Folio bulletin: 4 stories from 3 sources, about 12 minutes." | Your device language if it is en/de/es/sk, otherwise English |
| Introduction | "Als Nächstes, von Nachtschicht: Die Stadt, die nachts arbeitet." | The story's language |
| Story | the article, with word highlighting | The story's language |
| Closing | "That's the bulletin. Thanks for listening." | Bulletin language |

Announcements are speech segments with block ids starting with `announcement-`. No page has elements with those ids, so nothing is highlighted while they play, and tapping the page never seeks into them.

## Relaunch

The queue, the bulletin and the last spoken position are saved: immediately when the queue or play state changes, and at most every 3 seconds while words advance. After a relaunch, the queue comes back **paused** at that word. Audio never starts by itself.

## Code

| Piece | Where |
|---|---|
| Planner, filters, phrases | `Packages/FolioAudio/Sources/FolioAudio/NewsRadio.swift` |
| Stations (Daily Mix, topics, languages, sources) | `Packages/FolioAudio/Sources/FolioAudio/RadioLineup.swift` |
| Announcements in scripts | `SpeechScript.build(announcementsBefore:announcementsAfter:)` |
| Restore, lazy resume, "finished" callback | `ReadAlongController.restore`, `resume`, `onItemFinished` |
| App wiring | `Apps/FolioiOS/Folio/Model/ListenModel.swift`, `Listen/ListenView.swift` |
| Tests | `Packages/FolioAudio/Tests/FolioAudioTests/NewsRadioTests.swift`, `Apps/FolioiOS/FolioUITests` |
