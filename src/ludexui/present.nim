## Decision-relevant wording for the window, independent of GTK and I/O.
## Missing evidence produces no label. Compatibility claims identify what is
## known; review percentages retain their sample size rather than implying certainty.

import std/[options, strutils]

import ludexcore/[models, taste]

func escapeMarkup*(text: string): string =
  ## Pango markup for a row label. libadwaita parses `AdwPreferencesRow:title` and
  ## `AdwActionRow:subtitle` as markup and *blanks* the label on a parse error,
  ## logging only a warning, so a tag like "Point & Click" would silently vanish.
  ## Everything catalogue-derived that reaches a row goes through here first.
  result = text.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"))

func capitalized(value: string): string =
  result = value
  if result.len > 0:
    result[0] = result[0].toUpperAscii

func verdictLabel*(verdict: Verdict): string =
  ## The wire spelling stays unchanged; buttons use a readable initial capital.
  result = capitalized($verdict)

func formatPercent(value: float): string =
  ## Integer rounding avoids formatFloat's trailing dot at zero precision.
  $int(value * 100.0 + 0.5) & "%"

func gameGenres*(store: SteamFacts): string =
  ## Two strong tags describe the experience; genres cover untagged games.
  var labels: seq[string]
  if store.tags.isSome:
    labels = store.tags.get.value.topTags(2)
  if labels.len == 0:
    for genre in store.genres:
      if genre.len > 0 and genre notin labels and labels.len < 2:
        labels.add genre
  result = labels.join(" · ")

func compatibilitySummary*(release: Release; play: Option[Playability];
                           store: SteamFacts): string =
  ## Name evidence rather than promise successful play. Known blockers take
  ## precedence over the existence of a native build or an older positive tier.
  let known = play.get(Playability())
  if known.antiCheat.isSome and blocksLinux(known.antiCheat.get.value):
    return "Anti-cheat blocks play on Linux"
  if known.tier.isSome and known.tier.get.value == ptBorked:
    return "Reported not working on ProtonDB"
  if known.antiCheat.isSome and known.antiCheat.get.value == acPlanned:
    return "Linux anti-cheat support is planned, but not available yet"
  if release.runtime in {rkNative, rkBoth} or
      (known.nativeBuild.isSome and known.nativeBuild.get.value) or
      (store.linuxBuild.isSome and store.linuxBuild.get.value):
    return "A native Linux version is available"
  if known.tier.isSome and known.tier.get.value != ptUnknown:
    result = "ProtonDB: " & $known.tier.get.value
    if known.reportCount.isSome:
      let count = known.reportCount.get.value
      result.add " · " & $count & (if count == 1: " report" else: " reports")

func groupDigits(value: int): string =
  ## Thousands separators, so a sample size can be read at a glance.
  let digits = $value
  for index, character in digits:
    if index > 0 and (digits.len - index) mod 3 == 0:
      result.add ','
    result.add character

func reviewSummary*(store: SteamFacts): string =
  ## Steam's own summary word reads faster than the number, and a percentage
  ## only means something alongside its sample size. The three are joined when
  ## they exist, and a lone count is still better than nothing.
  if store.reviews.count.isSome and store.reviews.count.get.value > 0:
    let count = store.reviews.count.get.value
    let description = store.reviews.description.get("")
    let percent = if store.reviews.percent.isSome:
      formatPercent(store.reviews.percent.get.value / 100.0) else: ""
    if description.len > 0:
      result = description
      if percent.len > 0:
        result.add " · " & percent
    elif percent.len > 0:
      result = percent & " positive"
    if result.len > 0:
      result.add " · "
    result.add groupDigits(count) &
      (if count == 1: " review" else: " reviews")

func steamUrl*(release: Release): string =
  ## Catalogue identity supports a store link, not a claim of installation.
  let appid = release.appid.get(0)
  if appid > 0:
    result = "https://store.steampowered.com/app/" & $appid & "/"

type
  CompatibilityTone* = enum
    ## How strongly the evidence supports playing a game on Linux. The window
    ## turns this into an Adwaita semantic color, never into a claim of its own.
    toneUnknown, toneNegative, toneCaution, toneNeutral, tonePositive

func linuxSupport(release: Release; play: Option[Playability];
                  store: SteamFacts): tuple[supported: bool, blocked: bool,
                                           planned: bool] =
  ## The three independent facts every compatibility label is built from.
  let known = play.get(Playability())
  result.blocked = known.antiCheat.isSome and
    blocksLinux(known.antiCheat.get.value)
  result.planned = known.antiCheat.isSome and
    known.antiCheat.get.value == acPlanned
  result.supported = release.runtime in {rkNative, rkBoth} or
    (known.nativeBuild.isSome and known.nativeBuild.get.value) or
    (store.linuxBuild.isSome and store.linuxBuild.get.value)

func compatibilityTone*(release: Release; play: Option[Playability];
                        store: SteamFacts): CompatibilityTone =
  ## Color follows the strongest known fact, blockers first.
  let facts = linuxSupport(release, play, store)
  if facts.blocked:
    return toneNegative
  let known = play.get(Playability())
  if known.tier.isSome and known.tier.get.value == ptBorked:
    return toneNegative
  if facts.planned:
    return toneCaution
  if facts.supported:
    return tonePositive
  if known.tier.isSome:
    case known.tier.get.value
    of ptPlatinum, ptGold: result = tonePositive
    of ptSilver: result = toneNeutral
    of ptUnknown: result = toneUnknown
    else: result = toneCaution
  else:
    result = toneUnknown

func releasedYear*(store: SteamFacts): string =
  ## Steam's date is a display string, so take the year and drop the rest.
  if store.releaseDate.isSome:
    var run = ""
    for character in store.releaseDate.get.value:
      if character in {'0'..'9'}:
        run.add character
        if run.len == 4:
          result = run
      else:
        run.setLen(0)

func gameSubtitle*(store: SteamFacts): string =
  ## Genres plus the year: the one line that describes the game without a table.
  var parts: seq[string]
  let genres = gameGenres(store)
  if genres.len > 0:
    parts.add genres
  let year = releasedYear(store)
  if year.len > 0:
    parts.add year
  result = parts.join(" · ")

func currencySymbol(code: string): string =
  ## The store reports a currency code; a price reads better as a symbol. Codes
  ## without one keep their code rather than guessing at a glyph.
  case code
  of "USD": "$"
  of "EUR": "€"
  of "GBP": "£"
  of "JPY": "¥"
  of "CNY": "¥"
  of "RUB": "₽"
  of "BRL": "R$"
  of "CAD": "CA$"
  of "AUD": "A$"
  of "NZD": "NZ$"
  of "MXN": "MX$"
  of "INR": "₹"
  of "KRW": "₩"
  of "TRY": "₺"
  of "PLN": "zł"
  of "CHF": "CHF"
  of "SEK", "NOK", "DKK": "kr"
  else: ""

func priceText*(store: SteamFacts): string =
  ## A price without a currency is not a price.
  if store.isFree:
    return "Free"
  if store.price.isSome:
    let price = store.price.get.value
    let amount = formatFloat(float(price.final) / 100.0, ffDecimal, 2)
    let symbol = currencySymbol(price.currency)
    if symbol.len > 0:
      result = symbol & amount
    elif price.currency.len > 0:
      result = amount & " " & price.currency
    else:
      result = amount

func criticsSummary*(store: SteamFacts): string =
  ## A press aggregate, named so the number is not mistaken for a player score.
  if store.critics.isSome:
    result = $store.critics.get.score.value & " on Metacritic"

func criticsUrl*(store: SteamFacts): string =
  ## Where the press score came from, when the store says.
  if store.critics.isSome and store.critics.get.url.isSome:
    result = store.critics.get.url.get

func decodeEntity(entity: string): string =
  ## The handful of HTML entities the store actually uses in a one-line pitch.
  case entity
  of "amp": "&"
  of "quot": "\""
  of "apos", "#39", "#x27": "'"
  of "lt": "<"
  of "gt": ">"
  of "nbsp": " "
  of "trade": "™"
  of "hellip": "…"
  of "mdash": "—"
  of "ndash": "–"
  of "rsquo", "#x2019": "’"
  of "lsquo", "#x2018": "‘"
  of "ldquo", "#x201C": "“"
  of "rdquo", "#x201D": "”"
  else: ""

func plainText*(text: string): string =
  ## Steam's prose carries a little HTML and HTML entities and the window shows it
  ## in a plain label, so tags are dropped and entities decoded. Runs of
  ## whitespace collapse to one space, because the source is full of newlines.
  ## An unterminated `<` stays as text instead of swallowing the rest.
  var index = 0
  while index < text.len:
    let character = text[index]
    if character == '<':
      var close = index
      while close < text.len and text[close] != '>':
        inc close
      if close < text.len:
        result.add ' '
        index = close + 1
      else:
        result.add character
        inc index
    elif character == '&':
      let semicolon = text.find(';', index)
      if semicolon > index and semicolon - index <= 8:
        let decoded = decodeEntity(text[index + 1 ..< semicolon])
        if decoded.len > 0:
          result.add decoded
          index = semicolon + 1
        else:
          result.add character
          inc index
      else:
        result.add character
        inc index
    else:
      result.add character
      inc index
  var collapsed: string
  var pendingSpace = false
  for character in result:
    if character in {' ', '\n', '\r', '\t'}:
      pendingSpace = true
    else:
      if pendingSpace and collapsed.len > 0:
        collapsed.add ' '
      pendingSpace = false
      collapsed.add character
  result = collapsed

func pitch*(store: SteamFacts): string =
  ## The store's own one-line description, as plain readable text.
  plainText(store.shortDescription)

func firstOf*(values: seq[string]): string =
  ## The first non-empty entry, for developer and publisher lists.
  for value in values:
    if value.len > 0:
      return value

func tagSummary*(store: SteamFacts; limit: int): string =
  ## Tags carry the flavour of a game better than its store genres.
  if store.tags.isSome:
    var labels: seq[string]
    for tag in store.tags.get.value.topTags(limit):
      labels.add tag
    result = labels.join(" · ")
