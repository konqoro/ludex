## Decoding of the AreWeAntiCheatYet dataset.
##
## The project ships one JSON array covering every game it tracks, served
## straight from its repository:
##
## .. code-block:: json
##
##   [{"name":"Halo: The Master Chief Collection","native":false,
##     "status":"Supported","anticheats":["Easy Anti-Cheat"],
##     "storeIds":{"steam":"976730"},
##     "notes":[["...","https://..."]],
##     "updates":[{"name":"...","date":"...","reference":"..."}],
##     "dateChanged":"2024-01-19T04:40:56.000Z"}]
##
## Only the fields this catalogue uses are modelled. `notes`, `updates`, `logo`
## and `reference` are skipped by the decoder rather than carried around: they
## are prose for a human reading the website, not facts for a recommender.
##
## `storeIds` mixes shapes, `{"steam":"976730"}` beside a nested `epic` object,
## so the Steam id is captured as `RawJson` and interpreted here. That keeps a
## string-versus-number change upstream from failing the whole dataset.
##
## This module is pure: it turns a response body into facts and does no I/O.

import std/[options, strutils, tables]

import brian

import ../models

const GamesUrl* =
  "https://raw.githubusercontent.com/AreWeAntiCheatYet/AreWeAntiCheatYet/master/games.json"

type
  StoreIds* = object
    ## Store identifiers, of which only Steam interests us.
    steam*: RawJson

  Entry* = object
    ## One tracked game. Field names match the dataset, so `brian` maps them.
    name*: string
    status*: string
    native*: bool ## the dataset's own native-Linux flag
    anticheats*: seq[string]
    storeIds*: StoreIds

  Dataset* = seq[Entry]

func parseAntiCheat*(status: string): AntiCheat =
  ## Maps a status from the dataset or from a command line.
  ##
  ## The dataset capitalizes the same five words the enum uses, so one
  ## case-folded comparison covers both. Anything else becomes `acUnknown`
  ## rather than an error, because a new word from upstream should not fail a
  ## whole run.
  let folded = status.toLowerAscii
  for status in AntiCheat:
    if $status == folded:
      return status
  acUnknown

func decodeDataset*(body: string): Dataset =
  ## Decodes the whole dataset.
  ##
  ## Raises `JsonParsingError` when the body is malformed or a modelled field
  ## has an unexpected type.
  fromJson(body, Dataset)

func appIdOf*(entry: Entry): Option[int] =
  ## The Steam app id of one entry, when it has one.
  ##
  ## The captured value may arrive quoted or bare, so both are accepted, and the
  ## digits are accumulated by hand so a corrupt value is a `none` rather than
  ## an exception.
  # `RawJson` is a distinct string with no `$` in this version of brian, so
  # the captured bytes are taken through an explicit conversion.
  let text = string(entry.storeIds.steam).strip(chars = {'"', ' ', '\t'})
  if text.len == 0 or text.len > 9:
    return none(int)
  var value = 0
  for ch in text:
    if ch notin {'0'..'9'}:
      return none(int)
    value = value * 10 + (ord(ch) - ord('0'))
  some(value)

func toPlayability*(entry: Entry; fetchedAt: int64): Playability =
  ## Turns one entry into facts stamped with their source.
  result.antiCheat = some initFact(parseAntiCheat(entry.status),
                                   srcAntiCheatYet, fetchedAt)
  if entry.anticheats.len > 0:
    result.antiCheatNames = some entry.anticheats
  result.nativeBuild = some initFact(entry.native, srcAntiCheatYet, fetchedAt)

func worseStatus*(a, b: AntiCheat): AntiCheat =
  ## Resolves two verdicts for the same game.
  ##
  ## An unknown verdict carries no information, so a definite one wins. Between
  ## two definite verdicts the lower-quality one wins, because telling a player
  ## that a blocked game runs is the one error this catalogue must not make.
  if a == acUnknown: b
  elif b == acUnknown: a
  elif a <= b: a
  else: b

func mergeEntries*(a, b: Playability): Playability =
  ## Combines two entries that claim the same Steam app id.
  ##
  ## The dataset has five such pairs, some of which disagree, so the outcome
  ## cannot be left to iteration order. Both anti-cheat names are kept.
  result = a
  result.antiCheat = some initFact(worseStatus(a.antiCheat.get.value,
                                               b.antiCheat.get.value),
                                   srcAntiCheatYet,
                                   a.antiCheat.get.fetchedAt)
  if a.antiCheatNames.isSome and b.antiCheatNames.isSome:
    var names = a.antiCheatNames.get
    for name in b.antiCheatNames.get:
      if name notin names:
        names.add name
    result.antiCheatNames = some names
  elif b.antiCheatNames.isSome:
    result.antiCheatNames = b.antiCheatNames
  if a.nativeBuild.isSome and b.nativeBuild.isSome:
    result.nativeBuild = some initFact(a.nativeBuild.get.value and
                                       b.nativeBuild.get.value,
                                       srcAntiCheatYet,
                                       a.nativeBuild.get.fetchedAt)

func indexByAppId*(dataset: Dataset; fetchedAt: int64):
                   Table[int, Playability] =
  ## Indexes the dataset by Steam app id, skipping entries without one.
  ##
  ## Entries that name no Steam app id are skipped rather than guessed at:
  ## matching those by title belongs with the rest of the catalogue's
  ## resolution, in phase 2.
  for entry in dataset:
    let appid = appIdOf(entry)
    if appid.isSome:
      let fresh = toPlayability(entry, fetchedAt)
      if result.hasKey(appid.get):
        result[appid.get] = mergeEntries(result[appid.get], fresh)
      else:
        result[appid.get] = fresh
