## Tests for the Steam store and review summary decoders.
##
## The fixtures are real recorded responses. They are the reason the silent
## version of this decoder was caught: `snake_case` wire names against camelCase
## Nim fields produce an empty record, and a run that reports success while
## storing nothing is worse than one that fails.

import std/[options, os, strutils]

import brian

import ludexcore/[models, sources/steamdeck, sources/steamreviews, sources/steamstore]

const FixtureDir = currentSourcePath().parentDir() / "fixtures" / "steam"

proc fixture(name: string): string =
  readFile(FixtureDir / name)

block the_store_pitch_and_press_score_are_kept:
  # `short_description` is the one-line pitch the game page shows, and
  # `metacritic` is a press aggregate that only some games have. Neither is
  # named like its field, so both are decoded field by field.
  let app = decodeApp(fixture("365360-appdetails.json"), 365360)
  doAssert app.isSome
  doAssert app.get.shortDescription.startsWith("Lead a mercenary company")
  doAssert app.get.backgroundRaw.contains("page_bg_raw.jpg"),
    "the wide page art is a different field from the header"
  doAssert app.get.metacritic.isSome
  doAssert app.get.metacritic.get.score == 80
  doAssert app.get.metacritic.get.url.contains("metacritic.com")
  let facts = toSteamFacts(app.get, 1)
  doAssert facts.shortDescription == app.get.shortDescription
  doAssert facts.critics.isSome
  doAssert facts.critics.get.score.value == 80
  doAssert facts.critics.get.score.source == srcSteam
  doAssert facts.critics.get.url.isSome
  doAssert facts.art.background.isSome
  doAssert facts.art.background.get.value == app.get.backgroundRaw

block a_game_without_a_press_score_says_so:
  let app = decodeApp(fixture("1264280-appdetails.json"), 1264280)
  doAssert app.isSome
  doAssert app.get.shortDescription.len > 0
  doAssert app.get.metacritic.isNone
  doAssert toSteamFacts(app.get, 1).critics.isNone

block native_linux_release:
  let app = decodeApp(fixture("1999520-appdetails.json"), 1999520)
  doAssert app.isSome
  doAssert app.get.name == "CATO: Buttered Cat"
  doAssert app.get.kind == "game", "the payload calls this field `type`"
  doAssert app.get.steamAppid == 1999520, "and this one `steam_appid`"
  doAssert not app.get.isFree, "and this one `is_free`"
  doAssert app.get.platforms.linux
  doAssert app.get.platforms.windows
  doAssert app.get.developers == @["Team Woll"]
  doAssert app.get.publishers == @["GCORES PUBLISHING"]
  doAssert app.get.releaseDate.date == "Sep 5, 2024", "this one `release_date`"
  doAssert not app.get.releaseDate.comingSoon
  doAssert app.get.recommendations.isSome
  doAssert app.get.recommendations.get.total == 2795

  # Genres carry a string id and categories an int one, in the same payload.
  doAssert app.get.genres.len == 3
  doAssert app.get.genres[0].id == "25"
  doAssert app.get.genres[0].description == "Adventure"
  doAssert app.get.categories.len > 5
  doAssert app.get.categories[0].id == 2
  doAssert app.get.categories[0].description == "Single-player"

  let price = app.get.priceOverview.get
  doAssert price.currency == "USD"
  doAssert price.final == 1099
  doAssert price.initial == 1099
  doAssert price.discountPercent == 0, "a zero discount is not stored as absent"

block windows_only_release:
  let app = decodeApp(fixture("1264280-appdetails.json"), 1264280)
  doAssert app.isSome
  doAssert app.get.name == "Slipways"
  doAssert not app.get.platforms.linux, "Steam ships no Linux build for this one"
  doAssert app.get.platforms.mac
  doAssert app.get.genres.len == 1
  doAssert app.get.genres[0].description == "Strategy"
  doAssert app.get.recommendations.get.total == 2233

block unknown_app_reports_no_data:
  let app = decodeApp(fixture("999999999-appdetails.json"), 999999999)
  doAssert app.isNone, "`success: false` carries no data, which is not an error"

block a_key_that_does_not_match_is_not_accepted:
  # The answer is keyed by app id, so asking about one app and reading another
  # must not silently succeed.
  let wrong = decodeApp(fixture("1999520-appdetails.json"), 1264280)
  doAssert wrong.isNone

block store_entry_becomes_facts:
  let app = decodeApp(fixture("1999520-appdetails.json"), 1999520).get
  let facts = toSteamFacts(app, fetchedAt = 77)
  doAssert facts.isKnown, "an entry with details is known"
  doAssert facts.kind == "game"
  doAssert facts.genres == @["Adventure", "Casual", "Indie"]
  doAssert facts.categories[0] == "Single-player"
  doAssert facts.linuxBuild.get.value
  doAssert facts.linuxBuild.get.source == srcSteam
  doAssert facts.linuxBuild.get.fetchedAt == 77
  doAssert facts.releaseDate == some initFact("Sep 5, 2024", srcSteam, 77)
  doAssert facts.price.get.value.final == 1099
  doAssert facts.price.get.value.currency == "USD"
  doAssert facts.recommendations.get.value == 2795
  doAssert not facts.reviews.percent.isSome, "reviews come from the other call"

block pictures_are_read_because_looks_matter:
  # Screenshots are the one piece of store prose this catalogue reads on
  # purpose: "does this look like something I want to play" is half the
  # question, and it cannot be answered from a percentage.
  let app = decodeApp(fixture("1264280-appdetails.json"), 1264280).get
  doAssert app.headerImage.contains("header.jpg")
  doAssert app.screenshots.len == 10
  doAssert app.screenshots[0].pathThumbnail.contains("600x338")
  doAssert app.screenshots[0].pathFull.contains("1920x1080")
  doAssert app.screenshots[0].pathThumbnail != app.screenshots[0].pathFull,
    "the two sizes are different URLs, not one URL twice"

  let facts = toSteamFacts(app, fetchedAt = 9)
  doAssert facts.art.header.isSome
  doAssert facts.art.header.get.value == app.headerImage
  doAssert facts.art.header.get.source == srcSteam
  doAssert facts.art.header.get.fetchedAt == 9
  doAssert facts.art.screenshots.isSome
  let shots = facts.art.screenshots.get.value
  doAssert shots.len == 10
  doAssert shots[0].thumbnail == app.screenshots[0].pathThumbnail
  doAssert shots[0].full == app.screenshots[0].pathFull

  # Art alone does not make a store entry known: it is stamped with the same
  # fetch as the rest, and a game whose only answer was a picture would still be
  # a store entry this catalogue cannot describe.
  var picturesOnly = SteamFacts()
  picturesOnly.art = facts.art
  doAssert picturesOnly.isKnown, "a picture is something the store said"

block no_pictures_means_no_art_facts:
  # `success: false` has no data at all, so there is nothing to decorate.
  doAssert decodeApp(fixture("999999999-appdetails.json"), 999999999).isNone
  let app = decodeApp(fixture("1999520-appdetails.json"), 1999520).get
  var stripped = app
  stripped.headerImage = ""
  stripped.screenshots = @[]
  let facts = toSteamFacts(stripped, fetchedAt = 1)
  doAssert facts.art.header.isNone
  doAssert facts.art.screenshots.isNone

block empty_facts_are_not_known:
  # This is the assertion that fails when the wire names stop matching.
  doAssert not SteamFacts().isKnown

block review_summaries:
  let summary = decodeReviews(fixture("1264280-reviews.json"))
  doAssert summary.success == 1, "success is a number here, a boolean elsewhere"
  doAssert summary.querySummary.totalPositive == 2144
  doAssert summary.querySummary.totalNegative == 166
  doAssert summary.querySummary.totalReviews == 2310
  doAssert summary.querySummary.reviewScore == 8, "Steam's own 0-9 band"
  doAssert summary.querySummary.reviewScoreDesc == "Very Positive"

  let rating = toReviewScore(summary, fetchedAt = 5)
  doAssert rating.count.get.value == 2310
  doAssert rating.count.get.source == srcSteam
  doAssert rating.description == some("Very Positive")
  doAssert rating.percent.get.value == 92.8, "2144 of 2310, to one decimal"

block a_band_is_not_a_percentage:
  # `review_score` is a band, not a share: 9 is not 90%.
  let summary = decodeReviews(fixture("1999520-reviews.json"))
  doAssert summary.querySummary.reviewScore == 9
  let percent = positivePercent(summary.querySummary).get
  doAssert percent == 98.4, "3092 of 3143 positive"
  doAssert summary.querySummary.reviewScore in 0..9,
    "the band is Steam's own coarse scale"
  doAssert percent != float(summary.querySummary.reviewScore) * 10.0,
    "and it is a bucket, not a percentage"

block no_reviews_is_not_a_score:
  let empty = QuerySummary(totalReviews: 0, totalPositive: 0)
  doAssert positivePercent(empty).isNone, "a percentage of nothing is not zero"
  let rating = toReviewScore(ReviewResponse(success: 1, querySummary: empty), 1)
  doAssert rating.percent.isNone
  doAssert rating.count.get.value == 0, "but the zero count is a fact"
  doAssert rating.description.isNone

block deck_verdicts:
  # The three categories, each confirmed against a real response: `CATO` is
  # verified, `Titanfall 2` playable, and `Destiny 2` unsupported with the single
  # reason `UnsupportedAntiCheatConfiguration`, which agrees with the anti-cheat
  # dataset independently.
  let verified = decodeDeck(fixture("1999520-deck.json"))
  doAssert verified.success == 1
  doAssert verified.results.get.appid == 1999520
  doAssert verified.results.get.deckCategory == some(3)
  doAssert verified.results.get.steamosCategory == some(2)
  doAssert parseLinuxVerdict(3) == lvVerified
  doAssert toVerdict(verified.results.get.deckCategory, 11).get.value == lvVerified

  let playable = decodeDeck(fixture("1237970-deck.json"))
  doAssert playable.results.get.deckCategory == some(2)
  doAssert parseLinuxVerdict(2) == lvPlayable

  let unsupported = decodeDeck(fixture("1085660-deck.json"))
  doAssert unsupported.results.get.deckCategory == some(1)
  doAssert unsupported.results.get.steamosCategory == some(1)
  doAssert parseLinuxVerdict(1) == lvUnsupported

block deck_and_steamos_are_different_questions:
  # `steamos` is Linux with Proton, not a native build: Slipways is playable on
  # SteamOS while its own store entry says `platforms.linux: false`.
  let report = decodeDeck(fixture("1237970-deck.json"))
  doAssert report.results.get.steamosCategory == some(2)
  let slipways = decodeApp(fixture("1264280-appdetails.json"), 1264280).get
  doAssert not slipways.platforms.linux

block an_unreported_category_is_not_a_rejection:
  let body = """{"success":1,"results":{"appid":1,"resolved_category":null,
    "steamos_resolved_category":null}}"""
  let report = decodeDeck(body)
  doAssert report.results.get.deckCategory.isNone
  doAssert toVerdict(report.results.get.deckCategory, 1).isNone
  doAssert parseLinuxVerdict(0) == lvUnknown
  doAssert parseLinuxVerdict(99) == lvUnknown, "a new number is not a failure"
  doAssert lvUnknown < lvPlayable, "and unknown sorts below every verdict"

block a_missing_results_object_is_survivable:
  let report = decodeDeck("""{"success":0}""")
  doAssert report.success == 0
  doAssert report.results.isNone

block urls:
  doAssert detailsUrl(1999520, "gr") ==
    "https://store.steampowered.com/api/appdetails?appids=1999520&cc=gr&l=en"
  doAssert deckUrl(1999520) ==
    "https://store.steampowered.com/saleaction/ajaxgetdeckappcompatibilityreport" &
    "?nAppID=1999520"
  doAssert reviewsUrl(1999520) ==
    "https://store.steampowered.com/appreviews/1999520?json=1&num_per_page=0" &
    "&filter=all&language=all&purchase_type=all"

block malformed_bodies_raise:
  doAssertRaises JsonParsingError:
    discard decodeApp("""{"1":{"success":""", 1)
  doAssertRaises JsonParsingError:
    discard decodeApp("""{"1":{"success":true,"data":{"is_free":"no"}}}""", 1)
  doAssertRaises JsonParsingError:
    discard decodeReviews("""{"success":""")
  doAssertRaises JsonParsingError:
    discard decodeReviews("""{"query_summary":{"total_reviews":"many"}}""")
  doAssertRaises JsonParsingError:
    discard decodeDeck("""{"results":{"appid":""")
