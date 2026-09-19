## Core data types for ludex.
##
## This module is pure and must stay compilable to both C and JavaScript: no
## `std/os`, no threads, no FFI. Everything here is plain value data.

import std/[math, options]

type
  RuntimeKind* = enum
    rkUnknown = "unknown" ## the row carries no `GNU/Linux` token
    rkNative = "native"   ## ships a real Linux build
    rkWine = "wine"       ## Windows build running under Wine or Proton
    rkBoth = "both"       ## ships both, as in `GNU/Linux Native/Wine`

  RowKind* = enum
    rkHeader = "header"       ## table header, or a line that is not a row
    rkSeparator = "separator" ## the stray `------` row
    rkGame = "game"           ## a catalogue entry

  PackKind* = enum
    pkSingle = "single"         ## one game
    pkCollection = "collection" ## a pack nesting several releases

  Release* = object
    rowKind*: RowKind
    lineNumber*: int
    title*: string
    titleNorm*: string ## matching key from `normalize.normalizeTitle`
    pack*: PackKind
    buildId*: Option[string] ## `b15946357`
    version*: Option[string] ## `1.3.8`, when the row states one
    langToken*: Option[string] ## `MULTi6` or `ENG/JPN`, kept verbatim
    langs*: seq[string] ## ISO codes, only for explicit language lists
    runtime*: RuntimeKind
    appid*: Option[int] ## Steam app id, the join key for enrichment
    sizeBytes*: Option[int64] ## unknown for the rows the table marks `0 B`
    infoHash*: Option[string] ## 40 hex characters from the source magnet
    nested*: seq[string] ## releases named inside a collection
    warnings*: seq[string] ## every fallback the parser had to take

  SourceId* = enum ## where a fact came from; add members, never reorder
    srcListing = "listing"
    srcSteam = "steam"
    srcSteamSpy = "steamspy"
    srcProtonDb = "protondb"
    srcAntiCheatYet = "anticheatyet"
    srcPcGamingWiki = "pcgamingwiki"
    srcIgdb = "igdb"
    srcRawg = "rawg"
    srcOpenCritic = "opencritic"
    srcItad = "itad"
    srcHltb = "hltb"
    srcManual = "manual"

  PlayTier* = enum ## ordered worst to best so `tier >= ptGold` reads naturally
    ptUnknown = "unknown" ## no reports, or a tier we do not recognize
    ptBorked = "borked"
    ptBronze = "bronze"
    ptSilver = "silver"
    ptGold = "gold"
    ptPlatinum = "platinum"

  AntiCheat* = enum ## ordered worst to best, for the same reason as `PlayTier`
    acUnknown = "unknown" ## nobody has checked, so assume the worst
    acBroken = "broken" ## the anti-cheat blocks Linux entirely
    acDenied = "denied" ## the vendor refuses to enable Linux support
    acPlanned = "planned" ## support announced but not shipped
    acRunning = "running" ## it runs, but without the vendor's support
    acSupported = "supported" ## the vendor supports the anti-cheat on Linux

  Fact*[T] = object ## an enriched value that remembers where it came from
    value*: T
    source*: SourceId
    fetchedAt*: int64 ## unix seconds
    confidence*: float ## 0..1, so thin evidence stays visible

  Playability* = object ## how a game actually runs, not how it is packaged
    tier*: Option[Fact[PlayTier]]
    tierScore*: Option[Fact[float]] ## ProtonDB score, 0..1
    reportCount*: Option[Fact[int]] ## how many reports that tier rests on
    tierConfidence*: Option[string] ## ProtonDB's own word, e.g. `strong`
    antiCheat*: Option[Fact[AntiCheat]]
    antiCheatNames*: Option[seq[string]] ## a game can carry more than one
    nativeBuild*: Option[Fact[bool]] ## independently reported, not the listing's word

  LinuxVerdict* = enum ## Steam's own Linux verdict, ordered worst first
    lvUnknown = "unknown"
    lvUnsupported = "unsupported"
    lvPlayable = "playable"
    lvVerified = "verified"

  Tag* = object ## one SteamSpy tag and how many players applied it
    name*: string
    votes*: int

  Screenshot* = object ## one store screenshot, in the two sizes Steam serves
    ##
    ## Both URLs are kept rather than one: the thumbnail is what a window can
    ## afford to download and show, and the full size is what a "look closer"
    ## view needs, so choosing between them stays a presentation decision and
    ## not a re-fetch.
    thumbnail*: string ## 600x338
    full*: string ## 1920x1080

  ArtFacts* = object ## the store's pictures for one game
    ##
    ## Screenshots are how a player decides whether a game looks interesting,
    ## which is a question this catalogue is meant to answer, so they are stored
    ## as URLs with provenance like any other fact. The bytes are not stored
    ## here: the JSONL stays small and diffable, and `ludex art` downloads the
    ## images into a directory the UI reads.
    background*: Option[Fact[string]] ## the store page's own wide background art
    header*: Option[Fact[string]] ## 460x215 header image URL, for the list
    screenshots*: Option[Fact[seq[Screenshot]]] ## in the store's own order

  Price* = object ## the store's asking price, in minor units
    currency*: string
    initial*: int ## cents before the discount
    final*: int ## cents now
    discountPercent*: int

  ReviewScore* = object ## what players think of one game, from the store
    percent*: Option[Fact[float]] ## positive share, 0..100
    count*: Option[Fact[int]] ## how many reviews that share rests on
    description*: Option[string] ## the source's own words, e.g. `Very Positive`

  Critics* = object ## what the press thought, when a score exists
    score*: Fact[int] ## 0..100, as the aggregator reports it
    url*: Option[string] ## where the score comes from, for the curious

  SteamFacts* = object ## the store's own view of one game
    kind*: string ## `game`, `dlc`, `demo`
    isFree*: bool
    developers*: seq[string]
    publishers*: seq[string]
    genres*: seq[string]
    categories*: seq[string]
    shortDescription*: string ## the store's one-line pitch
    linuxBuild*: Option[Fact[bool]] ## Steam ships a Linux dep, whatever the listing says
    releaseDate*: Option[Fact[string]]
    price*: Option[Fact[Price]]
    recommendations*: Option[Fact[int]] ## how many players recommend it at all
    reviews*: ReviewScore
    critics*: Option[Critics] ## a press aggregate, absent for most games
    deck*: Option[Fact[LinuxVerdict]] ## Steam's verdict for the handheld
    steamos*: Option[Fact[LinuxVerdict]] ## Steam's verdict for desktop Linux
    tags*: Option[Fact[seq[Tag]]] ## SteamSpy's own vocabulary, by player votes
    owners*: Option[Fact[string]] ## SteamSpy's ownership band, e.g. `200,000 .. 500,000`
    currentPlayers*: Option[Fact[int]] ## SteamSpy's concurrent players when sampled
    averageMinutes*: Option[Fact[int]] ## SteamSpy's mean playtime, often unreported
    art*: ArtFacts ## pictures, which is how a player judges the look of a game

  Enrichment* = object ## everything known about one game beyond the listing
    appid*: int
    play*: Playability ## how it runs
    store*: SteamFacts ## what it is

const
  TierScoreDecimals* = 3 ## ProtonDB scores are aggregates, not measurements
  ReviewPercentDecimals* = 1 ## and a review share is not either

func roundTo*(value: float; decimals: int): float =
  ## Rounds to a fixed number of decimals.
  ##
  ## This is not cosmetic. `brian` 0.1.0's float parser is one unit in the last
  ## place off for values such as `0.3`, `0.6`, `0.7` and even `92.8`, so a
  ## value written and read back is not always the bit it started as. Rounding
  ## to the precision the source actually justifies makes the stored form
  ## canonical: what goes in is what comes out, and a snapshot stays diffable.
  var scale = 1.0
  for _ in 0 ..< decimals:
    scale *= 10.0
  round(value * scale) / scale

func roundTierScore*(value: float): float =
  ## Canonical ProtonDB score, to three decimals.
  roundTo(value, TierScoreDecimals)

func roundReviewPercent*(value: float): float =
  ## Canonical positive-review share, to one decimal.
  roundTo(value, ReviewPercentDecimals)

func initFact*[T](value: T; source: SourceId; fetchedAt: int64;
                  confidence = 1.0): Fact[T] =
  ## Attaches a source and fetch time to an enriched value.
  Fact[T](value: value, source: source, fetchedAt: fetchedAt,
          confidence: confidence)

func initEnrichment*(appid: int): Enrichment =
  ## Creates an empty record for one Steam app id.
  Enrichment(appid: appid)

func isKnown*(facts: SteamFacts): bool =
  ## True when the store said anything at all about this game.
  facts.kind.len > 0 or facts.genres.len > 0 or facts.linuxBuild.isSome or
    facts.price.isSome or facts.reviews.count.isSome or facts.tags.isSome or
    facts.steamos.isSome or facts.art.header.isSome or
    facts.art.screenshots.isSome

func topTags*(tags: openArray[Tag]; limit: int): seq[string] =
  ## The tag names by descending votes, capped at `limit`.
  ##
  ## SteamSpy already sends them in vote order, so this only trims, and a
  ## partial sort would be a lie about ties at the cut.
  for tag in tags:
    if result.len >= limit:
      break
    result.add tag.name

func isKnown*(play: Playability): bool =
  ## True when any playability fact is present.
  play.tier.isSome or play.antiCheat.isSome

func blocksLinux*(status: AntiCheat): bool =
  ## True when an anti-cheat stops the game running on Linux at all.
  ##
  ## `acUnknown` is deliberately not a block: "nobody checked" is a risk to
  ## show the player, not a fact to hide the game behind. Both unusable values
  ## sort below `acRunning`, so a threshold test excludes them on its own.
  status in {acBroken, acDenied}

func usableUnderLinux*(status: AntiCheat): bool =
  ## True when the anti-cheat is known to work on Linux, either with the
  ## vendor's blessing or without it.
  status in {acRunning, acSupported}

func initRelease*(lineNumber: int): Release =
  ## Creates an empty game row; the parser decides the real `RowKind`.
  Release(rowKind: rkGame, pack: pkSingle, lineNumber: lineNumber,
          runtime: rkUnknown)

func isGame*(release: Release): bool =
  ## True when the parsed line held a catalogue entry.
  release.rowKind == rkGame
