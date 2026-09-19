## Catalogue integration stays offline: temporary files exercise real decoding,
## search, duplicate grouping and transactional ratings without touching user data.

import std/[assertions, options, os, tables, tempfiles]
import ludexcore/[art, models, normalize, ratings, score, store, taste]
import ludexui/catalog

proc game(title: string; line: int; appid = 0): Release =
  result = Release(rowKind: rkGame, title: title, titleNorm: normalizeTitle(title),
    lineNumber: line)
  if appid > 0:
    result.appid = some appid

let folder = createTempDir("ludex-catalog-test-", "")
try:
  let paths = catalogPathsFor(folder / "games.jsonl")
  doAssert paths.enrichment == folder / "enrichment.jsonl"
  doAssert paths.ratings == folder / "ratings.jsonl"
  doAssert paths.art == folder / "art"
  writeFile(paths.store, encodeReleases(@[
    game("Zebra", 1, 42), game("Zebra Special Edition", 2, 42),
    game("Alpha", 3), game("Alpha", 4), game("Beta", 5, 43)]))
  var catalog = loadCatalog(paths)
  doAssert catalog.browse("").len == 4
  doAssert catalog.browse("")[0].release.lineNumber == 3
  doAssert catalog.browse("")[1].release.lineNumber == 4
  doAssert catalog.browse("special")[0].release.lineNumber == 2
  catalog.stores[42] = SteamFacts(genres: @["Strategy"], tags:
    some initFact(@[Tag(name: "Co-op", votes: 5)], srcSteamSpy, 1))
  doAssert catalog.browse("strategy zebra co op").len == 1
  doAssert catalog.browse("strategy alpha").len == 0
  catalog.ranked.candidates = @[ScoreCard(appid: 42, score: 0.9)]
  doAssert catalog.browse("")[0].release.appid == some 42

  block fresh_nested_rating_folder:
    catalog.paths.ratings = folder / "nested" / "ratings.jsonl"
    doAssert catalog.rate(42, "Zebra", vLoved)
    doAssert fileExists(catalog.paths.ratings)
    doAssert decodeTaste(readFile(catalog.paths.ratings)).taste.verdictOf(42) == some vLoved

  block preserve_external_rating_and_allow_undo:
    var external = catalog.taste
    external.rate(43, "Beta", vFinished, 1)
    writeFile(catalog.paths.ratings, encodeTaste(external))
    doAssert catalog.rate(42, "Zebra", vLater)
    doAssert catalog.taste.verdictOf(43) == some vFinished
    doAssert catalog.clearRating(42)
    doAssert catalog.taste.verdictOf(42).isNone
    doAssert decodeTaste(readFile(catalog.paths.ratings)).taste.verdictOf(43) == some vFinished

  block damaged_ratings_are_never_overwritten:
    let damaged = readFile(catalog.paths.ratings) & "broken json\n"
    writeFile(catalog.paths.ratings, damaged)
    doAssert not catalog.rate(42, "Zebra", vLoved)
    doAssert not catalog.clearRating(43)
    doAssert readFile(catalog.paths.ratings) == damaged
    doAssert catalog.taste.verdictOf(42).isNone

  block write_failure_keeps_memory:
    let obstacle = folder / "not-a-directory"
    writeFile(obstacle, "unchanged")
    catalog.paths.ratings = obstacle / "ratings.jsonl"
    doAssert not catalog.rate(42, "Zebra", vLoved)
    doAssert catalog.taste.verdictOf(42).isNone
    doAssert readFile(obstacle) == "unchanged"

  block art_files_are_classified_by_name:
    ## The downloader writes `background.*`, `header.*` and `shot-NN.*`, and the
    ## window tells them apart by name: a background sorted in with the
    ## screenshots would appear as a thumbnail in the strip.
    let artPaths = catalogPathsFor(folder / "arttest" / "games.jsonl")
    let artCatalog = loadCatalog(artPaths)
    let gameDir = artDir(artCatalog.paths.art, 7)
    createDir(gameDir)
    writeFile(gameDir / "background.jpg", "b")
    writeFile(gameDir / "header.jpg", "h")
    writeFile(gameDir / "shot-01.jpg", "s")
    writeFile(gameDir / "shot-02.jpg", "s")
    let files = artCatalog.artFiles(7)
    doAssert files.background.isSome
    doAssert files.header.isSome
    doAssert files.shots.len == 2, "only the numbered shots are screenshots"
    doAssert artCatalog.artFiles(0).header.isNone, "no app id means no pictures"

  block filters_ask_only_answerable_questions:
    ## Every switch is answerable from evidence the catalogue holds, and an
    ## absent fact is never a yes: a filter that guessed would hide games for
    ## no reason. `later` is a deferral, not a verdict, so it stays visible.
    let filterPaths = catalogPathsFor(folder / "filtertest" / "games.jsonl")
    createDir(folder / "filtertest")
    writeFile(filterPaths.store, encodeReleases(@[
      game("Native", 1, 101), game("Proton", 2, 102), game("Blocked", 3, 103),
      game("Unknown", 4, 104), game("Handheld", 5, 105), game("Port", 6, 106),
      game("SteamOS", 7, 107)]))
    var filterCatalog = loadCatalog(filterPaths)
    filterCatalog.stores[101] = SteamFacts(linuxBuild: some initFact(true, srcSteam, 1))
    filterCatalog.stores[103] = SteamFacts(linuxBuild: some initFact(true, srcSteam, 1))
    filterCatalog.stores[105] = SteamFacts(deck: some initFact(lvVerified, srcSteam, 1))
    filterCatalog.stores[107] = SteamFacts(steamos: some initFact(lvPlayable, srcSteam, 1))
    filterCatalog.play[102] = Playability(tier: some initFact(ptGold, srcProtonDb, 1))
    filterCatalog.play[103] = Playability(
      antiCheat: some initFact(acBroken, srcAntiCheatYet, 1))
    filterCatalog.play[106] = Playability(nativeBuild: some initFact(true, srcProtonDb, 1))

    doAssert filterCatalog.browse("").len == 7, "the default view hides nothing"
    let runsHere = filterCatalog.browse("", Filters(runsHere: true))
    doAssert runsHere.len == 3, "a native package, a gold tier and a reported port"
    for item in runsHere:
      doAssert item.release.appid.get in {101, 102, 106}
      doAssert item.release.appid.get != 103,
        "a blocked anti-cheat outranks a shipped Linux build"
    let deck = filterCatalog.browse("", Filters(deckReady: true))
    doAssert deck.len == 3, "a verified verdict, a playable verdict and a port"
    for item in deck:
      doAssert item.release.appid.get in {105, 106, 107}

    filterCatalog.taste.rate(102, "Proton", vLoved, 1)
    doAssert filterCatalog.browse("", Filters(unjudged: true)).len == 6
    filterCatalog.taste.rate(104, "Unknown", vLater, 2)
    doAssert filterCatalog.browse("", Filters(unjudged: true)).len == 6,
      "`later` is a deferral, so it stays in the running"
    doAssert filterCatalog.browse("handheld",
      Filters(runsHere: true)).len == 0, "search and filters compose"

  block genres_filter_by_type_of_game:
    ## The type of game comes from the store's own genre list. A game whose
    ## genres never arrived is not a match for any genre, and several picked
    ## genres mean "either", not "all". A genre held by a single game would be a
    ## menu entry that hides nearly everything, so it is not offered.
    let genrePaths = catalogPathsFor(folder / "genre" / "games.jsonl")
    createDir(folder / "genre")
    writeFile(genrePaths.store, encodeReleases(@[
      game("Action One", 1, 201), game("Action Two", 2, 202),
      game("Action Three", 3, 203), game("Puzzle One", 4, 204),
      game("Puzzle Two", 5, 205), game("Quiet", 6, 206)]))
    var genreCatalog = loadCatalog(genrePaths)
    genreCatalog.stores[201] = SteamFacts(genres: @["Action", "Indie"])
    genreCatalog.stores[202] = SteamFacts(genres: @["Action"])
    genreCatalog.stores[203] = SteamFacts(genres: @["Action", "Puzzle"])
    genreCatalog.stores[204] = SteamFacts(genres: @["Puzzle"])
    genreCatalog.stores[205] = SteamFacts(genres: @["Puzzle", "Indie"])
    doAssert genreCatalog.genreOptions() == @["Action", "Puzzle"],
      "only genres enough games carry are offered"
    doAssert genreCatalog.genreOptions(2) == @["Action", "Puzzle", "Indie"],
      "most common first, alphabetical within a count"

    doAssert genreCatalog.browse("", Filters(genres: @["Action"])).len == 3
    doAssert genreCatalog.browse("", Filters(genres: @["Puzzle"])).len == 3
    doAssert genreCatalog.browse("",
      Filters(genres: @["Action", "Puzzle"])).len == 5,
      "several genres mean either, not both"
    doAssert genreCatalog.browse("", Filters(genres: @["Stealth"])).len == 0,
      "an unknown genre matches nothing rather than everything"
    doAssert genreCatalog.browse("quiet",
      Filters(genres: @["Puzzle"])).len == 0,
      "a game with no genres is never a genre match"

  block damaged_input_is_reported_not_fatal:
    ## A window that opens with a note is more useful than one that refuses to
    ## open, so a bad line becomes a problem and the good lines still browse.
    let broken = folder / "broken"
    createDir(broken)
    let brokenPaths = catalogPathsFor(broken / "games.jsonl")
    writeFile(brokenPaths.store,
      encodeReleases(@[game("Solitaire", 1, 7)]) & "{\"line\":broken\n")
    writeFile(brokenPaths.ratings,
      "{\"appid\":7,\"title\":\"Solitaire\",\"verdict\":\"loved\",\"ratedAt\":1}\n" &
      "{\"appid\":8,\"title\":\"Ghost\",\"verdict\":\"nonsense\"}\n")
    let brokenCatalog = loadCatalog(brokenPaths)
    doAssert brokenCatalog.problems.len == 2
    doAssert brokenCatalog.browse("").len == 1
    doAssert brokenCatalog.browse("")[0].release.appid == some 7
    doAssert brokenCatalog.taste.verdictOf(7) == some vLoved
    doAssert brokenCatalog.taste.verdictOf(8).isNone
finally:
  removeDir(folder)

echo "tcatalog: ok"
