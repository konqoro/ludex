## The desktop app's view of the catalogue on disk.
##
## This is the only module under `ludexui/` that opens a file, mirroring the
## CLI's rule: the core stays pure and each front end owns its own I/O. Reading
## here means the owlkettle views only render values they are handed, and a bad
## line becomes a reported problem instead of taking the window down.
##
## There is no network here. Bulk enrichment stays a CLI job (`ludex enrich`);
## the window reads what that job already wrote, which is what makes browsing
## work offline.
##
## `profile` and `ranked` are the exception to "what is on disk is what you
## get": both are derived, so they are rebuilt whenever the files are loaded and
## whenever a rating or a weight changes. Keeping them here rather than beside
## the widgets is what stops the window from ever showing a ranking the ratings
## have outgrown.

import std/[algorithm, options, os, sets, strutils, tables, tempfiles, times]

import brian

import ludexcore/[art, models, normalize, ratings, score, store, taste]

type
  CatalogPaths* = object
    store*: string
    enrichment*: string
    ratings*: string
    weights*: string
    art*: string ## the image cache `ludex art` fills

  Catalog* = object
    paths*: CatalogPaths
    releases: seq[Release]
    play*: Table[int, Playability]
    stores*: Table[int, SteamFacts]
    taste*: Taste
    weights*: Weights
    profile*: Profile
    ranked*: Ranked
    problems*: seq[string]

  ArtFiles* = object ## the pictures on disk for one game
    background*: Option[string]
    header*: Option[string]
    shots*: seq[string]

  BrowseItem* = object
    ## One row of the library: the listing row and, when the recommender scored
    ## it, the card that explains where the row ended up.
    release*: Release
    card*: Option[ScoreCard]

func catalogPathsFor*(storePath: string): CatalogPaths =
  ## Companion files follow the selected catalogue, so opening another folder
  ## never writes its ratings into the previous library.
  let folder = storePath.parentDir
  CatalogPaths(store: storePath, enrichment: folder / "enrichment.jsonl",
    ratings: folder / "ratings.jsonl", weights: folder / "weights.json",
    art: folder / "art")

func defaultPaths*(): CatalogPaths =
  ## The same defaults the CLI uses, so both front ends read one dataset.
  catalogPathsFor("data/releases.jsonl")

# -- Loading ---------------------------------------------------------------

proc readText(path: string; problems: var seq[string]): Option[string] =
  ## A missing file is normal and silent; an unreadable one is worth reporting.
  if not fileExists(path):
    return
  try:
    result = some readFile(path)
  except IOError as error:
    problems.add("cannot read " & path & ": " & error.msg)

func tagVectors(c: Catalog): Table[int, seq[Tag]] =
  ## The tag vector of every game that has one: the feature space of the taste
  ## profile.
  for appid, facts in c.stores:
    if facts.tags.isSome:
      result[appid] = facts.tags.get.value

proc refresh(c: var Catalog) =
  ## Rebuilds what is derived. Called after a load and after every write, so it
  ## is the one place that knows `profile` and `ranked` are never stale.
  c.profile = buildProfile(c.taste, tagVectors(c))
  c.ranked = rank(c.releases, c.play, c.stores, c.taste, c.profile, c.weights)

proc loadCatalog*(paths: CatalogPaths): Catalog =
  ## Loads whatever the paths hold, recording every problem instead of raising.
  ## A window that opens with a note about a missing store is more useful than
  ## one that refuses to open.
  result.paths = paths

  let storeText = readText(paths.store, result.problems)
  if storeText.isSome:
    let decoded = decodeReleases(storeText.get)
    result.releases = decoded.items
    for failure in decoded.failures:
      result.problems.add("store line " & failure)
  else:
    result.problems.add("no store at " & paths.store &
      ": run `ludex parse` to write one")

  let enrichmentText = readText(paths.enrichment, result.problems)
  if enrichmentText.isSome:
    let decoded = decodeEnrichments(enrichmentText.get)
    for item in decoded.items:
      result.play[item.appid] = item.play
      result.stores[item.appid] = item.store
    for failure in decoded.failures:
      result.problems.add("enrichment line " & failure)

  let ratingsText = readText(paths.ratings, result.problems)
  if ratingsText.isSome:
    let decoded = decodeTaste(ratingsText.get)
    result.taste = decoded.taste
    for failure in decoded.failures:
      result.problems.add("ratings line " & failure)

  var weights = initWeights()
  let weightsText = readText(paths.weights, result.problems)
  if weightsText.isSome:
    try:
      fromJson(weightsText.get, weights)
    except CatchableError as error:
      result.problems.add("cannot read weights: " & error.msg)
  result.weights = weights

  refresh(result)

# -- Writes ----------------------------------------------------------------

proc updateRating(c: var Catalog; appid: int; title: string;
                  verdict: Option[Verdict]): bool =
  ## Replace the ratings file only after a complete decode and successful write.
  if appid <= 0:
    return false
  var next = c.taste
  var temporary = ""
  try:
    # Re-read before saving: a CLI rating written since launch must survive.
    # Refuse a partial decode rather than overwrite the unreadable records.
    if fileExists(c.paths.ratings):
      let decoded = decodeTaste(readFile(c.paths.ratings))
      if decoded.failures.len > 0:
        c.problems.add("cannot update ratings: existing ratings contain unreadable entries")
        return false
      next = decoded.taste
    if verdict.isSome:
      next.rate(appid, title, verdict.get, toUnix(getTime()))
    else:
      discard next.unrate(appid)
    let folder = c.paths.ratings.parentDir
    if folder.len > 0:
      createDir(folder)
    let pending = createTempFile(".ludex-ratings-", ".tmp",
      if folder.len > 0: folder else: ".")
    temporary = pending.path
    try:
      pending.cfile.write(encodeTaste(next))
      pending.cfile.flushFile()
    finally:
      pending.cfile.close()
    moveFile(temporary, c.paths.ratings)
  except CatchableError as error:
    c.problems.add("cannot write " & c.paths.ratings & ": " & error.msg)
    return false
  finally:
    if temporary.len > 0 and fileExists(temporary):
      try:
        removeFile(temporary)
      except OSError:
        discard
  c.taste = next
  refresh(c)
  result = true

proc rate*(c: var Catalog; appid: int; title: string; verdict: Verdict): bool =
  ## Save immediately, preserving on-disk changes and refusing damaged files.
  updateRating(c, appid, title, some verdict)

proc clearRating*(c: var Catalog; appid: int): bool =
  ## Undo a verdict through the same safe persistence path as setting one.
  updateRating(c, appid, "", none(Verdict))

# -- Lookups ---------------------------------------------------------------

func hasGames*(c: Catalog): bool =
  ## True when the store holds at least one catalogue entry. The store also
  ## round-trips the table's header and separator rows, so this is not the same
  ## as `releases.len > 0`.
  for release in c.releases:
    if release.isGame:
      return true

func genreOptions*(c: Catalog; minimum = 3): seq[string] =
  ## The genres worth offering as a filter: those at least `minimum` games
  ## carry, most common first and alphabetical within a count. A genre held by a
  ## single game is a menu entry that hides almost everything and helps nobody.
  var counts = initCountTable[string]()
  for facts in c.stores.values:
    for genre in facts.genres:
      counts.inc genre
  var ranked: seq[(string, int)]
  for genre, count in counts:
    if count >= minimum:
      ranked.add (genre, count)
  ranked.sort(proc (a, b: (string, int)): int =
    result = cmp(b[1], a[1])
    if result == 0:
      result = cmp(a[0], b[0]))
  for entry in ranked:
    result.add entry[0]

type
  Filters* = object
    ## The view's own switches. Each one is a question a player actually asks of
    ## a catalogue, and each is answered only from evidence the catalogue holds:
    ## an absent fact never counts as a yes.
    runsHere*: bool ## has a native build or a ProtonDB tier worth trusting
    deckReady*: bool ## Steam calls it playable or verified on the handheld
    unjudged*: bool ## hide what the reader has already rated
    genres*: seq[string] ## empty means every type of game, else any of these

func runsOnLinux(play: Playability; facts: SteamFacts): bool =
  ## True only when something says this runs: a Linux build, or a ProtonDB tier
  ## at silver or better, and never when anti-cheat is known to block it.
  if play.antiCheat.isSome and blocksLinux(play.antiCheat.get.value):
    return false
  if play.tier.isSome and play.tier.get.value in
      {ptSilver, ptGold, ptPlatinum}:
    return true
  if facts.linuxBuild.isSome and facts.linuxBuild.get.value:
    return true
  play.nativeBuild.isSome and play.nativeBuild.get.value

func deckSupported(play: Playability; facts: SteamFacts): bool =
  ## Steam's own handheld verdict, or a native build, which the Deck runs too.
  func usable(verdict: LinuxVerdict): bool =
    verdict in {lvPlayable, lvVerified}
  if facts.deck.isSome and usable(facts.deck.get.value):
    return true
  if facts.steamos.isSome and usable(facts.steamos.get.value):
    return true
  play.nativeBuild.isSome and play.nativeBuild.get.value

func matchesGenre(filters: Filters; facts: SteamFacts): bool =
  ## Several genres read as "any of these": picking Action and RPG asks for both
  ## kinds at once, which is how a multi-select filter is understood everywhere.
  if filters.genres.len == 0:
    return true
  for genre in facts.genres:
    if genre in filters.genres:
      return true

func keeps(filters: Filters; facts: SteamFacts; play: Playability;
           judged: bool): bool =
  if filters.runsHere and not runsOnLinux(play, facts):
    return false
  if filters.deckReady and not deckSupported(play, facts):
    return false
  if filters.unjudged and judged:
    return false
  filters.matchesGenre(facts)


func matchesSearch(release: Release; facts: SteamFacts; tokens: seq[string]): bool =
  var words = release.title & " " & facts.genres.join(" ")
  if facts.tags.isSome:
    for tag in facts.tags.get.value:
      words.add " " & tag.name
  let normalized = normalizeTitle(words)
  for token in tokens:
    if token notin normalized:
      return false
  result = true

func browse*(c: Catalog; text: string; filters = Filters()): seq[BrowseItem] =
  ## Search the entire collection by title, genres and tags, requiring every
  ## query word, and keep only what the filters admit. Matching happens before
  ## grouping so alternate release titles remain discoverable. Positive Steam
  ## IDs identify games; unidentified listings remain independent.
  ## Recommendation order precedes a stable alphabetical fallback, with the
  ## listing line breaking title ties.
  let tokens = normalizeTitle(text).splitWhitespace()
  var cards = initTable[int, ScoreCard]()
  for card in c.ranked.candidates:
    cards[card.appid] = card
  var seen = initHashSet[int]()
  var scored = initTable[int, Release]()
  var rest: seq[Release]
  for release in c.releases:
    if release.isGame:
      let appid = release.appid.get(0)
      let facts = c.stores.getOrDefault(appid)
      let play = c.play.getOrDefault(appid)
      let judged = appid > 0 and c.taste.isDecided(appid)
      if filters.keeps(facts, play, judged) and
          matchesSearch(release, facts, tokens) and
          (appid <= 0 or appid notin seen):
        if appid > 0:
          seen.incl appid
        if cards.hasKey(appid):
          scored[appid] = release
        else:
          rest.add release
  for card in c.ranked.candidates:
    if scored.hasKey(card.appid):
      result.add BrowseItem(release: scored[card.appid], card: some card)
      scored.del(card.appid)
  rest.sort(proc (a, b: Release): int =
    result = cmp(normalizeTitle(a.title), normalizeTitle(b.title))
    if result == 0:
      result = cmp(a.lineNumber, b.lineNumber))
  for release in rest:
    result.add BrowseItem(release: release)

func isBackgroundPath(path: string): bool =
  extractFilename(path).startsWith(BackgroundStem)

func isHeaderPath(path: string): bool =
  extractFilename(path).startsWith(HeaderStem)

proc artFiles*(c: Catalog; appid: int): ArtFiles =
  ## Every picture on disk for one game, split into the header and the rest.
  ##
  ## Deriving what is showable from the file system is what keeps the window
  ## offline: if the file is not here, there is nothing to draw, and the screen
  ## can name the command that would fetch it. The downloader writes `header.*`
  ## then `shot-NN.*`, so sorting by name puts the header first.
  if appid <= 0:
    return
  let dir = artDir(c.paths.art, appid)
  if not dirExists(dir):
    return
  var paths: seq[string]
  for path in walkFiles(dir & "/*"):
    paths.add path
  paths.sort()
  for path in paths:
    if isBackgroundPath(path):
      if result.background.isNone:
        result.background = some path
    elif isHeaderPath(path):
      if result.header.isNone:
        result.header = some path
    else:
      result.shots.add path
