## Round-trip and failure-reporting tests for the JSONL store.

import std/[options, os, strutils]

import brian

import ludexcore/[models, parse, store]

const FixturePath = currentSourcePath().parentDir() / "fixtures" / "listing-table.md"

let all = parseTable(readFile(FixturePath))

block empty_store:
  doAssert decodeReleases("").items.len == 0
  doAssert decodeReleases("\n\n  \n").items.len == 0
  doAssert encodeReleases(newSeq[Release]()) == ""

block wire_format:
  # The on-disk shape is a contract: short keys, omitted absences.
  let minimal = Release(rowKind: rkGame, pack: pkSingle, lineNumber: 7,
                        title: "Arco", titleNorm: "arco")
  doAssert toJson(minimal) == "{\"line\":7,\"row\":\"game\",\"title\":\"Arco\"," &
    "\"norm\":\"arco\",\"pack\":\"single\",\"runtime\":\"unknown\"}"

block absent_fields_stay_absent:
  let minimal = Release(rowKind: rkGame, pack: pkSingle, lineNumber: 7,
                        title: "Arco", titleNorm: "arco")
  let encoded = toJson(minimal)
  doAssert not encoded.contains("null"), "an absent value is omitted, never nulled"
  doAssert not encoded.contains("\"build\"")
  doAssert not encoded.contains("\"langs\""), "empty sequences are omitted too"
  doAssert not encoded.contains("\"warnings\"")
  let decoded = decodeReleases(encoded)
  doAssert decoded.failures.len == 0
  doAssert decoded.items == @[minimal]

block every_field_survives:
  let rich = Release(
    rowKind: rkGame,
    lineNumber: 42,
    title: "David Szymanski Collection",
    titleNorm: "david szymanski collection",
    pack: pkCollection,
    buildId: some("b13697029"),
    version: some("1.3.8"),
    langToken: some("MULTi12/7"),
    langs: @["ENG", "JPN"],
    runtime: rkBoth,
    appid: some(632470),
    sizeBytes: some(47828822016'i64),
    infoHash: some("cc2c41701cf2eca25f749ff26c0aedfaee1d2e5e"),
    nested: @["(Butcher's Creek)", "quote\"backslash\\slash"],
    warnings: @["no-metadata"])
  let decoded = decodeReleases(toJson(rich))
  doAssert decoded.failures.len == 0
  doAssert decoded.items.len == 1
  doAssert decoded.items[0] == rich
  doAssert decoded.items[0].sizeBytes.get == 47828822016'i64,
    "sizes past 2^32 must survive exactly"

block full_round_trip:
  let encoded = encodeReleases(all)
  let decoded = decodeReleases(encoded)
  doAssert decoded.failures.len == 0, "our own encoding must always decode"
  doAssert decoded.items.len == all.len
  for index in 0..<all.len:
    doAssert decoded.items[index] == all[index],
      "row " & $index & " must survive the round trip"

block art_survives_and_absent_art_is_omitted:
  # The enrichment file carries image *URLs*, never bytes, so a game with
  # pictures stays one small diffable line. A screenshot that the store sent in
  # only one size keeps only that size.
  var facts = SteamFacts(kind: "game")
  facts.art.background = some initFact(
    "https://example.test/page_bg_raw.jpg", srcSteam, 7)
  facts.art.header = some initFact("https://example.test/header.jpg", srcSteam, 7)
  facts.art.screenshots = some initFact(@[
    Screenshot(thumbnail: "https://example.test/1.600x338.jpg",
               full: "https://example.test/1.1920x1080.jpg"),
    Screenshot(thumbnail: "https://example.test/2.600x338.jpg")], srcSteam, 7)
  let items = @[Enrichment(appid: 1, store: facts)]
  let encoded = encodeEnrichments(items)
  doAssert encoded.contains("\"art\":{")
  doAssert encoded.contains("\"thumb\":")
  doAssert encoded.contains("\"full\":")
  doAssert not encoded.contains("\"full\":\"\""),
    "a size the store did not send is absent, not empty"
  let decoded = decodeEnrichments(encoded)
  doAssert decoded.failures.len == 0
  doAssert decoded.items.len == 1
  doAssert decoded.items[0].store.art == facts.art
  doAssert decoded.items[0] == items[0]

  # A game with no pictures writes no `art` key at all.
  let plain = encodeEnrichments(@[Enrichment(appid: 2,
                                             store: SteamFacts(kind: "game"))])
  doAssert not plain.contains("art")

block the_pitch_and_press_score_round_trip:
  # Adding a modelled field means touching the writer, the reader and the merge.
  # This is the reader/writer half: both new fields survive, and an absent one
  # writes no key at all.
  var facts = SteamFacts(kind: "game",
    shortDescription: "Weave isolated planets into a vast trade empire.",
    critics: some Critics(score: initFact(80, srcSteam, 7),
                          url: some "https://www.metacritic.com/game/pc/x"))
  let encoded = encodeEnrichments(@[Enrichment(appid: 9, store: facts)])
  doAssert encoded.contains("\"summary\":")
  doAssert encoded.contains("\"critics\":{")
  doAssert encoded.contains("\"score\":")
  let decoded = decodeEnrichments(encoded)
  doAssert decoded.failures.len == 0
  doAssert decoded.items[0].store == facts

  let bare = encodeEnrichments(@[Enrichment(appid: 10,
                                            store: SteamFacts(kind: "game"))])
  doAssert not bare.contains("summary"), "no pitch means no key"
  doAssert not bare.contains("critics"), "no press score means no key"

block one_line_per_release:
  let encoded = encodeReleases(all)
  var lines = 0
  for line in encoded.splitLines:
    if line.len > 0:
      inc lines
      doAssert line[0] == '{' and line[^1] == '}', "one object per line"
  doAssert lines == all.len

block batch_reports_each_bad_line:
  # A bad line is recorded with its own reason, and the batch still returns
  # every line that decoded.
  let decoded = decodeReleases("""
{"row":"game","title":"Arco","norm":"arco"}
{"row":"game"}
not json at all
{"row":"nonsense","title":"x","norm":"x"}
{"row":"separator","title":"------","norm":"------"}
""")
  doAssert decoded.items.len == 2, "the two good lines survive"
  doAssert decoded.failures.len == 3
  doAssert decoded.failures[0].startsWith("2: ")
  doAssert decoded.failures[1].startsWith("3: ")
  doAssert decoded.failures[2].startsWith("4: ")

block missing_title_is_a_failure:
  let decoded = decodeReleases("""{"line":1,"row":"game","norm":"x"}""")
  doAssert decoded.items.len == 0
  doAssert decoded.failures == @["1: game row without a title"]

block titleless_non_game_rows_are_fine:
  # Header and separator rows are stored and carry no title, which is not an
  # error: only a game row has to name itself.
  let decoded = decodeReleases("""
{"line":1,"row":"header","title":"","norm":""}
{"line":2,"row":"separator","title":"","norm":""}
""")
  doAssert decoded.failures.len == 0
  doAssert decoded.items.len == 2
  doAssert decoded.items[0].rowKind == rkHeader
  doAssert decoded.items[1].rowKind == rkSeparator

block unknown_fields_policy:
  let line = """{"row":"game","title":"Arco","norm":"arco","futureField":[1,2]}"""
  let tolerant = decodeReleases(line)
  doAssert tolerant.failures.len == 0, "additive changes stay readable"
  doAssert tolerant.items.len == 1

  let strict = decodeReleases(line, ufReject)
  doAssert strict.items.len == 0
  doAssert strict.failures.len == 1, "a strict reader rejects the new field"
  doAssert strict.failures[0].contains("futureField")

block enum_spellings:
  # The spellings are the on-disk contract, so pin them.
  doAssert $rkUnknown == "unknown"
  doAssert $rkWine == "wine"
  doAssert $rkBoth == "both"
  doAssert $pkCollection == "collection"
  doAssert $rkSeparator == "separator"
  doAssert decodeReleases("""{"row":"game","title":"x","runtime":"native"}""")
    .items[0].runtime == rkNative

block unknown_spelling_fails_the_line:
  let decoded = decodeReleases("""{"row":"game","title":"x","runtime":"macos"}""")
  doAssert decoded.items.len == 0
  doAssert decoded.failures.len == 1

block trailing_data_is_rejected:
  let decoded = decodeReleases("""{"row":"game","title":"x"} {"row":"game"}""")
  doAssert decoded.items.len == 0
  doAssert decoded.failures.len == 1
