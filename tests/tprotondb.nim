## Tests for the ProtonDB summary decoder.
##
## The fixtures are real recorded responses, so these assertions describe data
## the source actually produced rather than data we imagined.

import std/[math, options, os]

import brian

import ludexcore/[models, sources/protondb]

const FixtureDir = currentSourcePath().parentDir() / "fixtures" / "protondb"

proc fixture(name: string): string =
  readFile(FixtureDir / name)

block tier_spellings:
  doAssert parsePlayTier("borked") == ptBorked
  doAssert parsePlayTier("bronze") == ptBronze
  doAssert parsePlayTier("silver") == ptSilver
  doAssert parsePlayTier("gold") == ptGold
  doAssert parsePlayTier("platinum") == ptPlatinum
  doAssert parsePlayTier("unknown") == ptUnknown
  doAssert parsePlayTier("diamond") == ptUnknown, "a new word is not a failure"
  doAssert parsePlayTier("") == ptUnknown

block tier_order_is_quality_order:
  # Tiers are compared against thresholds, so the ordering is part of the
  # contract, and the unusable value has to sort below every usable one.
  doAssert ptUnknown < ptBorked
  doAssert ptBorked < ptBronze
  doAssert ptBronze < ptSilver
  doAssert ptSilver < ptGold
  doAssert ptGold < ptPlatinum

block recorded_platinum_response:
  let summary = decodeSummary(fixture("1264280-platinum-strong.json"))
  doAssert summary.tier == "platinum"
  doAssert summary.bestReportedTier == "platinum"
  doAssert summary.trendingTier == "platinum"
  doAssert summary.confidence == "strong"
  doAssert summary.score == 0.71
  doAssert summary.total == 31

  let play = toPlayability(summary, fetchedAt = 1000)
  doAssert play.tier.get.value == ptPlatinum
  doAssert play.tier.get.source == srcProtonDb
  doAssert play.tier.get.fetchedAt == 1000
  doAssert play.reportCount.get.value == 31
  doAssert play.tierConfidence == some("strong")
  doAssert play.antiCheat.isNone, "a source only reports what it knows"

block recorded_gold_response:
  let summary = decodeSummary(fixture("1281270-gold-moderate.json"))
  doAssert summary.tier == "gold"
  doAssert summary.score == 0.45
  doAssert summary.total == 9
  doAssert toPlayability(summary, 1000).tier.get.value == ptGold

block recorded_pending_response:
  # ProtonDB answers `pending` plus a `provisionalTier` when the reports are too
  # thin to call. That is still evidence worth keeping, but it must not read as
  # a good tier, and the provisional guess must not become a fact.
  let summary = decodeSummary(fixture("4403510-unknown-inadequate.json"))
  doAssert summary.tier == "pending"
  doAssert summary.provisionalTier == "silver"
  doAssert summary.total == 5
  doAssert summary.confidence == "inadequate"
  let play = toPlayability(summary, 1000)
  doAssert play.tier.get.value == ptUnknown
  doAssert play.reportCount.get.value == 5
  doAssert play.tier.get.value < ptBorked,
    "ptUnknown sorts lowest, so a tier bound rejects it without a special case"

block scores_are_rounded:
  # `0.7000000000000001` is what a float sum of report scores looks like when it
  # is written out verbatim. Three decimals is all the signal there is.
  doAssert roundTierScore(0.7000000000000001) == 0.7
  doAssert $roundTierScore(0.7000000000000001) == "0.7", "the noise is gone"
  doAssert roundTierScore(0.66666) == 0.667
  doAssert roundTierScore(1.0) == 1.0
  doAssert roundTierScore(0.0) == 0.0
  let noisy = Summary(tier: "gold", score: 0.7000000000000001, total: 4)
  doAssert $toPlayability(noisy, 1).tierScore.get.value == "0.7"

block no_reports_means_no_facts:
  # A summary with nothing behind it produces nothing, rather than a tier of
  # `unknown` pretending to be data.
  let empty = Summary(tier: "unknown", score: 0.0, total: 0)
  let play = toPlayability(empty, 1000)
  doAssert play.tier.isNone
  doAssert play.tierScore.isNone
  doAssert play.reportCount.isNone
  doAssert not play.isKnown

block missing_fields_keep_defaults:
  # A partial body is not an error: absent fields stay absent.
  let partial = decodeSummary("""{"tier":"silver","total":12}""")
  doAssert partial.tier == "silver"
  doAssert partial.total == 12
  doAssert partial.confidence == ""
  let play = toPlayability(partial, 1000)
  doAssert play.tier.get.value == ptSilver
  doAssert play.tierConfidence.isNone

block malformed_bodies_raise:
  doAssertRaises JsonParsingError:
    discard decodeSummary("""{"tier": """)
  doAssertRaises JsonParsingError:
    discard decodeSummary("""{"total": "many"}""")
  doAssertRaises JsonParsingError:
    discard decodeSummary("not json")

block summary_urls:
  doAssert summaryUrl(1264280) ==
    "https://www.protondb.com/api/v1/reports/summaries/1264280.json"
