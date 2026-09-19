## Tests for the SteamSpy decoder.
##
## Two of these are regressions from real responses: a game with no price sends
## `null` where a priced game sends a string, and a game with no tags sends an
## empty *array* where a tagged game sends an object.

import std/[options, os]

import brian

import ludexcore/[models, sources/steamspy]

const FixtureDir = currentSourcePath().parentDir() / "fixtures" / "steamspy"

proc fixture(name: string): string =
  readFile(FixtureDir / name)

block tagged_game:
  let spy = decodeSpyApp(fixture("1264280.json"))
  doAssert spy.name == "Slipways"
  doAssert spy.developer == "Beetlewing"
  doAssert spy.owners == "200,000 .. 500,000"
  doAssert spy.ccu == 10
  doAssert spy.averageForever == 0, "playtime is unreported for this one"

  doAssert spy.tags.tags.len == 20, "SteamSpy sends at most twenty"
  doAssert spy.tags.tags[0] == Tag(name: "Strategy", votes: 145)
  doAssert spy.tags.tags[0].votes >= spy.tags.tags[1].votes,
    "the order is descending by votes, and is preserved"
  doAssert spy.tags.tags[1].name == "Puzzle"
  doAssert spy.tags.tags[1].votes == 140

block tags_become_a_weighted_fact:
  let spy = decodeSpyApp(fixture("1264280.json"))
  let facts = toSteamFacts(spy, fetchedAt = 42)
  doAssert facts.isKnown
  let tags = facts.tags.get
  doAssert tags.source == srcSteamSpy
  doAssert tags.fetchedAt == 42
  doAssert tags.value.len == 20
  doAssert tags.value[0].name == "Strategy"
  doAssert facts.owners.get.value == "200,000 .. 500,000"
  doAssert facts.currentPlayers.get.value == 10
  doAssert facts.averageMinutes.isNone,
    "a zero playtime is unreported, not an instant game"
  doAssert facts.price.isNone, "the store's price is the one this catalogue keeps"

block tag_names_are_trimmed_in_order:
  let spy = decodeSpyApp(fixture("1264280.json"))
  doAssert spy.tagNames(3) == @["Strategy", "Puzzle", "Turn-Based Strategy"]
  doAssert spy.tagNames(0).len == 0
  doAssert spy.tagNames(100).len == 20
  doAssert spy.tags.tags.topTags(2) == @["Strategy", "Puzzle"]

block unpriced_game_sends_nulls:
  # Regression: a game with no price sends `null` for `price`, `initialprice`
  # and `discount`. Those fields are deliberately not modelled, which is what
  # keeps this record decodable at all.
  let body = """{"appid":1,"name":"Unpriced","developer":"d","publisher":"p",
    "owners":"0 .. 20,000","average_forever":0,"ccu":0,
    "price":null,"initialprice":null,"discount":null,"tags":[]}"""
  let spy = decodeSpyApp(body)
  doAssert spy.name == "Unpriced"
  doAssert spy.tags.tags.len == 0
  doAssert not toSteamFacts(spy, 1).isKnown, "nothing to store, so nothing is"

block untagged_game_sends_an_empty_array:
  # Regression: `tags` is an object when populated and an empty array when not.
  let asObject = """{"name":"x","owners":"0 .. 20,000","ccu":3,
    "tags":{"Puzzle":10}}"""
  doAssert decodeSpyApp(asObject).tags.tags == @[Tag(name: "Puzzle", votes: 10)]
  let asArray = """{"name":"x","owners":"0 .. 20,000","ccu":3,"tags":[]}"""
  doAssert decodeSpyApp(asArray).tags.tags.len == 0

block an_untracked_game_is_an_empty_object:
  # SteamSpy answers `{}` for an app it does not track, which is silence rather
  # than a failure.
  let spy = decodeSpyApp("{}")
  doAssert spy.name == ""
  doAssert not toSteamFacts(spy, 1).isKnown

block fields_this_catalogue_does_not_use_are_skipped:
  let body = """{"name":"x","owners":"0 .. 20,000","ccu":1,"tags":[],
    "future_field":{"nested":[1,2,3]},"score_rank":"","userscore":0}"""
  doAssert decodeSpyApp(body).owners == "0 .. 20,000"

block urls:
  doAssert spyUrl(1264280) ==
    "https://steamspy.com/api.php?request=appdetails&appid=1264280"

block malformed_bodies_raise:
  doAssertRaises JsonParsingError:
    discard decodeSpyApp("""{"ccu":""")
  doAssertRaises JsonParsingError:
    discard decodeSpyApp("""{"ccu":"lots"}""")
  doAssertRaises JsonParsingError:
    discard decodeSpyApp("""{"tags":{"Puzzle":"many"}}""")
  doAssertRaises JsonParsingError:
    discard decodeSpyApp("""{"tags":"Puzzle"}""")
