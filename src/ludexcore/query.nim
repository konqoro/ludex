## Filtering a store of releases.
##
## Pure and platform free, so the CLI, the desktop app and a browser front end
## all narrow the catalogue through the same rules.

import std/[options, strutils, tables]

import models, normalize

type
  Filter* = object
    runtime*: Option[RuntimeKind] ## `none` accepts every runtime
    maxSize*: Option[int64] ## keeps rows of known size up to this many bytes
    minSize*: Option[int64] ## keeps rows of known size from this many bytes
    lang*: string ## substring of the language token, empty accepts all
    title*: string ## substring of `titleNorm`, empty accepts all
    tier*: Option[PlayTier] ## minimum playability tier, needs playability data
    antiCheat*: seq[AntiCheat] ## exact statuses to keep, empty accepts all
    genre*: string ## substring of a store genre, empty accepts all
    tag*: string ## substring of a SteamSpy tag, empty accepts all
    steamos*: Option[LinuxVerdict] ## exact verdict for desktop Linux
    deck*: Option[LinuxVerdict] ## exact verdict for the handheld
    linuxBuildOnly*: bool ## keep only games Steam ships a Linux build for
    appidOnly*: bool ## keep only rows that name a Steam appid
    noAppid*: bool ## keep only rows that name none
    limit*: Option[int] ## `none` keeps every match

func initFilter*(): Filter =
  ## Builds the filter that keeps every game, in table order.
  Filter()

func initFilter*(runtime: RuntimeKind): Filter =
  ## Builds a filter for one runtime, which is the common case.
  Filter(runtime: some(runtime))

func matches*(release: Release; filter: Filter;
              play = none(Playability);
              store = SteamFacts()): bool =
  ## True when `release` is a game that every condition the filter set accepts.
  ##
  ## A size bound rejects rows whose size is unknown, because claiming they fit
  ## would be a guess.
  ##
  ## A tier bound rejects rows with no playability data, and the worst tiers
  ## sort below the usable ones, so an unknown tier fails the bound instead of
  ## sneaking past it. `antiCheat` is a set rather than a bound because the
  ## statuses name states, not a scale: `broken` is not "less than" `running`,
  ## it is simply a different answer, and asking for `broken,denied` is a
  ## different question from asking for `running,supported`.
  ##
  ## The limit is not consulted here; see `applyFilter`.
  if not release.isGame:
    return false
  if filter.runtime.isSome and release.runtime != filter.runtime.get:
    return false
  if filter.maxSize.isSome:
    if release.sizeBytes.isNone or release.sizeBytes.get > filter.maxSize.get:
      return false
  if filter.minSize.isSome:
    if release.sizeBytes.isNone or release.sizeBytes.get < filter.minSize.get:
      return false
  if filter.lang.len > 0:
    if release.langToken.isNone or release.langToken.get.find(filter.lang) < 0:
      return false
  if filter.title.len > 0 and release.titleNorm.find(filter.title) < 0:
    return false
  if filter.tier.isSome:
    if play.isNone or play.get.tier.isNone:
      return false
    if play.get.tier.get.value < filter.tier.get:
      return false
  if filter.antiCheat.len > 0:
    if play.isNone or play.get.antiCheat.isNone:
      return false
    if play.get.antiCheat.get.value notin filter.antiCheat:
      return false
  if filter.genre.len > 0 or filter.tag.len > 0 or filter.linuxBuildOnly or
     filter.steamos.isSome or filter.deck.isSome:
    # Store conditions need store data, and a game Steam has no entry for
    # cannot satisfy them: an unfiltered run still lists it.
    if not store.isKnown:
      return false
  if filter.genre.len > 0:
    var found = false
    for genre in store.genres:
      if genre.toLowerAscii.contains(filter.genre.toLowerAscii):
        found = true
    if not found:
      return false
  if filter.tag.len > 0:
    var found = false
    if store.tags.isSome:
      for tag in store.tags.get.value:
        if tag.name.toLowerAscii.contains(filter.tag.toLowerAscii):
          found = true
    if not found:
      return false
  if filter.linuxBuildOnly:
    if store.linuxBuild.isNone or not store.linuxBuild.get.value:
      return false
  if filter.steamos.isSome:
    if store.steamos.isNone or store.steamos.get.value != filter.steamos.get:
      return false
  if filter.deck.isSome:
    if store.deck.isNone or store.deck.get.value != filter.deck.get:
      return false
  if filter.appidOnly and release.appid.isNone:
    return false
  if filter.noAppid and release.appid.isSome:
    return false
  result = true

func playabilityOf*(play: Table[int, Playability];
                    release: Release): Option[Playability] =
  ## Looks up the playability facts of one release, if it has an app id and
  ## anything is known about it.
  if release.appid.isSome and play.hasKey(release.appid.get):
    result = some play[release.appid.get]

func storeFactsOf*(stores: Table[int, SteamFacts];
                   release: Release): SteamFacts =
  ## Looks up the store facts of one release, or an empty record.
  if release.appid.isSome and stores.hasKey(release.appid.get):
    result = stores[release.appid.get]

func countMatches*(releases: openArray[Release]; filter: Filter;
                   play: Table[int, Playability] = initTable[int, Playability]();
                   stores: Table[int, SteamFacts] = initTable[int, SteamFacts]()): int =
  ## Counts matching games, ignoring `filter.limit`.
  for release in releases:
    if matches(release, filter, playabilityOf(play, release),
               storeFactsOf(stores, release)):
      inc result

func applyFilter*(releases: openArray[Release]; filter: Filter;
                  play: Table[int, Playability] = initTable[int, Playability]();
                  stores: Table[int, SteamFacts] = initTable[int, SteamFacts]()):
                  seq[Release] =
  ## Keeps matching games in input order, honoring `filter.limit`.
  var taken = 0
  for release in releases:
    if matches(release, filter, playabilityOf(play, release),
               storeFactsOf(stores, release)):
      if filter.limit.isSome and taken >= filter.limit.get:
        return result
      inc taken
      result.add(release)

func filterByTitle*(releases: openArray[Release]; text: string): seq[Release] =
  ## Convenience for the common "find this game" query.
  applyFilter(releases, Filter(title: normalizeTitle(text)))
