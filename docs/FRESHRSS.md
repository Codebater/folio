# Connecting Folio to FreshRSS

Folio talks to FreshRSS through its Google Reader–compatible API. Nothing on the server has to be modified.

## On the server

1. **Enable the API.** In FreshRSS: *Settings › Authentication › Allow API access*.
2. **Set an API password.** *Settings › Profile › API management*. This password is separate from your web login and only works for API clients. Folio stores it in the iOS Keychain (this device only, never iCloud).
3. Optional: check the API at `https://<your server>/api/` (FreshRSS's own compatibility page).

## In Folio

*Settings › Connect your FreshRSS server* (or **Connect FreshRSS** on first launch):

| Field | What to enter |
|---|---|
| Server address | Any of `rss.example.com`, `https://rss.example.com/`, `https://rss.example.com/freshrss/i/` or the full API URL `https://rss.example.com/api/greader.php`. Folio works out the API URL. |
| Username | Your FreshRSS username |
| API password | The API password from step 2 |

Folio verifies the credentials before saving anything. Error messages tell you which part failed: an unreachable address, the API switched off (HTTP 404/503), or a wrong username or API password.

### Tailscale and private networks

- **Recommended:** expose FreshRSS with Tailscale Serve and connect to its MagicDNS name over HTTPS, for example `https://freshrss.tailnet-name.ts.net:8091`. The certificate is valid, so nothing special is needed, and the iPhone only needs to be on your tailnet.
- Plain `http://` works for local addresses (iOS allows local networking). Public addresses need HTTPS.
- Self-signed certificates are not supported yet.

## Feeds that send only a summary

About half of a typical subscription list sends a teaser, not the article (BBC, TechCrunch, Wired, Nature, Google News and many more). Folio fills in the rest itself, on the device, like Reader view (Settings → Reading → Fetch full articles, on by default):

- **When:** opening a short article (under 250 words) swaps in the full one, with a "Getting the full article…" banner; narration waits up to 6 seconds for it; Download for offline includes it; after each sync the 30 newest unread summaries of the last 3 days are fetched, three at a time, on Wi-Fi only (never on cellular or in Low Data Mode).
- **How:** `FullTextExtractor` (FolioReader) removes navigation, sidebars, comments, share bars and hidden parts, scores blocks by their paragraph text and link density, takes the shared container of the best blocks, and compares the result with the page's JSON-LD `articleBody`. The result goes through `ArticleParser` like any feed content.
- **Kept apart:** the full text is stored beside the feed's content (`full_html`), so a sync never overwrites it, and the article's word count follows the full text.
- **Honest limits:** sites that block automated requests (HTTP 403), paywalls and pages that build their text only in JavaScript stay summaries; the reader then says "The feed sent only a summary" with Original and Try again. YouTube, Google News redirect links, X and Reddit are never fetched; YouTube items show a Watch card.
- **Copyright:** pages are fetched by the reader's own iPhone for their own reading and kept only there. Nothing goes through a Folio server.

Checked on 2026-11-01 against the newest article of every short feed in a real FreshRSS library (`folio-dev fulltext --file …`): 32 of the 40 article pages came back as full articles (for example BBC 834 words from an 86-character summary, TechCrunch 1,287, Quanta 1,482, Dark Reading 1,059, ScienceDaily 964, Wired 838 via JSON-LD). The rest: 403 from the ACM library and MJBizDaily, The Economist's paywall, a redirect loop at OpenAI (Windows only; URLSession on iOS keeps cookies), and pages that really are short.

## What syncs

- Subscriptions and categories (FreshRSS categories become Folio's categories).
- **Unread**, **starred** and **recent** articles (last 14 days on the first sync, then everything new since the previous sync). Up to 3,000 unread and 2,000 starred ids per sync.
- Read and starred changes in both directions. Changes made offline are queued on the phone and sent on the next sync. If you toggle an article several times offline, only the final state is sent. A local change always wins over the server's older state until the server confirms it.
- Read, unstarred, not-downloaded articles older than 45 days are removed from the phone.

## The sync, step by step

1. Send queued changes (`edit-tag`, in batches of 250 ids).
2. Refresh subscriptions and categories (`subscription/list`, `tag/list`).
3. List ids: unread (`stream/items/ids` with `xt=read`), starred, and recent (`ot=` last sync minus one day, to tolerate clock skew).
4. Download only articles the phone doesn't have (`stream/items/contents`, 100 per request). Each article is parsed once to store its excerpt, lead image, word count and language.
5. Reconcile read and starred flags. When an id list was truncated by the limits above, Folio never marks articles read just because they were missing from it.

A failed run can be retried safely: transient errors (timeouts, 5xx, 429) are retried with backoff, and an expired session triggers one fresh login.

## Testing without your server

- **Demo library:** on first launch choose *Try the demo library*. It is an in-app server with sample articles in English, German, Spanish and Slovak. No network is needed.
- **Mock HTTP server:** `python -I MockServer/mock_freshrss.py` serves the same articles at `http://127.0.0.1:8787/api/greader.php` (user `demo`, API password `folio-demo`, overridable with `MOCK_USER`/`MOCK_PASSWORD`). It mimics FreshRSS's error behaviour (401 with `Google-Bad-Token`, 501 without `output=json`).
- **Command line:** `FOLIO_PASSWORD=… swift run folio-dev sync --server https://rss.example.com --user you` syncs into a throwaway database and prints what arrived.
