## Decoding of ProtonDB compatibility summaries.
##
## The per-appid summary endpoint answers with a small object:
##
## .. code-block:: json
##
##   {"bestReportedTier":"platinum","confidence":"strong","score":0.71,
##    "tier":"platinum","total":31,"trendingTier":"platinum"}
##
## An app id with no reports answers `404` rather than an empty object, so the
## ingest layer reads that as "nothing is known" instead of a failure.
##
## Real responses also contain `tier: "pending"` alongside a
## `provisionalTier`, which is what ProtonDB says when the reports are too thin
## to call. `pending` maps to `ptUnknown`, and the provisional guess is decoded
## but deliberately not promoted into a fact: a provisional tier backed by
## three reports would be a claim this catalogue cannot support.
##
## This module is pure: it turns a response body into facts and does no I/O.

import std/options

import brian

import ../models

type
  Summary* = object
    ## The endpoint's own shape. `brian` maps fields by name, so this type is
    ## the whole decoder.
    tier*: string ## current tier, or `pending` when reports are too thin
    bestReportedTier*: string ## best tier ever reported
    trendingTier*: string ## recent reports only
    provisionalTier*: string ## a guess while `tier` is still `pending`
    confidence*: string ## `strong`, `good`, or absent
    score*: float ## 0..1
    total*: int ## number of reports behind the tier

func parsePlayTier*(name: string): PlayTier =
  ## Maps a ProtonDB tier name.
  ##
  ## An unrecognized name becomes `ptUnknown` rather than an error: the
  ## vocabulary belongs to ProtonDB, and a new word from them should not fail a
  ## whole ingest run.
  for tier in PlayTier:
    if $tier == name:
      return tier
  ptUnknown

func decodeSummary*(body: string): Summary =
  ## Decodes one summary response.
  ##
  ## Raises `JsonParsingError` when the body is malformed or a field has the
  ## wrong type.
  fromJson(body, Summary)

func toPlayability*(summary: Summary; fetchedAt: int64): Playability =
  ## Turns a summary into playability facts stamped with their source.
  ##
  ## A summary with no reports yields no facts at all, rather than a tier of
  ## `unknown` pretending to be data.
  if summary.total <= 0:
    return
  result.tier = some initFact(parsePlayTier(summary.tier), srcProtonDb, fetchedAt)
  # Rounded because the stored value is a coarse aggregate, and because
  # `0.7000000000000001` in a diff is noise, not precision.
  result.tierScore = some initFact(roundTierScore(summary.score), srcProtonDb,
                                   fetchedAt)
  result.reportCount = some initFact(summary.total, srcProtonDb, fetchedAt)
  if summary.confidence.len > 0:
    result.tierConfidence = some summary.confidence

func summaryUrl*(appid: int): string =
  ## The summary endpoint for one Steam app id.
  "https://www.protondb.com/api/v1/reports/summaries/" & $appid & ".json"
