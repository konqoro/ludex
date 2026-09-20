## Downloading the store's pictures into the local art cache.
##
## The cache *layout* is `ludexcore/art.nim`, which is pure; this is the
## downloader that fills it, named after the cache it fills so the two modules do
## not share a name.
##
## Why this is a CLI job and not a window job: a picture is 50-200 KB and a
## catalogue sweep is thousands of them, so the window would lose its "works
## offline" property the moment it rendered a list. Instead the CLI fetches,
## caches and writes files, and the window only ever opens a local path.
##
## Why one sweep and not one picture at a time: `fetch.nim`'s batch primitive
## streams, so this walks the store once to plan — the URLs and file names are
## cheap strings — and then writes each body as it arrives and drops it. Memory
## is bounded by the client's window instead of by the size of the catalogue,
## which is what turns "download a few thousand pictures" from a gigabyte of
## bodies into a bounded operation. The same client, cache and rate limit as
## every other fetch, so re-running is free and safe: already-present files are
## skipped while planning, and `--limit` stays a resumable cursor.
##
## A failure is recorded against the game rather than aborting the run. A refused
## status is a failure here, unlike a store `404`: a missing picture is missing
## art, while a missing Steam store entry is an answer about the game.
##
## The pictures are the only thing downloaded outside `data/cache` proper: the
## cache holds the raw responses, the art directory holds the decoded files the
## UI reads. Both are generated and git-ignored.

import std/[options, os]

import ludexcore/[art, models]

import ./fetch

const
  DefaultArtDelayMs* = 100
    ## The CDN is not the store API, so the store's 1600 ms floor would only make
    ## a sweep slow. Still a floor, because a sweep is a burst by nature.

type
  ArtStats* = object
    ## What one sweep did, in the same spirit as `RunStats`.
    games*: int ## games that had a picture to fetch
    fetched*: int ## images written this run
    skipped*: int ## images already on disk
    failed*: int
    failures*: seq[string] ## `<appid>: <file>: <reason>`, kept per image
    sweep*: SweepStats ## the HTTP cost of the sweep

  Target = object
    ## One picture the sweep owes: where it goes, and which game it belongs to.
    appid: int
    path: string
    name: string

func wantedImages(store: SteamFacts): seq[(string, string)] =
  ## The (url, file name) pairs one game needs, widest first: the background is
  ## what the detail page shows large, the header is the list thumbnail, and the
  ## screenshots are the rest.
  if store.art.background.isSome:
    let url = store.art.background.get.value
    if url.len > 0:
      result.add (url, backgroundFileName(url))
  if store.art.header.isSome:
    let url = store.art.header.get.value
    if url.len > 0:
      result.add (url, headerFileName(url))
  if store.art.screenshots.isSome:
    for index, shot in store.art.screenshots.get.value:
      let url = imageUrl(shot)
      if url.len > 0:
        result.add (url, screenshotFileName(index + 1, url))

func failureReason(outcome: FetchOutcome): string =
  ## Why one picture is not on disk: an answer with a status that is not a
  ## picture, or the reason the request never got one.
  if outcome.answer.isSome:
    "HTTP " & $outcome.answer.get.status
  else:
    outcome.problem

proc fetchArt*(client: Client; items: openArray[Enrichment]; root: string;
               limit = 0; refresh = false): ArtStats =
  ## Downloads the pictures of every enriched game that names any, into
  ## `<root>/<appid>/`.
  ##
  ## `limit` caps how many games are visited, not how many images, so a sweep can
  ## be stopped and resumed without re-counting its own output. A game with no
  ## pictures is not visited and does not count against the limit.
  var urls: seq[string] = @[]
  var targets: seq[Target] = @[]
  var visited = 0
  for item in items:
    if limit > 0 and visited >= limit:
      break
    let wanted = wantedImages(item.store)
    if wanted.len == 0:
      continue
    inc visited
    inc result.games
    let dir = artDir(root, item.appid)
    for (url, name) in wanted:
      let path = dir & "/" & name
      if fileExists(path) and not refresh:
        inc result.skipped
      else:
        urls.add url # the sweep key is this URL's position in `urls`
        targets.add Target(appid: item.appid, path: path, name: name)

  var sweep = initSweep(client, urls, refresh)
  while true:
    let outcome = sweep.next()
    if outcome.isNone:
      break
    let picture = outcome.get
    let target = targets[picture.key]
    if picture.answer.isSome and picture.answer.get.status in 200..299:
      try:
        createDir(target.path.parentDir)
        writeFile(target.path, picture.answer.get.body)
        inc result.fetched
      except CatchableError as error:
        inc result.failed
        result.failures.add $target.appid & ": " & target.name &
          ": cannot write " & target.path & ": " & error.msg
    else:
      inc result.failed
      result.failures.add $target.appid & ": " & target.name & ": " &
        failureReason(picture)

  result.sweep = sweep.stats
