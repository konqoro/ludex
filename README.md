# ludex

A local-first catalogue of Linux-playable games: it parses a game listing, resolves each
entry to a stable identity, and is built to aggregate critic scores, Steam user reviews,
price, engine/tech facts and Proton playability so it can answer one question, **what do I
play next?**

Status: phases 0, 1, 3 and 4 done. Four sources are wired end to end: ProtonDB (one call
per game) for playability, AreWeAntiCheatYet (one file for everything it tracks) for
anti-cheat, Steam (three calls per game) for store facts, review scores and Steam's own
Linux verdicts, and SteamSpy for the weighted tags the ranking is built on. On top of that
sit a ratings file, a tag-based taste profile, gated and explainable scoring, and a
reproducible "pick for me". Parsing, filtering, storage and enrichment all work offline
against a response cache. A native GTK4/libadwaita window (`ludex-ui`) browses the same
store with the same filters, the same recommender and no network. See `docs/DESIGN.md` for
the full design, the data-source survey, and the roadmap.

Target: a native desktop application, built with `nim c` and shipping as an executable.
There is no browser build.

## Dependencies

Dependencies are managed with [Atlas](https://github.com/nim-lang/atlas); `nimble` is not
used. JSON is handled exclusively by [brian](https://github.com/planetis-m/brian), which
decodes straight into Nim types with no intermediate DOM.

```sh
atlas install     # resolves and clones deps/brian
atlas pin         # records the exact commit in atlas.lock
```

Atlas appends its own section to `nim.cfg` with the dependency paths, leaving anything
written outside that section alone. `deps/` is generated and git-ignored; `atlas.lock` is
committed so the resolution is reproducible.

## Build and run

```sh
nim c -o:bin/ludex src/ludex.nim

# The desktop window (needs GTK4 and libadwaita at build and run time).
nim c -o:bin/ludex-ui src/ludexui/app.nim
bin/ludex-ui

# The listing into a store.
bin/ludex parse --table tests/fixtures/listing-table.md --out data/releases.jsonl

# Browse it.
bin/ludex list --store data/releases.jsonl --runtime native --max-size 2GB
bin/ludex list --store data/releases.jsonl --lang ENG --title disco
bin/ludex show 632470 --store data/releases.jsonl

# Ask how the games actually run. ProtonDB is one request per game, so start
# small: each request is held back until --delay has passed since the last one
# (paced, not bursted), a sweep can be capped or rerun, and every answer is cached.
bin/ludex enrich --store data/releases.jsonl --limit 60
bin/ludex list --store data/releases.jsonl --tier gold

# Ask whether an anti-cheat blocks Linux. This one is a single request for
# every game it tracks.
bin/ludex enrich --store data/releases.jsonl --source anticheat
bin/ludex list --store data/releases.jsonl --anticheat broken,denied
bin/ludex list --store data/releases.jsonl --anticheat running,supported

# Ask Steam what a game is: genres, developer, price, Linux build, the share of
# positive reviews, and Steam's own verdicts for the handheld and for desktop
# Linux. Three calls per game, so it is the slowest source and the one most
# worth running in chunks.
bin/ludex enrich --store data/releases.jsonl --source steam --limit 20
bin/ludex list --store data/releases.jsonl --genre strategy
bin/ludex list --store data/releases.jsonl --linux-build
bin/ludex list --store data/releases.jsonl --steamos playable

# Ask what players say a game is. SteamSpy's weighted tags are what the
# ranking is built on, and they already filter well on their own. This is the
# sweep worth running first: it is what unlocks the "fit" factor.
bin/ludex enrich --store data/releases.jsonl --source steamspy --limit 400
bin/ludex list --store data/releases.jsonl --tag puzzle

# The store also says what the game looks like, and `enrich --source steam`
# records those URLs. `art` downloads the pictures next to the data, so the
# window can show them without ever opening a socket.
bin/ludex art --limit 50        # page art, header and screenshots, a few at a time
bin/ludex art                   # the rest; already-downloaded files are skipped

# Say what you thought of a few games, then ask what to play.
bin/ludex rate 1264280 loved
bin/ludex rate 729000 bounced
bin/ludex rate 1237970 skipped
bin/ludex pick --store data/releases.jsonl --limit 10
bin/ludex why 1615290 --store data/releases.jsonl     # every factor, spelled out
bin/ludex pick --store data/releases.jsonl --surprise 0.5 --seed 7
```

`pick` ranks only what it has evidence about, and says so:

```
taste     Strategy, Turn-Based Strategy, Sandbox, Turn-Based, Singleplayer, Puzzle
avoids    Crafting, Investigation, Female Protagonist
7 candidates, 7 blocked, 1984 with no data yet
```

`why` shows the arithmetic behind one game:

```
Ravenous Devils  [1615290]
  score     79.5% from 95% of the weight known
  quality     93%  92.6% of 9916 reviews, Very Positive, smoothed to 92.5%
  fit         57%  tag similarity 0.15 (Management, Cooking, Villain Protagonist)
  run         95%  ProtonDB platinum over 8 reports
  price       80%  USD 4.99
  popularity  80%  9482 players recommend it
  effort     unknown  no time budget given
```

The weights are tunable without a rebuild:

```sh
bin/ludex weights --out data/weights.json
bin/ludex pick --store data/releases.jsonl --weights data/weights.json
```

Run `bin/ludex help` for the full option list.

`enrich` writes `data/enrichment.jsonl` and caches every response under `data/cache`, so a
second run asks for nothing. `--offline` runs from the cache alone, `--refresh` ignores it,
and `--delay`/`--limit` keep a sweep civil: up to four requests may be in flight, but
`--delay` is a floor between them, so the source sees a fixed rate rather than a burst.
What a game is worth:

```
{"appid":1264280,"play":{"tier":{"value":"platinum","source":"protondb","fetchedAt":1789821650,"confidence":1.0},"tierScore":{"value":0.71,"source":"protondb","fetchedAt":1789821650,"confidence":1.0},"reports":{"value":31,"source":"protondb","fetchedAt":1789821650,"confidence":1.0},"tierConfidence":"strong"}}
```

The store is newline-delimited JSON, one game per line, with absent fields omitted rather
than written as `null`:

```json
{"line":3,"row":"game","title":"Slipways","norm":"slipways","pack":"single","runtime":"wine","appid":1264280,"build":"b15946357","lang":"MULTi6","size":130023424,"hash":"cc2c41701cf2eca25f749ff26c0aedfaee1d2e5e"}
```

## Desktop UI

Open `bin/ludex-ui` to find your next game. An artwork gallery puts recommendations
first, followed by the rest of the catalogue by title. Choose a game to see its Linux
compatibility, player reviews and screenshots, then **View on Steam** to take the next
step. This opens the store externally; Ludex does not track installations or launch games.

- Search the whole catalogue by title, genre or tag with **Ctrl+F**; **Esc** closes search.
- Go back with **Alt+Left** and keep your search, gallery page and scroll position.
- Use **Rate Game** on a game's page to guide future recommendations, or clear a rating.
  Ratings are saved immediately to the same file the CLI uses.
- Open another catalogue or reload it from the main menu. There is no preferences screen;
  ranking and appearance follow the catalogue defaults and system settings.

The gallery adapts from one column in narrow windows to multiple columns as space allows.
Pages hold 24 games to keep artwork loading responsive with large catalogues. Search
always covers every page.

Browsing is offline: `ludex enrich` supplies metadata and `ludex art` downloads pictures.
Missing artwork and optional facts stay unobtrusive. An empty catalogue offers
**Open Catalogue**, and technical load details are available through the menu only when
needed.

## Tests

```sh
nim c -r tests/tester.nim                # debug
nim c -d:release -r tests/tester.nim
nim c -d:danger -r tests/tester.nim
```

`tests/tester.nim` discovers every `t*.nim` in `tests/`. The suite is deterministic and
offline: `tests/fixtures/listing-table.md` is a verbatim copy of the upstream listing, and
`tests/tparse.nim` asserts its exact shape (1998 games, 1545 Steam appids, runtime split
1456/365/16/161, and so on). If a parser change moves those numbers, that is a decision to
make deliberately, not to discover in production.

No test touches the network. The decoders run against recorded responses in
`tests/fixtures/protondb/`, and the ingest tests seed a response cache and run the client
in offline mode, so the whole path is exercised deterministically.

## Documentation

```sh
nim doc --outdir:/tmp/ludexdoc src/ludexcore/parse.nim
```

## Layout

| Path | Role |
|---|---|
| `src/ludexcore/` | pure core: models, parsing, normalization, filtering, storage |
| `src/ludexcore/sources/` | pure decoders for one upstream source each |
| `src/ludexingest/` | cached, rate-limited HTTP: the enrich pipeline and the art downloader |
| `src/ludex.nim` | CLI, which owns the file system and the network |
| `src/ludexui/` | native GTK4 window: `catalog` reads the files, `present` words them, `app` draws them |
| `tests/` | golden parse test, query, store, decoder, offline ingest and presentation tests |
| `data/` | generated store (`releases.jsonl`) and the image cache (`data/art/`) |
| `deps/` | Atlas-managed checkouts (generated) |
| `docs/DESIGN.md` | design, data-source survey, recommender plan, roadmap |

`ludexcore` performs no I/O: parsing, filtering and scoring are pure functions over plain
data, which is why the tests need no network. The CLI, the ingest layer and `ludexui`
own the file system; only the ingest layer touches the network.
