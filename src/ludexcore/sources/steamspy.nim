## Decoding of SteamSpy's per-app data.
##
## .. code-block:: json
##
##   {"appid":1264280,"name":"Slipways","owners":"200,000 .. 500,000",
##    "average_forever":0,"ccu":10,"price":"1699","discount":"0",
##    "genre":"Strategy","positive":2000,"negative":154,
##    "tags":{"Strategy":145,"Puzzle":140,"Turn-Based Strategy":136}}
##
## What this source is for, and what it is not:
##
## - **Tags are the recommender's feature space.** They are what players say a
##   game *is*, weighted by how many agree, which is far better taste signal than
##   the store's handful of genres. SteamSpy sends at most twenty, already in vote
##   order.
## - **It is a daily snapshot.** SteamSpy refreshes once a day, so there is no
##   point asking twice in one day, and nothing here should be treated as live.
## - **Playtime is sparse.** `average_forever` is `0` for both recorded games,
##   including one with thousands of reviews, so it is a weak length signal and is
##   stored as "absent" rather than as a zero-minute game.
## - **Unused fields are not modelled, because they are the ones that vary.**
##   `price`, `initialprice` and `discount` are `null` for a game with no price,
##   so a `string` field would fail that game's whole record; they are also not
##   used here, since the store's own `price_overview` is the price this
##   catalogue keeps. The identity fields are always present, so they stay plain
##   strings.
##
## This module is pure: it turns a response body into facts and does no I/O.

import std/options

import brian

import ../models

const SpyPrefix* = "https://steamspy.com/api.php?request=appdetails&appid="

const
  KeyName = "name"
  KeyDeveloper = "developer"
  KeyPublisher = "publisher"
  KeyOwners = "owners"
  KeyAverageForever = "average_forever"
  KeyMedianForever = "median_forever"
  KeyCcu = "ccu"
  KeyTags = "tags"

type
  TagVotes* = object
    ## SteamSpy reports tags as an object of tag name to vote count.
    ##
    ## This is a named type rather than a plain `seq[Tag]` on purpose: a custom
    ## `readJson` for `seq[Tag]` would also capture the JSON *array* form the
    ## enrichment store uses for the same type, and reading one as the other
    ## fails in both directions.
    tags*: seq[Tag]

  SpyApp* = object
    name*: string
    developer*: string
    publisher*: string
    owners*: string ## an ownership band, not a number
    averageForever*: int ## mean playtime in minutes, often 0
    medianForever*: int
    ccu*: int ## concurrent players at the last refresh
    tags*: TagVotes

proc readJson*(dst: var TagVotes; r: var JsonReader; options: JsonReadOptions) =
  ## Reads the tags.
  ##
  ## A tagged game sends an object of name to vote count; a game with no tags
  ## sends an empty *array*. Both shapes are accepted, and the order SteamSpy
  ## chose, which is descending by votes, is preserved rather than re-sorted.
  case r.kind
  of jkObject:
    r.beginObject()
    var field: JsonField
    while r.nextField(field):
      var votes = 0
      readJson(votes, r, options)
      dst.tags.add Tag(name: field.toString(), votes: votes)
  of jkArray:
    r.beginArray()
    while r.nextElement():
      r.skipValue()
  else:
    r.raiseExpected("an object of tags or an empty array")

proc readJson*(dst: var SpyApp; r: var JsonReader; options: JsonReadOptions) =
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyName:
      readJson(dst.name, r, options)
    elif field == KeyDeveloper:
      readJson(dst.developer, r, options)
    elif field == KeyPublisher:
      readJson(dst.publisher, r, options)
    elif field == KeyOwners:
      readJson(dst.owners, r, options)
    elif field == KeyAverageForever:
      readJson(dst.averageForever, r, options)
    elif field == KeyMedianForever:
      readJson(dst.medianForever, r, options)
    elif field == KeyCcu:
      readJson(dst.ccu, r, options)
    elif field == KeyTags:
      readJson(dst.tags, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known SteamSpy field, got \"" & field.toString() & "\"")
    else:
      r.skipValue()

func decodeSpyApp*(body: string): SpyApp =
  ## Decodes one SteamSpy record.
  ##
  ## Raises `JsonParsingError` when the body is malformed or a modelled field has
  ## an unexpected type. SteamSpy answers an empty object `{}` for an app it does
  ## not track, which decodes to an empty record rather than failing.
  fromJson(body, SpyApp)

func toSteamFacts*(spy: SpyApp; fetchedAt: int64): SteamFacts =
  ## Turns a SteamSpy record into facts stamped with their source.
  if spy.tags.tags.len > 0:
    result.tags = some initFact(spy.tags.tags, srcSteamSpy, fetchedAt)
  if spy.owners.len > 0:
    result.owners = some initFact(spy.owners, srcSteamSpy, fetchedAt)
  if spy.ccu > 0:
    result.currentPlayers = some initFact(spy.ccu, srcSteamSpy, fetchedAt)
  if spy.averageForever > 0:
    result.averageMinutes = some initFact(spy.averageForever, srcSteamSpy,
                                          fetchedAt)

func tagNames*(spy: SpyApp; limit: int): seq[string] =
  ## The tag names by descending votes, capped at `limit`.
  spy.tags.tags.topTags(limit)

func spyUrl*(appid: int): string =
  ## The SteamSpy record URL for one app id.
  SpyPrefix & $appid
