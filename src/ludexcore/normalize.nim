## Token and string normalization for listing rows.
##
## Every function here is pure string work with no platform dependency, so the
## module stays usable from the browser front end as well as the CLI and the
## desktop build.

import std/[options, strutils]

import models

const LegacySuffix* = "-jc141" ## marker of legacy rows, as in `Isle.of.Swaps-jc141`

const DroppedChars* = {'\''} ## removed outright: `Schrödinger's` -> `schrödingers`

const
  BreakerChars* = {'.', ',', ':', ';', '!', '?', '"', '/', '\\', '(', ')', '[',
                   ']', '{', '}', '&', '+', '_', '-', '*', '#', '%', '@', '~',
                   '|', '<', '>', '='} ## fold to a word separator

func isSeparatorToken*(token: string): bool =
  ## True for the stray `------` markdown separator row.
  token.len >= 3 and token.allCharsInSet({'-', ' '})

func isBuildToken*(token: string): bool =
  ## True for build ids such as `b15946357` and `b13697029/1.3.8`.
  if not token.startsWith("b") or token.len < 3:
    return false
  var i = 1
  var digits = 0
  while i < token.len and token[i] in {'0'..'9'}:
    inc i
    inc digits
  result = digits >= 5 and (i == token.len or token[i] == '/')

func isVersionPart(part: string): bool =
  if part.len == 0 or part[0] notin {'0'..'9'}:
    return false
  result = true
  for ch in part:
    case ch
    of '0'..'9', '.', 'a'..'z', 'A'..'Z': discard
    else: return false

func isVersionToken*(token: string): bool =
  ## True for `1.3.8`, `2.0.11.0`, `1.41a` and version pairs such as
  ## `1.1.0.0/1.0.13`.
  result = true
  for part in token.split('/'):
    if not isVersionPart(part):
      return false

func isDecimalNumber*(text: string): bool =
  ## True for digit strings holding at most one dot, such as `1.3` or `44`.
  var dots = 0
  var digits = 0
  for ch in text:
    case ch
    of '0'..'9': inc digits
    of '.': inc dots
    else: return false
  result = digits > 0 and dots <= 1

func isIsoPart*(part: string): bool =
  ## True for an ISO language code such as `ENG`, `SPA` or `JPN`.
  part.len >= 2 and part.len <= 3 and part.allCharsInSet({'A'..'Z'})

func isMultiPart(part: string): bool =
  ## True for the packager's `MULTiN` marker, with or without the count.
  if not part.startsWith("MULTi"):
    return false
  part.len == 5 or part[5..^1].allCharsInSet({'0'..'9'})

func isLanguageToken*(token: string): bool =
  ## True for `MULTi11`, `ENG`, `ENG/JPN`, `MULTi9/ENG` and `MULTi12/7`.
  ##
  ## `MULTi11` is a language *count*, not a set, so it is kept verbatim and
  ## never expanded into which eleven languages those are. A bare number is
  ## only accepted directly after a `MULTiN` marker, where it continues that
  ## count rather than naming a language.
  var parts = 0
  var afterMulti = false
  for part in token.split('/'):
    if isMultiPart(part):
      afterMulti = true
    elif isIsoPart(part):
      afterMulti = false
    elif afterMulti and isDecimalNumber(part):
      afterMulti = false
    else:
      return false
    inc parts
  result = parts > 0 and token.len > 0

func parseRuntime*(token: string): Option[RuntimeKind] =
  ## Decodes `GNU/Linux Wine`, `GNU/Linux Native` and `GNU/Linux Native/Wine`.
  const prefix = "GNU/Linux "
  if not token.startsWith(prefix):
    return none(RuntimeKind)
  case token[prefix.len..^1]
  of "Wine": some(rkWine)
  of "Native": some(rkNative)
  of "Native/Wine", "Wine/Native": some(rkBoth)
  else: none(RuntimeKind)

func parseRuntimeName*(name: string): Option[RuntimeKind] =
  ## Decodes an enum spelling such as `native`, `wine` or `both`, which is how
  ## runtimes arrive from a command line or a query string.
  for runtime in RuntimeKind:
    if $runtime == name:
      return some(runtime)

func parseSizeBytes*(size: string): Option[int64] =
  ## Decodes `124 MB`, `1.3 GB` and `44.5 GB`.
  ##
  ## `0 B` marks an unknown size in the source data, so it yields `none`
  ## instead of a misleading zero.
  let parts = size.splitWhitespace
  if parts.len != 2 or not isDecimalNumber(parts[0]):
    return none(int64)
  let value = parseFloat(parts[0])
  if value <= 0:
    return none(int64)
  let scale =
    case parts[1].toUpperAscii
    of "B": 1'i64
    of "KB", "KIB": 1024'i64
    of "MB", "MIB": 1024'i64 * 1024
    of "GB", "GIB": 1024'i64 * 1024 * 1024
    of "TB", "TIB": 1024'i64 * 1024 * 1024 * 1024
    else: 0'i64
  if scale == 0:
    return none(int64)
  some(int64(value * float(scale)))

func parseSizeLoose*(text: string): Option[int64] =
  ## Like `parseSizeBytes`, but also accepts `5GB` without a separating space.
  ##
  ## This is the shape sizes arrive in from a command line, where the space has
  ## to be quoted.
  let direct = parseSizeBytes(text)
  if direct.isSome:
    return direct
  var split = text.len
  while split > 0 and text[split - 1] in {'A'..'Z', 'a'..'z'}:
    dec split
  if split == 0 or split == text.len:
    return none(int64)
  parseSizeBytes(text[0..<split] & " " & text[split..^1])

func foldChar*(ch: char): string =
  ## Folds one character to its normalized form: a lowercase character, a
  ## space, or nothing.
  ##
  ## Bytes outside ASCII pass through unchanged, so accented titles keep the
  ## spelling used by the upstream sources they are matched against.
  if ch in DroppedChars:
    result = ""
  elif ch in BreakerChars or ch in {'\t', '\n', '\r'}:
    result = " "
  else:
    result = newString(1)
    result[0] = toLowerAscii(ch)

func normalizeTitle*(title: string): string =
  ## Builds the comparison key used for matching only, never for display.
  ## Case- and punctuation-folded, whitespace-collapsed and stripped of a
  ## leading article, so `The Cosmic Wheel Sisterhood` matches `Cosmic Wheel
  ## Sisterhood`.
  var folded = newStringOfCap(title.len)
  for ch in title:
    folded.add(foldChar(ch))
  folded = folded.splitWhitespace.join(" ")
  for article in ["the ", "a ", "an "]:
    if folded.startsWith(article):
      return folded[article.len..^1]
  result = folded

func stripLegacySuffix*(name: string): Option[string] =
  ## Turns `Isle.of.Swaps-jc141` into `Isle of Swaps`.
  if not name.endsWith(LegacySuffix):
    return none(string)
  let stem = name[0..<name.len - LegacySuffix.len]
  if stem.len == 0:
    return none(string)
  some(stem.replace('.', ' '))
