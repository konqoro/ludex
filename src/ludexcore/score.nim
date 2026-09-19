## Ranking the catalogue against what you like and what will actually run.
##
## Two stages, in this order, because they answer different questions:
##
## 1. **Gates** decide whether a game is a candidate at all. A blocked
##    anti-cheat, a `borked` ProtonDB tier, more bytes than the disk has, or a
##    game you have already judged. Gates are named, not silent: a game that is
##    excluded says why, and `--include-blocked` overrides them.
## 2. **Factors** put the survivors in order. Each factor is a number in `0..1`
##    with a weight, and the score is the weighted mean **over the factors that
##    had data**, with the known share reported as `coverage`. A game with two
##    known factors is not scored as if it had six and scored badly.
##
## What this deliberately does not do:
##
## - It does not invent a quality score for a game nobody has reviewed. Missing
##   evidence is reported as missing, and a game with no evidence at all is not
##   ranked, it is listed as unrankable. Filling that gap with a neutral 0.5
##   would put unknown games in the middle of the ranking and look like an
##   opinion.
## - It does not use a length factor it cannot compute. `averageMinutes` is
##   absent for almost every game, so time budgeting is a factor that will report
##   itself as unknown rather than guess.
##
## This module is pure, and `roll` takes an explicit random state so a caller can
## reproduce a result.

import std/[algorithm, math, options, random, strutils, tables]

import models, query, taste

type
  FactorKind* = enum
    ## One dimension of the ranking, each with a weight.
    fkQuality = "quality" ## what players say, smoothed for small samples
    fkFit = "fit" ## how close it is to the tags you like
    fkRun = "run" ## how well it is known to run on Linux
    fkPrice = "price" ## what it costs you
    fkPopularity = "popularity" ## whether anyone is playing it
    fkEffort = "effort" ## whether it fits the time you have

  Factor* = object
    kind*: FactorKind
    value*: Option[float] ## `none` when the evidence is missing
    weight*: float
    reason*: string ## one line, for the human reading the list

  Weights* = object
    ## Every weight is tunable, and `scoreFactor` only counts the factors that
    ## actually had data, so changing one does not require touching the others.
    quality*: float
    fit*: float
    run*: float
    price*: float
    popularity*: float
    effort*: float
    ## Smoothing for a review score, in the same units as a review count:
    ## `(positive + priorCount * prior) / (total + priorCount)`. A game with
    ## three reviews should not outrank one with three thousand.
    reviewPrior*: float ## the share assumed before any reviews
    reviewPriorCount*: float
    ## What a game being cheap is worth, as bands, because "quality per euro" is
    ## a fiction when the catalogue is free anyway.
    freePrice*: float
    cheapPrice*: float ## at or below `cheapUnder` cents
    cheapUnder*: int
    midPrice*: float ## at or below `midUnder` cents
    midUnder*: int
    dearPrice*: float
    ## The least share of the weight that has to be known before a game is worth
    ## ranking at all. Below this it is reported as too little evidence rather
    ## than recommended, which is what keeps "the listing says it is a native
    ## build and nothing else is known" out of the answer.
    minCoverage*: float

  ScoreCard* = object
    appid*: int
    title*: string
    score*: float ## weighted mean over known factors, 0..1
    coverage*: float ## share of the total weight that had data, 0..1
    factors*: seq[Factor]
    blockers*: seq[string] ## non-empty means "not a candidate"

  Ranked* = object
    candidates*: seq[ScoreCard] ## ranked, best first
    blocked*: seq[ScoreCard] ## excluded, with reasons
    unranked*: seq[ScoreCard] ## no usable evidence yet

func initWeights*(): Weights =
  ## The default weights.
  ##
  ## `quality` leads because it is the best-covered signal and the one a player
  ## would reach for first. `fit` is second because it is the only personal one.
  ## `run` matters but is partly a gate already. `price` and `popularity` break
  ## ties; `effort` is expected to be unknown and so carries little weight.
  Weights(quality: 0.30, fit: 0.25, run: 0.20, price: 0.10, popularity: 0.10,
          effort: 0.05, reviewPrior: 0.75, reviewPriorCount: 50.0,
          freePrice: 1.0, cheapPrice: 0.8, cheapUnder: 1000, midPrice: 0.6,
          midUnder: 3000, dearPrice: 0.3, minCoverage: 0.25)

func factor(kind: FactorKind; value: Option[float]; weight: float;
            reason: string): Factor =
  Factor(kind: kind, value: value, weight: weight, reason: reason)

func smoothedQuality*(percent: float; count: int; weights: Weights): float =
  ## Shrinks a review share towards the prior in proportion to how few reviews
  ## back it, so a game with five glowing reviews does not outrank one with five
  ## thousand good ones.
  let total = float(count)
  let prior = weights.reviewPrior
  let share = percent / 100.0
  (share * total + prior * weights.reviewPriorCount) /
    (total + weights.reviewPriorCount)

func qualityFactor*(store: SteamFacts; weights: Weights): Factor =
  ## The review share, smoothed.
  if store.reviews.percent.isSome and store.reviews.count.isSome:
    let percent = store.reviews.percent.get.value
    let count = store.reviews.count.get.value
    let smoothed = smoothedQuality(percent, count, weights)
    let word = store.reviews.description.get("no summary")
    result = factor(fkQuality, some smoothed, weights.quality,
      formatFloat(percent, ffDecimal, 1) & "% of " & $count & " reviews, " &
      word & ", smoothed to " & formatFloat(smoothed * 100.0, ffDecimal, 1) &
      "%")
  else:
    result = factor(fkQuality, none(float), weights.quality,
                    "no review score yet")

func popularityFactor*(store: SteamFacts; weights: Weights): Factor =
  ## How many players the game has, on a log scale.
  ##
  ## `recommendations.total` is the count of players who recommend the game at
  ## all, which is a better popularity proxy than review count. Ten thousand and
  ## a hundred thousand recommendations should be closer to each other than one
  ## and ten, which is what the logarithm is for.
  if store.recommendations.isSome and store.recommendations.get.value > 0:
    let total = float(store.recommendations.get.value)
    let scaled = min(1.0, log10(total) / 5.0) ## 100k recommendations is a 1.0
    result = factor(fkPopularity, some scaled, weights.popularity,
      $store.recommendations.get.value & " players recommend it")
  else:
    result = factor(fkPopularity, none(float), weights.popularity,
                    "no popularity data")

func priceFactor*(store: SteamFacts; weights: Weights): Factor =
  ## What it costs, as bands rather than a ratio.
  if store.isFree:
    result = factor(fkPrice, some weights.freePrice, weights.price, "free")
  elif store.price.isSome:
    let price = store.price.get.value
    let cents = price.final
    let value =
      if cents <= weights.cheapUnder: weights.cheapPrice
      elif cents <= weights.midUnder: weights.midPrice
      else: weights.dearPrice
    var reason = price.currency & " " & formatFloat(float(cents) / 100.0,
                                                    ffDecimal, 2)
    if price.discountPercent > 0:
      reason.add " at -" & $price.discountPercent & "%"
    result = factor(fkPrice, some value, weights.price, reason)
  else:
    result = factor(fkPrice, none(float), weights.price, "price unknown")

func runFactor*(release: Release; play: Playability; store: SteamFacts;
                weights: Weights): Factor =
  ## How well the game is known to run on Linux, taking the best evidence
  ## available rather than averaging sources that measure different things.
  var best = none(float)
  var reason = ""

  if play.tier.isSome:
    let tier = play.tier.get.value
    let value =
      case tier
      of ptPlatinum: 0.95
      of ptGold: 0.85
      of ptSilver: 0.6
      of ptBronze: 0.35
      of ptBorked: 0.0
      of ptUnknown: 0.0
    if best.isNone or value > best.get:
      best = some value
      reason = "ProtonDB " & $tier
      if play.reportCount.isSome:
        reason.add " over " & $play.reportCount.get.value & " reports"

  if store.steamos.isSome:
    let verdict = store.steamos.get.value
    let value =
      case verdict
      of lvVerified: 1.0
      of lvPlayable: 0.8
      of lvUnsupported: 0.1
      of lvUnknown: 0.0
    if best.isNone or value > best.get:
      best = some value
      reason = "Steam rates it " & $verdict & " for desktop Linux"

  if store.linuxBuild.isSome and store.linuxBuild.get.value:
    if best.isNone or best.get < 1.0:
      best = some 1.0
      reason = "Steam ships a Linux build"

  if best.isSome:
    if reason.len == 0:
      reason = "packaged for Wine" & (if play.antiCheat.isSome:
                                        ", anti-cheat " &
                                        $play.antiCheat.get.value
                                      else: "")
    result = factor(fkRun, best, weights.run, reason)
  elif release.runtime == rkNative:
    result = factor(fkRun, some 1.0, weights.run,
                    "ships a native Linux build in the listing")
  else:
    result = factor(fkRun, none(float), weights.run, "nothing is known yet")

func fitFactor*(profile: Profile; store: SteamFacts;
                weights: Weights): Factor =
  ## How close the game's tags are to yours.
  if profile.len == 0:
    return factor(fkFit, none(float), weights.fit, "no taste profile yet")
  let gameTags = if store.tags.isSome: store.tags.get.value else: newSeq[Tag]()
  let similarity = cosine(profile, gameTags)
  if similarity.isNone:
    return factor(fkFit, none(float), weights.fit, "not tagged yet")
  let value = max(0.0, (similarity.get + 1.0) / 2.0)
  var reason = "tag similarity " & formatFloat(similarity.get, ffDecimal, 2)
  let top = gameTags.topTags(3)
  if top.len > 0:
    reason.add " (" & top.join(", ") & ")"
  factor(fkFit, some value, weights.fit, reason)

func effortFactor*(store: SteamFacts; budgetMinutes: int;
                   weights: Weights): Factor =
  ## Whether the game fits the session you have.
  ##
  ## This is the weakest factor by design: SteamSpy's playtime is absent for
  ## most games, and mean playtime is not "how long to finish" anyway. It reports
  ## itself as unknown rather than guessing, and the honest fix is a length
  ## source, not a better guess.
  if budgetMinutes <= 0:
    return factor(fkEffort, none(float), weights.effort,
                  "no time budget given")
  if store.averageMinutes.isSome and store.averageMinutes.get.value > 0:
    let average = store.averageMinutes.get.value
    let ratio = min(1.0, float(budgetMinutes) / float(average))
    return factor(fkEffort, some ratio, weights.effort,
      $average & " minutes on average, against " & $budgetMinutes &
      " available")
  factor(fkEffort, none(float), weights.effort, "no playtime data")

func scoreFactors*(factors: openArray[Factor]): tuple[score, coverage: float] =
  ## The weighted mean over the factors that had data, shrunk towards the middle
  ## in proportion to how little of the weight was known.
  ##
  ## The shrinkage is the same idea as smoothing a review score, applied one
  ## level up: a game whose only evidence is the listing's own native-build flag
  ## has one factor of six, and that is a hint, not a 100% verdict. Without this,
  ## every barely-known game outranks every well-known one simply by having less
  ## to be marked down for.
  const Neutral = 0.5
  var totalWeight = 0.0
  var knownWeight = 0.0
  var weighted = 0.0
  for item in factors:
    totalWeight += item.weight
    if item.value.isSome:
      knownWeight += item.weight
      weighted += item.weight * item.value.get
  if totalWeight > 0.0:
    result.coverage = knownWeight / totalWeight
  if knownWeight > 0.0:
    result.score = (weighted / knownWeight) * result.coverage +
      Neutral * (1.0 - result.coverage)

func gates*(release: Release; play: Playability; store: SteamFacts;
            taste: Taste; diskBytes: int64): seq[string] =
  ## The reasons this game is not a candidate, empty when it is one.
  ##
  ## Order matters only for reading: the first reason is the most decisive.
  if release.appid.isSome and taste.isDecided(release.appid.get):
    let verdict = verdictOf(taste, release.appid.get).get
    result.add "already rated " & $verdict

  if play.antiCheat.isSome and blocksLinux(play.antiCheat.get.value):
    var reason = "anti-cheat " & $play.antiCheat.get.value
    if play.antiCheatNames.isSome:
      reason.add " (" & play.antiCheatNames.get.join(", ") & ")"
    result.add reason & " blocks Linux"

  if play.tier.isSome and play.tier.get.value == ptBorked:
    result.add "ProtonDB rates it borked"

  if diskBytes > 0:
    if release.sizeBytes.isNone:
      result.add "size unknown, and a disk budget was given"
    elif release.sizeBytes.get > diskBytes:
      result.add "needs " & $release.sizeBytes.get & " bytes, more than the " &
        $diskBytes & " available"

func rank*(releases: openArray[Release];
           play: Table[int, Playability];
           stores: Table[int, SteamFacts];
           taste: Taste; profile: Profile; weights: Weights;
           diskBytes = 0'i64; budgetMinutes = 0;
           includeBlocked = false; minCoverage = -1.0): Ranked =
  ## Scores the whole catalogue: candidates first, then the blocked and the
  ## unranked, each with their reasons.
  ##
  ## A game with too little evidence is `unranked` rather than scored zero,
  ## because "no evidence" and "bad" are different answers and only one of them
  ## is a recommendation. `minCoverage` defaults to the weights' own threshold.
  let threshold =
    if minCoverage >= 0.0: minCoverage
    else: weights.minCoverage

  for release in releases:
    if release.isGame:
      let facts = storeFactsOf(stores, release)
      let playability = playabilityOf(play, release).get(Playability())
      var card = ScoreCard(appid: release.appid.get(0), title: release.title)

      for reason in gates(release, playability, facts, taste, diskBytes):
        card.blockers.add reason

      card.factors = @[
        qualityFactor(facts, weights),
        fitFactor(profile, facts, weights),
        runFactor(release, playability, facts, weights),
        priceFactor(facts, weights),
        popularityFactor(facts, weights),
        effortFactor(facts, budgetMinutes, weights),
      ]
      let scored = scoreFactors(card.factors)
      card.score = scored.score
      card.coverage = scored.coverage

      if card.blockers.len > 0 and not includeBlocked:
        result.blocked.add card
      elif card.coverage < threshold:
        result.unranked.add card
      else:
        result.candidates.add card

  result.candidates.sort(proc (a, b: ScoreCard): int =
    if a.score != b.score: cmp(b.score, a.score)
    else: cmp(a.appid, b.appid))
  result.blocked.sort(proc (a, b: ScoreCard): int = cmp(a.appid, b.appid))
  result.unranked.sort(proc (a, b: ScoreCard): int = cmp(a.appid, b.appid))

proc roll*(cards: openArray[ScoreCard]; surprise: float;
           rng: var Rand): Option[ScoreCard] =
  ## Picks one card, with `surprise` controlling how much the ranking is obeyed.
  ##
  ## At `0` the best card always wins. At `1` the choice is nearly uniform over
  ## the candidates, which is what "surprise me" has to mean if it is to be
  ## different from "best". In between, cards are sampled with weights
  ## `exp(score / temperature)`, so a good game stays likely without the outcome
  ## being fixed.
  if cards.len == 0:
    return none(ScoreCard)
  if surprise <= 0.0:
    return some cards[0]

  let temperature = max(0.01, surprise * 0.15)
  var weights = newSeq[float](cards.len)
  var total = 0.0
  for index, card in cards:
    weights[index] = exp((card.score - cards[0].score) / temperature)
    total += weights[index]
  var target = rng.rand(total)
  for index, weight in weights:
    target -= weight
    if target <= 0.0:
      return some cards[index]
  some cards[^1]
