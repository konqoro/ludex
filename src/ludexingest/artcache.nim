## Downloading the store's pictures into the local art cache.
##
## The cache *layout* is `ludexcore/art.nim`, which is pure; this is the
## downloader that fills it, named after the cache it fills so the two modules
## do not share a name.
##
## Why this is a CLI job and not a window job: a picture is 50-200 KB and a
## catalogue sweep is thousands of them, so the window would lose its "works
## offline" property the moment it rendered a list. Instead the CLI fetches,
## caches and writes files, and the window only ever opens a local path.
##
## It behaves like every other fetch in this project: through the same caching,
## rate-limited `Client`, one picture at a time, already-present files skipped,
## and a failure recorded against the game rather than aborting the run. Re-running
## is therefore free and safe, which is what makes `--limit` a resumable cursor.
##
## The pictures are the only thing downloaded outside `data/cache` proper: the
## cache holds the raw responses, the art directory holds the decoded files the
## UI reads. Both are generated and git-ignored.

import std/[options, os]

import ludexcore/[art, models]

import fetch

const
  DefaultArtDelayMs* = 100
    ## The CDN is not the store API, so the 1600 ms store pause would only make
    ## a sweep slow. Still a pause, because a sweep is a burst by nature.

type
  ArtStats* = object
    ## What one sweep did, in the same spirit as `RunStats`.
    games*: int ## games that had a picture to fetch
    fetched*: int ## images written this run
    skipped*: int ## images already on disk
    failed*: int
    failures*: seq[string] ## `<appid>: <reason>`, kept per image

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

proc fetchArt*(client: Client; items: openArray[Enrichment]; root: string;
               limit = 0; refresh = false): ArtStats =
  ## Downloads the pictures of every enriched game that names any, into
  ## `<root>/<appid>/`.
  ##
  ## `limit` caps how many games are visited, not how many images, so a sweep can
  ## be stopped and resumed without re-counting its own output.
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
        var failure = ""
        try:
          let response = client.fetch(url, refresh = refresh)
          if response.status notin 200..299:
            failure = "HTTP " & $response.status
          else:
            createDir(dir)
            writeFile(path, response.body)
            inc result.fetched
        except FetchError as error:
          failure = error.msg
        except CatchableError as error:
          failure = "cannot write " & path & ": " & error.msg
        if failure.len > 0:
          inc result.failed
          result.failures.add $item.appid & ": " & name & ": " & failure
