## Pure decision labels omit unavailable evidence and prioritize known blockers.
## These checks need no display, files or network.

import std/[assertions, options]

import ludexcore/[models, taste]
import ludexui/present

proc release(appid = 0; runtime = rkWine): Release =
  result = Release(rowKind: rkGame, title: "Game", titleNorm: "game",
    pack: pkSingle, runtime: runtime)
  if appid > 0:
    result.appid = some appid

block rating_labels:
  doAssert verdictLabel(vLoved) == "Loved"
  doAssert verdictLabel(vBounced) == "Bounced"
  doAssert $vLoved == "loved"

block decision_summaries_do_not_invent_evidence:
  let bare = SteamFacts()
  doAssert gameGenres(bare) == ""
  doAssert compatibilitySummary(release(), none(Playability), bare) == ""
  doAssert reviewSummary(bare) == ""
  doAssert steamUrl(release()) == ""
  doAssert steamUrl(Release(appid: some -1)) == ""
  doAssert steamUrl(release(appid = 42)) == "https://store.steampowered.com/app/42/"
  var facts = SteamFacts(genres: @["Puzzle", "Strategy", "Adventure"])
  doAssert gameGenres(facts) == "Puzzle · Strategy"
  facts.tags = some initFact(@[Tag(name: "Cozy", votes: 20),
    Tag(name: "Cats", votes: 12), Tag(name: "Puzzle", votes: 1)], srcSteamSpy, 1)
  doAssert gameGenres(facts) == "Cozy · Cats"
  facts.reviews.percent = some initFact(92.8, srcSteam, 1)
  doAssert reviewSummary(facts) == ""
  facts.reviews.count = some initFact(120, srcSteam, 1)
  doAssert reviewSummary(facts) == "93% positive · 120 reviews"
  facts.reviews.count = some initFact(28861, srcSteam, 1)
  doAssert reviewSummary(facts) == "93% positive · 28,861 reviews"
  var play = Playability(tier: some initFact(ptGold, srcProtonDb, 1),
    reportCount: some initFact(3, srcProtonDb, 1))
  doAssert compatibilitySummary(release(), some play, bare) ==
    "ProtonDB: gold · 3 reports"
  doAssert compatibilitySummary(release(runtime = rkNative), some play, bare) ==
    "A native Linux version is available"
  play.antiCheat = some initFact(acDenied, srcAntiCheatYet, 1)
  doAssert compatibilitySummary(release(runtime = rkNative), some play, bare) ==
    "Anti-cheat blocks play on Linux"
  play.antiCheat = none(Fact[AntiCheat])
  play.tier = some initFact(ptBorked, srcProtonDb, 1)
  doAssert compatibilitySummary(release(runtime = rkNative), some play, bare) ==
    "Reported not working on ProtonDB"

block tone_follows_the_strongest_known_fact:
  ## Semantic color is derived from evidence, blockers first.
  let bare = SteamFacts()
  doAssert compatibilityTone(release(), none(Playability), bare) == toneUnknown
  var play = Playability(tier: some initFact(ptPlatinum, srcProtonDb, 1))
  doAssert compatibilityTone(release(), some play, bare) == tonePositive
  play.tier = some initFact(ptSilver, srcProtonDb, 1)
  doAssert compatibilityTone(release(), some play, bare) == toneNeutral
  play.tier = some initFact(ptBronze, srcProtonDb, 1)
  doAssert compatibilityTone(release(), some play, bare) == toneCaution
  doAssert compatibilityTone(release(runtime = rkNative), some play, bare) ==
    tonePositive
  play.antiCheat = some initFact(acDenied, srcAntiCheatYet, 1)
  doAssert compatibilityTone(release(runtime = rkNative), some play, bare) ==
    toneNegative

block subtitle_price_and_year_omit_nothing_they_lack:
  var facts = SteamFacts()
  doAssert gameSubtitle(facts) == ""
  doAssert priceText(facts) == ""
  doAssert releasedYear(facts) == ""
  facts.genres = @["Strategy"]
  facts.releaseDate = some initFact("Mar 24, 2017", srcSteam, 1)
  doAssert releasedYear(facts) == "2017"
  doAssert gameSubtitle(facts) == "Strategy · 2017"
  facts.price = some initFact(Price(currency: "USD", final: 2999), srcSteam, 1)
  doAssert priceText(facts) == "$29.99"
  facts.price = some initFact(Price(currency: "XYZ", final: 500), srcSteam, 1)
  doAssert priceText(facts) == "5.00 XYZ",
    "a code without a symbol keeps its code rather than guessing a glyph"
  facts.isFree = true
  doAssert priceText(facts) == "Free"

block the_pitch_and_press_score_are_labelled:
  var facts = SteamFacts()
  doAssert pitch(facts) == "", "no pitch means no paragraph"
  doAssert criticsSummary(facts) == ""
  doAssert criticsUrl(facts) == ""
  facts.shortDescription = "Weave isolated planets into a vast trade empire."
  doAssert pitch(facts) == facts.shortDescription
  facts.shortDescription = "A <strong>bold</strong> &quot;game&quot;\n\nwith &amp; entities&#39;"
  doAssert pitch(facts) == "A bold \"game\" with & entities'",
    "the store's short HTML is dropped and its entities decoded"
  doAssert plainText("one   two\n\nthree") == "one two three",
    "runs of whitespace collapse, because the source is full of newlines"
  facts.critics = some Critics(score: initFact(80, srcSteam, 1))
  doAssert criticsSummary(facts) == "80 on Metacritic",
    "the number is named, so it is not read as a player score"
  doAssert criticsUrl(facts) == ""
  facts.critics = some Critics(score: initFact(80, srcSteam, 1),
                               url: some "https://www.metacritic.com/game/pc/x")
  doAssert criticsUrl(facts) == "https://www.metacritic.com/game/pc/x"

block markup_labels_are_escaped:
  # A row subtitle is Pango markup, and a parse failure blanks it, so an
  # ampersand in a tag name has to become an entity before it gets there.
  doAssert escapeMarkup("Point & Click") == "Point &amp; Click"
  doAssert escapeMarkup("<b>bold</b>") == "&lt;b&gt;bold&lt;/b&gt;"
  doAssert escapeMarkup("a & b < c > d") == "a &amp; b &lt; c &gt; d"
  doAssert escapeMarkup("Plain tag") == "Plain tag"

block developer_tags_and_first_entry:
  var facts = SteamFacts()
  doAssert firstOf(facts.developers) == ""
  doAssert tagSummary(facts, 3) == ""
  facts.developers = @["", "Overhype Studios"]
  doAssert firstOf(facts.developers) == "Overhype Studios"
  facts.tags = some initFact(@[Tag(name: "Cozy", votes: 20),
    Tag(name: "Cats", votes: 12), Tag(name: "Puzzle", votes: 1)], srcSteamSpy, 1)
  doAssert tagSummary(facts, 2) == "Cozy · Cats"

echo "tpresent: ok"
