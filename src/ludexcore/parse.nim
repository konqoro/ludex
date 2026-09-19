## Parsing of listing table rows into `Release` values.
##
## The listing table is a markdown table with three cells per row:
##
## .. code-block:: text
##
##   | Name | Size | Magnet |
##
## The `Name` cell is not uniform. Three shapes appear in the real data:
##
## .. code-block:: text
##
##   A) legacy dotted, title only:
##      Isle.of.Swaps-jc141
##   B) canonical:
##      Slipways - b15946357 - MULTi6 - GNU/Linux Wine - jc141 (Appid=1264280)
##   C) title containing " - ":
##      Disco Elysium - The Final Cut - b23762888 - MULTi13 - GNU/Linux Wine - jc141 (Appid=632470)
##
## Metadata fields vary in order and in presence, so they are matched by
## pattern walking inwards from the `jc141` marker and never by position.

import std/[options, strutils]

import models, normalize

const AppIdPrefix = "Appid="
const InfoHashPrefix = "btih:"
const PackagerMarker = "jc141"
const InfoHashLength = 40

const HtmlEntities = [("&#039;", "'"), ("&#39;", "'"), ("&quot;", "\""),
                      ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")]

const NoiseChars* = {'*', ' ', '\t'} ## trailing decoration the table sometimes adds

func trimNoise*(text: string): string =
  ## Removes trailing decoration such as the `*` some rows end with.
  var last = text.len - 1
  while last >= 0 and text[last] in NoiseChars:
    dec last
  result = text[0..last]

func unescapeHtml*(text: string): string =
  ## Resolves the handful of HTML entities the upstream table emits.
  ##
  ## `&amp;` is resolved last so that `&amp;#039;` cannot be double-decoded.
  result = text
  for (entity, plain) in HtmlEntities:
    result = result.replace(entity, plain)

func takeTrailer*(name: string, trailer: var string): string =
  ## Fallback for rows without a packager marker.
  ##
  ## Peels every trailing parenthesized group off `name`, scanning backwards
  ## with a depth counter so nested parens stay intact, and returns the
  ## remaining core text. The peeled text is appended to `trailer`.
  result = name.strip
  while result.endsWith(")"):
    var depth = 0
    var opening = -1
    var i = result.len - 1
    while i >= 0:
      if result[i] == ')':
        inc depth
      elif result[i] == '(':
        dec depth
        if depth == 0:
          opening = i
          break
      dec i
    if opening < 0:
      break
    trailer = result[opening + 1..<result.len - 1] & " " & trailer
    result = result[0..<opening].strip

func parseAppId*(text: string): Option[int] =
  ## Extracts `N` from an `Appid=N` fragment. Steam app ids are seven digits,
  ## so anything longer is treated as noise rather than parsed.
  let at = text.find(AppIdPrefix)
  if at < 0:
    return none(int)
  var i = at + AppIdPrefix.len
  var digits = ""
  while i < text.len and text[i] in {'0'..'9'} and digits.len < 9:
    digits.add(text[i])
    inc i
  if digits.len == 0:
    return none(int)
  some(parseInt(digits))

func parseInfoHash*(link: string): Option[string] =
  ## Extracts the 40 hex character info hash from a magnet link.
  let at = link.find(InfoHashPrefix)
  if at < 0:
    return none(string)
  var i = at + InfoHashPrefix.len
  var digits = ""
  while i < link.len and link[i] in {'0'..'9', 'a'..'f', 'A'..'F'}:
    digits.add(link[i])
    inc i
  if digits.len != InfoHashLength:
    return none(string)
  some(digits.toLowerAscii)

func stripAppIdGroup*(text: string): string =
  ## Removes the `(Appid=N)` group from `text` and keeps the rest.
  let at = text.find(AppIdPrefix)
  if at < 0:
    return text
  var opening = at
  while opening > 0 and text[opening - 1] != '(':
    dec opening
  if opening == 0:
    return text
  dec opening
  var closing = at
  while closing < text.len and text[closing] != ')':
    inc closing
  if closing >= text.len:
    result = text[0..<opening]
  else:
    result = text[0..<opening] & text[closing + 1..^1]

func classifyTailToken(release: var Release, token: string): bool =
  ## Consumes one metadata token from the right end of the name cell.
  ##
  ## Returns false for the first token that is not metadata, which marks where
  ## the title ends.
  if token == PackagerMarker or token.len == 0:
    return true
  let runtime = parseRuntime(token)
  if runtime.isSome:
    release.runtime = runtime.get
    return true
  if isLanguageToken(token):
    release.langToken = some(token)
    var allIso = true
    for part in token.split('/'):
      if not isIsoPart(part):
        allIso = false
    if allIso:
      release.langs = token.split('/')
    return true
  if isBuildToken(token):
    let parts = token.split('/')
    release.buildId = some(parts[0])
    if parts.len > 1:
      release.version = some(parts[1])
    return true
  if isVersionToken(token):
    release.version = some(token)
    return true
  false

func markCollection(release: var Release, trailer: string) =
  ## Flags packs whose trailing text carries nested releases, such as
  ## `David Szymanski Collection ... (Butcher's Creek - b17121038/1.151 ...)`.
  let parts = trailer.split(" - ")
  var nestedBuild = false
  for part in parts:
    let tokens = part.splitWhitespace
    if tokens.len > 0 and isBuildToken(tokens[0]):
      nestedBuild = true
  if nestedBuild or (release.appid.isNone and parts.len > 1):
    release.pack = pkCollection

func parseName*(name: string, lineNumber: int): Release =
  ## Splits one `Name` cell into title, metadata and packager annotations.
  result = initRelease(lineNumber)
  let unescaped = unescapeHtml(name).strip

  # The packager marker is a far more reliable anchor than "peel trailing
  # parenthesized groups": appended content is not always wrapped in parens and
  # not always last, as in
  # `... jc141 (Appid=3198540) Dungeon Antiqua 2`.
  var core = ""
  var trailer = ""
  let anchor = unescaped.find(PackagerMarker)
  if anchor >= 0:
    core = unescaped[0..<anchor]
    trailer = unescaped[anchor..^1]
  else:
    core = takeTrailer(unescaped, trailer)

  core = trimNoise(core.strip)
  while core.endsWith("-"):
    core = trimNoise(core[0..<core.len - 1])

  result.appid = parseAppId(trailer)
  if result.appid.isNone:
    result.appid = parseAppId(core)

  if trailer.len > 0:
    markCollection(result, trailer)
    let markerAt = trailer.find(PackagerMarker)
    let appended = if markerAt >= 0: trailer[markerAt + PackagerMarker.len..^1]
                   else: trailer
    let nested = stripAppIdGroup(appended).strip
    if nested.len > 0:
      result.nested = @[nested]

  if core.len == 0:
    result.warnings.add("empty-core")
    core = unescaped

  if " - " notin core:
    # Rows without metadata are either dotted (`Isle.of.Swaps-jc141`) or plain
    # (`Arco-jc141`). Both keep the title and are flagged, because a missing
    # runtime token is exactly what makes them need a Steam lookup later.
    if core.find('.') >= 0:
      result.title = core.replace('.', ' ')
    else:
      result.title = core
    result.warnings.add("no-metadata")
  else:
    var fields: seq[string] = @[]
    for field in core.split(" - "):
      fields.add(field.strip)
    # `last > 0` guarantees one field survives as the title: `FEZ - 1.12 -
    # MULTi9 - GNU/Linux Wine` would otherwise consume its own title, since
    # `FEZ` is indistinguishable from an ISO language code.
    var last = fields.len - 1
    while last > 0 and classifyTailToken(result, fields[last]):
      dec last
    result.title = fields[0..last].join(" - ")
    if result.runtime == rkUnknown:
      result.warnings.add("runtime-unknown")

  result.title = trimNoise(result.title.strip)
  result.titleNorm = normalizeTitle(result.title)
  if result.titleNorm.len == 0:
    result.warnings.add("empty-title")

func splitCells*(line: string): seq[string] =
  ## Splits a table row into its trimmed cells.
  var body = line.strip
  if body.startsWith("|"):
    body = body[1..^1]
  if body.endsWith("|"):
    body = body[0..<body.len - 1]
  for cell in body.split('|'):
    result.add(cell.strip)

func parseTableLine*(line: string, lineNumber: int): Release =
  ## Parses one line. The returned `rowKind` says whether it held a game.
  result = initRelease(lineNumber)
  let trimmed = line.strip
  if trimmed.len == 0 or not trimmed.startsWith("|"):
    result.rowKind = rkHeader
    return
  let cells = splitCells(trimmed)
  if cells.len < 3:
    result.rowKind = rkHeader
    return
  if cells[0] == "Name" and cells[1] == "Size":
    result.rowKind = rkHeader
    return
  if isSeparatorToken(cells[0]):
    result.rowKind = rkSeparator
    return
  result = parseName(cells[0], lineNumber)
  result.sizeBytes = parseSizeBytes(cells[1])
  result.infoHash = parseInfoHash(cells[^1])

func parseTable*(content: string): seq[Release] =
  ## Parses a whole listing table, header and separator rows included.
  var lineNumber = 0
  for line in content.splitLines:
    inc lineNumber
    if line.strip.len > 0:
      result.add(parseTableLine(line, lineNumber))
