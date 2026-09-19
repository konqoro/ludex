## Decoding of Steam's Deck and SteamOS compatibility report.
##
## One call answers for one app id:
##
## .. code-block:: json
##
##   {"success":1,"results":{"appid":1999520,"resolved_category":3,
##    "steamos_resolved_category":2,"machine_resolved_category":3,
##    "frame_resolved_category":null,"resolved_items":[...],"search_id":null}}
##
## Two things this endpoint teaches:
##
## - The category is a small integer: `1` unsupported, `2` playable, `3`
##   verified. Verified is confirmed for `CATO: Buttered Cat`, playable for
##   `Titanfall 2` and `Slipways`, and unsupported for `Destiny 2`, whose only
##   reported item is `UnsupportedAntiCheatConfiguration`, which agrees with the
##   anti-cheat dataset independently.
## - `steamos_resolved_category` is Steam's verdict for **SteamOS**, and SteamOS
##   is Linux with Proton, not a native build. `Slipways` is playable there while
##   its own store entry says `platforms.linux: false`. So this is a first-party
##   desktop-Linux signal and it is a different question from `linuxBuild`.
##
## Every category can be `null`, so each is an `Option[int]` rather than an `int`
## that a null would fail to decode.
##
## This module is pure: it turns a response body into facts and does no I/O.

import std/options

import brian

import ../models

const DeckPrefix* =
  "https://store.steampowered.com/saleaction/ajaxgetdeckappcompatibilityreport?nAppID="

const
  KeySuccess = "success"
  KeyResults = "results"
  KeyAppId = "appid"
  KeyDeckCategory = "resolved_category"
  KeySteamOsCategory = "steamos_resolved_category"

type
  DeckResults* = object
    appid*: int
    deckCategory*: Option[int] ## the handheld verdict
    steamosCategory*: Option[int] ## the desktop Linux verdict

  DeckReport* = object
    success*: int
    results*: Option[DeckResults]

proc readJson*(dst: var DeckResults; r: var JsonReader;
               options: JsonReadOptions) =
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyAppId:
      readJson(dst.appid, r, options)
    elif field == KeyDeckCategory:
      readJson(dst.deckCategory, r, options)
    elif field == KeySteamOsCategory:
      readJson(dst.steamosCategory, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known deck result field, got \"" &
        field.toString() & "\"")
    else:
      r.skipValue()

proc readJson*(dst: var DeckReport; r: var JsonReader;
               options: JsonReadOptions) =
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeySuccess:
      readJson(dst.success, r, options)
    elif field == KeyResults:
      readJson(dst.results, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known deck field, got \"" & field.toString() & "\"")
    else:
      r.skipValue()

func parseLinuxVerdict*(category: int): LinuxVerdict =
  ## Maps Steam's category number.
  ##
  ## Anything outside the known three becomes `lvUnknown` rather than an error,
  ## because a new number from Steam should not fail a whole run.
  case category
  of 1: lvUnsupported
  of 2: lvPlayable
  of 3: lvVerified
  else: lvUnknown

func decodeDeck*(body: string): DeckReport =
  ## Decodes one compatibility report.
  ##
  ## Raises `JsonParsingError` when the body is malformed or a modelled field has
  ## an unexpected type.
  fromJson(body, DeckReport)

func toVerdict*(category: Option[int]; fetchedAt: int64): Option[Fact[LinuxVerdict]] =
  ## Turns a reported category into a fact.
  ##
  ## An absent category means Steam has not looked at this game, which is not the
  ## same as Steam having rejected it, so nothing is stored.
  if category.isNone:
    return none(Fact[LinuxVerdict])
  some initFact(parseLinuxVerdict(category.get), srcSteam, fetchedAt)

func deckUrl*(appid: int): string =
  ## The compatibility report URL for one app id.
  DeckPrefix & $appid
