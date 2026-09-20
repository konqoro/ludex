## Command line front end for ludex.
## Command line front end for ludex.
##
## This is the only layer that touches the file system, so the core stays pure
## and testable without fixtures on disk.

import std/[algorithm, options, os, random, strutils, tables, times]

import brian

import ludexcore/[art, models, normalize, parse, query, ratings, score, store,
                  taste]
import ludexcore/sources/[awac, protondb]
import ludexingest/[artcache, fetch, enrich]

const Usage = """
ludex: local-first catalogue of Linux-playable games

Usage:
  ludex parse  --table <table.md> --out <store.jsonl>
  ludex enrich --store <store.jsonl> --out <enrichment.jsonl> --source protondb
  ludex art    [--enrichment <file>] [--art <dir>] [--limit <n>]
  ludex list   --store <store.jsonl> [--enrichment <file>] [filters]
  ludex show   <appid> --store <store.jsonl> [--enrichment <file>]
  ludex rate   <appid> <verdict> [--ratings <file>] [--store <store.jsonl>]
  ludex pick   --store <store.jsonl> [--ratings <file>] [--enrichment <file>]
  ludex why    <appid> --store <store.jsonl> [same options as pick]
  ludex weights --out <weights.json>
  ludex help

Verdicts for `rate`:
  loved, played, finished, bounced, skipped, later

Options for `pick` and `why`:
  --time <hours>              session budget, for the effort factor
  --disk <size>               free space, e.g. 50GB
  --surprise <0..1>           how much to obey the ranking, default 0
  --limit <n>                 how many candidates to show, default 10
  --include-blocked           keep games a gate excluded, and say why
  --weights <file>            tunable weights, as written by `ludex weights`
  --seed <n>                  fix the dice, for a reproducible pick

Filters for `list`:
  --runtime native|wine|both|unknown|any   default: any
  --max-size <size>                        e.g. 5GB or "5 GB"
  --min-size <size>
  --lang <token>                           ENG, ENG/JPN, MULTi6, ...
  --title <text>                           substring of the normalized title
  --tier borked|bronze|silver|gold|platinum  needs --enrichment
  --anticheat <status>,<status>  e.g. broken,denied or running,supported
                                 exact statuses, needs --enrichment
  --genre <text>                 substring of a Steam genre, needs --enrichment
  --linux-build                  only games Steam ships a Linux build for
  --tag <name>                   substring of a SteamSpy tag, needs --enrichment
  --steamos verified|playable|unsupported   Steam's verdict for desktop Linux
  --deck verified|playable|unsupported     Steam's verdict for the handheld
  --appid                                  keep only rows naming a Steam appid
  --no-appid                               keep only rows that name none
  --limit <n>

Options for `art` (downloads the store's pictures):
  --enrichment <file>                      default data/enrichment.jsonl
  --art <dir>                              where the images go, default data/art
  --cache <dir>                            response cache, default data/cache
  --delay <ms>                             pause between images, default 100
  --limit <n>                              stop after n games, default all
  --refresh                                fetch again despite a local file
  --offline                                never touch the network

Options for `enrich`:
  --source protondb|anticheat|steam|steamspy   which source to ask
  --cc <country>                           price country for steam, default us
  --cache <dir>                            response cache, default data/cache
  --delay <ms>                             override the per-source pause
  --limit <n>                              stop after n app ids, default all
  --refresh                                ignore cached responses
  --offline                                never touch the network
"""

const
  DefaultEnrichmentPath = "data/enrichment.jsonl"
  DefaultCacheDir = "data/cache"
  DefaultRatingsPath = "data/ratings.jsonl"

type
  Request = object
    command: string
    options: Table[string, string]
    positional: seq[string]

proc fail(message: string) {.noreturn.} =
  stderr.writeLine("ludex: " & message)
  stderr.writeLine(Usage)
  quit QuitFailure

proc parseArgs(args: seq[string]): Request =
  ## Splits argv into a command, options and positional arguments.
  ##
  ## `parseopt`'s sequence overload yields `--table` and its value as two
  ## separate tokens, so the pairing is done here. `--name value`, `--name=value`
  ## and bare flags are all accepted, and `--` ends option parsing.
  var index = 0
  if args.len > 0:
    result.command = args[0]
    index = 1
  while index < args.len:
    let token = args[index]
    if token == "--":
      inc index
      while index < args.len:
        result.positional.add(args[index])
        inc index
    elif token.startsWith("--"):
      let body = token[2..^1]
      let equals = body.find('=')
      if equals >= 0:
        result.options[body[0..<equals]] = body[equals + 1..^1]
      elif index + 1 < args.len and not args[index + 1].startsWith("-"):
        result.options[body] = args[index + 1]
        inc index
      else:
        result.options[body] = ""
    elif token.startsWith("-") and token.len > 1:
      result.options[token[1..^1]] = ""
    else:
      result.positional.add(token)
    inc index

proc optionValue(request: Request; name: string): Option[string] =
  if request.options.hasKey(name):
    result = some(request.options[name])

proc requireOption(request: Request; name: string): string =
  let value = optionValue(request, name)
  if value.isNone or value.get.len == 0:
    fail("missing --" & name)
  result = value.get

proc readText(path: string; what: string): string =
  if not fileExists(path):
    fail("no such " & what & ": " & path)
  try:
    result = readFile(path)
  except IOError as error:
    fail("cannot read " & path & ": " & error.msg)

proc writeText(path: string; content: string) =
  try:
    writeFile(path, content)
  except IOError as error:
    fail("cannot write " & path & ": " & error.msg)

proc readStore(path: string): seq[Release] =
  let decoded = decodeReleases(readText(path, "store"))
  for failure in decoded.failures:
    stderr.writeLine("ludex: skipped " & failure)
  result = decoded.items

proc readEnrichmentFile(path: string): seq[Enrichment] =
  ## Loads an enrichment store, reporting bad lines and keeping the rest.
  let decoded = decodeEnrichments(readText(path, "enrichment store"))
  for failure in decoded.failures:
    stderr.writeLine("ludex: skipped " & failure)
  result = decoded.items

proc readEnrichment(request: Request): seq[Enrichment] =
  ## Loads the enrichment store when one is configured or present, so `list`
  ## and `show` work with or without it.
  let path = optionValue(request, "enrichment").get(DefaultEnrichmentPath)
  if fileExists(path):
    result = readEnrichmentFile(path)

proc indexPlayability(items: openArray[Enrichment]): Table[int, Playability] =
  ## Indexes playability by Steam app id, which is the join key.
  for item in items:
    result[item.appid] = item.play

proc readTaste(request: Request): Taste =
  ## Loads the ratings file when one is configured or present.
  let path = optionValue(request, "ratings").get(DefaultRatingsPath)
  if fileExists(path):
    let loaded = decodeTaste(readText(path, "ratings"))
    for failure in loaded.failures:
      stderr.writeLine("ludex: skipped " & failure)
    result = loaded.taste

proc readWeights(request: Request): Weights =
  ## Loads a weights file, falling back to the defaults.
  let path = optionValue(request, "weights")
  if path.isNone:
    return initWeights()
  var loaded = initWeights()
  try:
    fromJson(readText(path.get, "weights"), loaded)
  except CatchableError as error:
    fail("cannot read weights: " & error.msg)
  result = loaded

proc tagVectors(items: openArray[Enrichment]): Table[int, seq[Tag]] =
  ## The tag vector of every game that has one, which is what the profile is
  ## built from.
  for item in items:
    if item.store.tags.isSome:
      result[item.appid] = item.store.tags.get.value

proc indexStore(items: openArray[Enrichment]): Table[int, SteamFacts] =
  ## Indexes store facts by the same key.
  for item in items:
    result[item.appid] = item.store

proc verdictOption(request: Request;
                   name: string): Option[LinuxVerdict] =
  ## Reads a compatibility verdict by its enum spelling, reporting a bad value
  ## instead of silently matching nothing.
  let value = optionValue(request, name)
  if value.isSome:
    for verdict in LinuxVerdict:
      if $verdict == value.get:
        result = some verdict
    if result.isNone:
      fail("--" & name & " wants unknown, unsupported, playable or verified, " &
        "got: " & value.get)

proc sizeOption(request: Request; name: string): Option[int64] =
  let value = optionValue(request, name)
  if value.isSome:
    result = parseSizeLoose(value.get)
    if result.isNone:
      fail("--" & name & " wants a size such as 5GB, got: " & value.get)

proc buildFilter(request: Request): Filter =
  result = initFilter()
  let runtime = optionValue(request, "runtime")
  if runtime.isSome and runtime.get != "any":
    result.runtime = parseRuntimeName(runtime.get)
    if result.runtime.isNone:
      fail("--runtime wants native, wine, both, unknown or any, got: " &
        runtime.get)
  result.maxSize = sizeOption(request, "max-size")
  result.minSize = sizeOption(request, "min-size")
  result.appidOnly = request.options.hasKey("appid")
  result.noAppid = request.options.hasKey("no-appid")
  result.lang = request.options.getOrDefault("lang")
  result.title = normalizeTitle(request.options.getOrDefault("title"))
  let tier = optionValue(request, "tier")
  if tier.isSome:
    let parsed = parsePlayTier(tier.get)
    if parsed == ptUnknown:
      fail("--tier wants borked, bronze, silver, gold or platinum, got: " &
        tier.get)
    result.tier = some parsed
  result.genre = request.options.getOrDefault("genre")
  result.tag = request.options.getOrDefault("tag")
  result.linuxBuildOnly = request.options.hasKey("linux-build")
  result.steamos = verdictOption(request, "steamos")
  result.deck = verdictOption(request, "deck")
  let antiCheat = optionValue(request, "anticheat")
  if antiCheat.isSome:
    for name in antiCheat.get.split(','):
      let trimmed = name.strip
      if trimmed.len > 0:
        let parsed = parseAntiCheat(trimmed)
        if parsed == acUnknown:
          fail("--anticheat wants broken, denied, planned, running or " &
            "supported, got: " & trimmed)
        result.antiCheat.add parsed
  let limit = request.options.getOrDefault("limit")
  if limit.len > 0:
    try:
      result.limit = some(parseInt(limit))
    except ValueError:
      fail("--limit wants a number, got: " & limit)

proc countGames(releases: openArray[Release]): int =
  for release in releases:
    if release.isGame:
      inc result

proc formatSize(bytes: int64): string =
  ## Renders `130023424` as `124.0 MB`.
  const units = ["B", "KB", "MB", "GB", "TB"]
  var value = float(bytes)
  var index = 0
  while value >= 1024 and index < units.len - 1:
    value /= 1024.0
    inc index
  if index == 0:
    result = $bytes & " B"
  else:
    result = formatFloat(value, ffDecimal, 1) & " " & units[index]

proc formatSize(release: Release): string =
  if release.sizeBytes.isSome: formatSize(release.sizeBytes.get) else: "-"

proc formatRuntime(runtime: RuntimeKind): string =
  if runtime == rkUnknown: "-" else: $runtime

proc formatAntiCheat(play: Playability): string =
  ## The anti-cheat status, what is blocking it, and whether it blocks at all.
  if play.antiCheat.isNone:
    return "-"
  let status = play.antiCheat.get.value
  result = $status
  if play.antiCheatNames.isSome:
    result.add " (" & play.antiCheatNames.get.join(", ") & ")"
  if blocksLinux(status):
    result.add " - blocks Linux"
  elif not usableUnderLinux(status):
    result.add " - not usable yet"

proc formatTier(play: Playability): string =
  ## The ProtonDB tier, with the evidence it rests on, because "gold" over
  ## three reports is not "gold" over three hundred.
  if play.tier.isNone:
    return "-"
  result = $play.tier.get.value
  if play.reportCount.isSome:
    result.add " (" & $play.reportCount.get.value & " reports"
    if play.tierConfidence.isSome:
      result.add ", " & play.tierConfidence.get
    result.add ")"

proc formatAppId(release: Release): string =
  if release.appid.isSome: $release.appid.get else: "-"

proc elide(text: string; width: int): string =
  if text.len <= width: text else: text[0..<width - 3] & "..."

proc formatPrice(price: Price): string =
  ## Renders cents as the store shows them, with the discount when there is one.
  result = price.currency & " " & formatFloat(float(price.final) / 100.0,
                                              ffDecimal, 2)
  if price.discountPercent > 0:
    result.add " (was " & formatFloat(float(price.initial) / 100.0,
                                      ffDecimal, 2) & ", -" &
      $price.discountPercent & "%)"

proc printRelease(release: Release; play: Option[Playability];
                  store: SteamFacts) =
  echo "title      ", release.title
  echo "line       ", release.lineNumber
  echo "steam      ", formatAppId(release)
  echo "runtime    ", formatRuntime(release.runtime)
  echo "size       ", formatSize(release)
  echo "build      ", release.buildId.get("-")
  echo "version    ", release.version.get("-")
  echo "languages  ", release.langToken.get("-")
  echo "kind       ", $release.pack
  if store.genres.len > 0:
    echo "genres     ", store.genres.join(", ")
  if store.developers.len > 0:
    echo "developer  ", store.developers.join(", ")
  if store.releaseDate.isSome:
    echo "released   ", store.releaseDate.get.value
  if store.price.isSome:
    let price = store.price.get.value
    echo "price      ", formatPrice(price)
  if store.reviews.count.isSome:
    let rating = store.reviews
    if rating.percent.isSome:
      echo "reviews    ", formatFloat(rating.percent.get.value, ffDecimal, 1),
        "% of ", $rating.count.get.value, " positive (",
        rating.description.get(""), ")"
    else:
      echo "reviews    ", $rating.count.get.value, " reviews, no score yet"
  if store.recommendations.isSome:
    echo "recommends ", $store.recommendations.get.value
  if store.tags.isSome:
    let names = store.tags.get.value.topTags(8)
    echo "tags       ", names.join(", ")
  if store.owners.isSome:
    echo "owners     ", store.owners.get.value
  if store.currentPlayers.isSome:
    echo "players    ", $store.currentPlayers.get.value, " concurrent at sampling"
  if store.averageMinutes.isSome:
    echo "playtime   ", $store.averageMinutes.get.value, " minutes on average"
  if store.deck.isSome:
    echo "deck       ", $store.deck.get.value
  if store.steamos.isSome:
    echo "steamos    ", $store.steamos.get.value,
      " (Steam's own verdict for desktop Linux)"
  if store.linuxBuild.isSome:
    echo "steamlinux ", (if store.linuxBuild.get.value: "yes" else: "no"),
      " (Steam's own Linux build)"
  if play.isSome:
    echo "protondb   ", formatTier(play.get)
    echo "anticheat  ", formatAntiCheat(play.get)
    if play.get.nativeBuild.isSome:
      echo "native     ", (if play.get.nativeBuild.get.value: "yes" else: "no"),
        " (per AreWeAntiCheatYet)"
  if release.nested.len > 0:
    for extra in release.nested:
      echo "packed     ", extra
  if release.warnings.len > 0:
    echo "warnings   ", release.warnings.join(", ")

proc commandParse(request: Request) =
  let tablePath = requireOption(request, "table")
  let outPath = requireOption(request, "out")
  let releases = parseTable(readText(tablePath, "table"))
  writeText(outPath, encodeReleases(releases))

  var games = 0
  var withAppId = 0
  var withoutRuntime = 0
  for release in releases:
    if release.isGame:
      inc games
      if release.appid.isSome:
        inc withAppId
      if release.runtime == rkUnknown:
        inc withoutRuntime
  echo games, " games, ", withAppId, " with a Steam appid, ",
    withoutRuntime, " with no metadata"
  echo "wrote ", outPath

proc commandList(request: Request) =
  let storePath = requireOption(request, "store")
  let releases = readStore(storePath)
  let filter = buildFilter(request)
  let items = readEnrichment(request)
  let play = indexPlayability(items)
  let stores = indexStore(items)

  if filter.tier.isSome:
    echo "appid     ", "size".align(10), "  ", "tier".align(10), "  ",
      "reports".align(7), "  title"
  elif filter.antiCheat.len > 0:
    echo "appid     ", "size".align(10), "  ", "status".align(10), "  ",
      "anticheat".align(22), "  title"
  else:
    echo "appid     ", "size".align(10), "  ", "runtime".align(8), "  ",
      "lang".align(10), "  title"
  var shown = 0
  var matched = 0
  for release in releases:
    if matches(release, filter, playabilityOf(play, release),
               storeFactsOf(stores, release)):
      inc matched
      if filter.limit.isNone or shown < filter.limit.get:
        inc shown
        if filter.tier.isSome:
          # The list shows the tier and the evidence behind it in full, because
          # "platinum" over six reports is a weaker claim than over three
          # hundred, and a truncated cell would hide that.
          let facts = playabilityOf(play, release)
          let tier =
            if facts.isSome and facts.get.tier.isSome:
              $facts.get.tier.get.value
            else:
              "-"
          let reports =
            if facts.isSome and facts.get.reportCount.isSome:
              $facts.get.reportCount.get.value
            else:
              "-"
          echo formatAppId(release).align(9), " ",
            formatSize(release).align(10), "  ",
            tier.align(10), "  ",
            reports.align(7), "  ",
            elide(release.title, 50)
        elif filter.antiCheat.len > 0:
          let facts = playabilityOf(play, release)
          let status =
            if facts.isSome and facts.get.antiCheat.isSome:
              $facts.get.antiCheat.get.value
            else:
              "-"
          let names =
            if facts.isSome and facts.get.antiCheatNames.isSome:
              facts.get.antiCheatNames.get.join(", ")
            else:
              "-"
          echo formatAppId(release).align(9), " ",
            formatSize(release).align(10), "  ",
            status.align(10), "  ",
            elide(names, 22).align(22), "  ",
            elide(release.title, 40)
        else:
          echo formatAppId(release).align(9), " ",
            formatSize(release).align(10), "  ",
            formatRuntime(release.runtime).align(8), "  ",
            release.langToken.get("-").align(10), "  ",
            elide(release.title, 60)
  echo matched, " of ", countGames(releases), " games matched"

proc commandShow(request: Request) =
  let storePath = requireOption(request, "store")
  if request.positional.len == 0:
    fail("show needs a Steam appid")
  let wanted = try:
                 parseInt(request.positional[0])
               except ValueError:
                 fail("not a Steam appid: " & request.positional[0])
  let items = readEnrichment(request)
  let play = indexPlayability(items)
  let stores = indexStore(items)
  for release in readStore(storePath):
    if release.appid.isSome and release.appid.get == wanted:
      let facts = if stores.hasKey(wanted): stores[wanted] else: SteamFacts()
      printRelease(release, playabilityOf(play, release), facts)
      return
  fail("no release with appid " & $wanted)

proc enrichmentPath(request: Request; name: string): string =
  ## The enrichment store to read or write, honouring `--enrichment` and
  ## `--out` so `enrich` and `list` can point at the same file.
  result = optionValue(request, name).get(DefaultEnrichmentPath)

proc optionFloat(request: Request; name: string): float =
  ## Reads a float option, defaulting to zero.
  let value = optionValue(request, name)
  if value.isNone or value.get.len == 0:
    return 0.0
  try:
    result = parseFloat(value.get)
  except ValueError:
    fail("--" & name & " wants a number, got: " & value.get)

proc sizeOf(request: Request; name: string): int64 =
  ## Reads a size option, defaulting to zero, which means unbounded.
  let value = optionValue(request, name)
  if value.isNone:
    return 0'i64
  let parsed = parseSizeLoose(value.get)
  if parsed.isNone:
    fail("--" & name & " wants a size such as 50GB, got: " & value.get)
  result = parsed.get

proc numberOf(request: Request; name: string; fallback: int): int =
  ## Reads an integer option, reporting a bad value instead of raising.
  let value = optionValue(request, name)
  if value.isNone or value.get.len == 0:
    return fallback
  try:
    result = parseInt(value.get)
  except ValueError:
    fail("--" & name & " wants a number, got: " & value.get)

proc commandEnrich(request: Request) =
  let storePath = requireOption(request, "store")
  let outPath = enrichmentPath(request, "out")
  let sourceName = optionValue(request, "source").get("protondb")
  var source = srcSummary
  var recognized = false
  for candidate in SourceKind:
    if $candidate == sourceName:
      source = candidate
      recognized = true
  if not recognized:
    fail("--source must be protondb, anticheat, steam or steamspy, got: " &
      sourceName)

  let releases = readStore(storePath)
  var existing: seq[Enrichment]
  if fileExists(outPath):
    existing = readEnrichmentFile(outPath)

  let client = initClient(cacheDir = optionValue(request, "cache").get(
                            DefaultCacheDir),
                          delayMs = numberOf(request, "delay",
                                             defaultDelayMs(source)),
                          offline = request.options.hasKey("offline"))
  var run: RunResult
  # The client owns a connection pool, so it is released on every path out.
  try:
    run = enrich(client,
                 source,
                 releases,
                 existing,
                 refresh = request.options.hasKey("refresh"),
                 limit = numberOf(request, "limit", 0),
                 country = optionValue(request, "cc").get("us"))
  finally:
    client.close()

  writeText(outPath, encodeEnrichments(run.items))
  echo run.stats.asked, " asked, ", run.stats.answered, " answered, ",
    run.stats.silent, " silent, ", run.stats.cached, " from cache, ",
    run.stats.partial, " partial, ", run.stats.failed, " failed"
  for failure in run.stats.failures:
    stderr.writeLine("ludex: " & failure)
  echo "wrote ", outPath

proc commandArt(request: Request) =
  ## Downloads the pictures the enrichment store names.
  ##
  ## This is a separate command from `enrich` on purpose: the store keeps only
  ## the URLs, and a picture is an order of magnitude bigger than the JSON record
  ## pointing at it, so fetching thousands of them is its own operation with its
  ## own limit. Re-running skips what is already on disk, which makes `--limit` a
  ## resumable cursor.
  let path = optionValue(request, "enrichment").get(DefaultEnrichmentPath)
  let items = readEnrichmentFile(path)
  if items.len == 0:
    fail("no enrichment at " & path &
      ": run `ludex enrich --source steam` to write one")

  let artRoot = optionValue(request, "art").get(DefaultArtDir)
  let client = initClient(cacheDir = optionValue(request, "cache").get(
                            DefaultCacheDir),
                          delayMs = numberOf(request, "delay",
                                             DefaultArtDelayMs),
                          offline = request.options.hasKey("offline"))
  var stats: ArtStats
  # The client owns a connection pool, so it is released on every path out.
  try:
    stats = fetchArt(client, items, artRoot,
                     limit = numberOf(request, "limit", 0),
                     refresh = request.options.hasKey("refresh"))
  finally:
    client.close()

  echo stats.games, " games, ", stats.fetched, " images fetched, ",
    stats.skipped, " already here, ", stats.failed, " failed"
  for failure in stats.failures:
    stderr.writeLine("ludex: " & failure)
  echo "wrote ", artRoot

proc requireTaste(request: Request): string =
  ## The ratings file to write, so `rate` and `pick` agree on one path.
  optionValue(request, "ratings").get(DefaultRatingsPath)

proc verdictArgument(text: string): Verdict =
  ## Reads a verdict by its enum spelling, listing the options on a mistake.
  for verdict in Verdict:
    if $verdict == text:
      return verdict
  fail("verdict must be loved, played, finished, bounced, skipped or later, " &
    "got: " & text)

proc commandRate(request: Request) =
  if request.positional.len < 2:
    fail("rate needs an appid and a verdict")
  let appid = try:
                parseInt(request.positional[0])
              except ValueError:
                fail("not a Steam appid: " & request.positional[0])
  let verdict = verdictArgument(request.positional[1])
  let path = requireTaste(request)

  var taste =
    if fileExists(path): readTaste(request)
    else: Taste()
  var title = ""
  let storePath = optionValue(request, "store")
  if storePath.isSome and fileExists(storePath.get):
    for release in readStore(storePath.get):
      if release.appid.isSome and release.appid.get == appid:
        title = release.title
  taste.rate(appid, title, verdict, toUnix(getTime()))
  writeText(path, encodeTaste(taste))
  echo "rated ", appid, " as ", $verdict, " (", taste.ratings.len,
    " ratings)"

proc printCard(card: ScoreCard; showFactors: bool) =
  ## One game's verdict. A card with no app id is a listing row that never
  ## resolved to a Steam game, so there is nothing to look up.
  echo card.title, "  [", (if card.appid > 0: $card.appid else: "no appid"), "]"
  echo "  score     ", formatFloat(card.score * 100.0, ffDecimal, 1), "% ",
    "from ", $int(card.coverage * 100.0 + 0.5), "% of the weight known"
  if card.blockers.len > 0:
    for blocker in card.blockers:
      echo "  blocked   ", blocker
  if showFactors:
    for item in card.factors:
      # A whole-number percentage: `ffDecimal` with a precision of zero still
      # emits the decimal point.
      let value =
        if item.value.isSome: align($int(item.value.get * 100.0 + 0.5) & "%", 4)
        else: align("unknown", 4)
      echo "  ", alignLeft($item.kind, 10), " ", value, "  ", item.reason

proc commandPick(request: Request) =
  let storePath = requireOption(request, "store")
  let releases = readStore(storePath)
  let items = readEnrichment(request)
  let store = indexStore(items)
  let play = indexPlayability(items)
  let taste = readTaste(request)
  let weights = readWeights(request)
  let profile = buildProfile(taste, tagVectors(items))
  let diskHours = numberOf(request, "time", 0)

  let ranked = rank(releases, play, store, taste, profile, weights,
                    diskBytes = sizeOf(request, "disk"),
                    budgetMinutes = diskHours * 60)

  if profile.len > 0:
    echo "taste     ", profile.topProfileTags(6).join(", ")
    if profile.dislikes(3).len > 0:
      echo "avoids    ", profile.dislikes(3).join(", ")
  else:
    echo "taste     nothing yet: rate a few games with `ludex rate`"

  echo ranked.candidates.len, " candidates, ", ranked.blocked.len,
    " blocked, ", ranked.unranked.len, " with no data yet"
  echo ""

  let limit = numberOf(request, "limit", 10)
  var shown = 0
  for card in ranked.candidates:
    if shown >= limit:
      break
    inc shown
    printCard(card, showFactors = false)

  if ranked.unranked.len > 0:
    echo ""
    echo "no data yet for ", ranked.unranked.len, " games: run `ludex enrich`"

  if request.options.hasKey("include-blocked") and ranked.blocked.len > 0:
    # Excluded games are printed after the answer rather than mixed into it: the
    # ranking is a recommendation, and a game a gate rejected is not one. They
    # are still ordered by score, so the list reads.
    echo ""
    echo "blocked, best first:"
    var ordered = ranked.blocked
    ordered.sort(proc (a, b: ScoreCard): int =
      if a.score != b.score: cmp(b.score, a.score)
      else: cmp(a.appid, b.appid))
    for card in ordered:
      printCard(card, showFactors = false)

  let surprise = request.optionFloat("surprise")
  if surprise > 0.0 and ranked.candidates.len > 0:
    var rng = initRand(numberOf(request, "seed", 0))
    let picked = roll(ranked.candidates, surprise, rng)
    if picked.isSome:
      echo ""
      echo "rolled (surprise ", formatFloat(surprise, ffDecimal, 2), "):"
      printCard(picked.get, showFactors = true)

proc commandWhy(request: Request) =
  let storePath = requireOption(request, "store")
  if request.positional.len == 0:
    fail("why needs a Steam appid")
  let wanted = try:
                 parseInt(request.positional[0])
               except ValueError:
                 fail("not a Steam appid: " & request.positional[0])
  let releases = readStore(storePath)
  let items = readEnrichment(request)
  let store = indexStore(items)
  let play = indexPlayability(items)
  let taste = readTaste(request)
  let weights = readWeights(request)
  let profile = buildProfile(taste, tagVectors(items))
  let ranked = rank(releases, play, store, taste, profile, weights,
                    diskBytes = sizeOf(request, "disk"),
                    budgetMinutes = numberOf(request, "time", 0) * 60,
                    includeBlocked = true)
  for card in ranked.candidates:
    if card.appid == wanted:
      printCard(card, showFactors = true)
      return
  for card in ranked.blocked:
    if card.appid == wanted:
      printCard(card, showFactors = true)
      return
  for card in ranked.unranked:
    if card.appid == wanted:
      printCard(card, showFactors = true)
      echo "  no factor had data, so there is nothing to rank yet"
      return
  fail("no release with appid " & $wanted)

proc commandWeights(request: Request) =
  let path = optionValue(request, "out").get("data/weights.json")
  writeText(path, toJson(initWeights()))
  echo "wrote ", path

proc main() =
  let request = parseArgs(commandLineParams())
  case request.command
  of "parse": commandParse(request)
  of "enrich": commandEnrich(request)
  of "art": commandArt(request)
  of "list": commandList(request)
  of "show": commandShow(request)
  of "rate": commandRate(request)
  of "pick": commandPick(request)
  of "why": commandWhy(request)
  of "weights": commandWeights(request)
  of "", "help", "--help", "-h": echo Usage
  else: fail("unknown command: " & request.command)

when isMainModule:
  main()
