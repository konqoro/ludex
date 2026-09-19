## Turning enrichment sources into stored facts.
##
## The pipeline is the same for every source: pick the app ids worth asking
## about, fetch, decode with a pure decoder, merge into what is already known,
## and keep going when one game fails. This module is the batch boundary, so a
## per-game failure is recorded instead of ending the run.
##
## The merge rule is deliberately simple: a freshly fetched fact replaces the
## previous one, and everything else is left alone. That is what makes
## `--source protondb` safe to rerun after `--source steam`, and it means a
## source can never delete another source's facts by staying silent.

import std/[algorithm, options, sets, tables, times]

import ludexcore/[models, sources/awac, sources/protondb]
import ludexcore/sources/[steamdeck, steamreviews, steamspy, steamstore]
import ./client

type
  SourceKind* = enum
    srcSummary = "protondb" ## ProtonDB per-appid compatibility summary
    srcAntiCheat = "anticheat" ## AreWeAntiCheatYet, one file for every game
    srcSteamStore = "steam" ## store details, reviews and the Deck report
    srcSteamSpy = "steamspy" ## tags, ownership and player counts

  RunStats* = object
    ## What one run actually did, so a partial sweep is never mistaken for a
    ## complete one.
    asked*: int ## app ids the source was queried about
    answered*: int ## app ids the source had data for
    silent*: int ## app ids the source answered "nothing known" for
    cached*: int ## answers served from the cache
    failed*: int ## app ids nothing could be fetched for at all
    partial*: int ## app ids where some calls failed and others answered
    failures*: seq[string] ## `<appid>: <reason>`

  RunResult* = object
    items*: seq[Enrichment] ## every record known after the run, by app id
    stats*: RunStats

proc defaultDelayMs*(source: SourceKind): int =
  ## The pause between requests that keeps each source civil.
  ##
  ## ProtonDB publishes no limit, Steam's store tolerates roughly 200 requests
  ## per five minutes per address, and AreWeAntiCheatYet is one request for the
  ## whole dataset.
  case source
  of srcSummary: 250
  of srcSteamStore: 1600
  of srcSteamSpy: 1200
  of srcAntiCheat: 0

proc nowUnix(): int64 =
  ## The current time in unix seconds, stamped onto every fetched fact.
  toUnix(getTime())

func prefer[T](base, update: Option[T]): Option[T] =
  ## The newer value wins when there is one; otherwise the older one stays.
  ##
  ## Every field of `Playability` goes through this one rule, so adding a field
  ## cannot silently lose it on the next merge.
  if update.isSome: update else: base

func mergePlayability*(base, update: Playability): Playability =
  ## Overlays `update` onto `base` field by field, so a source that knows
  ## nothing about anti-cheat cannot erase what another source found.
  result.tier = prefer(base.tier, update.tier)
  result.tierScore = prefer(base.tierScore, update.tierScore)
  result.reportCount = prefer(base.reportCount, update.reportCount)
  result.tierConfidence = prefer(base.tierConfidence, update.tierConfidence)
  result.antiCheat = prefer(base.antiCheat, update.antiCheat)
  result.antiCheatNames = prefer(base.antiCheatNames, update.antiCheatNames)
  result.nativeBuild = prefer(base.nativeBuild, update.nativeBuild)

proc indexByAppId(items: openArray[Enrichment]): Table[int, Enrichment] =
  ## Indexes records by app id, keeping the last word on duplicates.
  for item in items:
    result[item.appid] = item

func appIdsOf(releases: openArray[Release]): seq[int] =
  ## The distinct Steam app ids worth asking about, in catalogue order.
  var seen = initHashSet[int]()
  for release in releases:
    if release.appid.isSome and not seen.containsOrIncl(release.appid.get):
      result.add release.appid.get

func mergeSteamFacts*(base, update: SteamFacts): SteamFacts =
  ## Overlays `update` onto `base`.
  ##
  ## Lists are replaced wholesale when the new answer has them, because half a
  ## genre list is not a fact about anything, and everything else goes through
  ## the same prefer rule as playability.
  result = base
  if update.kind.len > 0:
    result.kind = update.kind
  result.isFree = base.isFree or update.isFree
  if update.developers.len > 0:
    result.developers = update.developers
  if update.publishers.len > 0:
    result.publishers = update.publishers
  if update.genres.len > 0:
    result.genres = update.genres
  if update.categories.len > 0:
    result.categories = update.categories
  if update.shortDescription.len > 0:
    result.shortDescription = update.shortDescription
  result.linuxBuild = prefer(base.linuxBuild, update.linuxBuild)
  result.releaseDate = prefer(base.releaseDate, update.releaseDate)
  result.price = prefer(base.price, update.price)
  result.recommendations = prefer(base.recommendations, update.recommendations)
  result.reviews.percent = prefer(base.reviews.percent, update.reviews.percent)
  result.reviews.count = prefer(base.reviews.count, update.reviews.count)
  result.reviews.description = prefer(base.reviews.description,
                                     update.reviews.description)
  result.critics = prefer(base.critics, update.critics)
  result.deck = prefer(base.deck, update.deck)
  result.steamos = prefer(base.steamos, update.steamos)
  result.tags = prefer(base.tags, update.tags)
  result.owners = prefer(base.owners, update.owners)
  result.currentPlayers = prefer(base.currentPlayers, update.currentPlayers)
  result.averageMinutes = prefer(base.averageMinutes, update.averageMinutes)
  # Art is merged like everything else. Forgetting it here costs silently: the
  # facts decode, the run reports success, and the pictures never appear.
  result.art.background = prefer(base.art.background, update.art.background)
  result.art.header = prefer(base.art.header, update.art.header)
  result.art.screenshots = prefer(base.art.screenshots, update.art.screenshots)

proc collect(known: Table[int, Enrichment]): seq[Enrichment] =
  ## Snapshots the working set, ordered by app id so the file is stable across
  ## runs and diffs stay small.
  for item in known.values:
    result.add item
  result.sort(proc (a, b: Enrichment): int = cmp(a.appid, b.appid))

proc steamFacts(client: Client; appid: int; country: string; refresh: bool;
                problems: var seq[string]): SteamFacts =
  ## Asks Steam for one game's store entry, review summary and Deck report.
  ##
  ## The three calls are independent, and each failure is recorded but does not
  ## discard the others: a game whose store entry vanished can still have
  ## reviews, and losing two good answers because a third call timed out would
  ## waste the sweep. `problems` receives one line per failed call.
  template attempt(label: string; body: untyped) =
    try:
      body
    except FetchError as error:
      problems.add label & ": " & error.msg
    except CatchableError as error:
      problems.add label & " cannot decode: " & error.msg

  attempt "details":
    let details = fetch(client, detailsUrl(appid, country), refresh)
    if details.status == 200:
      let app = decodeApp(details.body, appid)
      if app.isSome:
        result = toSteamFacts(app.get, nowUnix())
  attempt "reviews":
    let reviews = fetch(client, reviewsUrl(appid), refresh)
    if reviews.status == 200:
      result.reviews = toReviewScore(decodeReviews(reviews.body), nowUnix())
  attempt "deck":
    let deck = fetch(client, deckUrl(appid), refresh)
    if deck.status == 200:
      let report = decodeDeck(deck.body)
      if report.results.isSome:
        let deckResults = report.results.get
        result.deck = toVerdict(deckResults.deckCategory, nowUnix())
        result.steamos = toVerdict(deckResults.steamosCategory, nowUnix())

proc enrichSteam*(client: Client; releases: openArray[Release];
                  existing: openArray[Enrichment]; refresh = false;
                  limit = 0; country = "us"): RunResult =
  ## Enriches the catalogue from Steam's store details and review summaries.
  ##
  ## Three requests per game: store details, the review summary and the Deck
  ## compatibility report. A game Steam has no entry for is counted as silent and
  ## keeps whatever it already had.
  var known = indexByAppId(existing)
  for appid in appIdsOf(releases):
    if limit > 0 and result.stats.asked >= limit:
      break
    inc result.stats.asked
    var problems: seq[string] = @[]
    let facts = steamFacts(client, appid, country, refresh, problems)
    for problem in problems:
      result.stats.failures.add($appid & " " & problem)
    if facts.isKnown:
      if problems.len > 0:
        inc result.stats.partial
      else:
        inc result.stats.answered
      let base = known.getOrDefault(appid, initEnrichment(appid))
      known[appid] = Enrichment(appid: appid, play: base.play,
                                store: mergeSteamFacts(base.store, facts))
    elif problems.len > 0:
      inc result.stats.failed
    else:
      inc result.stats.silent

  result.stats.cached = client.hits
  result.items = collect(known)

proc enrichSteamSpy*(client: Client; releases: openArray[Release];
                     existing: openArray[Enrichment]; refresh = false;
                     limit = 0): RunResult =
  ## Enriches the catalogue from SteamSpy: tags, ownership and player counts.
  ##
  ## One request per game. SteamSpy refreshes its data once a day, so a repeat
  ## run inside a day is answered from the cache and is worth nothing anyway.
  var known = indexByAppId(existing)
  for appid in appIdsOf(releases):
    if limit > 0 and result.stats.asked >= limit:
      break
    inc result.stats.asked
    var facts = SteamFacts()
    var problem = ""
    try:
      let fetched = fetch(client, spyUrl(appid), refresh)
      if fetched.status == 200:
        facts = toSteamFacts(decodeSpyApp(fetched.body), nowUnix())
    except FetchError as error:
      problem = error.msg
    except CatchableError as error:
      problem = "cannot decode: " & error.msg
    if problem.len > 0:
      inc result.stats.failed
      result.stats.failures.add($appid & ": " & problem)
    elif facts.isKnown:
      inc result.stats.answered
      let base = known.getOrDefault(appid, initEnrichment(appid))
      known[appid] = Enrichment(appid: appid, play: base.play,
                                store: mergeSteamFacts(base.store, facts))
    else:
      inc result.stats.silent

  result.stats.cached = client.hits
  result.items = collect(known)

proc summaryFacts(client: Client; appid: int;
                  refresh: bool): Option[Playability] =
  ## Asks ProtonDB about one app id. `none` means the source knows nothing.
  let fetched = fetch(client, summaryUrl(appid), refresh)
  if fetched.status != 200:
    result = none(Playability)
  else:
    result = some toPlayability(decodeSummary(fetched.body), nowUnix())

proc applyFacts(known: var Table[int, Enrichment]; updates: openArray[Release];
                facts: Table[int, Playability]): RunStats =
  ## Applies a source's answers to every app id in the catalogue.
  ##
  ## Used by sources that answer about all games at once, where the unit of
  ## work is the catalogue rather than one request per game.
  for appid in appIdsOf(updates):
    inc result.asked
    if facts.hasKey(appid):
      inc result.answered
      let base = known.getOrDefault(appid, initEnrichment(appid))
      known[appid] = Enrichment(appid: appid,
                                play: mergePlayability(base.play, facts[appid]),
                                store: base.store)
    else:
      inc result.silent

proc enrichAntiCheat*(client: Client; releases: openArray[Release];
                      existing: openArray[Enrichment]; refresh = false;
                      limit = 0): RunResult =
  ## Enriches the catalogue from the AreWeAntiCheatYet dataset.
  ##
  ## This source answers once for everyone, so `limit` does not apply to it and
  ## is ignored. One request, 1167 games, and a per-entry decode that cannot
  ## fail the whole run.
  var known = indexByAppId(existing)
  let fetched = fetch(client, GamesUrl, refresh)
  if fetched.status == 200:
    result.stats = applyFacts(known, releases,
                              indexByAppId(decodeDataset(fetched.body), nowUnix()))
  else:
    result.stats.asked = appIdsOf(releases).len
    result.stats.failed = 1
    result.stats.failures.add("dataset: HTTP " & $fetched.status)
  result.stats.cached = client.hits
  result.items = collect(known)

proc enrichSummary*(client: Client; releases: openArray[Release];
                    existing: openArray[Enrichment]; refresh = false;
                    limit = 0): RunResult =
  ## Enriches the catalogue from ProtonDB summaries.
  ##
  ## `limit` caps how many app ids this run asks about, which is what makes a
  ## polite partial sweep possible. Records for app ids that were not asked
  ## about are passed through untouched.
  var known = indexByAppId(existing)
  for appid in appIdsOf(releases):
    if limit > 0 and result.stats.asked >= limit:
      break
    inc result.stats.asked
    var update = none(Playability)
    var problem = ""
    # Any per-game failure is recoverable: the run records it and moves on.
    try:
      update = summaryFacts(client, appid, refresh)
    except FetchError as error:
      problem = error.msg
    except CatchableError as error:
      problem = "cannot decode: " & error.msg
    if problem.len > 0:
      inc result.stats.failed
      result.stats.failures.add($appid & ": " & problem)
    elif update.isSome:
      inc result.stats.answered
      let base = known.getOrDefault(appid, initEnrichment(appid))
      known[appid] = Enrichment(appid: appid,
                                play: mergePlayability(base.play, update.get),
                                store: base.store)
    else:
      inc result.stats.silent

  result.stats.cached = client.hits
  result.items = collect(known)

proc enrich*(client: Client; source: SourceKind; releases: openArray[Release];
             existing: openArray[Enrichment]; refresh = false;
             limit = 0; country = "us"): RunResult =
  ## Dispatches to one source.
  case source
  of srcSummary:
    enrichSummary(client, releases, existing, refresh, limit)
  of srcAntiCheat:
    enrichAntiCheat(client, releases, existing, refresh, limit)
  of srcSteamStore:
    enrichSteam(client, releases, existing, refresh, limit, country)
  of srcSteamSpy:
    enrichSteamSpy(client, releases, existing, refresh, limit)
