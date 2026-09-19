## Rating storage for `ludex rate`.
##
## Ratings are the one file the user authors by hand through the CLI, so the
## format stays a flat JSON object per line and unknown fields are skipped, which
## keeps a hand-edited file loadable.

import std/strutils

import brian

import taste

const
  KeyAppId = "appid"
  KeyTitle = "title"
  KeyVerdict = "verdict"
  KeyRatedAt = "ratedAt"

proc writeJson*(w: var JsonWriter; value: Rating) =
  ## Writes one rating.
  w.beginObject()
  w.writeField(KeyAppId)
  writeJson(w, value.appid)
  w.writeField(KeyTitle)
  writeJson(w, value.title)
  w.writeField(KeyVerdict)
  writeJson(w, value.verdict)
  w.writeField(KeyRatedAt)
  writeJson(w, value.ratedAt)
  w.endObject()

proc readJson*(dst: var Rating; r: var JsonReader; options: JsonReadOptions) =
  ## Reads one rating, named field by field like every other reader here.
  r.beginObject()
  var field: JsonField
  while r.nextField(field):
    if field == KeyAppId:
      readJson(dst.appid, r, options)
    elif field == KeyTitle:
      readJson(dst.title, r, options)
    elif field == KeyVerdict:
      readJson(dst.verdict, r, options)
    elif field == KeyRatedAt:
      readJson(dst.ratedAt, r, options)
    elif options.unknownFields == ufReject:
      r.raiseExpected("a known rating field, got \"" & field.toString() & "\"")
    else:
      r.skipValue()

func encodeTaste*(taste: Taste): string =
  ## Encodes the profile as one JSON object per rating, ordered by app id.
  for rating in sortedRatings(taste):
    result.add toJson(rating)
    result.add '\n'

type
  TasteLoad* = object
    taste*: Taste ## ratings that decoded
    failures*: seq[string] ## `<line>: <reason>` for lines that did not

proc decodeTaste*(content: string; unknownFields = ufSkip): TasteLoad
    {.raises: [].} =
  ## Decodes a ratings file, recording a failure per unusable line.
  var options = defaultJsonReadOptions()
  options.unknownFields = unknownFields
  var lineNumber = 0
  for line in content.splitLines:
    inc lineNumber
    if line.strip.len > 0:
      var rating = Rating()
      var failure = ""
      # Both branches are recoverable: the batch records the problem and keeps
      # going. `JsonParsingError` is the child, so it is matched first.
      try:
        fromJson(line, rating, options)
        if rating.appid > 0:
          result.taste.ratings.add rating
        else:
          failure = "rating without an app id"
      except JsonParsingError as error:
        failure = error.msg
      except CatchableError as error:
        failure = "cannot decode: " & error.msg
      if failure.len > 0:
        result.failures.add($lineNumber & ": " & failure)
