## Tests for the taste profile and the ratings file.

import std/[math, options, strutils, tables]

import ludexcore/[models, ratings, taste]

func tags(pairs: openArray[(string, int)]): seq[Tag] =
  for (name, votes) in pairs:
    result.add Tag(name: name, votes: votes)

let
  # Two games whose tags overlap the way real ones do.
  slipways = tags({"Strategy": 145, "Puzzle": 140, "Turn-Based Strategy": 136,
                   "Relaxing": 123, "Sandbox": 123})
  wytchwood = tags({"Crafting": 200, "Female Protagonist": 180, "Cute": 150})
  shooter = tags({"Shooter": 300, "Multiplayer": 280, "FPS": 250})
  tagsByApp = {
    1: slipways,
    2: wytchwood,
    3: shooter,
  }.toTable

func rated(appid: int; verdict: Verdict): Rating =
  Rating(appid: appid, title: "game " & $appid, verdict: verdict, ratedAt: 1)

block verdict_spellings:
  # The spellings are the file format, so they are pinned.
  doAssert $vLoved == "loved"
  doAssert $vPlayed == "played"
  doAssert $vFinished == "finished"
  doAssert $vBounced == "bounced"
  doAssert $vSkipped == "skipped"
  doAssert $vLater == "later"

block rating_records_replace_rather_than_accumulate:
  var taste: Taste
  taste.rate(1, "one", vLoved, 10)
  taste.rate(2, "two", vBounced, 11)
  doAssert taste.ratings.len == 2
  taste.rate(1, "one again", vSkipped, 12)
  doAssert taste.ratings.len == 2, "a second verdict replaces the first"
  doAssert taste.verdictOf(1) == some(vSkipped)
  doAssert taste.ratings[0].ratedAt == 12
  doAssert taste.verdictOf(99).isNone

  doAssert taste.unrate(2)
  doAssert taste.ratings.len == 1
  doAssert not taste.unrate(2), "forgetting twice is not a success"

block decided_verdicts_gate_and_later_does_not:
  var taste: Taste
  for verdict in [vLoved, vPlayed, vFinished, vBounced, vSkipped]:
    taste.rate(ord(verdict) + 1, "x", verdict, 1)
    doAssert taste.isDecided(ord(verdict) + 1),
      $verdict & " is a decision, so the game is not a candidate"
  taste.rate(90, "later", vLater, 1)
  doAssert not taste.isDecided(90), "`later` keeps a game in the running"
  doAssert not taste.isDecided(91), "and an unrated game is a candidate"

block unit_vectors_have_length_one:
  let unit = unitVector(slipways)
  doAssert unit.len == 5
  var magnitude = 0.0
  for _, weight in unit:
    magnitude += weight * weight
  doAssert abs(magnitude - 1.0) < 1.0e-9
  doAssert unitVector(newSeq[Tag]()).len == 0

block a_game_with_more_tags_does_not_dominate:
  # Five tags and three tags both contribute a direction, not a magnitude, which
  # is why they are scaled before being added.
  var taste: Taste
  taste.rate(1, "slipways", vLoved, 1)
  let oneGame = buildProfile(taste, tagsByApp)
  doAssert abs(oneGame["Strategy"] - unitVector(slipways)["Strategy"]) < 1.0e-9
  doAssert not oneGame.hasKey("Cute"), "a tag nobody liked is simply absent"
  doAssert oneGame.hasKey("Turn-Based Strategy"),
    "the profile keeps SteamSpy's own capitalization"

block loved_pulls_towards_and_bounced_pushes_away:
  var taste: Taste
  taste.rate(1, "slipways", vLoved, 1)
  taste.rate(2, "wytchwood", vBounced, 2)
  let profile = buildProfile(taste, tagsByApp)

  doAssert profile["Strategy"] > 0.0, "the liked tags gain weight"
  doAssert profile["Puzzle"] > 0.0
  doAssert profile["Crafting"] < 0.0, "and the disliked ones lose it"
  doAssert profile["Female Protagonist"] < 0.0

  # A profile is unit length, so it is a direction in tag space.
  var magnitude = 0.0
  for _, weight in profile:
    magnitude += weight * weight
  doAssert abs(magnitude - 1.0) < 1.0e-9

  doAssert topProfileTags(profile, 3) == @["Strategy", "Puzzle",
                                           "Turn-Based Strategy"]
  doAssert dislikes(profile, 2) == @["Crafting", "Female Protagonist"]

block only_liked_and_bounced_shape_the_profile:
  var taste: Taste
  taste.rate(1, "slipways", vLoved, 1)
  let liked = buildProfile(taste, tagsByApp)
  taste.rate(2, "wytchwood", vSkipped, 2)
  taste.rate(3, "shooter", vLater, 3)
  doAssert buildProfile(taste, tagsByApp) == liked,
    "skipping and deferring are decisions about games, not about taste"

block ratings_without_tags_still_gate:
  var taste: Taste
  taste.rate(404, "unknown game", vLoved, 1)
  doAssert buildProfile(taste, tagsByApp).len == 0, "nothing to learn from"
  doAssert taste.isDecided(404), "but the decision still counts"

block a_profile_with_nothing_positive_is_empty:
  var taste: Taste
  taste.rate(2, "wytchwood", vBounced, 1)
  doAssert buildProfile(taste, tagsByApp).len > 0,
    "a dislike is still a direction"
  doAssert topProfileTags(buildProfile(taste, tagsByApp), 3).len == 0,
    "with nothing liked, there is nothing to recommend towards"

block cosine_measures_alignment:
  var taste: Taste
  taste.rate(1, "slipways", vLoved, 1)
  taste.rate(2, "wytchwood", vBounced, 2)
  let profile = buildProfile(taste, tagsByApp)

  let liked = cosine(profile, slipways)
  let disliked = cosine(profile, wytchwood)
  let unrelated = cosine(profile, shooter)
  doAssert liked.isSome and disliked.isSome and unrelated.isSome
  doAssert liked.get > 0.5, "a game of the liked tags is the closest match"
  doAssert disliked.get < 0.0, "a game of the disliked tags points the other way"
  doAssert abs(unrelated.get) < 1.0e-9, "and an unrelated game is orthogonal"
  doAssert liked.get > unrelated.get and unrelated.get > disliked.get,
    "similarity orders the three the way a person would"
  doAssert abs(liked.get - 0.7071) < 0.001, "and by a knowable amount"

  # With an unopposed profile the disliked game is merely unrelated rather than
  # repulsive, which is the difference between "disliked" and "unknown".
  var loved: Taste
  loved.rate(1, "slipways", vLoved, 1)
  doAssert abs(cosine(buildProfile(loved, tagsByApp), wytchwood).get) < 1.0e-9

  doAssert cosine(profile, newSeq[Tag]()).isNone,
    "no tags is not the same as no similarity"
  doAssert cosine(initTable[string, float](), slipways).isNone

block ratings_file_round_trip:
  var taste: Taste
  taste.rate(2, "two", vLater, 20)
  taste.rate(1, "one", vLoved, 10)
  let encoded = encodeTaste(taste)
  let lines = encoded.splitLines
  var written = 0
  for line in lines:
    if line.len > 0:
      inc written
  doAssert written == 2, "one line per rating, plus the trailing newline"
  doAssert lines[0].startsWith("""{"appid":1,"""),
    "the file is ordered by app id, so it is stable across runs"

  let loaded = decodeTaste(encoded)
  doAssert loaded.failures.len == 0
  doAssert loaded.taste.ratings.len == 2
  doAssert loaded.taste.verdictOf(1) == some(vLoved)
  doAssert loaded.taste.ratings[0].title == "one"

block ratings_file_reports_bad_lines:
  let loaded = decodeTaste("""
{"appid":1,"title":"one","verdict":"loved","ratedAt":10}
{"appid":0,"title":"no id","verdict":"loved","ratedAt":10}
{"appid":2,"title":"two","verdict":"adored","ratedAt":10}
not json
""")
  doAssert loaded.taste.ratings.len == 1
  doAssert loaded.failures.len == 3
  doAssert loaded.failures[0].contains("app id")
  doAssert loaded.failures[1].contains("Verdict")
  doAssert loaded.failures[2].contains("JSON"),
    "a malformed line keeps the parser's own message"

block a_hand_edited_file_still_loads:
  # Unknown fields are skipped, so a file with notes added by hand is fine.
  let loaded = decodeTaste(
    """{"appid":5,"title":"five","verdict":"loved","ratedAt":1,"note":"why"}""")
  doAssert loaded.failures.len == 0
  doAssert loaded.taste.verdictOf(5) == some(vLoved)
