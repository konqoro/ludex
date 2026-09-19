## Golden test against the real listing table.
##
## The fixture is a verbatim copy of the upstream table, so any parser change
## that moves these numbers has to be justified rather than discovered.

import std/[options, os, strutils]

import ludexcore/[models, normalize, parse]

const FixturePath = currentSourcePath().parentDir() / "fixtures" / "listing-table.md"

let all = parseTable(readFile(FixturePath))

var games: seq[Release]
for release in all:
  if release.isGame:
    games.add(release)

proc countAppIds(releases: openArray[Release]): int =
  for release in releases:
    if release.appid.isSome: inc result

proc countRuntime(releases: openArray[Release]; kind: RuntimeKind): int =
  for release in releases:
    if release.runtime == kind: inc result

proc countRowKind(releases: openArray[Release]; kind: RowKind): int =
  for release in releases:
    if release.rowKind == kind: inc result

proc countWarning(releases: openArray[Release]; warning: string): int =
  for release in releases:
    if warning in release.warnings: inc result

proc countMissingLang(releases: openArray[Release]): int =
  for release in releases:
    if release.langToken.isNone: inc result

proc countMissingHash(releases: openArray[Release]): int =
  for release in releases:
    if release.infoHash.isNone: inc result

proc countCollection(releases: openArray[Release]): int =
  for release in releases:
    if release.pack == pkCollection: inc result

proc findByAppId(releases: openArray[Release]; appid: int): Option[Release] =
  for release in releases:
    if release.appid.isSome and release.appid.get == appid:
      return some(release)

proc findByTitle(releases: openArray[Release]; title: string): Option[Release] =
  for release in releases:
    if release.title == title:
      return some(release)

block row_classification:
  doAssert all.len == 2000, "the fixture holds 2000 non-empty lines"
  doAssert countRowKind(all, rkGame) == 1998, "1998 of them are games"
  doAssert countRowKind(all, rkSeparator) == 1, "one stray `------` row"
  doAssert countRowKind(all, rkHeader) == 1, "one header row"

block steam_appids:
  doAssert countAppIds(games) == 1545, "1545 rows name a Steam appid"
  doAssert games.len - countAppIds(games) == 453, "453 rows need matching later"

block runtime_split:
  doAssert countRuntime(games, rkWine) == 1456
  doAssert countRuntime(games, rkNative) == 365
  doAssert countRuntime(games, rkBoth) == 16
  doAssert countRuntime(games, rkUnknown) == 161

block metadata_free_rows:
  # Every row without a runtime token is flagged, and that set is exactly the
  # set of rows carrying no metadata at all.
  doAssert countWarning(games, "no-metadata") == 161
  doAssert countRuntime(games, rkUnknown) == countWarning(games, "no-metadata")

block shared_fields:
  doAssert countMissingHash(games) == 0, "reading the info hash never fails"
  doAssert countWarning(games, "empty-title") == 0
  doAssert countWarning(games, "empty-core") == 0
  doAssert countWarning(games, "runtime-unknown") == 0

block languages:
  doAssert countMissingLang(games) == 173
  doAssert countCollection(games) == 10, "packs nesting other releases"

block canonical_rows:
  let slipways = findByAppId(games, 1264280)
  doAssert slipways.isSome
  doAssert slipways.get.title == "Slipways"
  doAssert slipways.get.buildId == some("b15946357")
  doAssert slipways.get.langToken == some("MULTi6")
  doAssert slipways.get.runtime == rkWine
  doAssert slipways.get.sizeBytes.isNone, "`0 B` means unknown, not zero"

  let brothers = findByAppId(games, 365360)
  doAssert brothers.get.title == "Battle Brothers"
  doAssert brothers.get.buildId == some("b23856902")
  doAssert brothers.get.version == some("1.5.2.3")

  let titanfall = findByAppId(games, 1237970)
  doAssert titanfall.get.title == "Titanfall 2"
  doAssert titanfall.get.version == some("2.0.11.0")

block titles_containing_separators:
  # These titles hold ` - ` themselves and must survive the field walk.
  let disco = findByAppId(games, 632470)
  doAssert disco.get.title == "Disco Elysium - The Final Cut"
  doAssert disco.get.runtime == rkWine

  let mini = findByAppId(games, 2289650)
  doAssert mini.get.title == "Mini Airways - ATC simulator"
  doAssert mini.get.runtime == rkNative

block title_is_never_consumed_as_metadata:
  # `FEZ` is indistinguishable from an ISO language code, so the walk has to
  # stop before it eats the only remaining field.
  doAssert findByTitle(games, "FEZ").isSome
  doAssert findByTitle(games, "OFF").isSome
  doAssert findByTitle(games, "1000xRESIST").isSome

block packager_annotations:
  # Content appended after the packager marker is not always parenthesized and
  # not always last, so the marker is the anchor.
  let antiqua = findByAppId(games, 3198540)
  doAssert antiqua.get.title == "Dungeon Antiqua Collection"
  doAssert antiqua.get.nested == @["Dungeon Antiqua 2"]

  let tomba = findByAppId(games, 2851150)
  doAssert tomba.get.title == "Tomba! Collection"

  let villagers = findByAppId(games, 16180)
  doAssert villagers.get.title == "Virtual Villagers - Collection"
  doAssert villagers.get.langToken == some("ENG")

  let cod = findByTitle(games, "Call of Duty 2")
  doAssert cod.isSome
  doAssert cod.get.appid.isNone
  doAssert cod.get.nested.len == 1

block legacy_dotted_names:
  let isle = findByTitle(games, "Isle of Swaps")
  doAssert isle.isSome
  doAssert isle.get.titleNorm == "isle of swaps"
  doAssert isle.get.appid.isNone
  doAssert isle.get.infoHash.isSome

block html_entities:
  for game in games:
    doAssert not game.title.contains("&#039;")
  let butcher = findByTitle(games, "David Szymanski Collection")
  doAssert butcher.isSome
  doAssert butcher.get.nested[0].startsWith("(Butcher's Creek")

block normalization_for_matching:
  doAssert normalizeTitle("Crusader Kings III") == "crusader kings iii"
  doAssert normalizeTitle("The Cosmic Wheel Sisterhood") == "cosmic wheel sisterhood"
  doAssert normalizeTitle("Schrödinger's Call") == "schrödingers call"
  doAssert normalizeTitle("Good Pizza, Great Pizza") == "good pizza great pizza"
  doAssert normalizeTitle("S.T.A.L.K.E.R.") == "s t a l k e r"
  doAssert normalizeTitle("") == ""

block token_classification:
  doAssert isLanguageToken("ENG")
  doAssert isLanguageToken("ENG/JPN")
  doAssert isLanguageToken("MULTi11")
  doAssert isLanguageToken("MULTi")
  doAssert isLanguageToken("MULTi9/ENG")
  doAssert isLanguageToken("MULTi12/7")
  doAssert isLanguageToken("ENG/FRE/MULTi4")
  doAssert not isLanguageToken("Slipways")
  doAssert not isLanguageToken("")

  doAssert isVersionToken("1.3.8")
  doAssert isVersionToken("2.0.11.0")
  doAssert isVersionToken("1.41a")
  doAssert isVersionToken("1.1.0.0/1.0.13")
  doAssert not isVersionToken("Titanfall 2")

  doAssert isBuildToken("b15946357")
  doAssert isBuildToken("b13697029/1.3.8")
  doAssert not isBuildToken("battle")
  doAssert isSeparatorToken("------")
  doAssert not isSeparatorToken("-")

block runtime_tokens:
  doAssert parseRuntime("GNU/Linux Wine") == some(rkWine)
  doAssert parseRuntime("GNU/Linux Native") == some(rkNative)
  doAssert parseRuntime("GNU/Linux Native/Wine") == some(rkBoth)
  doAssert parseRuntime("GNU/Linux Wine/Native") == some(rkBoth)
  doAssert parseRuntime("GNU/Linux").isNone
  doAssert parseRuntime("Windows").isNone

block size_tokens:
  doAssert parseSizeBytes("124 MB") == some(130023424'i64)
  doAssert parseSizeBytes("1.3 GB") == some(1395864371'i64)
  doAssert parseSizeBytes("44.5 GB") == some(47781511168'i64)
  doAssert parseSizeBytes("0 B").isNone
  doAssert parseSizeBytes("1 PB").isNone
  doAssert parseSizeBytes("").isNone

block info_hash_tokens:
  let withHash = parseInfoHash("magnet:?xt=urn:btih:CC2C41701CF2ECA25F749FF26C0AEDFAEE1D2E5E&dn=x")
  doAssert withHash == some("cc2c41701cf2eca25f749ff26c0aedfaee1d2e5e")
  doAssert parseInfoHash("magnet:?xt=urn:btih:tooshort").isNone
  doAssert parseInfoHash("[magnet](https://example.org)").isNone
