# Using ludex

The [README](../README.md) has the quick start. This file is the full
walkthrough: every command, the options that matter, and the on-disk formats.

ludex records a game listing, enriches it from four upstream sources, and then
lets the CLI or the native window answer **what do I play next?** Everything is
local once fetched.

## Build

```sh
atlas install      # resolve and clone deps/brian
atlas pin          # record the exact commit in atlas.lock
nim c -o:bin/ludex src/ludex.nim

# The desktop window, which needs GTK4 and libadwaita at build and run time.
nim c -o:bin/ludex-ui src/ludexui/app.nim
bin/ludex-ui
```

Dependencies are managed with [Atlas](https://github.com/nim-lang/atlas); `nimble`
is not used. `deps/` is generated and git-ignored, and `atlas.lock` is committed
so the resolution is reproducible.

## 1. Parse a listing

Turn the listing table into a newline-delimited JSON store. Each row is resolved
to a stable identity and a runtime (`native`, `wine`, `both` or `unknown`).

```sh
bin/ludex parse --table tests/fixtures/listing-table.md --out data/releases.jsonl
```

## 2. Browse the catalogue

`list` searches and filters in one pass. `show` prints everything known about one
game.

```sh
bin/ludex list --store data/releases.jsonl --runtime native --max-size 2GB
bin/ludex list --store data/releases.jsonl --lang ENG --title disco
bin/ludex list --store data/releases.jsonl --genre strategy        # needs enrichment
bin/ludex list --store data/releases.jsonl --linux-build
bin/ludex list --store data/releases.jsonl --steamos playable
bin/ludex show 632470 --store data/releases.jsonl
```

The filters most worth knowing:

| Option | Meaning |
|---|---|
| `--runtime native\|wine\|both\|unknown\|any` | How the release ships |
| `--max-size` / `--min-size` | e.g. `2GB` or `"2 GB"` |
| `--lang <token>` | `ENG`, `ENG/JPN`, `MULTi6`, … |
| `--title <text>` | Substring of the normalized title |
| `--tier <tier>` | Minimum ProtonDB tier (`bronze` … `platinum`) |
| `--anticheat <s>` | Exact statuses, comma-separated: `broken,denied` |
| `--steamos` / `--deck` | `verified`, `playable` or `unsupported` |
| `--linux-build` | Steam ships a Linux build |
| `--appid` / `--no-appid` | Has, or has no, Steam app id |
| `--limit <n>` | Cap the output |

## 3. Enrich from the sources

Enrichment is separate from parsing because it is the slow, networked half.
`enrich` writes `data/enrichment.jsonl` and caches every response under
`data/cache`, so a rerun asks for nothing (`--offline`, `--refresh` and
`--delay`/`--limit` are described below).

### ProtonDB — how it actually runs

One request per game, so start small. A sweep is paced and can be capped or
resumed.

```sh
bin/ludex enrich --store data/releases.jsonl --limit 60
bin/ludex list --store data/releases.jsonl --tier gold
```

### AreWeAntiCheatYet — what blocks Linux

One request for every game it tracks, so `--limit` does not apply.

```sh
bin/ludex enrich --store data/releases.jsonl --source anticheat
bin/ludex list --store data/releases.jsonl --anticheat broken,denied
bin/ludex list --store data/releases.jsonl --anticheat running,supported
```

### Steam — what the game is

Three requests per game: store details, review summary and the Deck
compatibility report. Genres, developer, price, Linux build, the share of
positive reviews, and Steam's verdicts for the handheld and desktop Linux.

```sh
bin/ludex enrich --store data/releases.jsonl --source steam --limit 20
bin/ludex list --store data/releases.jsonl --genre strategy
```

### SteamSpy — what players call it

Weighted tags are what the recommender's "fit" factor is built on, so this is
the sweep worth running first. One request per game; the data refreshes daily.

```sh
bin/ludex enrich --store data/releases.jsonl --source steamspy --limit 400
bin/ludex list --store data/releases.jsonl --tag puzzle
```

## 4. Download pictures

The Steam store gives image URLs; `art` downloads the bytes next to the data
(`data/art/<appid>/`). The window only ever opens the local files.

```sh
bin/ludex art --limit 50   # page art, header and screenshots, a few at a time
bin/ludex art              # the rest; already-downloaded files are skipped
```

Three kinds of file live in each game's folder: `background.*` (the wide page
art), `header.*` (the list image) and `shot-NN.*` (screenshots).

## 5. Rate and recommend

Ratings live in `data/ratings.jsonl` and feed the recommender.

```sh
bin/ludex rate 1264280 loved
bin/ludex rate 729000 bounced
bin/ludex rate 1237970 skipped
bin/ludex pick --store data/releases.jsonl --limit 10
bin/ludex why 1615290 --store data/releases.jsonl
```

`pick` options:

| Option | Meaning |
|---|---|
| `--time <hours>` | Session budget, for the effort factor |
| `--disk <size>` | Free space, e.g. `50GB` |
| `--surprise <0..1>` | How much to ignore the ranking, default 0 |
| `--limit <n>` | How many candidates to show, default 10 |
| `--include-blocked` | Keep games a gate excluded, and say why |
| `--weights <file>` | Weights written by `ludex weights` |
| `--seed <n>` | Fix the dice for a reproducible pick |

The weights are JSON, so you can tune the ranking without a rebuild:

```sh
bin/ludex weights --out data/weights.json
bin/ludex pick --store data/releases.jsonl --weights data/weights.json
```

## Default paths

| Path | Contents |
|---|---|
| `data/releases.jsonl` | The parsed store (`parse --out`) |
| `data/enrichment.jsonl` | Facts from the four sources (`enrich --out`) |
| `data/cache` | Raw HTTP responses, one file per URL |
| `data/ratings.jsonl` | Your ratings |
| `data/weights.json` | Tunable ranking weights |
| `data/art` | Downloaded pictures |

## The data format

The store is newline-delimited JSON, one game per line, compact. Absent fields
are omitted rather than written as `null`, because absence is a fact here.

```json
{"line":3,"row":"game","title":"Slipways","norm":"slipways","pack":"single","runtime":"wine","appid":1264280,"build":"b15946357","lang":"MULTi6","size":130023424,"hash":"cc2c41701cf2eca25f749ff26c0aedfaee1d2e5e"}
```

Every enriched value carries its provenance, so a price or score is never a
claim about the present without a timestamp:

```json
{"appid":1264280,"play":{"tier":{"value":"platinum","source":"protondb","fetchedAt":1789821650,"confidence":1.0},"tierScore":{"value":0.71,"source":"protondb","fetchedAt":1789821650,"confidence":1.0},"reports":{"value":31,"source":"protondb","fetchedAt":1789821650,"confidence":1.0},"tierConfidence":"strong"}}
```

## Offline, caching and pacing

- `--offline` never opens a socket and treats a cache miss as a failure.
- `--refresh` ignores the cache and fetches again.
- A rerun over a warm cache asks for nothing; answers are cached, problems are
  not, so a `429` or `5xx` is retried on the next run.
- `--delay` is a floor between submissions per source, and up to four requests
  may be in flight, so a source sees a fixed rate rather than a burst.
- `--limit` caps a sweep. For per-game sources it counts games; for the
  whole-dataset anti-cheat source it is ignored.

Run `bin/ludex help` for the condensed option list.
