## Tests for the cached client and the enrichment pipeline.
##
## Nothing here touches the network. Instead the cache is seeded with recorded
## responses and the client is put in offline mode, which exercises the whole
## path, cache lookup, decode, merge and failure recording, while keeping the
## suite deterministic.

import std/[options, os, strutils, tables]

import ludexcore/[models, sources/awac, sources/protondb, store]
import ludexcore/sources/[steamdeck, steamreviews, steamspy, steamstore]
import ludexingest/[cache, enrich, fetch]

const
  ProtonDir = currentSourcePath().parentDir() / "fixtures" / "protondb"
  AwacPath = currentSourcePath().parentDir() / "fixtures" / "awac-games.json"
  SteamDir = currentSourcePath().parentDir() / "fixtures" / "steam"
  SpyDir = currentSourcePath().parentDir() / "fixtures" / "steamspy"

proc fixture(name: string): string =
  readFile(ProtonDir / name)

proc tempCacheDir(): string =
  result = getTempDir() / "ludex-test-cache"
  removeDir(result)
  createDir(result)

proc release(appid: int; title: string): Release =
  Release(rowKind: rkGame, title: title, titleNorm: title.toLowerAscii,
          pack: pkSingle, runtime: rkWine, appid: some(appid))

proc seed(client: Client; appid: int; status: int; body: string) =
  client.writeCacheEntry(summaryUrl(appid), status, body)

block cache_file_names:
  doAssert cacheFileName("https://a/b.json") == "https___a_b.json"
  doAssert cacheFileName("") == ""
  doAssert cacheFileName("plain") == "plain", "a safe name is left alone"
  doAssert cacheFileName("x".repeat(400)).len == 180, "long names are capped"

block offline_cache_hit:
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  client.seed(1264280, 200, fixture("1264280-platinum-strong.json"))
  let fetched = fetch(client, summaryUrl(1264280))
  doAssert fetched.status == 200
  doAssert fetched.cached
  doAssert fetched.body.contains("platinum")
  doAssert client.hits == 1
  doAssert client.requests == 0, "offline never sends anything"
  client.close()

block offline_cache_miss_raises:
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  doAssertRaises FetchError:
    discard fetch(client, summaryUrl(1))
  client.close()

block a_404_is_remembered_as_an_answer:
  # ProtonDB answers 404 for a game nobody has reported. That is a fact worth
  # caching, not an error worth repeating.
  let dir = tempCacheDir()
  let client = initClient(dir, delayMs = 0, offline = true)
  client.seed(999999999, 404, "")
  let fetched = fetch(client, summaryUrl(999999999))
  doAssert fetched.status == 404
  doAssert fetched.body.len == 0
  client.close()

block corrupt_cache_entry_is_a_miss:
  let dir = tempCacheDir()
  let client = initClient(dir, delayMs = 0, offline = true)
  createDir(dir)
  writeFile(client.cachePath(summaryUrl(7)), "this is not a cache entry")
  doAssertRaises FetchError:
    discard fetch(client, summaryUrl(7))
  client.close()

block empty_cache_dir_is_created_on_write:
  let dir = getTempDir() / "ludex-test-cache-nested" / "deeper"
  removeDir(dir.parentDir)
  let client = initClient(dir, delayMs = 0, offline = true)
  client.seed(1, 200, "{}")
  doAssert fileExists(client.cachePath(summaryUrl(1)))
  client.close()
  removeDir(dir.parentDir)

block pipeline_answers_and_silence:
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  client.seed(1264280, 200, fixture("1264280-platinum-strong.json"))
  client.seed(1281270, 200, fixture("1281270-gold-moderate.json"))
  client.seed(4403510, 404, "")
  let releases = @[
    release(1264280, "Slipways"),
    release(1281270, "Fatum Betula"),
    release(4403510, "Sensory Overload"),
    Release(rowKind: rkGame, title: "Arco", titleNorm: "arco",
            pack: pkSingle, runtime: rkUnknown),
  ]
  let run = enrichSummary(client, releases, newSeq[Enrichment]())
  client.close()

  doAssert run.stats.asked == 3, "the game without an app id is not asked about"
  doAssert run.stats.answered == 2
  doAssert run.stats.silent == 1
  doAssert run.stats.cached == 3
  doAssert run.stats.failed == 0
  doAssert run.items.len == 2, "nothing is stored for a game nobody reported"

  doAssert run.items[0].appid == 1264280
  doAssert run.items[0].play.tier.get.value == ptPlatinum
  doAssert run.items[0].play.reportCount.get.value == 31
  doAssert run.items[0].play.tierConfidence == some("strong")
  doAssert run.items[1].appid == 1281270
  doAssert run.items[1].play.tier.get.value == ptGold

block limit_stops_the_sweep:
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  let releases = @[release(1, "One"), release(2, "Two"), release(3, "Three")]
  let run = enrichSummary(client, releases, newSeq[Enrichment](), limit = 2)
  client.close()
  doAssert run.stats.asked == 2, "a partial sweep asks only what it was told"
  doAssert run.stats.failed == 2, "both asks missed the cache"

block merge_keeps_other_sources_facts:
  # A ProtonDB run must not erase an anti-cheat fact learned elsewhere, and a
  # game the source is silent about must keep what it already had.
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  client.seed(1264280, 200, fixture("1264280-platinum-strong.json"))
  let existing = @[
    Enrichment(appid: 1264280, play: Playability(
      antiCheat: some initFact(acBroken, srcAntiCheatYet, 500),
      antiCheatNames: some(@["EAC"]))),
    Enrichment(appid: 4403510, play: Playability(
      antiCheat: some initFact(acRunning, srcAntiCheatYet, 500))),
  ]
  let releases = @[release(1264280, "Slipways"), release(4403510, "Sensory")]
  let run = enrichSummary(client, releases, existing)
  client.close()

  doAssert run.items.len == 2
  var byId = initTable[int, Enrichment]()
  for item in run.items:
    byId[item.appid] = item
  doAssert byId[1264280].play.antiCheat.get.value == acBroken,
    "the other source's fact survives"
  doAssert byId[1264280].play.antiCheatNames == some(@["EAC"])
  doAssert byId[1264280].play.tier.get.value == ptPlatinum
  doAssert byId[4403510].play.antiCheat.get.value == acRunning,
    "a silent source changes nothing"

block failures_are_recorded_not_fatal:
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  client.seed(2, 200, fixture("1281270-gold-moderate.json"))
  let releases = @[release(1, "Missing"), release(2, "Present")]
  let run = enrichSummary(client, releases, newSeq[Enrichment]())
  client.close()
  doAssert run.stats.failed == 1, "the cache miss is one failure"
  doAssert run.stats.answered == 1
  doAssert run.stats.failures.len == 1
  doAssert run.stats.failures[0].startsWith("1: ")
  doAssert run.stats.failures[0].contains("offline")

block malformed_response_is_recorded_not_fatal:
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  client.seed(1, 200, """{"tier": """)
  client.seed(2, 200, fixture("1281270-gold-moderate.json"))
  let releases = @[release(1, "Broken"), release(2, "Present")]
  let run = enrichSummary(client, releases, newSeq[Enrichment]())
  client.close()
  doAssert run.stats.failed == 1
  doAssert run.stats.answered == 1
  doAssert run.stats.failures[0].contains("decode")

block results_are_ordered_by_app_id:
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  client.seed(1281270, 200, fixture("1281270-gold-moderate.json"))
  client.seed(1264280, 200, fixture("1264280-platinum-strong.json"))
  let releases = @[release(1281270, "Later"), release(1264280, "Earlier")]
  let run = enrichSummary(client, releases, newSeq[Enrichment]())
  client.close()
  doAssert run.items[0].appid == 1264280, "output is stable across runs"
  doAssert run.items[1].appid == 1281270

block enrichment_store_round_trip:
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  client.seed(1264280, 200, fixture("1264280-platinum-strong.json"))
  let run = enrichSummary(client, @[release(1264280, "Slipways")],
                          newSeq[Enrichment]())
  client.close()

  let encoded = encodeEnrichments(run.items)
  doAssert not encoded.contains("null"), "absent fields are omitted, not nulled"
  let decoded = decodeEnrichments(encoded)
  doAssert decoded.failures.len == 0
  doAssert decoded.items.len == run.items.len
  for index in 0..<run.items.len:
    doAssert decoded.items[index].appid == run.items[index].appid
    doAssert decoded.items[index].play.tier.get.value == ptPlatinum
    doAssert decoded.items[index].play.tier.get.source == srcProtonDb
    doAssert decoded.items[index].play.tier.get.fetchedAt ==
      run.items[index].play.tier.get.fetchedAt
    doAssert decoded.items[index].play.reportCount.get.value == 31
    doAssert decoded.items[index].play.tierConfidence == some("strong")

block enrichment_store_rejects_junk:
  let decoded = decodeEnrichments("""
{"appid":1,"play":{"tier":{"value":"gold","source":"protondb","fetchedAt":1,"confidence":1.0}}}
{"play":{"tier":{}}}
{"appid":2,"play":{"tier":{"value":"diamond","source":"protondb","fetchedAt":1,"confidence":1.0}}}
""")
  doAssert decoded.items.len == 1
  doAssert decoded.failures.len == 2
  doAssert decoded.failures[0].contains("app id")
  doAssert decoded.failures[1].contains("PlayTier"),
    "the message names the enum that could not be decoded"

block anticheat_is_one_request_for_everyone:
  # This source answers once for the whole catalogue, so `limit` has nothing to
  # limit and the counters describe the join rather than requests made.
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  client.writeCacheEntry(GamesUrl, 200, readFile(AwacPath))
  let releases = @[
    release(440900, "Conan Exiles Enhanced"),  # Broken upstream
    release(1237970, "Titanfall 2"),           # Supported upstream
    release(999999, "Not tracked at all"),
    Release(rowKind: rkGame, title: "Arco", titleNorm: "arco",
            pack: pkSingle, runtime: rkUnknown),  # no app id
  ]
  let run = enrichAntiCheat(client, releases, newSeq[Enrichment](), limit = 1)
  client.close()

  doAssert run.stats.asked == 3, "limit does not apply to a whole-dataset source"
  doAssert run.stats.answered == 2
  doAssert run.stats.silent == 1
  doAssert run.stats.failed == 0
  doAssert run.items.len == 2, "a game nobody tracks gets no record"

  var byId = initTable[int, Enrichment]()
  for item in run.items:
    byId[item.appid] = item
  doAssert byId[440900].play.antiCheat.get.value == acBroken
  doAssert byId[440900].play.antiCheatNames == some(@["BattlEye"])
  doAssert blocksLinux(byId[440900].play.antiCheat.get.value)
  doAssert byId[1237970].play.antiCheat.get.value == acSupported
  doAssert byId[1237970].play.antiCheat.get.source == srcAntiCheatYet

block anticheat_merges_with_protondb_facts:
  # The two sources must layer, not overwrite: a game can be platinum on
  # ProtonDB and still be blocked by its anti-cheat, and a later run of either
  # source must leave the other's facts alone.
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  client.writeCacheEntry(GamesUrl, 200, readFile(AwacPath))
  let existing = @[Enrichment(
    appid: 1237970,
    play: toPlayability(decodeSummary(fixture("1264280-platinum-strong.json")),
                        fetchedAt = 11))]
  let run = enrichAntiCheat(client, @[release(1237970, "Titanfall 2")], existing)
  client.close()

  doAssert run.items.len == 1
  let play = run.items[0].play
  doAssert play.tier.get.value == ptPlatinum, "the ProtonDB fact survives"
  doAssert play.reportCount.get.value == 31
  doAssert play.antiCheat.get.value == acSupported, "and the new fact lands"
  doAssert play.antiCheatNames == some(@["FairFight"])

block a_failed_dataset_is_one_failure:
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  client.writeCacheEntry(GamesUrl, 404, "")
  let run = enrichAntiCheat(client, @[release(1, "One"), release(2, "Two")],
                            newSeq[Enrichment]())
  client.close()
  doAssert run.stats.failed == 1
  doAssert run.stats.answered == 0
  doAssert run.stats.failures.len == 1
  doAssert run.stats.failures[0].contains("404")

block dispatch_by_name:
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  client.writeCacheEntry(GamesUrl, 200, readFile(AwacPath))
  let run = enrich(client, srcAntiCheat, @[release(440900, "Conan Exiles")],
                   newSeq[Enrichment]())
  client.close()
  doAssert run.stats.answered == 1
  doAssert run.items[0].play.antiCheat.get.value == acBroken

proc steamFixture(name: string): string =
  readFile(SteamDir / name)

proc spyFixture(name: string): string =
  readFile(SpyDir / name)

block steam_needs_two_calls_per_game:
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  client.writeCacheEntry(detailsUrl(1264280, "us"), 200,
                         steamFixture("1264280-appdetails.json"))
  client.writeCacheEntry(reviewsUrl(1264280), 200,
                         steamFixture("1264280-reviews.json"))
  client.writeCacheEntry(detailsUrl(1999520, "us"), 200,
                         steamFixture("1999520-appdetails.json"))
  client.writeCacheEntry(reviewsUrl(1999520), 200,
                         steamFixture("1999520-reviews.json"))
  # `success: false` is Steam saying it has no such app, which is silence.
  client.writeCacheEntry(detailsUrl(4403510, "us"), 200,
                         steamFixture("999999999-appdetails.json"))
  client.writeCacheEntry(reviewsUrl(4403510), 404, "")
  client.writeCacheEntry(deckUrl(1999520), 200,
                         steamFixture("1999520-deck.json"))
  client.writeCacheEntry(deckUrl(1264280), 404, "")
  client.writeCacheEntry(deckUrl(4403510), 404, "")

  let releases = @[
    release(1264280, "Slipways"),
    release(1999520, "CATO"),
    release(4403510, "Sensory Overload"),
  ]
  let run = enrichSteam(client, releases, newSeq[Enrichment]())
  client.close()

  doAssert run.stats.asked == 3
  doAssert run.stats.answered == 2
  doAssert run.stats.silent == 1, "an app Steam has no entry for is not a failure"
  doAssert run.stats.cached == 9, "three answers per game"
  doAssert run.stats.failed == 0
  doAssert run.items.len == 2

  var byId = initTable[int, Enrichment]()
  for item in run.items:
    byId[item.appid] = item

  let slipways = byId[1264280].store
  doAssert slipways.kind == "game"
  doAssert slipways.genres == @["Strategy"]
  doAssert slipways.developers == @["Beetlewing"]
  doAssert slipways.price.get.value.final == 1699
  doAssert slipways.price.get.value.currency == "USD"
  doAssert not slipways.linuxBuild.get.value
  doAssert slipways.reviews.count.get.value == 2310
  doAssert slipways.reviews.percent.get.value == 92.8
  doAssert slipways.reviews.description == some("Very Positive")
  doAssert slipways.recommendations.get.value == 2233
  doAssert slipways.deck.isNone, "Steam has no Deck report for this one"
  doAssert slipways.steamos.isNone
  doAssert slipways.isKnown

  let cato = byId[1999520].store
  doAssert cato.linuxBuild.get.value, "Steam ships a Linux build for this one"
  doAssert cato.genres == @["Adventure", "Casual", "Indie"]
  doAssert cato.reviews.percent.get.value == 98.4
  doAssert cato.deck.get.value == lvVerified
  doAssert cato.steamos.get.value == lvPlayable,
    "verified on the handheld, merely playable on desktop Linux"
  doAssert cato.deck.get.source == srcSteam

block one_steam_call_succeeding_is_worth_keeping:
  # A store entry that vanished can still have reviews, and vice versa.
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  client.writeCacheEntry(detailsUrl(7, "us"), 404, "")
  client.writeCacheEntry(reviewsUrl(7), 200,
                         steamFixture("1264280-reviews.json"))
  client.writeCacheEntry(deckUrl(7), 404, "")
  let run = enrichSteam(client, @[release(7, "Only Reviews")],
                        newSeq[Enrichment]())
  client.close()
  doAssert run.stats.answered == 1
  doAssert run.items[0].store.reviews.count.get.value == 2310
  doAssert run.items[0].store.genres.len == 0, "and nothing else was invented"

block steam_facts_merge_across_sources:
  # A Steam run must not disturb playability, and a playability run must not
  # disturb the store.
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  client.writeCacheEntry(detailsUrl(1264280, "us"), 200,
                         steamFixture("1264280-appdetails.json"))
  client.writeCacheEntry(reviewsUrl(1264280), 200,
                         steamFixture("1264280-reviews.json"))
  client.writeCacheEntry(deckUrl(1264280), 404, "")
  let existing = @[Enrichment(
    appid: 1264280,
    play: toPlayability(decodeSummary(fixture("1264280-platinum-strong.json")),
                        fetchedAt = 3))]
  let run = enrichSteam(client, @[release(1264280, "Slipways")], existing)
  client.close()
  doAssert run.items[0].play.tier.get.value == ptPlatinum, "playability survives"
  doAssert run.items[0].store.genres == @["Strategy"], "and the store lands"
  doAssert run.items[0].store.price.get.value.final == 1699

block steam_facts_merge_is_per_field:
  let base = SteamFacts(kind: "game", genres: @["Strategy"],
                        developers: @["Beetlewing"], isFree: false)
  let update = SteamFacts(kind: "game", price: some initFact(
    Price(currency: "USD", initial: 999, final: 499, discountPercent: 50),
    srcSteam, 9))
  let merged = mergeSteamFacts(base, update)
  doAssert merged.genres == @["Strategy"], "untouched fields stay"
  doAssert merged.price.get.value.final == 499, "and new ones land"
  doAssert not merged.isFree

  let empty = mergeSteamFacts(base, SteamFacts())
  doAssert empty == base, "a silent answer changes nothing"
  doAssert mergeSteamFacts(SteamFacts(), base) == base

block store_facts_survive_the_store:
  # The enrichment file is the only place these facts live between runs, so the
  # codec and the merge both have to keep them.
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  client.writeCacheEntry(detailsUrl(1999520, "us"), 200,
                         steamFixture("1999520-appdetails.json"))
  client.writeCacheEntry(reviewsUrl(1999520), 200,
                         steamFixture("1999520-reviews.json"))
  client.writeCacheEntry(deckUrl(1999520), 200,
                         steamFixture("1999520-deck.json"))
  let run = enrichSteam(client, @[release(1999520, "CATO")],
                        newSeq[Enrichment]())
  client.close()

  let encoded = encodeEnrichments(run.items)
  doAssert not encoded.contains("null"), "absent fields are still omitted"
  let decoded = decodeEnrichments(encoded)
  doAssert decoded.failures.len == 0
  doAssert decoded.items.len == 1
  let facts = decoded.items[0].store
  doAssert facts.kind == "game"
  doAssert facts.genres == @["Adventure", "Casual", "Indie"]
  doAssert facts.categories.len > 5
  doAssert facts.developers == @["Team Woll"]
  doAssert facts.linuxBuild.get.value
  doAssert facts.linuxBuild.get.source == srcSteam
  doAssert facts.releaseDate == some initFact("Sep 5, 2024", srcSteam,
    facts.releaseDate.get.fetchedAt)
  doAssert facts.price.get.value.currency == "USD"
  doAssert facts.price.get.value.final == 1099
  doAssert facts.reviews.count.get.value == 3143
  doAssert facts.reviews.percent.get.value == 98.4
  doAssert facts.reviews.description == some("Overwhelmingly Positive")
  doAssert facts.recommendations.get.value == 2795
  # Pictures travel the whole path too: decoded from the store, merged, encoded
  # and read back. They are the field most easily dropped by a merge that names
  # every field by hand, and dropping them is silent.
  doAssert facts.art.header.isSome
  doAssert facts.art.header.get.value.contains("header.jpg")
  doAssert facts.art.screenshots.isSome
  doAssert facts.art.screenshots.get.value.len == 14
  doAssert facts.art.screenshots.get.value[0].thumbnail.contains("600x338")

block art_survives_a_merge:
  # The regression this exists for: `mergeSteamFacts` lists each field by hand,
  # so a field it forgets decodes fine and then never reaches the store. The
  # window would simply never show a picture, with nothing reporting a problem.
  let base = SteamFacts(kind: "game", genres: @["Strategy"])
  let update = SteamFacts(kind: "game", art: ArtFacts(
    background: some initFact("https://example.test/page_bg_raw.jpg", srcSteam, 4),
    header: some initFact("https://example.test/header.jpg", srcSteam, 4),
    screenshots: some initFact(@[
      Screenshot(thumbnail: "https://example.test/1.600x338.jpg",
                 full: "https://example.test/1.1920x1080.jpg")], srcSteam, 4)))
  let merged = mergeSteamFacts(base, update)
  doAssert merged.genres == @["Strategy"], "untouched fields stay"
  doAssert merged.art.background.isSome, "the wide page art lands too"
  doAssert merged.art.header.isSome, "and the pictures land"
  doAssert merged.art.screenshots.get.value.len == 1

  # A source that knows nothing about pictures cannot erase them either.
  let kept = mergeSteamFacts(merged, SteamFacts(kind: "game"))
  doAssert kept.art == merged.art

block pitch_and_press_score_survive_a_merge:
  # Same trap as the pictures: the merge names every field, so a new one is
  # dropped without a word unless it is listed there too.
  let base = SteamFacts(kind: "game", genres: @["Strategy"])
  let update = SteamFacts(kind: "game",
    shortDescription: "Weave isolated planets into a vast trade empire.",
    critics: some Critics(score: initFact(80, srcSteam, 4),
                          url: some "https://www.metacritic.com/game/pc/x"))
  let merged = mergeSteamFacts(base, update)
  doAssert merged.genres == @["Strategy"]
  doAssert merged.shortDescription.len > 0, "the store pitch lands"
  doAssert merged.critics.isSome, "and so does the press score"
  doAssert merged.critics.get.score.value == 80

  let kept = mergeSteamFacts(merged, SteamFacts(kind: "game"))
  doAssert kept.shortDescription == merged.shortDescription
  doAssert kept.critics == merged.critics

block a_record_with_no_facts_is_rejected:
  let decoded = decodeEnrichments("""{"appid":5,"play":{},"store":{}}""")
  doAssert decoded.items.len == 0
  doAssert decoded.failures.len == 1
  doAssert decoded.failures[0].contains("no facts")

block steamspy_tags_and_counts:
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  client.writeCacheEntry(spyUrl(1264280), 200, spyFixture("1264280.json"))
  client.writeCacheEntry(spyUrl(1999520), 200, spyFixture("1999520.json"))
  # SteamSpy answers `{}` for an app it does not track.
  client.writeCacheEntry(spyUrl(4403510), 200, "{}")

  let releases = @[release(1264280, "Slipways"), release(1999520, "CATO"),
                   release(4403510, "Sensory Overload")]
  let run = enrichSteamSpy(client, releases, newSeq[Enrichment]())
  client.close()

  doAssert run.stats.asked == 3
  doAssert run.stats.answered == 2
  doAssert run.stats.silent == 1, "an untracked app is silence, not a failure"
  doAssert run.stats.cached == 3
  doAssert run.stats.failed == 0

  var byId = initTable[int, Enrichment]()
  for item in run.items:
    byId[item.appid] = item
  let slipways = byId[1264280].store
  doAssert slipways.tags.get.value.len == 20
  doAssert slipways.tags.get.source == srcSteamSpy
  doAssert slipways.tags.get.value[0].name == "Strategy"
  doAssert slipways.owners.get.value == "200,000 .. 500,000"
  doAssert slipways.currentPlayers.get.value == 10
  doAssert slipways.tags.get.value.topTags(3) ==
    @["Strategy", "Puzzle", "Turn-Based Strategy"]
  doAssert byId[1999520].store.tags.get.value[0].name == "Puzzle-Platformer"

block steamspy_and_steam_layer_without_overwriting:
  # The store's own fields and SteamSpy's tags come from different sources about
  # the same game, and a run of either must leave the other alone.
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  client.writeCacheEntry(detailsUrl(1264280, "us"), 200,
                         steamFixture("1264280-appdetails.json"))
  client.writeCacheEntry(reviewsUrl(1264280), 200,
                         steamFixture("1264280-reviews.json"))
  client.writeCacheEntry(deckUrl(1264280), 404, "")
  var existing: seq[Enrichment]
  existing = enrichSteam(client, @[release(1264280, "Slipways")], existing).items
  client.close()
  doAssert existing[0].store.genres == @["Strategy"], "the store landed"

  let spyClient = initClient(tempCacheDir(), delayMs = 0, offline = true)
  spyClient.writeCacheEntry(spyUrl(1264280), 200, spyFixture("1264280.json"))
  let run = enrichSteamSpy(spyClient, @[release(1264280, "Slipways")], existing)
  spyClient.close()

  let store = run.items[0].store
  doAssert store.genres == @["Strategy"], "the store facts survive SteamSpy"
  doAssert store.price.get.value.final == 1699
  doAssert store.reviews.count.get.value == 2310
  doAssert store.tags.get.value.len == 20, "and the tags land"
  doAssert store.reviews.count.get.source == srcSteam
  doAssert store.tags.get.source == srcSteamSpy

block tags_and_verdicts_survive_the_store:
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  client.writeCacheEntry(detailsUrl(1999520, "us"), 200,
                         steamFixture("1999520-appdetails.json"))
  client.writeCacheEntry(reviewsUrl(1999520), 200,
                         steamFixture("1999520-reviews.json"))
  client.writeCacheEntry(deckUrl(1999520), 200,
                         steamFixture("1999520-deck.json"))
  client.writeCacheEntry(spyUrl(1999520), 200, spyFixture("1999520.json"))
  let first = enrichSteam(client, @[release(1999520, "CATO")],
                          newSeq[Enrichment]()).items
  let run = enrichSteamSpy(client, @[release(1999520, "CATO")], first)
  client.close()

  let decoded = decodeEnrichments(encodeEnrichments(run.items))
  doAssert decoded.failures.len == 0
  let store = decoded.items[0].store
  doAssert store.deck.get.value == lvVerified
  doAssert store.steamos.get.value == lvPlayable
  doAssert store.deck.get.source == srcSteam
  doAssert store.tags.get.value.len == 20
  doAssert store.tags.get.value[0] == Tag(name: "Puzzle-Platformer", votes: 227)
  doAssert store.tags.get.source == srcSteamSpy
  doAssert store.owners.get.value == "200,000 .. 500,000"
  doAssert store.genres == @["Adventure", "Casual", "Indie"]

block a_failing_call_does_not_discard_the_others:
  # The three Steam calls are independent. In offline mode a cache miss stands
  # in for a call that failed, and the two that answered must survive.
  # The app id has to be the real one: `decodeApp` refuses an answer whose
  # envelope key does not match the app that was asked about, so a fixture
  # cannot be borrowed for an imaginary game.
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  client.writeCacheEntry(detailsUrl(1264280, "us"), 200,
                         steamFixture("1264280-appdetails.json"))
  client.writeCacheEntry(reviewsUrl(1264280), 200,
                         steamFixture("1264280-reviews.json"))
  # deckUrl(1264280) is deliberately not cached, so that call fails.
  let run = enrichSteam(client, @[release(1264280, "Partial")],
                        newSeq[Enrichment]())
  client.close()

  doAssert run.stats.partial == 1, "counted apart from a clean answer"
  doAssert run.stats.answered == 0
  doAssert run.stats.failed == 0, "the game was not a total loss"
  doAssert run.stats.failures.len == 1, "but the reason is still reported"
  doAssert run.stats.failures[0].contains("deck")
  doAssert run.items.len == 1
  doAssert run.items[0].store.genres == @["Strategy"], "the store survives"
  doAssert run.items[0].store.reviews.count.get.value == 2310
  doAssert run.items[0].store.deck.isNone
  doAssert run.items[0].store.isKnown

block a_game_where_everything_failed_is_a_failure:
  let client = initClient(tempCacheDir(), delayMs = 0, offline = true)
  let run = enrichSteam(client, @[release(11, "Nothing")],
                        newSeq[Enrichment]())
  client.close()
  doAssert run.stats.failed == 1
  doAssert run.stats.partial == 0
  doAssert run.stats.answered == 0
  doAssert run.stats.failures.len == 3, "one line per failed call"
  doAssert run.items.len == 0
