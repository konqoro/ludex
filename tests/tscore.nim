## Tests for the ranking: factors, gates, coverage and the roll.

import std/[math, options, random, strutils, tables]

import brian

import ludexcore/[models, score, taste]

let weights = initWeights()

func release(appid: int; runtime = rkWine; size = 0'i64): Release =
  Release(rowKind: rkGame, title: "game " & $appid, titleNorm: "game " & $appid,
          pack: pkSingle, runtime: runtime, appid: some(appid),
          sizeBytes: (if size > 0: some size else: none(int64)))

func store(percent: float; count: int; recommendations = 0;
           final = 0; currency = "USD"; isFree = false;
           tags: seq[Tag] = @[]; steamos = none(Fact[LinuxVerdict]);
           linuxBuild = none(Fact[bool]); average = 0): SteamFacts =
  result.reviews.percent = some initFact(percent, srcSteam, 1)
  result.reviews.count = some initFact(count, srcSteam, 1)
  if recommendations > 0:
    result.recommendations = some initFact(recommendations, srcSteam, 1)
  if final > 0:
    result.price = some initFact(
      Price(currency: currency, initial: final, final: final,
            discountPercent: 0), srcSteam, 1)
  result.isFree = isFree
  if tags.len > 0:
    result.tags = some initFact(tags, srcSteamSpy, 1)
  result.steamos = steamos
  result.linuxBuild = linuxBuild
  if average > 0:
    result.averageMinutes = some initFact(average, srcSteamSpy, 1)

func tag(name: string; votes: int): Tag =
  Tag(name: name, votes: votes)

block review_smoothing:
  # A handful of glowing reviews should not beat thousands of good ones.
  doAssert smoothedQuality(100.0, 3, weights) < smoothedQuality(90.0, 5000,
                                                               weights)
  doAssert smoothedQuality(100.0, 3, weights) < 0.80,
    "three reviews cannot carry a game to a high score"
  doAssert smoothedQuality(92.6, 9916, weights) > 0.92,
    "and a large sample is barely moved"
  doAssert smoothedQuality(75.0, 0, weights) == weights.reviewPrior,
    "no reviews is the prior itself"

block quality_factor:
  let known = qualityFactor(store(92.6, 9916), weights)
  doAssert known.value.isSome
  doAssert known.reason.contains("92.6% of 9916 reviews")
  doAssert known.reason.contains("smoothed")

  let unknown = qualityFactor(SteamFacts(), weights)
  doAssert unknown.value.isNone
  doAssert unknown.reason == "no review score yet"

block run_takes_the_best_evidence:
  # Three sources measure the same question differently, so the best answer wins
  # rather than an average of answers that disagree.
  let native = runFactor(release(1), Playability(),
                         store(0, 0, linuxBuild = some initFact(true, srcSteam, 1)), weights)
  doAssert native.value == some(1.0)
  doAssert native.reason.contains("Linux build")

  let proton = runFactor(release(1),
                         Playability(tier: some initFact(ptGold, srcProtonDb, 1),
                                     reportCount: some initFact(60, srcProtonDb, 1)),
                         SteamFacts(), weights)
  doAssert proton.value.get > 0.8 and proton.value.get < 0.9
  doAssert proton.reason.contains("gold")
  doAssert proton.reason.contains("60 reports")

  let steamOs = runFactor(release(1), Playability(),
                          store(0, 0, steamos = some initFact(lvPlayable, srcSteam, 1)), weights)
  doAssert steamOs.value == some(0.8)

  # ProtonDB platinum beats Steam's "playable", because it is the better
  # measurement of the same thing.
  let both = runFactor(release(1),
                       Playability(tier: some initFact(ptPlatinum, srcProtonDb, 1)),
                       store(0, 0, steamos = some initFact(lvPlayable, srcSteam, 1)), weights)
  doAssert both.value.get > 0.9

  let unsupported = runFactor(
    release(1), Playability(),
    store(0, 0, steamos = some initFact(lvUnsupported, srcSteam, 1)), weights)
  doAssert unsupported.value.get < 0.2, "Steam saying no is not a recommendation"

  let listed = runFactor(release(1, runtime = rkNative), Playability(),
                         SteamFacts(), weights)
  doAssert listed.value == some(1.0),
    "and with nothing else known, the listing's own runtime is used"
  doAssert listed.reason.contains("native")

  let nothing = runFactor(release(1), Playability(), SteamFacts(), weights)
  doAssert nothing.value.isNone
  doAssert nothing.reason == "nothing is known yet"

  let borked = runFactor(release(1),
                         Playability(tier: some initFact(ptBorked, srcProtonDb, 1)),
                         SteamFacts(), weights)
  doAssert borked.value == some(0.0)

block price_bands:
  doAssert priceFactor(store(0, 0, isFree = true), weights).value ==
    some(weights.freePrice)
  doAssert priceFactor(store(0, 0, final = 499), weights).reason == "USD 4.99"
  doAssert priceFactor(store(0, 0, final = 499), weights).value ==
    some(weights.cheapPrice)
  doAssert priceFactor(store(0, 0, final = 2000), weights).value ==
    some(weights.midPrice)
  doAssert priceFactor(store(0, 0, final = 5999), weights).value ==
    some(weights.dearPrice)
  doAssert priceFactor(SteamFacts(), weights).value.isNone
  doAssert priceFactor(SteamFacts(), weights).reason == "price unknown"

block popularity_is_logarithmic:
  let small = popularityFactor(store(0, 0, recommendations = 10), weights)
  let mid = popularityFactor(store(0, 0, recommendations = 1000), weights)
  let large = popularityFactor(store(0, 0, recommendations = 100000), weights)
  doAssert small.value.get < mid.value.get
  doAssert mid.value.get < large.value.get
  doAssert large.value.get == 1.0, "a hundred thousand is the ceiling"
  doAssert mid.value.get > 0.5, "and the scale is compressed, not linear"
  doAssert popularityFactor(SteamFacts(), weights).value.isNone

block effort_reports_itself_unknown:
  doAssert effortFactor(store(0, 0), 0, weights).value.isNone
  doAssert effortFactor(store(0, 0), 120, weights).value.isNone
  doAssert effortFactor(store(0, 0), 120, weights).reason == "no playtime data"

  let fits = effortFactor(store(0, 0, average = 60), 120, weights)
  doAssert fits.value == some(1.0), "twice the time needed is plenty"
  let tight = effortFactor(store(0, 0, average = 120), 60, weights)
  doAssert tight.value == some(0.5)
  doAssert tight.reason.contains("120 minutes on average")

block coverage_shrinks_the_score:
  # The bug this exists for: a game whose only evidence is one perfect factor
  # out of six used to score 100% and lead the list.
  let thin = @[Factor(kind: fkRun, value: some 1.0, weight: 0.20,
                      reason: "native only")] & @[
    Factor(kind: fkQuality, value: none(float), weight: 0.30, reason: ""),
    Factor(kind: fkFit, value: none(float), weight: 0.25, reason: ""),
    Factor(kind: fkPrice, value: none(float), weight: 0.10, reason: ""),
    Factor(kind: fkPopularity, value: none(float), weight: 0.10, reason: ""),
    Factor(kind: fkEffort, value: none(float), weight: 0.05, reason: ""),
  ]
  let thinScored = scoreFactors(thin)
  doAssert abs(thinScored.coverage - 0.20) < 1.0e-9
  doAssert abs(thinScored.score - 0.60) < 1.0e-9,
    "one factor of six is a hint, so the score sits above the middle and no more"

  let full = @[
    Factor(kind: fkQuality, value: some 0.85, weight: 0.30, reason: ""),
    Factor(kind: fkFit, value: some 0.5, weight: 0.25, reason: ""),
    Factor(kind: fkRun, value: some 0.9, weight: 0.20, reason: ""),
    Factor(kind: fkPrice, value: some 0.6, weight: 0.10, reason: ""),
    Factor(kind: fkPopularity, value: some 0.7, weight: 0.10, reason: ""),
    Factor(kind: fkEffort, value: some 0.5, weight: 0.05, reason: ""),
  ]
  let fullScored = scoreFactors(full)
  doAssert fullScored.coverage == 1.0
  doAssert fullScored.score > thinScored.score,
    "a well-known good game beats a barely-known perfect one"

  doAssert scoreFactors(newSeq[Factor]()).score == 0.0
  doAssert scoreFactors(newSeq[Factor]()).coverage == 0.0

block gates_name_their_reason:
  var taste: Taste
  taste.rate(1, "game 1", vLoved, 1)
  doAssert gates(release(1), Playability(), SteamFacts(), taste, 0) ==
    @["already rated loved"]

  let blockedAnticheat = Playability(
    antiCheat: some initFact(acBroken, srcAntiCheatYet, 1),
    antiCheatNames: some(@["BattlEye"]))
  doAssert gates(release(2), blockedAnticheat, SteamFacts(), Taste(), 0) ==
    @["anti-cheat broken (BattlEye) blocks Linux"]

  doAssert gates(release(3),
                 Playability(tier: some initFact(ptBorked, srcProtonDb, 1)),
                 SteamFacts(), Taste(), 0) == @["ProtonDB rates it borked"]

  # A disk budget cannot be satisfied by a size nobody knows.
  doAssert gates(release(4), Playability(), SteamFacts(), Taste(),
                 100'i64) == @["size unknown, and a disk budget was given"]
  doAssert gates(release(4, size = 500'i64), Playability(), SteamFacts(),
                 Taste(), 100'i64) ==
    @["needs 500 bytes, more than the 100 available"]
  doAssert gates(release(4, size = 50'i64), Playability(), SteamFacts(),
                 Taste(), 100'i64).len == 0

  # Denied blocks too, and an unknown anti-cheat does not.
  doAssert gates(release(5),
                 Playability(antiCheat: some initFact(acDenied, srcAntiCheatYet, 1)),
                 SteamFacts(), Taste(), 0).len == 1
  doAssert gates(release(6),
                 Playability(antiCheat: some initFact(acUnknown, srcAntiCheatYet, 1)),
                 SteamFacts(), Taste(), 0).len == 0

  doAssert gates(release(7), Playability(), SteamFacts(), Taste(), 0).len == 0,
    "an unrated game with unknown everything is still a candidate"

block ranking_splits_three_ways:
  var play = initTable[int, Playability]()
  var stores = initTable[int, SteamFacts]()
  stores[1] = store(90.0, 1000, recommendations = 5000, final = 999,
                    tags = @[tag("Strategy", 100)])
  stores[2] = store(50.0, 1000, recommendations = 5000, final = 999,
                    tags = @[tag("Shooter", 100)])
  play[3] = Playability(antiCheat: some initFact(acBroken, srcAntiCheatYet, 1))
  var taste: Taste
  taste.rate(4, "game 4", vBounced, 1)

  let ranked = rank(@[release(1), release(2), release(3), release(4),
                      release(5, runtime = rkNative), release(6)],
                    play, stores, taste, initTable[string, float](), weights)
  doAssert ranked.candidates.len == 2, "the two games with evidence"
  doAssert ranked.candidates[0].appid == 1, "best first"
  doAssert ranked.candidates[1].appid == 2
  doAssert ranked.blocked.len == 2
  doAssert ranked.unranked.len == 2

  var unrankedIds: seq[int]
  for card in ranked.unranked:
    unrankedIds.add card.appid
  # 5 is the interesting one: the listing says it is a native build and nothing
  # else is known. One perfect factor out of six is a hint, not a recommendation,
  # so it does not get to outrank a game with a thousand reviews behind it.
  doAssert unrankedIds == @[5, 6]
  doAssert ranked.candidates[0].coverage >= weights.minCoverage
  doAssert unrankedIds.len == 2

  # A candidate carries its factors, so the CLI never has to re-derive them.
  doAssert ranked.candidates[0].factors.len == 6
  doAssert ranked.candidates[0].coverage == 0.5

block include_blocked_moves_them_into_the_running:
  var play = initTable[int, Playability]()
  play[1] = Playability(antiCheat: some initFact(acBroken, srcAntiCheatYet, 1))
  var stores = initTable[int, SteamFacts]()
  stores[1] = store(90.0, 1000, recommendations = 5000)
  let ranked = rank(@[release(1)], play, stores, Taste(),
                    initTable[string, float](), weights, includeBlocked = true)
  doAssert ranked.blocked.len == 0
  doAssert ranked.candidates.len == 1
  doAssert ranked.candidates[0].blockers.len == 1,
    "but the reason still travels with it"

  # Including a blocked game does not make it rankable: being blocked and
  # having no evidence are two separate disqualifications.
  let bare = rank(@[release(1)], play, initTable[int, SteamFacts](), Taste(),
                  initTable[string, float](), weights, includeBlocked = true)
  doAssert bare.candidates.len == 0
  doAssert bare.unranked.len == 1

block a_lower_threshold_lets_the_hints_in:
  # The threshold is tunable, and lowering it is a deliberate choice to see
  # weakly-known games rather than a silent behaviour change.
  let ranked = rank(@[release(5, runtime = rkNative)],
                    initTable[int, Playability](), initTable[int, SteamFacts](),
                    Taste(), initTable[string, float](), weights,
                    minCoverage = 0.1)
  doAssert ranked.candidates.len == 1
  doAssert abs(ranked.candidates[0].score - 0.6) < 1.0e-9,
    "and its score says how little is behind it"

block a_profile_changes_the_order:
  var stores = initTable[int, SteamFacts]()
  stores[1] = store(80.0, 1000, tags = @[tag("Strategy", 200), tag("Puzzle", 100)])
  stores[2] = store(80.0, 1000, tags = @[tag("Shooter", 200), tag("FPS", 100)])
  var taste: Taste
  taste.rate(9, "liked", vLoved, 1)
  var tagsByApp = initTable[int, seq[Tag]]()
  tagsByApp[9] = @[tag("Strategy", 200), tag("Puzzle", 100)]
  let profile = buildProfile(taste, tagsByApp)

  let without = rank(@[release(1), release(2)], initTable[int, Playability](),
                     stores, taste, initTable[string, float](), weights)
  let with = rank(@[release(1), release(2)], initTable[int, Playability](),
                  stores, taste, profile, weights)

  doAssert without.candidates.len == 2 and with.candidates.len == 2
  doAssert with.candidates[0].appid == 1,
    "with a profile, the game sharing its tags leads"
  let fit = with.candidates[0].factors[1]
  doAssert fit.kind == fkFit
  doAssert fit.value.get > 0.9
  doAssert fit.reason.contains("tag similarity")

block ranking_is_deterministic:
  var stores = initTable[int, SteamFacts]()
  stores[1] = store(80.0, 1000)
  stores[2] = store(80.0, 1000)
  let first = rank(@[release(1), release(2)], initTable[int, Playability](),
                   stores, Taste(), initTable[string, float](), weights)
  let second = rank(@[release(2), release(1)], initTable[int, Playability](),
                    stores, Taste(), initTable[string, float](), weights)
  doAssert first.candidates[0].appid == second.candidates[0].appid,
    "a tie is broken by app id, so the order does not depend on input order"

block surprise_zero_always_takes_the_best:
  var stores = initTable[int, SteamFacts]()
  stores[1] = store(90.0, 1000)
  stores[2] = store(50.0, 1000)
  let ranked = rank(@[release(1), release(2)], initTable[int, Playability](),
                    stores, Taste(), initTable[string, float](), weights)
  var rng = initRand(1)
  for _ in 0 ..< 5:
    doAssert roll(ranked.candidates, 0.0, rng).get.appid == 1
  doAssert roll(newSeq[ScoreCard](), 0.5, rng).isNone

block surprise_is_reproducible_and_varies:
  var stores = initTable[int, SteamFacts]()
  var releases: seq[Release]
  for appid in 1 .. 10:
    stores[appid] = store(float(50 + appid), 1000)
    releases.add release(appid)
  let ranked = rank(releases, initTable[int, Playability](), stores, Taste(),
                    initTable[string, float](), weights)

  var rngA = initRand(7)
  var rngB = initRand(7)
  doAssert roll(ranked.candidates, 0.8, rngA).get.appid ==
    roll(ranked.candidates, 0.8, rngB).get.appid, "the same seed repeats"

  var seen = initTable[int, bool]()
  for seed in 0 ..< 20:
    var rng = initRand(seed)
    seen[roll(ranked.candidates, 0.9, rng).get.appid] = true
  doAssert seen.len > 1, "and different seeds explore"

  # Surprise is monotone: less of it obeys the ranking more, and even at full
  # surprise the best game is picked more often than one game in ten.
  # `best` is by score, not by app id: the ranking is what is being varied here.
  let best = ranked.candidates[0].appid
  var mildBest = 0
  var flatBest = 0
  var outcomes = initTable[int, bool]()
  for seed in 0 ..< 200:
    var mild = initRand(seed)
    if roll(ranked.candidates, 0.3, mild).get.appid == best:
      inc mildBest
    var flat = initRand(seed)
    let picked = roll(ranked.candidates, 1.0, flat).get.appid
    outcomes[picked] = true
    if picked == best:
      inc flatBest
  doAssert mildBest > flatBest, "lower surprise obeys the ranking more"
  doAssert flatBest >= 15,
    "and even at full surprise the best beats one game in ten, which is " &
    $ranked.candidates.len
  doAssert outcomes.len > 3, "while the tail gets a turn"

block weights_are_a_json_file:
  let encoded = toJson(initWeights())
  let loaded = fromJson(encoded, Weights)
  # Compared with a tolerance rather than exactly, because `brian` 0.1.0's float
  # parser is one unit in the last place high for values such as `0.3` and
  # `0.6`, which the defaults use. Stored facts are rounded to a canonical
  # precision so they are unaffected; a configuration file is not stored data
  # and does not need that treatment.
  doAssert abs(loaded.quality - weights.quality) < 1.0e-12
  doAssert abs(loaded.midPrice - weights.midPrice) < 1.0e-12
  doAssert loaded.cheapUnder == weights.cheapUnder
  doAssert loaded.minCoverage == weights.minCoverage

  var tuned = weights
  tuned.quality = 0.9
  tuned.fit = 0.1
  var reloaded = initWeights()
  fromJson(toJson(tuned), reloaded)
  doAssert abs(reloaded.quality - 0.9) < 1.0e-12
  doAssert abs(reloaded.fit - 0.1) < 1.0e-12
  doAssert reloaded.reviewPrior == weights.reviewPrior,
    "and an untouched field keeps its default"
