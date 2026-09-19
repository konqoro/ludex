# ludex — design

A local-first catalog of candidate Linux-playable games that aggregates critic scores,
user reviews, price, engine/tech facts and Proton playability into one place, then ranks
them so you can answer one question: **what do I play next?**

Data source for v0: the `jc141-listing` table (1999 catalog rows) joined against public
gamemetadata APIs by Steam AppID.

Working name: `ludex` (ludus + index). Directory is `~/Projects/ludex`; rename freely,
nothing depends on the name.

---

## 1. Scope

In scope:

- Ingest the listing table, normalize it, resolve each row to a stable game identity.
- Enrich every game from public sources: critic score, Steam user review score, tags,
  genres, price, engine/API/middleware, Proton tier, anticheat status, Steam Deck status,
  length (HLTB), artwork.
- Store everything in a local, diffable, offline-browsable dataset.
- Rank games against a personal taste profile with explanations, and offer a
  "pick for me" roll.
- A native desktop UI (owlkettle) and a CLI over the same core.

Explicitly **out of scope**:

- Any torrent/download automation or acquisition client. The listing row keeps its
  source reference as opaque provenance and links back to the source table; nothing in
  the app drives a download. Price and "is it worth buying" data is in scope instead.
- Account-scoped data (your Steam library, playtime, friends) in v0. Possible later via
  a user-supplied Steam Web API key.
- SteamDB. See §4.

## 2. Prior art and the gap

Checked against the real landscape:

| Tool | What it covers | Gap |
|---|---|---|
| Playnite (MIT, Windows/.NET) | library aggregation, plugins, metadata from IGDB | Windows-only, no recommender, no critic+user aggregation view |
| Lutris / Heroic (GPL) | launching, runner management | not a catalog; thin metadata; no scoring |
| Gameyfin (AGPL) / RomM (AGPL) / GameVault | self-hosted file libraries w/ metadata | ROMs or DRM-free files you already have; no scores, no recommender |
| Depressurizer (GPL) | Steam auto-categorization by genre/score/HLTB | **archived Feb 2026**, Windows-only, Steam-only |
| Augmented Steam (GPL) | overlays Metacritic/OpenCritic/HLTB/price onto Steam pages | browser extension, Steam pages only, not your own catalog |
| Backloggd / Grouvee (SaaS) | backlog tracking | closed, community scores only, no critic/tech aggregation, no recommender |
| SteamDB | prices, depots, stats | no API, actively blocks scrapers, so a dead end (§4) |

Conclusion: the three things you want (multi-source metadata aggregation, Linux
playability facts, and an actual recommender over a personal backlog) each exist
somewhere but **no single tool has all three**, and there is no Nim implementation of any
of it. That is the niche.

## 3. What the source data actually contains

Measured against the real `table.md` by `ludex parse`, not assumed. Every number below is
asserted by `tests/tparse.nim`, so it cannot drift:

- 2000 table lines: 1 header, 1 stray `------` separator, **1998 game rows**.
- All 1998 game rows carry a 40-hex `btih` info hash.
- **1545 rows carry `Appid=N`** → a free, exact join key to Steam/ProtonDB/AWAC/PCGW.
- **453 rows have no AppID** → need fuzzy title resolution (§7). These are the expensive
  and error-prone ones.
- Runtime: 1456 Wine, 365 Native, 16 Native/Wine, 161 with no runtime token at all.
- Those 161 are exactly the rows carrying **no metadata whatsoever**, in two spellings:
  116 dotted legacy names and 45 plain ones. Same class, same handling.
- Size: 3 rows are `0 B`, which means "unknown" and is stored as absent, not as zero.
- 10 rows are collections that nest other releases; 351 rows carry packager annotations.
- `Name` encoding is **not** uniform. Field counts by `" - "` split:
  `{1: 162, 3: 1, 4: 193, 5: 1597, 6: 41, 7: 2, 9: 1, 11: 1, 14: 1}` (the 162 includes the
  separator row). Three shapes exist:

  ```text
  # A) legacy dotted or plain, title only, no appid, no metadata (161 rows)
  Isle.of.Swaps-jc141
  Arco-jc141

  # B) canonical (~1570 rows)
  Slipways - b15946357 - MULTi6 - GNU/Linux Wine - jc141 (Appid=1264280)

  # C) title contains " - ", and/or the packager appends content (46 rows)
  Disco Elysium - The Final Cut - b23762888 - MULTi13 - GNU/Linux Wine - jc141 (Appid=632470)
  Call of Duty 2 - ENG - GNU/Linux Wine - jc141 (+ Multiplayer, Back2Fronts, ...)
  David Szymanski Collection - ENG - GNU/Linux Wine/Native - jc141 (Butcher&#039;s Creek - b17121038/1.151 - ...)
  ```

  Also present: HTML entities (`&#039;`), trailing `*` decoration,
  `${build}/${version}` pairs (`b13697029/1.3.8`), version pairs (`1.1.0.0/1.0.13`),
  language tokens with counts glued on (`MULTi12/7`, `ENG/FRE/MULTi4`), and appended
  content that is neither parenthesized nor last:

  ```text
  Dungeon Antiqua Collection - MULTi3 - GNU/Linux Native - jc141 (Appid=3198540) Dungeon Antiqua 2
  ```

  That last shape is why the parser anchors on the `jc141` marker instead of peeling
  trailing parenthesized groups.

Implication: the parser was the first real deliverable, and it needed golden tests against
this file. Two traps cost real data when handled naively:

- `split(" - ")` loses every title containing a separator, including the largest titles
  in the catalogue (`Disco Elysium - The Final Cut`, `Mini Airways - ATC simulator`).
- Walking metadata inwards from the right without a floor loses titles that look like
  metadata: `FEZ` and `OFF` are indistinguishable from ISO language codes.


## 4. Source catalog

All endpoints verified live during this design pass.

| Source | Endpoint | Key | Limit | Use |
|---|---|---|---|---|
| Steam appdetails | `store.steampowered.com/api/appdetails?appids=N&cc=XX&l=en` | none | ~200 req / 5 min / IP | **implemented.** genres, categories, `platforms.linux`, price, release date, recommendation count, dev/pub, and the picture URLs (below) |
| Steam appreviews | `store.steampowered.com/appreviews/N?json=1&num_per_page=0&filter=all&language=all&purchase_type=all` | none | generous | **implemented.** `num_per_page=0` returns the summary with no review bodies, so bulk costs one small call per game |
| SteamSpy | `steamspy.com/api.php?request=appdetails&appid=N` | none | 1/s; `all` 1/min, daily refresh | **implemented.** tags (the recommender's feature vector), ownership band, concurrent players |
| ProtonDB | `protondb.com/api/v1/reports/summaries/N.json` | none | undocumented, be polite | **implemented.** tier/score/confidence/reports; see §7.5 |
| Steam Deck report | `store.steampowered.com/saleaction/ajaxgetdeckappcompatibilityreport?nAppID=N` | none | same as store | **implemented**, and it also carries Steam's desktop-Linux verdict |
| AreWeAntiCheatYet | `raw.githubusercontent.com/AreWeAntiCheatYet/AreWeAntiCheatYet/master/games.json` | none | single file, MIT | **implemented.** hard blocker flag; see §7.6 for the measured coverage |
| PCGamingWiki | `pcgamingwiki.com/w/api.php?action=cargoquery&tables=Game&fields=...` | MediaWiki bot password (required since Aug 2026) | 60/min | `Engine`, `API`, `Middleware` → "tech used" |
| IGDB | `api.igdb.com/v4/games` (POST) | Twitch client id/secret | 4/s, free non-commercial | genres, themes, keywords, engine, artwork, metacritic-ish for the 453 unmatched rows |
| RAWG | `api.rawg.io/api/games` | free key | 20k/month non-commercial | `metacritic` field, fallback metadata |
| OpenCritic | via RapidAPI | RapidAPI key | free tier 200/day | critic score — too small for bulk, use **on demand** only |
| IsThereAnyDeal | `api.isthereanydeal.com` | key | free tier | all-time low / historical price → "wait for a sale" signal |

Deliberately excluded:

- **SteamDB** — no public API, forbids scraping, returns 403 to automated clients. Prices
  come from Steam appdetails, historical lows from ITAD.
- **Metacritic** — no API, Cloudflare-obfuscated HTML. Get its score second-hand from
  IGDB/RAWG; do not build a scraper.
- **HLTB** — no official API. Treat as an optional, best-effort, lower-priority enricher
  so its absence never breaks a run.

## 5. Architecture

Three binaries over one core library. The core is deliberately dependency-free so it
compiles to both C and JS.

```text
        jc141 table.md ──┐
                         │
  ludex ingest ──┐       ▼
  (network,      │   ┌──────────────┐   ┌──────────────┐
   rate-limited, │   │  ludexcore   │◄──│ data/*.jsonl │  (source of truth,
   cached)        └──►│  pure, no IO │   └──────────────┘   diffable, greppable)
                      └──────┬───────┘
                             │  in-memory index
             ┌───────────────┼───────────────┐
             ▼               ▼               ▼
        ludex (CLI)   ludex-ui (owlkettle)  ludex-web (Nim→JS)
```

Decisions and why:

1. **JSONL snapshots, not a database.** 2000 games × a few KB is ~10-20 MB in RAM. A
   server DB buys nothing at this scale and costs a C dependency, a schema migration
   story, and cross-compilation pain. Raw HTTP responses will be cached on disk as
   content-addressed files (sha256 of URL) so re-ingest is cheap and resumable.
   Revisit only if the dataset grows past ~100k rows.
2. **JSON goes through `brian`, and only `brian`.** No `std/json`, no DOM. `brian` decodes
   straight into Nim types and encodes straight into a string, so a `Release` is read and
   written by the store's own `readJson`/`writeJson` overloads and the on-disk format is
   stated in exactly one place. Absent fields are omitted rather than written as `null`,
   which keeps a snapshot diffable, and reading an unrecognized enum spelling fails that
   line instead of guessing.
3. **Two-phase ingest.** Fetch (network, retry, cache) is separate from reduce (pure,
   deterministic, testable). Reducer runs offline against the cache, so the recommender
   and parser can be developed and tested with no network at all.
4. **Every fact carries provenance.** `Fact[T] = (value, source, fetchedAt, confidence)`.
   A score you cannot trace is a score you cannot debug — and half this data is
   best-effort (HLTB, fuzzy-matched rows).
5. **Native C backend, not a web app. Settled.** The app is built with `nim c` and ships as
   an executable, with `owlkettle` (GTK4/libadwaita) as the UI. There is no browser target
   and no Nim-to-JS build: the portability question was asked and answered, not left open.
   Not every module can cross to JS anyway, because `brian` uses `copyMem`, but that is no
   longer a constraint the design has to respect. What survives from that investigation is
   the useful half of the rule: `ludexcore` performs no I/O, so parsing, filtering and
   scoring stay pure, deterministic and testable without fixtures on disk, and the CLI and
   the UI own the file system and the network.

## 6. Data model

Plain objects, value semantics, `Option` for genuinely-absent facts, and enums with
explicit string spellings so `$`/`parseEnum` round-trip against the JSONL on disk (that
round trip is what `brian` relies on when it reads and writes an enum).

```nim
type
  RuntimeKind* = enum            ## how the release runs on Linux
    rkNative = "native"
    rkWine   = "wine"
    rkBoth   = "both"
    rkUnknown = "unknown"

  PlayTier* = enum               ## normalized ProtonDB tier
    ptBorked = "borked", ptBronze = "bronze", ptSilver = "silver"
    ptGold = "gold", ptPlatinum = "platinum", ptUnknown = "unknown"

  AntiCheat* = enum
    acRunning = "running", acBroken = "broken"
    acPlanned = "planned", acUnknown = "unknown"

  SourceId* = enum               ## closed set; add members, never reorder
    srcListing, srcSteam, srcSteamSpy, srcProtonDb, srcAntiCheatYet
    srcPcGamingWiki, srcIgdb, srcRawg, srcOpenCritic, srcItad, srcHltb
    srcManual

  Fact*[T] = object              ## any enriched value keeps its provenance
    value*: T
    source*: SourceId
    fetchedAt*: int64            ## unix seconds
    confidence*: float           ## 0..1; fuzzy title matches score low

  PriceFact* = object
    currency*: string
    final*: int                  ## in cents; -1 = unknown
    initial*: int
    discountPercent*: int
    atHistoricalLow*: bool

  Release* = object              ## implemented; see §7.1 for the parse rules
    rowKind*: RowKind            ## game | separator | header
    lineNumber*: int
    title*: string               ## as printed in the listing
    titleNorm*: string           ## folded key, for matching only
    pack*: PackKind              ## single | collection
    buildId*: Option[string]     ## "b15946357"
    version*: Option[string]     ## "1.3.8"
    langToken*: Option[string]   ## "MULTi6" / "ENG/JPN", kept verbatim
    langs*: seq[string]          ## ISO codes, only for explicit lists
    runtime*: RuntimeKind
    appid*: Option[int]          ## the join key for all enrichment
    sizeBytes*: Option[int64]    ## absent means unknown, never zero
    infoHash*: Option[string]    ## provenance from the source listing
    nested*: seq[string]         ## releases named inside a collection
    warnings*: seq[string]       ## every fallback the parser took

  GameKey* = distinct string     ## "steam:1264280" | "title:isle of swaps"

  Game* = object                 ## one logical game; may have several Release
    key*: GameKey
    title*: string
    releases*: seq[Release]
    store*: Option[SteamStore]
    scores*: Scores
    tags*: seq[TagWeight]        ## recommender feature vector
    tech*: TechFacts
    play*: Playability
    price*: Option[PriceFact]
    length*: Option[LengthFact]
    art*: ArtFacts

  Scores* = object
    steamPositivePct*: Option[Fact[float]]
    steamReviewCount*: Option[Fact[int]]
    criticScore*: Option[Fact[float]]
    criticCount*: Option[Fact[int]]
    owners*: Option[Fact[int]]

  TechFacts* = object
    engine*: Option[Fact[string]]
    api*: Option[Fact[string]]         ## stack of APIs (D3D11/D3D12/Vulkan/OpenGL)
    middleware*: Option[Fact[seq[string]]]

  Playability* = object
    tier*: Option[Fact[PlayTier]]
    protondbConfidence*: Option[string]
    antiCheat*: Option[Fact[AntiCheat]]
    antiCheatName*: Option[string]
    deckStatus*: Option[string]
    minRamMb*: Option[int]
    nativeBuild*: bool                 ## Steam ships a real Linux build
```

One lookup surface per shape, per the codebase's API conventions: a strict raising path
for required data (`[]` on the index raises `KeyError`) and explicit safe paths
(`hasKey`, `getOrDefault`) for the optional enrichment facts — which is basically all of
them. `ScoreCard` (§9) is the only place where missing data is a normal, expected state
and never an error.

## 7. Pipeline

### 7.1 Parse (implemented: `src/ludexcore/parse.nim`)

`func parseTableLine(line: string; lineNumber: int): Release`, with `rowKind` telling the
caller whether the line held a game. Algorithm, driven directly by the shapes measured in
§3:

1. Reject non-table lines, the header, and the `------` separator via `rowKind`.
2. Split the row into `Name | Size | Magnet`.
3. **Anchor on the `jc141` marker** once, then cut: everything left of it is title plus
   metadata, everything right is packager annotation. This is what survives
   `... jc141 (Appid=3198540) Dungeon Antiqua 2`, where the appid group is neither last
   nor the only annotation.
4. Pull `Appid=N` from the annotation and the 40-hex `btih` hash from the magnet link.
5. Walk `" - "` fields **inwards from the right**, consuming any token that is a build id
   (`b15946357`, `b13697029/1.3.8`), a version (`2.0.11.0`, `1.1.0.0/1.0.13`), a language
   token (`MULTi9`, `ENG/JPN`, `MULTi12/7`), a runtime (`GNU/Linux Wine`) or the marker.
   Field order varies, so match by pattern, never by position.
6. **Stop with at least one field left.** `FEZ`, `OFF` and `1000xRESIST` are
   indistinguishable from ISO language codes, so without that floor the walk eats its own
   title. Whatever remains is the title.
7. Metadata-free rows keep their title and get a `no-metadata` warning; dotted legacy
   names (`Isle.of.Swaps-jc141`) additionally have dots folded to spaces.
8. HTML-unescape entities, trim trailing `*` decoration, and record every fallback taken in
   `warnings`.
9. Mark `pack = pkCollection` when the annotation carries nested build ids.

`normalize.splitLegacySuffix` and `parse.takeTrailer` (balanced-paren peeling) remain as
the fallback path for rows without the marker.

### 7.2 Normalize (implemented: `src/ludexcore/normalize.nim`)

- **Language tokens.** `MULTi6` is a *count*, not a set, so it is kept verbatim in
  `langToken` and never expanded into which six languages those are. `langs` is filled only
  when the token is an explicit ISO list. The glued-on variants in the real data are
  accepted: `MULTi12/7`, `MULTi9/ENG`, `ENG/FRE/MULTi4`, and a bare `MULTi`.
- **Sizes.** `1.3 GB` becomes bytes; `0 B` becomes absent, because zero would be a lie.
- **Titles.** `titleNorm` folds case, drops apostrophes outright (`Schrödinger's` becomes
  `schrödingers`), turns other punctuation into separators, collapses whitespace and strips
  a leading article. Bytes outside ASCII pass through unchanged, so accented titles keep
  the spelling of the upstream names they are matched against.
- **Still to do:** Roman-vs-Arabic numeral unification (`Crusader Kings III` against
  `Crusader Kings 3`). The parse layer stores titles as printed, so this belongs to
  matching in §7.3.

### 7.3 Match

1545 rows resolve by AppID, free. For the 453 without:

1. Exact `titleNorm` hit against the local IGDB/Steam name index.
2. Token-set + Jaro-Winkler similarity, accepted above a threshold.
3. Tie-break with corroborating facts: release year, developer, and whether the release
   year is consistent with the listing's build id era.
4. Ambiguous or below-threshold results become `GameKey "title:<norm>"` with
   `confidence < 0.6` and are surfaced in a `ludex review-matches` queue for a human
   decision — never silently guessed. Collections get one key plus child keys.

### 7.4 Fetch (implemented: `src/ludexingest/client.nim`)

One caching, rate-limited client, with no HTTP dependency beyond `std/httpclient` and
`-d:ssl`:

- **Cache.** One file per URL, named after the sanitized URL so a cache directory stays
  readable, holding the status line and the body:

  ```text
  HTTP/1.1 200

  {"tier":"platinum","score":0.71,"total":31}
  ```

  The status is cached, not just the body, because `404` from ProtonDB means "nobody has
  reported this game" and is worth remembering instead of re-asking. A corrupt cache file
  is a miss, not an exception. `--refresh` ignores the cache; `--offline` never opens a
  socket and fails on a miss, which is what the tests use.
- **Politeness.** An unconditional pause between requests (`--delay`, default 250 ms), a
  descriptive `User-Agent` with a contact URL, and a hard `--limit` so a sweep can be
  partial. Retries `429` and `5xx` with exponential backoff, then gives up on that game.
- **Failure handling.** Any per-game failure is recorded with its reason and the run
  continues. The client's own errors are `FetchError`; `httpclient` declares `Exception`
  for its TLS paths, which is translated there and only there, with `Defect` re-raised so
  a programming bug is never recorded as a source outage.
- **Still to come:** ETag/Last-Modified revalidation and `--max-age` (the cache is
  currently valid until `--refresh`), per-host token buckets, and resumable job state.
  OpenCritic at 200/day stays an on-demand source, never a bulk one.

### 7.5 What ProtonDB actually returns (implemented)

`src/ludexcore/sources/protondb.nim` is a pure decoder, and the real responses taught the
design three things the tables in §4 could not:

- **404 for silence.** An app id nobody has reported answers `404`, not an empty object.
  That is recorded as "nothing known" and counted as `silent`, never as a failure.
- **`pending` plus `provisionalTier`.** When the reports are too thin to call, the tier is
  `pending` and the payload carries a guess. `pending` maps to `ptUnknown`, and the
  provisional tier is decoded but deliberately **not** promoted into a fact: a provisional
  tier behind a handful of reports is a claim this catalogue cannot support. The score and
  report count are still kept, so the UI can say "unknown, 5 reports, inadequate".
- **`ptUnknown` sorts last.** The tier enum is ordered by quality so `tier >= ptGold`
  reads naturally, which puts `ptUnknown` above platinum. Every tier test therefore checks
  `actual == ptUnknown` explicitly; a filter that forgot to would rank its least-known
  games as its best. There is a test for exactly that.

Scores are rounded to three decimals on the way in, because the raw values arrive as
`0.7000000000000001` and a diff full of float noise helps nobody.
### 7.6 What AreWeAntiCheatYet actually provides (implemented)

`src/ludexcore/sources/awac.nim` decodes the whole dataset in one request, and the real
file changed the model in three ways:

- **Five statuses, not four.** The dataset says `Supported`, `Running`, `Broken`,
  `Denied` and `Planned`. `Denied` (the vendor refuses) is materially different from
  `Broken` (it fails today), and `Supported` (the vendor blesses it) from `Running` (it
  works unoffically), so `AntiCheat` grew to match. `blocksLinux` covers `Broken` and
  `Denied`; `usableUnderLinux` covers `Running` and `Supported`.
- **`unknown` sorts lowest, and so does `unknown` for tiers.** The first version of
  `PlayTier` ordered quality ascending with `ptUnknown` last, which meant `tier >= ptGold`
  quietly ranked the least-known games as the best, and needed a special case to fix.
  Both enums now order worst-first, so every threshold fails closed with no exception to
  remember. That reordering is a one-line change with a test that would have caught the
  original bug.
- **Coverage is thin, and that is a finding, not a flaw.** 1167 entries, 682 name a Steam
  app id, but only **677 distinct** ones: five pairs share an id and three of those pairs
  disagree on the status (`Predecessor`/`Final Fantasy XIV` share 961200, for instance).
  The dataset is aimed at large online games and this catalogue is mostly single-player
  imports, so the overlap with the 1545 catalogue app ids is **13 games**. Two of those
  thirteen (`Conan Exiles Enhanced`, `Ghost of Tsushima`) are blocked, which is exactly
  the expensive mistake the source exists to prevent.

Two consequences worth stating:

- Where two entries claim one app id, the resolution is explicit rather than left to
  iteration order: a definite verdict beats an unknown one, and between two definite
  verdicts the worse one wins. Telling a player that a blocked game runs is the single
  error this catalogue must not make. Anti-cheat names from both entries are kept.
- A source that answers for everyone does not get a per-game request loop, so
  `enrichAntiCheat` has its own shape: one fetch, one decode, then a join over the
  catalogue. `--limit` has nothing to limit there and is ignored, which the usage text
  says.

Only the fields the recommender uses are modelled. `notes`, `updates`, `logo`, `url` and
`reference` are skipped: they are prose for a human reading the website.

### 7.7 What the Steam endpoints actually do (implemented)

`src/ludexcore/sources/steamstore.nim` and `steamreviews.nim`, one store call plus one
review call per game, and the recordings exposed four things:

- **Silent mapping failure, the worst kind.** The payload is `snake_case` (`price_overview`,
  `is_free`, `release_date`) and `type` is a keyword, while Nim fields are camelCase. Left
  to name matching, every field silently stayed empty: the run reported "4 answered" and
  stored `"store": {}`. Every reader is now explicit about the wire name, and
  `not SteamFacts().isKnown` is asserted so an empty mapping cannot pass again.
- **Reader order is load-bearing.** `brian` resolves a nested reader through `mixin` at the
  point of instantiation, so `readJson(App)` must be declared after the readers for the
  types it contains and before the one that reaches it. The readers are ordered innermost
  first, and that constraint is written down in the module docs because violating it fails
  silently again.
- **A review band is not a percentage.** `review_score` is Steam's own 0-9 bucket while
  `total_positive`/`total_reviews` give the share: 8 means "Very Positive", not 80%, and
  the two can disagree by 13 points. The share is what gets stored; the band is only
  range-checked.
- **The payload also carries what the page needs to say.** `short_description` is the
  store's one-line pitch and every enriched game has one; `metacritic` is a press
  aggregate that only some games carry (4 of the first 12), with a score and a source URL;
  and `platforms.linux` is the store's own statement about a Linux build, independent of
  ProtonDB. All three are stored, named explicitly like every other field.
- **Prices move, and prices differ by country.** The same game read `$10.99` at one point
  and `$16.99` for another app in the same session, and `cc` is a parameter precisely
  because a store page shows you a local number. This is the argument for `fetchedAt` on
  every fact: a price without a timestamp is a claim about the past presented as the
  present.

Cross-source disagreement is real and is the reason each fact carries its source:
`Sensory Overload` is packaged as a Wine build in the listing while Steam ships a Linux
build for it, and `Night in the Woods` agrees on both. Neither source is thrown away; the
UI can show that they differ.

Two operating notes:

- Steam's store tolerates roughly 200 requests per five minutes, so its default pause is
  1600 ms while ProtonDB's is 250 ms. A full catalogue sweep is two calls per game, about
  40 minutes for 1545 app ids at that pace, which is why `--limit` plus a warm cache is the
  intended way to work through it.
- `l=en` is fixed in the URL, because English names are what the listing uses and matching
  depends on it. Only `cc` is a parameter.

**Pictures, added after all.** The first version of this decoder skipped `header_image` and
`screenshots[]` as store prose, and that was the wrong call: a screenshot is how a player
decides whether a game looks interesting, which is half of "what do I play next". The
URLs are now facts (`art.background`, `art.header`, `art.screenshots`), and the bytes are
deliberately *not*
in the JSONL — a picture is 50-200 KB against a ~1 KB record, and a store of image blobs
would stop being diffable. So the split is: `enrich --source steam` records the URLs,
`ludex art` downloads the pictures into `data/art/<appid>/` through the same client and
cache, and the window only ever opens a local file. Both sizes are kept per screenshot
(`path_thumbnail` 600x338 and `path_full` 1920x1080), and the downloader takes the full
size with the thumbnail as a fallback, because the window shows a screenshot in a
full-window viewer and would otherwise have to blow a 600px image up to the window.
Changing that preference means an existing cache holds the smaller file under the same
name, so `ludex art --refresh` is what fetches the larger one. The full size costs roughly
ten times the bytes, and the response cache keeps a second copy of every body, so
`ludex art --limit` is the cursor that bounds a sweep and `data/cache` can be deleted
whenever the space is wanted.

Adding the field exposed a second, quieter trap: `mergeSteamFacts` names every field by
hand, so a field it forgets decodes correctly and is then thrown away by the merge — the
run reports success and the pictures simply never appear. That is the same class of silent
failure as the `snake_case` mapping bug in §7.7, and it now has its own regression test
(`art_survives_a_merge`).

### 7.8 What SteamSpy and the Deck report actually give (implemented)

`src/ludexcore/sources/steamspy.nim` and `steamdeck.nim`. Between them they supply the
taste vector and a second first-party opinion on whether a game runs.

- **Tags are the taste vector, and they are far better than genres.** `Slipways` carries
  twenty weighted tags (`Strategy 145`, `Puzzle 140`, `Relaxing 123`, `Economy 114`,
  `4X 87`) against a single store genre. A tag filter is already useful on its own:
  `--tag puzzle` and `--tag cats` both return something sensible.
- **`steamos_resolved_category` is a desktop-Linux verdict, not a Deck one.** SteamOS is
  Linux with Proton, so this answers "will this run on Linux" independently of whether a
  native build exists: `Slipways` is playable on SteamOS while its own store entry says
  `platforms.linux: false`. The two verdicts are kept separately and filtered separately,
  because they are different questions. On the twelve games sampled, desktop `playable`
  was 12, handheld `playable` 8 and handheld `verified` 4.
- **The categories are 1/2/3.** Verified, playable and unsupported, confirmed against
  three recorded games, including `Destiny 2`, whose only reported item is
  `UnsupportedAntiCheatConfiguration`, agreeing with the anti-cheat dataset from a
  completely different direction.
- **SteamSpy's fields vary where you would not expect.** A game with no price sends `null`
  for `price`/`initialprice`/`discount`, and a game with no tags sends an empty **array**
  where a tagged game sends an **object**. Both would fail a naive record, so unused
  fields are deliberately not modelled at all, and the tags reader accepts both shapes.
  The type is also a named wrapper rather than `seq[Tag]`, because a custom reader for
  `seq[Tag]` would also capture the array form the enrichment store uses for the same
  type and break it in both directions.
- **Playtime is not a length signal.** `average_forever` is `0` for both recorded games,
  one of which has thousands of reviews, so it is stored as absent rather than as a
  zero-minute game. Length still needs HLTB or something like it.

One structural consequence: **a per-game failure inside a multi-call source no longer
discards the other calls.** The Steam source makes three calls per game, and the first
version let a failing third call throw away two good answers. Each call is now attempted
independently, and `RunStats` grew a `partial` counter so "some calls answered" is visible
rather than being reported as either a clean answer or a total failure.

## 8. Recommendation engine

`list --tier` is a threshold because tiers are a scale; `list --anticheat` takes a
comma-separated set because statuses name states. That asymmetry is deliberate and is
documented in the usage text: `broken` is not "less than" `running`, it is a different
answer, so `--anticheat broken,denied` and `--anticheat running,supported` are two
different questions rather than two points on one scale.

Two stages: **gates** then **rank**. Both must explain themselves, because a picker you
disagree with and cannot interrogate is worse than a list.

### Gates (hard, overridable)

- Anticheat `broken` → excluded from "can play now".
- `PlayTier == borked` → excluded.
- Above available disk space → excluded.
- Already finished / marked `never` → excluded.

Excluded games stay visible with a reason and a one-click override (`--include-blocked`),
plus a "show me why not" panel. Nothing is silently hidden.

### Ranking (v1, weighted and explainable)

```text
score = Σ wᵢ · fᵢ  ,  w in a tunable config table, Σwᵢ = 1

f_quality  Bayesian-smoothed Steam % vs a prior, blended with critic score when
           the critic sample is large enough to trust
f_fit      cosine(taste vector, tag vector) — taste = mean tags of games you loved
           minus mean tags of games you bounced (SteamSpy tags are the feature space)
f_length   gaussian fit of HLTB main hours against the session budget you set
f_run      native 1.0 · platinum .95 · gold .85 · silver .6 · bronze .35
f_price    owned/free = 1; else quality-per-euro, plus a bonus at or near
           historical low and a "wait for sale" penalty when full price is far off low
f_novelty  penalty for recent plays, repeats, and tag overlap with your last 3 sessions
f_risk     penalty for online-only / always-online categories when you wanted single-player
```

`f_fit` is the only learned component, and it is a plain vector model — no ML framework,
no training loop, cold-start-able from five ratings. Options that were considered and
rejected for v1: collaborative filtering over Steam reviews (too sparse, no signal about
you), and LLM embeddings over review text (interesting, but adds a service dependency
before the cheap tags have even been tried).

### Pick modes

- **Best now** — argmax with a "don't repeat the last N" rule.
- **Roll** — temperature-softmax sampling over the top-N. A slider from 0 (deterministic
  best) to 1 (near-random) keeps surprise without serving garbage.
- **Shortlist** — top 5 with the factors that decided it, plus the runners-up and the
  single factor that dropped each one.

### Human feedback loop

Every pick is `played | loved | bounced | skipped | later`. Those labels are the training
data for `f_fit` and, later, for fitting the weights themselves by pairwise logistic
regression over "chose A over B". Phase 5 — not needed to ship something useful.

## 8b. The recommender, as built (phase 3)

`src/ludexcore/taste.nim` and `score.nim`, driven by `ludex rate`, `ludex pick` and
`ludex why`. The shape follows §8; what follows is what changed once it met real data.

**Two stages, and the gates are named.** `rank` splits the catalogue into `candidates`,
`blocked` and `unranked`. A blocked card carries its reasons ("anti-cheat broken (BattlEye)
blocks Linux", "already rated bounced"), so `--include-blocked` prints them in their own
section rather than mixing a rejected game into the answer.

**The taste profile is a Rocchio centroid over SteamSpy tags.** Each rated game's tags are
scaled to unit length, loved games add theirs and bounced games subtract theirs, and the sum
is scaled again. From five ratings it reads back as words:

```text
taste     Strategy, Turn-Based Strategy, Sandbox, Turn-Based, Singleplayer, Puzzle
avoids    Crafting, Investigation, Female Protagonist
```

**Six factors, each a number in `0..1` with a weight, and the score is a weighted mean over
the factors that had data.** `coverage` reports how much of the weight that was. Three of
the factor decisions were forced by the data:

- **Coverage shrinks the score, and there is a floor.** The first version scored a game
  whose only evidence was the listing's native-build flag at 100%: one perfect factor out of
  six, leading the list, because there was nothing else to mark it down for. Scores are now
  shrunk towards the middle in proportion to the missing weight, and `minCoverage` (0.25)
  keeps "a hint" out of the answer entirely. Both are tunable, and the CLI prints the
  coverage next to every score, so a 60%-coverage game never pretends to be a verdict.
- **`run` takes the best evidence rather than an average.** ProtonDB's tier, Steam's
  desktop-Linux verdict and a native build in the listing are three measurements of one
  question; averaging answers that disagree produces a number that means nothing, so the
  highest wins and the reason says which one it was.
- **`effort` reports itself unknown, on purpose.** Length needs HLTB; SteamSpy's mean
  playtime is absent for nearly every game. A factor that guesses would be worse than one
  that admits it has nothing, so `effort` only fires when a budget and a playtime both
  exist.

**Surprise is a temperature, not a dice roll.** `--surprise` maps to
`exp((score - best) / T)` sampling. At `0` the best always wins, at `1` the choice is close
to uniform, and the measured effect is monotone: at surprise 0.3 the top game wins 30 of 200
fixed seeds, at 1.0 it wins 24. The same seed always produces the same pick, so a result can
be reproduced and argued with.

**The weights are a JSON file**, `ludex weights --out weights.json`, read back with
`--weights`. That is the "config table" from §8, without inventing a second config format.

### The honest state of the coverage

On the current cache the recommender can judge **7 games out of 1998**:

```text
taste     Strategy, Turn-Based Strategy, Sandbox, Turn-Based, Singleplayer, Puzzle
avoids    Crafting, Investigation, Female Protagonist
7 candidates, 7 blocked, 1984 with no data yet
```

That is not a bug and the tool says so. Four sweeps make it real, and the cached ones
already prove the pipeline:

```sh
ludex enrich --offline                                  # everything already asked for
ludex enrich --source protondb --delay 250 --limit 400   # ~2 minutes per 400 games
ludex enrich --source steam --limit 200                  # 3 calls each, ~15 minutes
ludex enrich --source steamspy --limit 400               # 1 call each, ~8 minutes
ludex enrich --source anticheat                          # one request, then done
```

`steamspy` is the one that unlocks `fit` for the whole ranking, so it is the sweep worth
running first.

## 9. UI and interface surface

### CLI (first, because it is the fastest path to "I have a useful thing")

Implemented today:

```text
ludex parse --table table.md --out data/releases.jsonl
ludex list  --store data/releases.jsonl [--runtime R] [--max-size S] [--min-size S]
            [--lang T] [--title T] [--appid] [--no-appid] [--limit N]
ludex show  <appid> --store data/releases.jsonl
ludex help
```

Implemented for one source:

```text
ludex enrich --store data/releases.jsonl --out data/enrichment.jsonl --source protondb
             [--cache dir] [--delay ms] [--limit n] [--refresh] [--offline]
ludex enrich --store data/releases.jsonl --source anticheat     # one request, no limit
ludex enrich --store data/releases.jsonl --source steam --limit 20 --cc gr
ludex enrich --store data/releases.jsonl --source steamspy --limit 100
ludex list   --store data/releases.jsonl --tier gold
ludex list   --store data/releases.jsonl --anticheat broken,denied
ludex list   --store data/releases.jsonl --genre strategy
ludex list   --store data/releases.jsonl --linux-build
ludex list   --store data/releases.jsonl --tag puzzle
ludex list   --store data/releases.jsonl --steamos playable

ludex rate 1264280 loved
ludex pick --store data/releases.jsonl [--time 3h] [--surprise 0.3] [--weights w.json]
ludex why  1264280 --store data/releases.jsonl
ludex weights --out data/weights.json
```

Planned:

```text
ludex enrich     --tech           # PCGamingWiki engine/API/middleware
ludex resolve    --unmatched      # title matching queue
ludex list       --min-score 75 --max-hours 8 --price-under 20
```

### Desktop app — owlkettle (GTK4 + libadwaita)

**Built:** `nim c -o:bin/ludex-ui src/ludexui/app.nim`. Owlkettle 3.1.0 supplies the
native GTK4/libadwaita widgets and links through `pkg-config`. Keep the platform
baselines in `nim.cfg` (`--define:adwminor=4`, `--define:gtkminor=10`); newer online
libadwaita APIs are not necessarily available in this checkout.

The product model is **an artwork collection → one game → View on Steam**. The
research, rejected alternatives and design thesis are recorded in
[UI-REDESIGN.md](UI-REDESIGN.md). The catalogue contains candidate games, not proof of
ownership, installation or play history, so the external store handoff does not claim
to launch an installed game.

- **Collection:** `score.rank` orders recommendations automatically, with remaining
  games alphabetically afterwards. Duplicate Steam IDs appear once. A native `FlowBox`
  of artwork tiles reflows from one column to several as width permits; title and
  concise genres sit beneath the picture. Each page holds 24 games, bounding widget
  creation and image decoding. This deliberately trades continuous scrolling for
  predictable work: Owlkettle has no `GridView` binding. Page controls appear only when
  needed. Most catalogue rows carry no picture yet, so a tile without one shows an
  `AdwAvatar` of the title's initials, which is native, quiet and varies per game, and a
  loved game is marked with a small accent star beside its title.
- **Search:** Ctrl+F reveals a search field; Escape closes it. Search matches title,
  genres and tags across the entire catalogue, independent of the displayed page.
  All query tokens must match; the current page resets when the query changes.
- **Filtering:** a filter button (`view-more-symbolic`, the HIG's secondary-menu icon)
  opens a popover of checkable rows: Runs on Linux, Steam Deck ready, Hide games I've
  rated, and a "Type of Game" list built from the catalogue's own store genres (offered
  once at least three games carry them, most common first). Several genres mean either,
  not both. Every switch is answered only from stored evidence, so an absent fact is
  never a yes: no ProtonDB tier, no Linux build and no native build means "not a match".
  A check-role menu row keeps the popover open, so several filters can be set in one
  visit, and the button's tooltip reports how many are active. With anything filtered the
  collection states "N games match your filters" beside a Clear Filters button; when the
  filters admit nothing, a status page names the cause and offers the same recovery.
- **Game:** the picture is the view's identity. The banner prefers the store's wide page
  art (`background_raw`, 1438x810) over the 460x215 header, which is too small to draw
  large, and its height is computed from that picture's own aspect at the column width so
  it fills the column exactly: no letterbox bars, and narrower windows crop the sides
  rather than squashing it. A game with no picture shows the title's initials instead. The title is `title-1` over a `caption` genre line, and a
  single suggested pill button is the view's only prominent control. Decision evidence
  is a boxed list (`PreferencesGroup` + `ActionRow`), the standard way GNOME groups a few
  labelled facts: Linux support with a semantic icon, player reviews, and a press score
  when one exists, each row omitted when its fact is absent. The store's one-line pitch
  sits between the action and the ratings, and the screenshots follow as a horizontal
  strip that opens any picture full-window, at its own size and never blown up. Secondary
  facts (price, released, developer, tags) form a second boxed list, and the
  reader's own verdict is a row of its own. A developer is kept and the publisher is not
  shown: a studio is a track record a player can recognise, while the publisher is a
  business entity with little bearing on whether the game is enjoyable; it stays stored
  because it arrives in the same payload. Back (Alt+Left) restores the collection's
  query, page and scroll position, and steps back out of the viewer first.
- **Rating:** a "Your rating" boxed-list row holds a `DropDown` of the existing verdicts
  plus "Not rated". Successful changes persist to the CLI's ratings file and update the
  ordering; a failed write leaves the previous rating intact and reports the failure.
- **Main menu:** a primary menu behind `open-menu-symbolic`, holding Open Catalogue…,
  Reload and, when load problems exist, Show Diagnostics…, grouped above the standard
  About Ludex. Narrowing the collection is a view concern rather than an app-wide command,
  so it lives in its own filter menu beside this one instead of inside it. The menu appears
  only on the top-level collection view, as the HIG requires of a
  window that uses hierarchical navigation, and every item carries an access key.

The window reads local files only; enrichment and artwork downloads remain CLI jobs.
An empty catalogue offers Open Catalogue. Unavailable optional metadata is not an error
surface. Failed requested actions receive concise feedback, while raw load diagnostics
remain available only on request. System appearance and native Adwaita styling handle
light, dark and high-contrast presentation without a theme preference.

Hierarchy comes from scale, spacing, grouping and imagery rather than decoration. Color
is restrained and purposeful: the artwork carries the richness, the system accent
appears only on the single suggested action, and Linux compatibility uses Adwaita's
`.success`/`.warning`/`.error` classes on a symbolic icon as well as its wording, so
color is never the only signal. The window ships no custom stylesheet or palette, which
keeps light, dark, high-contrast and user-chosen accent colors working.

Ownership remains explicit: `catalog.nim` owns files and derived browse results;
`present.nim` supplies pure wording; `app.nim` owns layout and interaction. The small
`widgets.nim` adapter handles search focus, scroll restoration and a width-bounded label
for grid titles through actual GTK APIs exposed by the repository bindings.
`AdwNavigationView` is not wrapped, so selected-game state and a native header back
button implement the single navigation level. `snapshot.nim`, compiled only under
`-d:ludexSnapshot`, renders the window to a PNG so the interface can be reviewed on a
machine with no screenshot tool.

Underlying CLI filters, recommendation weights, source provenance and score explanations
remain available without occupying the window. There are no Jobs, API-key or hardware
configuration surfaces, and no UI roadmap requirement to add them.

### No web front end

There is no browser target. The UI is a native GTK4 app, built as its own binary over the
same core. This keeps the dependency set to `brian`, `owlkettle` and the standard library,
and it keeps the "what should I play" answer in the same process as the library it is
choosing from.

## 10. Repository layout

```text
ludex/
  ludex.nimble                  # requires brian and owlkettle; Atlas resolves it
  nim.cfg                       # user section + Atlas-generated path section
  atlas.config                  # Atlas state (deps dir, resolver, overrides)
  atlas.lock                    # pinned commit, for reproducible installs
  config/weights.toml           # tunable recommender weights (phase 3)
  deps/                         # generated: Atlas-managed checkouts (brian, owlkettle)
  src/
    ludexcore/                  # no os/threads/FFI; JS-safe except store
      models.nim                # types + initX constructors (public surface)
      parse.nim                 # table row -> Release             [done]
      normalize.nim             # titles, languages, sizes         [done]
      query.nim                 # Filter + matches                [done]
      store.nim                 # JSONL read/write via brian      [done]
      match.nim                 # appid/title resolution + confidence
      taste.nim                 # ratings and the tag profile      [done]
      ratings.nim               # the ratings file                 [done]
      score.nim                 # gates, ranking, ScoreCard        [done]
      art.nim                   # the art cache layout, pure       [done]
    ludexcore/sources/
      protondb.nim              # summary decoder, pure          [done]
      awac.nim                  # anti-cheat dataset decoder      [done]
      steamstore.nim            # store entry decoder            [done]
      steamreviews.nim          # review summary decoder         [done]
      steamdeck.nim             # Deck and SteamOS verdicts       [done]
      steamspy.nim              # tags, ownership, player counts  [done]
    ludexingest/                # IO: fetch, cache, rate limit
      client.nim                # caching, rate-limited HTTP     [done]
      enrich.nim                # fetch, decode, merge, record   [done]
      artcache.nim              # pictures into data/art/<appid> [done]
    ludex.nim                   # CLI                           [done]
    ludexui/                    # owlkettle app (native GTK4)   [done]
      catalog.nim               # the only file-system access in the UI
      present.nim               # pure: facts -> labels, no GTK, no IO
      app.nim                   # the viewable App: library, game, dialogs
  tests/
    config.nims                 # adds src/ to the search path
    tester.nim                  # auto-discovers t*.nim
    fixtures/listing-table.md   # the real file, golden fixture
    tparse.nim tquery.nim tstore.nim tprotondb.nim tawac.nim tsteam.nim
    tsteamspy.nim tscore.nim ttaste.nim tenrich.nim tpresent.nim tart.nim
    fixtures/protondb/*.json    # recorded responses
    fixtures/awac-games.json    # the real dataset, 469 KB
    fixtures/steam/*.json       # recorded store, review and deck responses
    fixtures/steamspy/*.json    # recorded SteamSpy records
  data/                         # generated: releases.jsonl, enrichment.jsonl, cache/
  docs/DESIGN.md
```

`ludexcore` exports its models and entry-point `func`s and keeps orchestration and helpers
private. Ingest state (job cursor, rate buckets, cache handle, retry counters) will live in
a plain `IngestState` object passed by `var` through the pipeline, so cross-phase invariants
stay visible in signatures instead of hiding in nested captures. `ref object` is used only
where identity genuinely matters: the in-memory game index and the UI's app state.

## 11. Toolchain

`nimble` is **not installed** on this machine; `atlas` is (`~/.local/bin/atlas`). Atlas is
therefore the dependency workflow, including for `brian`:

```sh
atlas init            # writes deps/atlas.config
atlas install         # resolves the requirements in ludex.nimble
atlas pin             # writes atlas.lock so the resolution is reproducible
```

How it was set up, so it can be repeated:

- `requires "https://github.com/planetis-m/brian"` lives in `ludex.nimble`; `atlas install`
  cloned it to `deps/brian` and resolved `0c4d6829` (brian 0.1.0, `requires nim >= 2.2.0`).
- Atlas patched `nim.cfg` by appending its own section, leaving the user section
  (`--path:"src"`, `--hints:off`) untouched:

  ```text
  ############# begin Atlas config section ##########
  --noNimblePath
  --path:"deps/brian/src"
  ############# end Atlas config section   ##########
  ```

- `atlas update brian` reports the checkout up to date, so the version is pinned rather
  than tracking a branch. `atlas.lock` records the exact commit, `nim.cfg` and nimble
  contents. `deps/` is generated and ignored by git; `atlas.lock` is committed.
- brian's writer exposes `beginObject`/`writeField`/`endObject`, which is what lets a
  field be omitted cleanly. Its master branch reorganised this API around `JsonParser`
  and raw `write` calls, so if this ever moves to master, `store.nim` is the only file
  that has to change.

Other notes:

- **`brian` 0.1.0's float parser is one unit in the last place high** for values such as
  `0.3`, `0.6`, `0.7` and `92.8`, which was found by asserting that stored facts survive a
  round trip. The mitigation is that every float this catalogue stores is rounded to the
  precision its source justifies, on the way in *and* on the way out, so the stored form is
  canonical and a snapshot stays diffable. Configuration floats, which are not stored data,
  are compared with a tolerance in the tests instead. Upstream's master branch reworked
  float conversion, so this is worth rechecking when brian is next updated.
- System Nim is 2.3.1, and the build target is the C backend (`nim c`), not JavaScript.
- HTTP uses `std/httpclient` with `-d:ssl`; there is no third-party HTTP dependency.
  `-d:ssl` lives in the user section of `nim.cfg`, because every enrichment source is
  HTTPS only and a CLI built without it fails every request at runtime.
- The owlkettle UI links GTK4 4.22 and libadwaita 1.9 through `pkg-config`, which
  owlkettle's bindings run at compile time. The shared libraries are enough; no `-devel`
  headers are read, and owlkettle 3.1.0 compiles on system Nim 2.3.1 unchanged.

## 12. Testing

Implemented, and the numbers in §3 are these assertions:

- **Golden parse test** (`tests/tparse.nim`) against the real `table.md`: 2000 lines,
  1998 games, 1545 appids, 453 without, runtime counts 1456/365/16/161, exactly 161 rows
  flagged `no-metadata`, zero missing info hashes, plus one assertion per parsing trap:
  titles containing ` - `, a title that looks like a language code, packager annotations
  that are unparenthesized, HTML entities, and dotted legacy names.
- **Query tests** (`tests/tquery.nim`): runtime partition, size bounds excluding
  unknown sizes, the appid/no-appid split summing to 1998, folded title search, and
  `limit` capping the result without changing the match count.
- **Store tests** (`tests/tstore.nim`) cover the brian-backed wire format directly: the
  exact bytes of a minimal record, absent fields staying absent rather than `null`, a
  record exercising every field including escaping and a size past 2^32, a full round
  trip of all 2000 rows, one object per line, per-line failure reporting at the batch
  boundary, the `ufSkip` versus `ufReject` policies, titleless non-game rows, and
  rejection of unknown enum spellings and trailing data.
- **Decoder tests** (`tests/tprotondb.nim`) run against recorded real responses under
  `tests/fixtures/protondb/`: tier spellings, the quality ordering, the `pending` case,
  score rounding, the fact that a summary with no reports yields no facts, half-present
  bodies keeping defaults, and malformed bodies raising.
- **AWAC tests** (`tests/tawac.nim`) decode the real 1167-entry fixture and assert its
  shape (682 app ids, 677 distinct, the five status counts, 66 native builds), the status
  vocabulary including an unknown word, the blocking and usability predicates, the
  fail-safe ordering of both enums, app-id capture from a quoted or bare value, and the
  conflict rule for the five shared app ids. It also measures the overlap with the real
  catalogue (13 games, 2 blocked), so a refresh of the fixture has to be a deliberate
  decision.
- **Steam tests** (`tests/tsteam.nim`) decode the recorded store and review responses and
  assert every mapped field, including the ones whose wire name differs (`type`,
  `steam_appid`, `is_free`, `release_date`, `price_overview`), the string-versus-number
  genre and category ids, the `success: false` envelope with no `data`, a key that does not
  match the app asked about, the empty-facts check that catches silent mapping failure,
  the review share against Steam's band, and the picture URLs in both sizes.
- **SteamSpy tests** (`tests/tsteamspy.nim`) decode the recorded records and assert the
  tagged fields, the vote order, the trim, and the two regressions that real data forced:
  `null` prices and an empty-array `tags`. Also that an untracked app decodes to silence
  and that fields this catalogue does not use are skipped.
- **Ingest tests** (`tests/tenrich.nim`) seed a cache with those recorded bodies and put
  the client in offline mode, so the whole path runs with no network: cache hits and
  misses, a 404 remembered as an answer, a corrupt entry treated as a miss, the
  answered/silent/cached/failed counters, `--limit`, silent sources changing nothing, a
  different source's facts surviving a merge, malformed responses recorded rather than
  fatal, and the pictures surviving decode, merge and store as the regression for a merge
  that names every field by hand.
- **Taste tests** (`tests/ttaste.nim`) cover the verdict vocabulary, replacement and
  removal of ratings, which verdicts gate and which do not, unit-length scaling, that a game
  with many tags does not outweigh one with few, that loved pulls and bounced pushes, that
  `skipped` and `later` teach the profile nothing, and the alignment ordering across liked,
  unrelated and disliked games.
- **Scoring tests** (`tests/tscore.nim`) cover review smoothing, each factor's bands and
  unknown cases, the coverage shrink that stopped a one-factor game leading the list, the
  `minCoverage` floor and that lowering it is explicit, every gate reason, the three-way
  split, tie-breaking by app id, that `--surprise 0` always takes the best, that surprise is
  reproducible and monotone, and the weights file round trip.
- **Presentation tests** (`tests/tpresent.nim`) cover the UI's label layer, which is pure
  and so needs no window: verdict labels keep a readable display spelling that stays
  distinct from the wire spelling, missing genres, compatibility evidence and reviews
  produce no text rather than a placeholder, compatibility names a known blocker before a
  native build or a ProtonDB tier and carries the report count, review percentages round to
  whole numbers without emitting a decimal point, and a store link is offered only for a
  real app id.
- **Catalogue tests** (`tests/tcatalog.nim`) exercise the window's disk layer offline:
  companion paths follow the selected catalogue, search matches title, genres and tags with
  every token required, duplicate Steam ids group while unidentified listings stay
  independent, ranking precedes a stable alphabetical fallback, ratings persist through a
  temporary file that preserves external edits and creates nested folders, an unreadable
  ratings file is never overwritten, a write failure leaves memory unchanged, and damaged
  store or ratings lines become reported problems without aborting the browse.
- **Art tests** (`tests/tart.nim`) cover the cache contract and the downloader with image
  bodies seeded into the response cache: the file-name rule (including a URL with no
  usable extension), the thumbnail-versus-full fallback, header and screenshots written
  byte for byte, a second run downloading nothing, a missing image and a refused status
  reported as failures instead of raising, and `--limit` counting games rather than
  images.
- Run with `nim c -r tests/tester.nim`, and the same in `-d:release` and `-d:danger`.
  All three pass today.
- **Recorded-response tests** for decoders: capture real API JSON into fixtures, assert
  decode output. No network in the test suite, ever.

## 13. Roadmap

| Phase | Deliverable | Acceptance |
|---|---|---|
| 0 | `ludex parse` + `ludex list`/`show`, offline | **done**: golden test green on the real 2000-line file in debug, release and danger; `ludex list --runtime native --max-size 2GB` returns 318 of 1998 games |
| 1 | Free-source bulk ingest (Steam, SteamSpy, ProtonDB, AWAC, Deck) | **done**: four sources run end to end and cache, covering playability, anti-cheat, store facts, tags, Steam's own Linux verdicts and the picture URLs, with `--tier`, `--anticheat`, `--genre`, `--tag`, `--linux-build`, `--steamos` and `--deck` filters, and `ludex art` to fetch the images. Remaining polish is cache revalidation and resumable sweeps |
| 2 | PCGW tech facts + IGDB/RAWG + the 453-row match queue | ≥90% of rows have engine data or an explicit "no data" record; every fuzzy match has a confidence and is human-reviewable |
| 3 | Recommender: gates + `ScoreCard` + `pick`/`roll` | **done**: `rate`/`pick`/`why`/`weights`, gates that name their reason, six factors with coverage, a tunable threshold, and a reproducible roll |
| 4 | owlkettle UI (Collection and Game) | **done**: adaptive artwork gallery with bounded 24-game pages, catalogue-wide title/genre/tag search, preserved back position, contextual ratings and clearing, and external Steam handoff. Browsing is offline; preferences, diagnostics banners and metadata tables are removed from the ordinary flow. See [UI-REDESIGN.md](UI-REDESIGN.md) |
| 5 | Price history (ITAD) and a length source, weight fitting from your own ratings | weights recoverable from your own ratings; export to HTML/JSON |

## 14. Risks

1. **owlkettle needs GTK4 at build and run time — resolved.** GTK4 4.22 and libadwaita 1.9
   are installed, and owlkettle 3.1.0 compiles on system Nim 2.3.1. The bindings link via
   `pkg-config`, so the shared libraries suffice and no `-devel` headers were needed; the
   earlier reading that they were came from a container without the libraries at all. The
   core and CLI still carry no GTK dependency, which is why they build anywhere.
2. **Dependency portability — settled, not a risk.** `brian` uses `copyMem` and so builds
   on the C backend only. Since the target is native (§5), this costs nothing; it would
   only matter if a browser target were ever revived, in which case `store.nim` is the one
   module that has to change.
3. **Rate limits vs 1545 games** — Steam appdetails at ~200 req/5 min means a full
   appdetails sweep is ~40 minutes minimum, and `cc`/`l` enumeration multiplies it. Cache
   aggressively, allow partial ingest, and never re-fetch unchanged data.
4. **PCGW bot password** — Cargo queries now require authentication. If that is a
   blocker, fall back to IGDB `engine` + Steam depot hints, and mark tech facts lower
   confidence.
5. **Critic scores are the weakest link** — Metacritic has no API, OpenCritic's free tier
   is 200/day. Expect critic coverage to be partial; the Steam user score and ProtonDB
   tier are the reliable ones. Be honest about coverage in the UI rather than faking
   precision.
6. **Matching the 453 AppID-less rows** — some (`Need for Speed: Underground Collection`,
   mod packs, collections) may never resolve cleanly. Keep them as first-class
   title-keyed games rather than dropping them.
7. **Taste model overfitting** — a 2000-row catalog with a handful of ratings is easy to
   overfit. Keep the weights in a config file, keep v1 linear and explainable, and do not
   reach for a learned ranker until the labels exist.

## 15. Open questions

- Should the catalog be limited to games that run well on Linux, or keep everything with
  a playability badge? (Current design: keep everything, gate at pick time.)
- Hardware profile: manual entry, or auto-detect from `lspci`/`/proc/meminfo` (a small
  `std/os`-using helper outside core)?
- Multi-user / shared taste profiles — worth it, or single-profile forever?
- Do you want the Steam-library import (own playtime, unplayed backlog) in v1 or v2?
  It needs your Steam Web API key and is the single biggest boost to recommender quality.
