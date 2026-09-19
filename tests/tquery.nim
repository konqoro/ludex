## Tests for catalogue filtering.

import std/[options, os, strutils, tables]

import ludexcore/[models, normalize, parse, query]

const FixturePath = currentSourcePath().parentDir() / "fixtures" / "listing-table.md"

let all = parseTable(readFile(FixturePath))

block default_filter_keeps_games_only:
  let filter = initFilter()
  doAssert countMatches(all, filter) == 1998, "header and separator are not games"
  doAssert countMatches(all, initFilter(rkWine)) == 1456
  doAssert countMatches(all, initFilter(rkNative)) == 365
  doAssert countMatches(all, initFilter(rkBoth)) == 16
  doAssert countMatches(all, initFilter(rkUnknown)) == 161

block size_bounds:
  # A size bound rejects rows whose size is unknown, rather than guessing.
  var filter = initFilter()
  filter.maxSize = some(200'i64 * 1024 * 1024)
  let small = applyFilter(all, filter)
  doAssert small.len > 0
  for release in small:
    doAssert release.sizeBytes.isSome
    doAssert release.sizeBytes.get <= 200'i64 * 1024 * 1024

  filter = initFilter()
  filter.minSize = some(20'i64 * 1024 * 1024 * 1024)
  let huge = applyFilter(all, filter)
  doAssert huge.len > 0
  for release in huge:
    doAssert release.sizeBytes.get >= 20'i64 * 1024 * 1024 * 1024

block appid_partition:
  var withId = initFilter()
  withId.appidOnly = true
  var withoutId = initFilter()
  withoutId.noAppid = true
  doAssert countMatches(all, withId) == 1545
  doAssert countMatches(all, withoutId) == 453
  doAssert countMatches(all, withId) + countMatches(all, withoutId) == 1998

block language_and_title:
  var filter = initFilter(rkNative)
  filter.lang = "ENG"
  let englishNative = applyFilter(all, filter)
  doAssert englishNative.len > 0
  for release in englishNative:
    doAssert release.langToken.isSome
    doAssert release.langToken.get.contains("ENG")

  let disco = filterByTitle(all, "disco elysium")
  doAssert disco.len == 1
  doAssert disco[0].appid == some(632470)

  # The title key is folded, so casing and punctuation do not matter.
  doAssert filterByTitle(all, "DISCO ELYSIUM").len == 1
  doAssert filterByTitle(all, "Cosmic Wheel Sisterhood").len == 1
  doAssert filterByTitle(all, "The Cosmic Wheel Sisterhood").len == 1
  doAssert filterByTitle(all, "nothing resembles this").len == 0

block limit:
  var filter = initFilter(rkWine)
  filter.limit = some(3)
  doAssert applyFilter(all, filter).len == 3, "the limit caps the result"
  doAssert countMatches(all, filter) == 1456, "but not the match count"

  filter.limit = none(int)
  doAssert applyFilter(all, filter).len == 1456

block order_is_preserved:
  var filter = initFilter()
  filter.limit = some(5)
  let first = applyFilter(all, filter)
  var expected = 0
  for release in all:
    if release.isGame and expected < 5:
      doAssert release == first[expected]
      inc expected

block combined_conditions:
  var filter = initFilter(rkNative)
  filter.lang = "ENG"
  filter.maxSize = some(2'i64 * 1024 * 1024 * 1024)
  let matched = applyFilter(all, filter)
  doAssert matched.len > 0
  doAssert matched.len < 365, "the conditions really do combine"
  for release in matched:
    doAssert release.runtime == rkNative
    doAssert release.sizeBytes.isSome
    doAssert release.sizeBytes.get <= 2'i64 * 1024 * 1024 * 1024

block anticheat_is_a_set_not_a_scale:
  # `broken` is not "less than" `running`; it is a different answer. Asking for
  # broken,denied is a different question from asking for running,supported.
  var play = initTable[int, Playability]()
  play[1] = Playability(antiCheat: some initFact(acBroken, srcAntiCheatYet, 0))
  play[2] = Playability(antiCheat: some initFact(acDenied, srcAntiCheatYet, 0))
  play[3] = Playability(antiCheat: some initFact(acRunning, srcAntiCheatYet, 0))
  play[4] = Playability(antiCheat: some initFact(acSupported, srcAntiCheatYet, 0))
  play[5] = Playability(antiCheat: some initFact(acPlanned, srcAntiCheatYet, 0))
  play[6] = Playability(antiCheat: some initFact(acUnknown, srcAntiCheatYet, 0))
  play[7] = Playability()  # nothing known at all

  let releases = @[
    Release(rowKind: rkGame, appid: some(1)),
    Release(rowKind: rkGame, appid: some(2)),
    Release(rowKind: rkGame, appid: some(3)),
    Release(rowKind: rkGame, appid: some(4)),
    Release(rowKind: rkGame, appid: some(5)),
    Release(rowKind: rkGame, appid: some(6)),
    Release(rowKind: rkGame, appid: some(7)),
  ]

  var blocked = initFilter()
  blocked.antiCheat = @[acBroken, acDenied]
  doAssert countMatches(releases, blocked, play) == 2

  var works = initFilter()
  works.antiCheat = @[acRunning, acSupported]
  doAssert countMatches(releases, works, play) == 2

  var anyStatus = initFilter()
  anyStatus.antiCheat = @[acUnknown]
  doAssert countMatches(releases, anyStatus, play) == 1,
    "an explicitly unknown status is still a status"

  doAssert countMatches(releases, initFilter(), play) == 7,
    "an empty set accepts everything"

block tier_bound_excludes_the_unknowns:
  # ptUnknown sorts lowest, so a threshold fails closed rather than ranking the
  # least-known games as the best.
  var play = initTable[int, Playability]()
  play[1] = Playability(tier: some initFact(ptPlatinum, srcProtonDb, 0))
  play[2] = Playability(tier: some initFact(ptGold, srcProtonDb, 0))
  play[3] = Playability(tier: some initFact(ptSilver, srcProtonDb, 0))
  play[4] = Playability(tier: some initFact(ptUnknown, srcProtonDb, 0))
  play[5] = Playability()
  let releases = @[
    Release(rowKind: rkGame, appid: some(1)),
    Release(rowKind: rkGame, appid: some(2)),
    Release(rowKind: rkGame, appid: some(3)),
    Release(rowKind: rkGame, appid: some(4)),
    Release(rowKind: rkGame, appid: some(5)),
  ]
  var filter = initFilter()
  filter.tier = some(ptGold)
  doAssert countMatches(releases, filter, play) == 2
  filter.tier = some(ptUnknown)
  doAssert countMatches(releases, filter, play) == 4,
    "even the lowest bound needs a tier to exist"

block store_conditions:
  # Genre and Linux-build conditions need store data, and a game Steam has no
  # entry for cannot satisfy them: an unfiltered run still lists it.
  var stores = initTable[int, SteamFacts]()
  stores[1] = SteamFacts(genres: @["Strategy", "Indie"],
                         linuxBuild: some initFact(false, srcSteam, 0))
  stores[2] = SteamFacts(genres: @["Adventure", "Casual"],
                         linuxBuild: some initFact(true, srcSteam, 0))
  stores[3] = SteamFacts(genres: @["Action"])
  let releases = @[
    Release(rowKind: rkGame, appid: some(1)),
    Release(rowKind: rkGame, appid: some(2)),
    Release(rowKind: rkGame, appid: some(3)),
    Release(rowKind: rkGame, appid: some(4)),  # no store data at all
  ]

  var filter = initFilter()
  filter.genre = "strategy"
  doAssert countMatches(releases, filter, initTable[int, Playability](), stores) == 1
  filter.genre = "STRATEGY"
  doAssert countMatches(releases, filter, initTable[int, Playability](), stores) == 1,
    "genre matching is case-insensitive"
  filter.genre = "adventure"
  doAssert countMatches(releases, filter, initTable[int, Playability](), stores) == 1
  filter.genre = "indie"
  doAssert countMatches(releases, filter, initTable[int, Playability](), stores) == 1,
    "a substring of any genre counts"

  filter = initFilter()
  filter.tag = "puzzle-platformer"
  doAssert countMatches(releases, filter, initTable[int, Playability](), stores) == 0,
    "no tags in these records, so nothing matches"

  var tagged = initTable[int, SteamFacts]()
  tagged[1] = SteamFacts(tags: some initFact(@[
    Tag(name: "Strategy", votes: 145), Tag(name: "Puzzle", votes: 140)],
    srcSteamSpy, 0))
  tagged[2] = SteamFacts(tags: some initFact(@[Tag(name: "Cats", votes: 220)],
    srcSteamSpy, 0))
  filter = initFilter()
  filter.tag = "puzzle"
  doAssert countMatches(releases, filter, initTable[int, Playability](), tagged) == 1
  filter.tag = "PUZZLE"
  doAssert countMatches(releases, filter, initTable[int, Playability](), tagged) == 1,
    "tag matching is case-insensitive"
  filter.tag = "cats"
  doAssert countMatches(releases, filter, initTable[int, Playability](), tagged) == 1

  var verdicts = initTable[int, SteamFacts]()
  verdicts[1] = SteamFacts(deck: some initFact(lvVerified, srcSteam, 0),
                           steamos: some initFact(lvPlayable, srcSteam, 0))
  verdicts[2] = SteamFacts(deck: some initFact(lvUnsupported, srcSteam, 0),
                           steamos: some initFact(lvUnsupported, srcSteam, 0))
  filter = initFilter()
  filter.deck = some(lvVerified)
  doAssert countMatches(releases, filter, initTable[int, Playability](), verdicts) == 1
  filter.deck = some(lvUnsupported)
  doAssert countMatches(releases, filter, initTable[int, Playability](), verdicts) == 1
  filter = initFilter()
  filter.steamos = some(lvPlayable)
  doAssert countMatches(releases, filter, initTable[int, Playability](), verdicts) == 1,
    "the handheld and desktop verdicts are different questions"
  filter.steamos = some(lvVerified)
  doAssert countMatches(releases, filter, initTable[int, Playability](), verdicts) == 0,
    "a verified Deck verdict is not a verified desktop verdict"

  filter = initFilter()
  filter.linuxBuildOnly = true
  doAssert countMatches(releases, filter, initTable[int, Playability](), stores) == 1,
    "only the game Steam ships a Linux build for"
  doAssert storeFactsOf(stores, releases[1]).linuxBuild.get.value

block loose_sizes:
  doAssert parseSizeLoose("5GB") == parseSizeLoose("5 GB")
  doAssert parseSizeLoose("2gb") == parseSizeLoose("2 GB")
  doAssert parseSizeLoose("124MB") == some(130023424'i64)
  doAssert parseSizeLoose("garbage").isNone
  doAssert parseSizeLoose("").isNone
  doAssert parseSizeLoose("GB").isNone

block runtime_names:
  doAssert parseRuntimeName("wine") == some(rkWine)
  doAssert parseRuntimeName("native") == some(rkNative)
  doAssert parseRuntimeName("both") == some(rkBoth)
  doAssert parseRuntimeName("unknown") == some(rkUnknown)
  doAssert parseRuntimeName("macos").isNone
