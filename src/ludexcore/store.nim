## JSONL persistence for parsed releases, encoded with `brian`.
##
## `brian` decodes straight into Nim types and encodes straight into a string
## with no intermediate JSON DOM, so the store states its on-disk format once
## through its own `readJson` and `writeJson` overloads.
##
## One release per line, compact JSON, absent fields omitted:
##
## .. code-block:: json
##
##   {"line":3,"row":"game","title":"Slipways","norm":"slipways","pack":"single",
##    "runtime":"wine","appid":1264280,"build":"b15946357","lang":"MULTi6",
##    "size":130023424,"hash":"cc2c41701cf2eca25f749ff26c0aedfaee1d2e5e"}
##
## Enums are written as their Nim spellings, and reading an unrecognized
## spelling fails that line rather than guessing. Fields holding no value are
## omitted rather than written as `null`, which keeps a snapshot readable and
## diffable: absence is a fact in this catalogue, not a placeholder.
##
## Everything here produces and consumes strings, so the core keeps no file
## system dependency. Reading and writing files belongs to the CLI.

import std/[options, strutils]

import brian

import models

const
  KeyLine = "line"
  KeyRow = "row"
  KeyTitle = "title"
  KeyNorm = "norm"
  KeyPack = "pack"
  KeyRuntime = "runtime"
  KeyAppId = "appid"
  KeyBuild = "build"
  KeyVersion = "version"
  KeyLang = "lang"
  KeyLangs = "langs"
  KeySize = "size"
  KeyHash = "hash"
  KeyNested = "nested"
  KeyWarnings = "warnings"
  KeyTier = "tier"
  KeyTierScore = "tierScore"
  KeyReports = "reports"
  KeyTierConfidence = "tierConfidence"
  KeyAntiCheat = "anticheat"
  KeyAntiCheatNames = "anticheatNames"
  KeyNativeBuild = "nativeBuild"
  KeySteam = "steam"
  KeyKind = "kind"
  KeyIsFree = "isFree"
  KeyDevelopers = "developers"
  KeyPublishers = "publishers"
  KeyGenres = "genres"
  KeyCategories = "categories"
  KeyLinuxBuild = "linuxBuild"
  KeyReleaseDate = "releaseDate"
  KeyPrice = "price"
  KeyRecommendations = "recommendations"
  KeyReviews = "reviews"
  KeyCritics = "critics"
  KeyShortDescription = "summary"
  KeyCurrency = "currency"
  KeyInitial = "initial"
  KeyFinal = "final"
  KeyDiscount = "discountPercent"
  KeyPercent = "percent"
  KeyCount = "count"
  KeyDescription = "description"
  KeyDeck = "deck"
  KeySteamOs = "steamos"
  KeyTags = "tags"
  KeyOwners = "owners"
  KeyCurrentPlayers = "currentPlayers"
  KeyAverageMinutes = "averageMinutes"
  KeyVotes = "votes"
  KeyTagName = "name"
  KeyArt = "art"
  KeyHeader = "header"
  KeyBackground = "background"
  KeyScreenshots = "screenshots"
  KeyThumbnail = "thumb"
  KeyFull = "full"
  KeyScore = "score"
  KeyUrl = "url"

proc readOptions(unknownFields: UnknownFieldPolicy): JsonReadOptions =
  ## Builds reader options, keeping brian's default nesting limit.
  result = defaultJsonReadOptions()
  result.unknownFields = unknownFields

proc writeIfPresent[T](w: var JsonWriter; name: string; value: Option[T]) =
  ## Writes a field only when it holds a value.
  if value.isSome:
    mixin writeJson
    w.writeField(name)
    writeJson(w, value.get)

proc writeIfAny[T](w: var JsonWriter; name: string; value: seq[T]) =
  ## Writes a field only when the sequence is not empty.
  if value.len > 0:
    mixin writeJson
    w.writeField(name)
    writeJson(w, value)

proc writeJson*(w: var JsonWriter; value: Release) =
  ## Writes one release, omitting every field that holds no value.
  w.beginObject()
  w.writeField(KeyLine)
  writeJson(w, value.lineNumber)
  w.writeField(KeyRow)
  writeJson(w, value.rowKind)
  w.writeField(KeyTitle)
  writeJson(w, value.title)
  w.writeField(KeyNorm)
  writeJson(w, value.titleNorm)
  w.writeField(KeyPack)
  writeJson(w, value.pack)
  w.writeField(KeyRuntime)
  writeJson(w, value.runtime)
  writeIfPresent(w, KeyAppId, value.appid)
  writeIfPresent(w, KeyBuild, value.buildId)
  writeIfPresent(w, KeyVersion, value.version)
  writeIfPresent(w, KeyLang, value.langToken)
  writeIfAny(w, KeyLangs, value.langs)
  writeIfPresent(w, KeySize, value.sizeBytes)
  writeIfPresent(w, KeyHash, value.infoHash)
  writeIfAny(w, KeyNested, value.nested)
  writeIfAny(w, KeyWarnings, value.warnings)
  w.endObject()

proc readJson*(dst: var Release; r: var JsonReader; options: JsonReadOptions) =
  ## Reads one release.
  ##
  ## Unknown fields are skipped by default, so a snapshot written by a later
  ## version still loads; ask for `ufReject` to demand the exact shape instead.
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyLine:
      readJson(dst.lineNumber, r, options)
    elif field == KeyRow:
      readJson(dst.rowKind, r, options)
    elif field == KeyTitle:
      readJson(dst.title, r, options)
    elif field == KeyNorm:
      readJson(dst.titleNorm, r, options)
    elif field == KeyPack:
      readJson(dst.pack, r, options)
    elif field == KeyRuntime:
      readJson(dst.runtime, r, options)
    elif field == KeyAppId:
      readJson(dst.appid, r, options)
    elif field == KeyBuild:
      readJson(dst.buildId, r, options)
    elif field == KeyVersion:
      readJson(dst.version, r, options)
    elif field == KeyLang:
      readJson(dst.langToken, r, options)
    elif field == KeyLangs:
      readJson(dst.langs, r, options)
    elif field == KeySize:
      readJson(dst.sizeBytes, r, options)
    elif field == KeyHash:
      readJson(dst.infoHash, r, options)
    elif field == KeyNested:
      readJson(dst.nested, r, options)
    elif field == KeyWarnings:
      readJson(dst.warnings, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known field, got \"" & field.toString() & "\"")
    else:
      r.skipValue()

type
  BatchResult*[T] = object
    ## The outcome of decoding a whole file: what worked, and why the rest did
    ## not.
    items*: seq[T] ## lines that decoded
    failures*: seq[string] ## `<line>: <reason>` for lines that did not

proc decodeLines*[T](content: string; options: JsonReadOptions;
                     invalid: proc (item: T): string {.raises: [].}):
                     BatchResult[T] {.raises: [].} =
  ## Decodes one JSON value per line, asking `invalid` for the reason when a
  ## decoded value cannot be used.
  ##
  ## Every failure a single line can cause is recoverable here, because the
  ## batch records it and moves on. This is the batch boundary for the store.
  var lineNumber = 0
  for line in content.splitLines:
    inc lineNumber
    if line.strip.len > 0:
      var item = default(T)
      var failure = ""
      # `JsonParsingError` is the child, so it is matched first.
      try:
        mixin fromJson
        fromJson(line, item, options)
        failure = invalid(item)
      except JsonParsingError as error:
        failure = error.msg
      except CatchableError as error:
        failure = "cannot decode: " & error.msg
      if failure.len > 0:
        result.failures.add($lineNumber & ": " & failure)
      else:
        result.items.add item

proc releaseProblem(release: Release): string {.raises: [].} =
  ## Header and separator rows legitimately carry no title, and the store
  ## round-trips those too; only a game row has to name itself.
  if release.rowKind == rkGame and release.title.len == 0:
    result = "game row without a title"

proc decodeReleases*(content: string; unknownFields = ufSkip):
                     BatchResult[Release] =
  ## Decodes a whole release store.
  decodeLines(content, readOptions(unknownFields), releaseProblem)

proc encodeReleases*(releases: openArray[Release]): string =
  ## Encodes releases as one compact JSON object per line.
  for release in releases:
    result.add toJson(release)
    result.add '\n'

proc writeJson*(w: var JsonWriter; value: Price) =
  ## Writes a price, omitting a discount of zero.
  w.beginObject()
  w.writeField(KeyCurrency)
  writeJson(w, value.currency)
  w.writeField(KeyInitial)
  writeJson(w, value.initial)
  w.writeField(KeyFinal)
  writeJson(w, value.final)
  if value.discountPercent > 0:
    w.writeField(KeyDiscount)
    writeJson(w, value.discountPercent)
  w.endObject()

proc readJson*(dst: var Price; r: var JsonReader; options: JsonReadOptions) =
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyCurrency:
      readJson(dst.currency, r, options)
    elif field == KeyInitial:
      readJson(dst.initial, r, options)
    elif field == KeyFinal:
      readJson(dst.final, r, options)
    elif field == KeyDiscount:
      readJson(dst.discountPercent, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known price field, got \"" & field.toString() & "\"")
    else:
      r.skipValue()

proc writeJson*(w: var JsonWriter; value: ReviewScore) =
  ## Writes a review score, omitting what nobody has reported.
  w.beginObject()
  writeIfPresent(w, KeyPercent, value.percent)
  writeIfPresent(w, KeyCount, value.count)
  writeIfPresent(w, KeyDescription, value.description)
  w.endObject()

proc readJson*(dst: var ReviewScore; r: var JsonReader; options: JsonReadOptions) =
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyPercent:
      readJson(dst.percent, r, options)
      # Canonicalised on read, so a share that was stored as `92.8` reads back
      # as `92.8` rather than one unit in the last place higher.
      if dst.percent.isSome:
        dst.percent = some initFact(roundReviewPercent(dst.percent.get.value),
                                    dst.percent.get.source,
                                    dst.percent.get.fetchedAt,
                                    dst.percent.get.confidence)
    elif field == KeyCount:
      readJson(dst.count, r, options)
    elif field == KeyDescription:
      readJson(dst.description, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known review score field, got \"" &
        field.toString() & "\"")
    else:
      r.skipValue()

proc writeJson*(w: var JsonWriter; value: Tag) =
  ## Writes one tag and its vote count.
  w.beginObject()
  w.writeField(KeyTagName)
  writeJson(w, value.name)
  w.writeField(KeyVotes)
  writeJson(w, value.votes)
  w.endObject()

proc readJson*(dst: var Tag; r: var JsonReader; options: JsonReadOptions) =
  ## Reads one tag. This is the array element form, which is why the SteamSpy
  ## decoder uses a named wrapper for its object form instead of overloading
  ## `seq[Tag]`.
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyTagName:
      readJson(dst.name, r, options)
    elif field == KeyVotes:
      readJson(dst.votes, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known tag field, got \"" & field.toString() & "\"")
    else:
      r.skipValue()

proc writeJson*(w: var JsonWriter; value: Screenshot) =
  ## Writes one screenshot, omitting a size the store did not send.
  w.beginObject()
  if value.thumbnail.len > 0:
    w.writeField(KeyThumbnail)
    writeJson(w, value.thumbnail)
  if value.full.len > 0:
    w.writeField(KeyFull)
    writeJson(w, value.full)
  w.endObject()

proc readJson*(dst: var Screenshot; r: var JsonReader; options: JsonReadOptions) =
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyThumbnail:
      readJson(dst.thumbnail, r, options)
    elif field == KeyFull:
      readJson(dst.full, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known screenshot field, got \"" &
        field.toString() & "\"")
    else:
      r.skipValue()

proc writeJson*(w: var JsonWriter; value: ArtFacts) =
  ## Writes the art URLs, omitting the pictures this game does not have.
  w.beginObject()
  writeIfPresent(w, KeyBackground, value.background)
  writeIfPresent(w, KeyHeader, value.header)
  writeIfPresent(w, KeyScreenshots, value.screenshots)
  w.endObject()

proc readJson*(dst: var ArtFacts; r: var JsonReader; options: JsonReadOptions) =
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyBackground:
      readJson(dst.background, r, options)
    elif field == KeyHeader:
      readJson(dst.header, r, options)
    elif field == KeyScreenshots:
      readJson(dst.screenshots, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known art field, got \"" & field.toString() & "\"")
    else:
      r.skipValue()

proc writeJson*(w: var JsonWriter; value: Critics) =
  ## Writes a press aggregate. Absence is absence, so nothing is invented.
  w.beginObject()
  w.writeField(KeyScore)
  writeJson(w, value.score)
  writeIfPresent(w, KeyUrl, value.url)
  w.endObject()

proc readJson*(dst: var Critics; r: var JsonReader; options: JsonReadOptions) =
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyScore:
      readJson(dst.score, r, options)
    elif field == KeyUrl:
      readJson(dst.url, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known critics field, got \"" & field.toString() & "\"")
    else:
      r.skipValue()

proc writeJson*(w: var JsonWriter; value: SteamFacts) =
  ## Writes store facts, omitting everything unknown.
  w.beginObject()
  if value.kind.len > 0:
    w.writeField(KeyKind)
    writeJson(w, value.kind)
  if value.isFree:
    w.writeField(KeyIsFree)
    writeJson(w, value.isFree)
  writeIfAny(w, KeyDevelopers, value.developers)
  writeIfAny(w, KeyPublishers, value.publishers)
  writeIfAny(w, KeyGenres, value.genres)
  writeIfAny(w, KeyCategories, value.categories)
  if value.shortDescription.len > 0:
    w.writeField(KeyShortDescription)
    writeJson(w, value.shortDescription)
  writeIfPresent(w, KeyLinuxBuild, value.linuxBuild)
  writeIfPresent(w, KeyReleaseDate, value.releaseDate)
  writeIfPresent(w, KeyPrice, value.price)
  writeIfPresent(w, KeyRecommendations, value.recommendations)
  writeIfPresent(w, KeyCritics, value.critics)
  writeIfPresent(w, KeyDeck, value.deck)
  writeIfPresent(w, KeySteamOs, value.steamos)
  writeIfPresent(w, KeyTags, value.tags)
  writeIfPresent(w, KeyOwners, value.owners)
  writeIfPresent(w, KeyCurrentPlayers, value.currentPlayers)
  writeIfPresent(w, KeyAverageMinutes, value.averageMinutes)
  if value.art.header.isSome or value.art.screenshots.isSome:
    w.writeField(KeyArt)
    writeJson(w, value.art)
  if value.reviews.percent.isSome or value.reviews.count.isSome:
    w.writeField(KeyReviews)
    writeJson(w, value.reviews)
  w.endObject()

proc readJson*(dst: var SteamFacts; r: var JsonReader;
               options: JsonReadOptions) =
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyKind:
      readJson(dst.kind, r, options)
    elif field == KeyIsFree:
      readJson(dst.isFree, r, options)
    elif field == KeyDevelopers:
      readJson(dst.developers, r, options)
    elif field == KeyPublishers:
      readJson(dst.publishers, r, options)
    elif field == KeyGenres:
      readJson(dst.genres, r, options)
    elif field == KeyCategories:
      readJson(dst.categories, r, options)
    elif field == KeyShortDescription:
      readJson(dst.shortDescription, r, options)
    elif field == KeyLinuxBuild:
      readJson(dst.linuxBuild, r, options)
    elif field == KeyReleaseDate:
      readJson(dst.releaseDate, r, options)
    elif field == KeyPrice:
      readJson(dst.price, r, options)
    elif field == KeyRecommendations:
      readJson(dst.recommendations, r, options)
    elif field == KeyCritics:
      readJson(dst.critics, r, options)
    elif field == KeyReviews:
      readJson(dst.reviews, r, options)
    elif field == KeyDeck:
      readJson(dst.deck, r, options)
    elif field == KeySteamOs:
      readJson(dst.steamos, r, options)
    elif field == KeyTags:
      readJson(dst.tags, r, options)
    elif field == KeyOwners:
      readJson(dst.owners, r, options)
    elif field == KeyCurrentPlayers:
      readJson(dst.currentPlayers, r, options)
    elif field == KeyAverageMinutes:
      readJson(dst.averageMinutes, r, options)
    elif field == KeyArt:
      readJson(dst.art, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known store field, got \"" & field.toString() & "\"")
    else:
      r.skipValue()

proc writeJson*(w: var JsonWriter; value: Playability) =
  ## Writes playability facts, omitting what is not known.
  w.beginObject()
  writeIfPresent(w, KeyTier, value.tier)
  writeIfPresent(w, KeyTierScore, value.tierScore)
  writeIfPresent(w, KeyReports, value.reportCount)
  writeIfPresent(w, KeyTierConfidence, value.tierConfidence)
  writeIfPresent(w, KeyAntiCheat, value.antiCheat)
  writeIfPresent(w, KeyAntiCheatNames, value.antiCheatNames)
  writeIfPresent(w, KeyNativeBuild, value.nativeBuild)
  w.endObject()

proc readJson*(dst: var Playability; r: var JsonReader; options: JsonReadOptions) =
  ## Reads playability facts, accepting a subset of the known fields.
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyTier:
      readJson(dst.tier, r, options)
    elif field == KeyTierScore:
      readJson(dst.tierScore, r, options)
    elif field == KeyReports:
      readJson(dst.reportCount, r, options)
    elif field == KeyTierConfidence:
      readJson(dst.tierConfidence, r, options)
    elif field == KeyAntiCheat:
      readJson(dst.antiCheat, r, options)
    elif field == KeyAntiCheatNames:
      readJson(dst.antiCheatNames, r, options)
    elif field == KeyNativeBuild:
      readJson(dst.nativeBuild, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known playability field, got \"" & field.toString() & "\"")
    else:
      r.skipValue()

proc enrichmentProblem(item: Enrichment): string {.raises: [].} =
  ## An enrichment record is addressed by Steam app id, so one without an app
  ## id cannot be joined to anything. A record with no facts at all is not
  ## stored, which is why an envelope check lives here rather than in the
  ## pipeline: it is a property of the file format.
  if item.appid <= 0:
    result = "enrichment without a steam app id"
  elif not item.play.isKnown and not item.store.isKnown:
    result = "enrichment with no facts"

proc decodeEnrichments*(content: string; unknownFields = ufSkip):
                        BatchResult[Enrichment] =
  ## Decodes a whole enrichment store.
  decodeLines(content, readOptions(unknownFields), enrichmentProblem)

proc encodeEnrichments*(items: openArray[Enrichment]): string =
  ## Encodes enrichments as one JSON object per line.
  ##
  ## `Playability` and `Fact[T]` are plain objects of options, enums and
  ## numbers, so `brian` maps all of them without a hand-written field list.
  for item in items:
    result.add toJson(item)
    result.add '\n'
