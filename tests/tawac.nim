## Tests for the AreWeAntiCheatYet decoder.
##
## The fixture is the real dataset, so these assertions describe the coverage it
## actually provides for this catalogue as well as the decoding itself.

import std/[options, os, tables]

import brian

import ludexcore/[models, parse, sources/awac]

const
  FixtureDir = currentSourcePath().parentDir() / "fixtures"
  DatasetPath = FixtureDir / "awac-games.json"
  TablePath = FixtureDir / "listing-table.md"

let dataset = decodeDataset(readFile(DatasetPath))

block status_vocabulary:
  # The dataset capitalizes the same words the enum uses.
  doAssert parseAntiCheat("Supported") == acSupported
  doAssert parseAntiCheat("supported") == acSupported
  doAssert parseAntiCheat("Broken") == acBroken
  doAssert parseAntiCheat("BROKEN") == acBroken
  doAssert parseAntiCheat("Denied") == acDenied
  doAssert parseAntiCheat("Planned") == acPlanned
  doAssert parseAntiCheat("Running") == acRunning
  doAssert parseAntiCheat("No Longer Under Development") == acUnknown,
    "a new word from upstream is not a failure"
  doAssert parseAntiCheat("") == acUnknown

block blocking_and_usability:
  doAssert blocksLinux(acBroken)
  doAssert blocksLinux(acDenied)
  doAssert not blocksLinux(acPlanned), "planned is a promise, not a state"
  doAssert not blocksLinux(acRunning)
  doAssert not blocksLinux(acSupported)
  doAssert not blocksLinux(acUnknown), "unchecked is a risk, not a block"

  doAssert usableUnderLinux(acRunning)
  doAssert usableUnderLinux(acSupported)
  doAssert not usableUnderLinux(acPlanned)
  doAssert not usableUnderLinux(acUnknown)

block statuses_sort_worst_first:
  # Every unusable status sorts below the usable ones, so a threshold test
  # fails closed without a special case.
  doAssert acUnknown < acRunning
  doAssert acBroken < acRunning
  doAssert acDenied < acRunning
  doAssert acPlanned < acRunning
  doAssert acRunning < acSupported

block dataset_shape:
  doAssert dataset.len == 1167, "the dataset covers 1167 games"

  var counts = initTable[string, int]()
  for entry in dataset:
    counts[entry.status] = counts.getOrDefault(entry.status) + 1
  doAssert counts["Broken"] == 640
  doAssert counts["Running"] == 276
  doAssert counts["Supported"] == 196
  doAssert counts["Denied"] == 53
  doAssert counts["Planned"] == 2

  var withSteam = 0
  var multi = 0
  var natives = 0
  for entry in dataset:
    if appIdOf(entry).isSome:
      inc withSteam
    if entry.anticheats.len > 1:
      inc multi
    if entry.native:
      inc natives
  doAssert withSteam == 682, "the rest are console or Epic only"
  doAssert multi == 103, "a game can carry more than one anti-cheat"
  doAssert natives == 66

block app_id_decoding:
  let halo = dataset[0]
  doAssert halo.name == "Halo: The Master Chief Collection"
  doAssert appIdOf(halo) == some(976730), "the id arrives quoted"

  # A bare number is accepted too, so an upstream formatting change is not fatal.
  let bare = Entry(storeIds: StoreIds(steam: RawJson("440900")))
  doAssert appIdOf(bare) == some(440900)
  doAssert appIdOf(Entry()) == none(int), "no store ids means no app id"
  doAssert appIdOf(Entry(storeIds: StoreIds(steam: RawJson("\"12x45\"")))) ==
    none(int)
  doAssert appIdOf(Entry(storeIds: StoreIds(steam: RawJson("\"\"")))) == none(int)
  doAssert appIdOf(Entry(storeIds: StoreIds(steam: RawJson("\"1234567890\"")))) ==
    none(int), "an id longer than nine digits is noise"

block entry_becomes_facts:
  let entry = Entry(name: "Conan Exiles", status: "Broken", native: false,
                    anticheats: @["BattlEye", "Other"],
                    storeIds: StoreIds(steam: RawJson("440900")))
  let play = toPlayability(entry, fetchedAt = 1234)
  doAssert play.antiCheat.get.value == acBroken
  doAssert play.antiCheat.get.source == srcAntiCheatYet
  doAssert play.antiCheat.get.fetchedAt == 1234
  doAssert play.antiCheatNames == some(@["BattlEye", "Other"]),
    "both anti-cheats are kept"
  doAssert play.nativeBuild.get.value == false
  doAssert blocksLinux(play.antiCheat.get.value)

  let noNames = toPlayability(Entry(status: "Running", native: true), 1)
  doAssert noNames.antiCheatNames.isNone, "an absent field stays absent"
  doAssert noNames.nativeBuild.get.value

block index_by_app_id:
  # 682 entries name a Steam app id, but only 677 distinct ones: five pairs
  # share an id, and three of those pairs disagree on the status.
  let index = indexByAppId(dataset, fetchedAt = 99)
  doAssert index.len == 677
  doAssert index[976730].antiCheat.get.value == acSupported
  doAssert index[440900].antiCheat.get.value == acBroken
  doAssert index[440900].antiCheatNames == some(@["BattlEye"])
  doAssert index[440900].antiCheat.get.fetchedAt == 99

block conflicting_entries_fail_safe:
  # Resolving "Supported" against "Running" must not land on "Supported".
  doAssert worseStatus(acSupported, acRunning) == acRunning
  doAssert worseStatus(acRunning, acSupported) == acRunning
  doAssert worseStatus(acBroken, acUnknown) == acBroken,
    "a definite verdict beats no verdict"
  doAssert worseStatus(acUnknown, acSupported) == acSupported
  doAssert worseStatus(acDenied, acRunning) == acDenied
  doAssert worseStatus(acBroken, acDenied) == acBroken

  let merged = mergeEntries(
    toPlayability(Entry(status: "Supported", anticheats: @["Easy Anti-Cheat"]), 5),
    toPlayability(Entry(status: "Running", anticheats: @["BattlEye"]), 6))
  doAssert merged.antiCheat.get.value == acRunning
  doAssert merged.antiCheatNames == some(@["Easy Anti-Cheat", "BattlEye"]),
    "both names survive the merge"

  # Predecessor and Final Fantasy XIV share app id 961200 in the real dataset.
  let index = indexByAppId(dataset, fetchedAt = 0)
  doAssert index[961200].antiCheat.get.value == acRunning

block overlap_with_the_catalogue:
  # Measured against the real listing: the anti-cheat dataset is aimed at big
  # online games, and this catalogue is mostly single-player, so the overlap is
  # small. Small is not the same as useless: two of these games will not run at
  # all, and that is worth knowing before downloading fifty gigabytes.
  var catalogue = initTable[int, string]()
  for release in parseTable(readFile(TablePath)):
    if release.isGame and release.appid.isSome:
      catalogue[release.appid.get] = release.title

  let index = indexByAppId(dataset, fetchedAt = 0)
  var shared: seq[int]
  for appid in index.keys:
    if catalogue.hasKey(appid):
      shared.add appid
  doAssert shared.len == 13, "refresh the fixture and this number moves"

  var broken = 0
  for appid in shared:
    if blocksLinux(index[appid].antiCheat.get.value):
      inc broken
  doAssert broken == 2
  doAssert catalogue[440900] == "Conan Exiles Enhanced"
  doAssert index[440900].antiCheat.get.value == acBroken

block malformed_dataset_raises:
  doAssertRaises JsonParsingError:
    discard decodeDataset("[{\"status\": ")
  doAssertRaises JsonParsingError:
    discard decodeDataset("[{\"native\": \"yes\"}]")
  doAssertRaises JsonParsingError:
    discard decodeDataset("")
