## Decoding of Steam's store `appdetails` endpoint.
##
## One call answers for one app id, and the answer is an object *keyed by that
## app id* rather than an object with an app id field:
##
## .. code-block:: json
##
##   {"1999520":{"success":true,"data":{"type":"game","name":"CATO: Buttered Cat",
##    "platforms":{"windows":true,"mac":true,"linux":true},
##    "genres":[{"id":"25","description":"Adventure"}],
##    "categories":[{"id":2,"description":"Single-player"}],
##    "price_overview":{"currency":"USD","initial":1099,"final":1099,
##                      "discount_percent":0},
##    "release_date":{"coming_soon":false,"date":"Sep 5, 2024"},
##    "recommendations":{"total":2795},"developers":["Team Woll"]}}}
##
## Three shapes the API uses that a model has to respect:
##
## - `success: false` answers with no `data` key at all, so absence, not a null,
##   is how "no such app" is reported.
## - `genres[].id` is a string while `categories[].id` is a number, in the same
##   payload. Both are modelled as the API sends them.
## - The payload is `snake_case` throughout (`price_overview`, `is_free`,
##   `release_date`) while Nim fields are camelCase, and `type` is a keyword.
##   Every reader below is therefore explicit about the wire name. Leaving this
##   to field-name matching silently yields an empty record, which is worse than
##   an error: the run reports success and stores nothing.
##
## The endpoint sends 20-40 KB per app, and most of it is store prose this
## catalogue never reads. Those fields are skipped rather than modelled; the
## tests assert the values that are read, not the shape of the whole payload.
##
## The pictures are the exception to that rule, and a deliberate one:
## `header_image` and `screenshots[].path_thumbnail` / `path_full` are read
## because whether a game *looks* interesting is part of the question this
## catalogue answers. Only the URLs are stored, never the bytes, so the JSONL
## stays small and diffable and the images stay a cache the CLI fills.
##
## This module is pure: it turns a response body into facts and does no I/O.

import std/options

import brian

import ../models

const
  DetailsPrefix* = "https://store.steampowered.com/api/appdetails?appids="
  ## The `l=en` language is fixed: English names are what the listing uses, so
  ## matching the two stays meaningful. The country only moves prices.
  DetailsSuffix* = "&l=en"

type
  Genre* = object
    id*: string ## a string here
    description*: string

  Category* = object
    id*: int ## and a number here
    description*: string

  Platforms* = object
    windows*: bool
    mac*: bool
    linux*: bool

  PriceOverview* = object
    currency*: string
    initial*: int
    final*: int
    discountPercent*: int

  ReleaseDate* = object
    comingSoon*: bool
    date*: string

  Recommendations* = object
    total*: int

  StoreScreenshot* = object
    ## One entry of the `screenshots` array. The wire type stays separate from
    ## `models.Screenshot`, which has its own reader in the store: one type with
    ## two readers is ambiguous where `brian` resolves `mixin`.
    pathThumbnail*: string ## `path_thumbnail`, 600x338
    pathFull*: string ## `path_full`, 1920x1080

  Metacritic* = object
    ## The press aggregate the store republishes, when it has one.
    score*: int
    url*: string

  App* = object
    ## The subset of a store entry this catalogue keeps.
    kind*: string ## `type` in the payload
    name*: string
    steamAppid*: int
    isFree*: bool
    developers*: seq[string]
    publishers*: seq[string]
    genres*: seq[Genre]
    categories*: seq[Category]
    platforms*: Platforms
    releaseDate*: ReleaseDate
    priceOverview*: Option[PriceOverview]
    recommendations*: Option[Recommendations]
    shortDescription*: string ## `short_description`, the one-line pitch
    backgroundRaw*: string ## `background_raw`, the store page's wide art
    metacritic*: Option[Metacritic]
    headerImage*: string ## `header_image`, 460x215
    screenshots*: seq[StoreScreenshot] ## in the store's own order

  Envelope* = object
    ## One app id and the answer for it.
    key*: string ## the object key, which is the app id
    success*: bool
    data*: Option[App]

  Envelopes* = seq[Envelope]

const
  KeySuccess = "success"
  KeyData = "data"
  KeyType = "type"
  KeyName = "name"
  KeySteamAppId = "steam_appid"
  KeyIsFree = "is_free"
  KeyDevelopers = "developers"
  KeyPublishers = "publishers"
  KeyGenres = "genres"
  KeyCategories = "categories"
  KeyId = "id"
  KeyDescription = "description"
  KeyPlatforms = "platforms"
  KeyWindows = "windows"
  KeyMac = "mac"
  KeyLinux = "linux"
  KeyReleaseDate = "release_date"
  KeyComingSoon = "coming_soon"
  KeyDate = "date"
  KeyPriceOverview = "price_overview"
  KeyCurrency = "currency"
  KeyInitial = "initial"
  KeyFinal = "final"
  KeyDiscountPercent = "discount_percent"
  KeyRecommendations = "recommendations"
  KeyTotal = "total"
  KeyShortDescription = "short_description"
  KeyBackgroundRaw = "background_raw"
  KeyMetacritic = "metacritic"
  KeyScore = "score"
  KeyUrl = "url"
  KeyHeaderImage = "header_image"
  KeyScreenshots = "screenshots"
  KeyPathThumbnail = "path_thumbnail"
  KeyPathFull = "path_full"

proc readJson*(dst: var Genre; r: var JsonReader; options: JsonReadOptions) =
  ## `genres[].id` arrives as a string.
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyId:
      readJson(dst.id, r, options)
    elif field == KeyDescription:
      readJson(dst.description, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known genre field, got \"" & field.toString() & "\"")
    else:
      r.skipValue()

proc readJson*(dst: var Category; r: var JsonReader;
               options: JsonReadOptions) =
  ## `categories[].id` arrives as a number, in the same payload as `genres`.
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyId:
      readJson(dst.id, r, options)
    elif field == KeyDescription:
      readJson(dst.description, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known category field, got \"" & field.toString() & "\"")
    else:
      r.skipValue()

proc readJson*(dst: var Platforms; r: var JsonReader;
               options: JsonReadOptions) =
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyWindows:
      readJson(dst.windows, r, options)
    elif field == KeyMac:
      readJson(dst.mac, r, options)
    elif field == KeyLinux:
      readJson(dst.linux, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known platform field, got \"" & field.toString() & "\"")
    else:
      r.skipValue()

proc readJson*(dst: var ReleaseDate; r: var JsonReader;
               options: JsonReadOptions) =
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyComingSoon:
      readJson(dst.comingSoon, r, options)
    elif field == KeyDate:
      readJson(dst.date, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known release field, got \"" & field.toString() & "\"")
    else:
      r.skipValue()

proc readJson*(dst: var PriceOverview; r: var JsonReader;
               options: JsonReadOptions) =
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyCurrency:
      readJson(dst.currency, r, options)
    elif field == KeyInitial:
      readJson(dst.initial, r, options)
    elif field == KeyFinal:
      readJson(dst.final, r, options)
    elif field == KeyDiscountPercent:
      readJson(dst.discountPercent, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known price field, got \"" & field.toString() & "\"")
    else:
      r.skipValue()

proc readJson*(dst: var Recommendations; r: var JsonReader;
               options: JsonReadOptions) =
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyTotal:
      readJson(dst.total, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known recommendation field, got \"" &
        field.toString() & "\"")
    else:
      r.skipValue()

proc readJson*(dst: var StoreScreenshot; r: var JsonReader;
               options: JsonReadOptions) =
  ## A screenshot also carries an `id`, which is not read: it is a position in
  ## the array, not a fact about the game.
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyPathThumbnail:
      readJson(dst.pathThumbnail, r, options)
    elif field == KeyPathFull:
      readJson(dst.pathFull, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known screenshot field, got \"" &
        field.toString() & "\"")
    else:
      r.skipValue()

proc readJson*(dst: var Metacritic; r: var JsonReader; options: JsonReadOptions) =
  ## Only the score and where it came from are kept; the store sends more.
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyScore:
      readJson(dst.score, r, options)
    elif field == KeyUrl:
      readJson(dst.url, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known metacritic field, got \"" &
        field.toString() & "\"")
    else:
      r.skipValue()

proc readJson*(dst: var App; r: var JsonReader; options: JsonReadOptions) =
  ## Maps one store entry. The wire names differ from the Nim names, so every
  ## field is named here rather than inferred.
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyType:
      readJson(dst.kind, r, options)
    elif field == KeyName:
      readJson(dst.name, r, options)
    elif field == KeySteamAppId:
      readJson(dst.steamAppid, r, options)
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
    elif field == KeyPlatforms:
      readJson(dst.platforms, r, options)
    elif field == KeyReleaseDate:
      readJson(dst.releaseDate, r, options)
    elif field == KeyPriceOverview:
      readJson(dst.priceOverview, r, options)
    elif field == KeyRecommendations:
      readJson(dst.recommendations, r, options)
    elif field == KeyShortDescription:
      readJson(dst.shortDescription, r, options)
    elif field == KeyBackgroundRaw:
      readJson(dst.backgroundRaw, r, options)
    elif field == KeyMetacritic:
      readJson(dst.metacritic, r, options)
    elif field == KeyHeaderImage:
      readJson(dst.headerImage, r, options)
    elif field == KeyScreenshots:
      readJson(dst.screenshots, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known store field, got \"" & field.toString() & "\"")
    else:
      r.skipValue()

proc readJson*(dst: var Envelope; r: var JsonReader; options: JsonReadOptions) =
  ## Maps the `success` and `data` fields of one app answer.
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeySuccess:
      readJson(dst.success, r, options)
    elif field == KeyData:
      readJson(dst.data, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known envelope field, got \"" & field.toString() & "\"")
    else:
      r.skipValue()

proc readJson*(dst: var Envelopes; r: var JsonReader;
               options: JsonReadOptions) =
  ## `appdetails` keys its answer by app id, and `brian` has no table support in
  ## the pinned version, so the key is captured as a value here. That also makes
  ## a mismatched key visible to the caller instead of silently ignored.
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    var envelope = Envelope(key: field.toString())
    readJson(envelope, r, options)
    dst.add envelope

func decodeApp*(body: string; appid: int): Option[App] =
  ## The store entry for `appid`, or `none` when Steam reports no data for it.
  ##
  ## Raises `JsonParsingError` when the body is malformed or a modelled field has
  ## an unexpected type.
  for envelope in fromJson(body, Envelopes):
    if envelope.key == $appid and envelope.success and envelope.data.isSome:
      return envelope.data

func toSteamFacts*(app: App; fetchedAt: int64): SteamFacts =
  ## Turns a store entry into facts stamped with their source.
  result.kind = app.kind
  result.isFree = app.isFree
  result.developers = app.developers
  result.publishers = app.publishers
  for genre in app.genres:
    result.genres.add genre.description
  for category in app.categories:
    result.categories.add category.description
  result.shortDescription = app.shortDescription
  result.linuxBuild = some initFact(app.platforms.linux, srcSteam, fetchedAt)
  if app.releaseDate.date.len > 0:
    result.releaseDate = some initFact(app.releaseDate.date, srcSteam, fetchedAt)
  if app.priceOverview.isSome:
    let price = app.priceOverview.get
    result.price = some initFact(
      Price(currency: price.currency, initial: price.initial, final: price.final,
            discountPercent: price.discountPercent),
      srcSteam, fetchedAt)
  if app.recommendations.isSome:
    result.recommendations = some initFact(app.recommendations.get.total,
                                           srcSteam, fetchedAt)
  if app.metacritic.isSome:
    let critics = app.metacritic.get
    if critics.score > 0:
      result.critics = some Critics(
        score: initFact(critics.score, srcSteam, fetchedAt),
        url: if critics.url.len > 0: some critics.url else: none(string))
  if app.headerImage.len > 0:
    result.art.header = some initFact(app.headerImage, srcSteam, fetchedAt)
  if app.backgroundRaw.len > 0:
    result.art.background = some initFact(app.backgroundRaw, srcSteam, fetchedAt)
  if app.screenshots.len > 0:
    var shots: seq[Screenshot]
    for shot in app.screenshots:
      if shot.pathThumbnail.len > 0 or shot.pathFull.len > 0:
        shots.add Screenshot(thumbnail: shot.pathThumbnail,
                             full: shot.pathFull)
    if shots.len > 0:
      result.art.screenshots = some initFact(shots, srcSteam, fetchedAt)

func detailsUrl*(appid: int; country: string): string =
  ## The store detail URL for one app id in one country.
  DetailsPrefix & $appid & "&cc=" & country & DetailsSuffix
