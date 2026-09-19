## The taste profile: what you thought of games, and the tag vector that implies.
##
## A rating is a decision, and a decision is the only thing a picker needs to
## exclude a game: once you have said "bounced", proposing it again is noise. The
## same ratings also build a weighted tag profile, which is how "more like the
## ones I loved" becomes a number.
##
## The profile is a Rocchio-style centroid over tags:
##
## 1. Each rated game's tags are scaled to unit length, so a game carrying
##    twenty tags does not outweigh one carrying three.
## 2. Loved games add their vector, bounced games subtract theirs.
## 3. The sum is scaled to unit length, so `cosine` is a plain dot product.
##
## Ratings whose game has no tags are not ignored: they still gate, they just
## contribute nothing to the profile.
##
## The profile is `Table[string, float]` rather than `seq[Tag]` on purpose.
## `Tag.votes` is an integer because that is what SteamSpy sends; a computed
## weight is not a vote count and should not pretend to be one.
##
## This module is pure. Persistence is a string in, string out.

import std/[algorithm, math, options, tables]

import models

type
  Verdict* = enum
    ## What you decided about a game.
    vLoved = "loved" ## you would play it again
    vPlayed = "played" ## you played it, no strong feeling
    vFinished = "finished" ## done with it
    vBounced = "bounced" ## you gave up and would not go back
    vSkipped = "skipped" ## you looked and passed
    vLater = "later" ## not now, but keep it in the running

  Rating* = object
    appid*: int
    title*: string ## kept so the file reads without the catalogue
    verdict*: Verdict
    ratedAt*: int64 ## unix seconds

  Taste* = object
    ratings*: seq[Rating]

  Profile* = Table[string, float]
    ## A unit-length tag vector: the shape of what you like.

const Decided* = {vLoved, vPlayed, vFinished, vBounced, vSkipped}
  ## Verdicts meaning "this has been considered", so a picker should not propose
  ## it again. `vLater` is deliberately not one of them.

func verdictOf*(taste: Taste; appid: int): Option[Verdict] =
  ## The verdict for one game, if any.
  for rating in taste.ratings:
    if rating.appid == appid:
      return some rating.verdict

func isDecided*(taste: Taste; appid: int): bool =
  ## True when this game has already been judged, and so is not a candidate.
  let verdict = verdictOf(taste, appid)
  verdict.isSome and verdict.get in Decided

func rate*(taste: var Taste; appid: int; title: string; verdict: Verdict;
           ratedAt: int64) =
  ## Records a verdict, replacing any earlier one for the same game.
  for index in 0..<taste.ratings.len:
    if taste.ratings[index].appid == appid:
      taste.ratings[index] = Rating(appid: appid, title: title,
                                    verdict: verdict, ratedAt: ratedAt)
      return
  taste.ratings.add Rating(appid: appid, title: title, verdict: verdict,
                           ratedAt: ratedAt)

func unrate*(taste: var Taste; appid: int): bool =
  ## Forgets one game, returning true when there was something to forget.
  for index in 0..<taste.ratings.len:
    if taste.ratings[index].appid == appid:
      taste.ratings.delete(index)
      return true

func sortedRatings*(taste: Taste): seq[Rating] =
  ## The ratings by app id, so the file is stable across runs.
  result = taste.ratings
  result.sort(proc (a, b: Rating): int = cmp(a.appid, b.appid))

func unitVector*(tags: openArray[Tag]): Profile =
  ## Scales one game's tags to unit length, so it contributes a direction rather
  ## than a magnitude.
  var magnitude = 0.0
  for tag in tags:
    magnitude += float(tag.votes) * float(tag.votes)
  if magnitude <= 0.0:
    return initTable[string, float]()
  let scale = 1.0 / sqrt(magnitude)
  for tag in tags:
    result[tag.name] = float(tag.votes) * scale

func unitProfile*(profile: Profile): Profile =
  ## Scales a profile to unit length, which is what makes `cosine` a dot product.
  var magnitude = 0.0
  for _, weight in profile:
    magnitude += weight * weight
  if magnitude <= 0.0:
    return initTable[string, float]()
  let scale = 1.0 / sqrt(magnitude)
  for name, weight in profile:
    result[name] = weight * scale

func buildProfile*(taste: Taste; tags: Table[int, seq[Tag]]): Profile =
  ## Builds the profile from the ratings and the tags of the games they name.
  ##
  ## Loved games pull towards their tags and bounced games push away from theirs.
  ## Every other verdict is a decision about the game, not about taste.
  var accumulated = initTable[string, float]()
  for rating in taste.ratings:
    if rating.verdict in {vLoved, vBounced} and tags.hasKey(rating.appid):
      let direction = if rating.verdict == vLoved: 1.0 else: -1.0
      for name, weight in unitVector(tags[rating.appid]):
        accumulated[name] = accumulated.getOrDefault(name) + direction * weight
  result = unitProfile(accumulated)

func cosine*(profile: Profile; gameTags: openArray[Tag]): Option[float] =
  ## Similarity between the profile and one game's tags.
  ##
  ## Both sides are scaled to unit length, so the result is a dot product in
  ## `-1..1`. It is `none` when either side has no tags, because "no tags" is not
  ## the same as "no similarity".
  if profile.len == 0 or gameTags.len == 0:
    return none(float)
  let game = unitVector(gameTags)
  if game.len == 0:
    return none(float)
  var dot = 0.0
  for name, weight in profile:
    dot += weight * game.getOrDefault(name, 0.0)
  some dot

func topProfileTags*(profile: Profile; limit: int): seq[string] =
  ## The strongest positive tags, which is the profile in words: "you like
  ## Strategy, Puzzle, Relaxing".
  var positive: seq[Tag] = @[]
  for name, weight in profile:
    if weight > 0.0:
      positive.add Tag(name: name, votes: int(weight * 1000000.0))
  positive.sort(proc (a, b: Tag): int = cmp(b.votes, a.votes))
  for tag in positive:
    if result.len >= limit:
      break
    result.add tag.name

func dislikes*(profile: Profile; limit: int): seq[string] =
  ## The strongest negative tags, which is the other half of a profile and the
  ## half a list of likes cannot show.
  var negative: seq[Tag] = @[]
  for name, weight in profile:
    if weight < 0.0:
      negative.add Tag(name: name, votes: int(-weight * 1000000.0))
  negative.sort(proc (a, b: Tag): int = cmp(b.votes, a.votes))
  for tag in negative:
    if result.len >= limit:
      break
    result.add tag.name
