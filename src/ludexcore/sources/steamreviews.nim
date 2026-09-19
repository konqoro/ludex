## Decoding of Steam's review summary.
##
## The reviews endpoint returns review bodies by default, but `num_per_page=0`
## asks for the summary alone, which is one small response per game:
##
## .. code-block:: json
##
##   {"success":1,"query_summary":{"num_reviews":0,"review_score":8,
##    "review_score_desc":"Very Positive","total_positive":2144,
##    "total_negative":166,"total_reviews":2310},"reviews":[],"cursor":"*"}
##
## Two details a model has to respect:
##
## - `success` is a *number* here, while `appdetails` reports it as a boolean.
## - `review_score` is Steam's own 0-9 band, and it is not a percentage. The
##   share of positive reviews is what this catalogue stores, computed from
##   `total_positive` and `total_reviews`, with their own word kept for display.
##
## This module is pure: it turns a response body into facts and does no I/O.

import std/options

import brian

import ../models

const
  ReviewsPrefix* = "https://store.steampowered.com/appreviews/"
  ## `num_per_page=0` fetches the summary without any review bodies, and
  ## `language=all` matches Steam's own store-wide score rather than the
  ## English-only one.
  ReviewsSuffix* = "?json=1&num_per_page=0&filter=all&language=all&purchase_type=all"

type
  QuerySummary* = object
    numReviews*: int
    reviewScore*: int ## Steam's 0-9 band, not a percentage
    reviewScoreDesc*: string ## e.g. `Very Positive`
    totalPositive*: int
    totalNegative*: int
    totalReviews*: int

  ReviewResponse* = object
    success*: int ## a number here, a boolean in `appdetails`
    querySummary*: QuerySummary

const
  KeySuccess = "success"
  KeyQuerySummary = "query_summary"
  KeyNumReviews = "num_reviews"
  KeyReviewScore = "review_score"
  KeyReviewScoreDesc = "review_score_desc"
  KeyTotalPositive = "total_positive"
  KeyTotalNegative = "total_negative"
  KeyTotalReviews = "total_reviews"

proc readJson*(dst: var QuerySummary; r: var JsonReader;
               options: JsonReadOptions) =
  ## Maps the summary. The wire names are `snake_case`, so leaving this to
  ## field-name matching would silently produce an empty summary.
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyNumReviews:
      readJson(dst.numReviews, r, options)
    elif field == KeyReviewScore:
      readJson(dst.reviewScore, r, options)
    elif field == KeyReviewScoreDesc:
      readJson(dst.reviewScoreDesc, r, options)
    elif field == KeyTotalPositive:
      readJson(dst.totalPositive, r, options)
    elif field == KeyTotalNegative:
      readJson(dst.totalNegative, r, options)
    elif field == KeyTotalReviews:
      readJson(dst.totalReviews, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known summary field, got \"" & field.toString() & "\"")
    else:
      r.skipValue()

proc readJson*(dst: var ReviewResponse; r: var JsonReader;
               options: JsonReadOptions) =
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeySuccess:
      readJson(dst.success, r, options)
    elif field == KeyQuerySummary:
      readJson(dst.querySummary, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known review field, got \"" & field.toString() & "\"")
    else:
      r.skipValue()

func decodeReviews*(body: string): ReviewResponse =
  ## Decodes one review summary response.
  ##
  ## Raises `JsonParsingError` when the body is malformed or a field has the
  ## wrong type.
  fromJson(body, ReviewResponse)

func positivePercent*(summary: QuerySummary): Option[float] =
  ## The share of positive reviews, 0..100, or `none` when nobody has reviewed
  ## the game yet: a percentage of zero reviews is not zero percent.
  if summary.totalReviews <= 0:
    return none(float)
  some(roundReviewPercent(1000.0 * float(summary.totalPositive) /
                          float(summary.totalReviews) / 10.0))

func toReviewScore*(response: ReviewResponse; fetchedAt: int64): ReviewScore =
  ## Turns a review summary into rating facts stamped with their source.
  ##
  ## A summary with no reviews yields only the count, because an absent score is
  ## not the same as a bad one.
  if response.querySummary.totalReviews <= 0:
    result.count = some initFact(0, srcSteam, fetchedAt)
    return
  result.percent = some initFact(positivePercent(response.querySummary).get,
                                 srcSteam, fetchedAt)
  result.count = some initFact(response.querySummary.totalReviews, srcSteam,
                               fetchedAt)
  if response.querySummary.reviewScoreDesc.len > 0:
    result.description = some response.querySummary.reviewScoreDesc

func reviewsUrl*(appid: int): string =
  ## The review summary URL for one app id.
  ReviewsPrefix & $appid & ReviewsSuffix
