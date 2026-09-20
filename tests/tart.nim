## Tests for the art cache: the naming contract and the downloader.
##
## Nothing here touches the network. Image bodies are seeded into the response
## cache and the client runs offline, so the whole path is exercised (URL to
## file, naming, skipping what is already there, reporting a failure) without a
## network and without a display.

import std/[options, os, strutils]

import ludexcore/[art, models]
import ludexingest/[artcache, cache, fetch]

const
  HeaderUrl = "https://example.test/store/header.jpg"
  BackgroundUrl = "https://example.test/store/page_bg_raw.jpg"
  ShotUrl = "https://example.test/store/ss_slipways.600x338.jpg?t=1732"
  FullUrl = "https://example.test/store/ss_slipways.1920x1080.jpg?t=1732"
  MissingUrl = "https://example.test/store/gone.jpg"

proc tempDir(name: string): string =
  result = getTempDir() / ("ludex-art-" & name & "-" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)

func enrichment(art: ArtFacts; appid = 42): Enrichment =
  Enrichment(appid: appid, store: SteamFacts(kind: "game", art: art))

func twoImages(): ArtFacts =
  ArtFacts(
    header: some initFact(HeaderUrl, srcSteam, 1),
    screenshots: some initFact(@[Screenshot(thumbnail: ShotUrl)], srcSteam, 1))

block file_names_are_the_contract:
  # The downloader writes these names and the window reads them, so both sides
  # use these functions rather than agreeing informally.
  doAssert extensionFromUrl(HeaderUrl) == ".jpg"
  doAssert extensionFromUrl("https://example.test/a/b.png?v=2") == ".png"
  doAssert extensionFromUrl("https://example.test/a/weird") == ".img",
    "no usable extension means a neutral one, not the host's dot"
  doAssert headerFileName(HeaderUrl) == "header.jpg"
  doAssert backgroundFileName(BackgroundUrl) == "background.jpg",
    "the wide page art keeps its own name, not the header's"
  doAssert screenshotFileName(1, ShotUrl) == "shot-01.jpg"
  doAssert screenshotFileName(11, "https://example.test/a.png") == "shot-11.png"
  doAssert artDir("data/art", 1264280) == "data/art/1264280"

block the_full_size_is_preferred_and_the_thumbnail_is_the_fallback:
  let shot = Screenshot(full: "https://example.test/full.1920x1080.jpg")
  doAssert imageUrl(shot) == "https://example.test/full.1920x1080.jpg",
    "the full size gives the viewer pixels, and it is used when present"
  doAssert imageUrl(Screenshot(thumbnail: ShotUrl)) == ShotUrl,
    "a store that sent only a thumbnail is still worth downloading"
  doAssert imageUrl(Screenshot(thumbnail: ShotUrl, full: FullUrl)) == FullUrl,
    "when both exist the full size wins, so the viewer has resolution"

block the_wide_page_art_lands_beside_the_header:
  # The banner is the biggest picture on the page, and it is a different file
  # from the header rather than a replacement for it, so both are written.
  let root = tempDir("background")
  let client = initClient(tempDir("cachebg"), delayMs = 0, offline = true)
  writeCacheEntry(client.cacheDir, BackgroundUrl, 200, "BACKGROUND-BYTES")
  writeCacheEntry(client.cacheDir, HeaderUrl, 200, "HEADER-BYTES")
  writeCacheEntry(client.cacheDir, ShotUrl, 200, "SHOT-BYTES")
  let items = @[enrichment(ArtFacts(
    background: some initFact(BackgroundUrl, srcSteam, 1),
    header: some initFact(HeaderUrl, srcSteam, 1),
    screenshots: some initFact(@[Screenshot(thumbnail: ShotUrl)], srcSteam, 1)))]
  let stats = fetchArt(client, items, root)
  doAssert stats.fetched == 3
  doAssert stats.failed == 0
  let dir = artDir(root, 42)
  doAssert readFile(dir & "/background.jpg") == "BACKGROUND-BYTES"
  doAssert readFile(dir & "/header.jpg") == "HEADER-BYTES"
  doAssert readFile(dir & "/shot-01.jpg") == "SHOT-BYTES"
  # A second run is a cursor, not a re-download.
  let again = fetchArt(client, items, root)
  client.close()
  doAssert again.fetched == 0 and again.skipped == 3
  removeDir(root)

block downloads_the_header_and_every_screenshot:
  let root = tempDir("download")
  let client = initClient(tempDir("cache"), delayMs = 0, offline = true)
  writeCacheEntry(client.cacheDir, HeaderUrl, 200, "HEADER-BYTES")
  writeCacheEntry(client.cacheDir, ShotUrl, 200, "SHOT-BYTES")
  let stats = fetchArt(client, @[enrichment(twoImages())], root)
  client.close()

  doAssert stats.games == 1, "one game had pictures"
  doAssert stats.fetched == 2
  doAssert stats.skipped == 0
  doAssert stats.failed == 0
  let dir = artDir(root, 42)
  doAssert readFile(dir & "/header.jpg") == "HEADER-BYTES",
    "image bytes are written as they arrived"
  doAssert readFile(dir & "/shot-01.jpg") == "SHOT-BYTES"
  removeDir(root)

block a_second_run_downloads_nothing:
  # This is what makes `--limit` a resumable cursor instead of a re-download.
  let root = tempDir("resume")
  let client = initClient(tempDir("cache2"), delayMs = 0, offline = true)
  writeCacheEntry(client.cacheDir, HeaderUrl, 200, "HEADER-BYTES")
  writeCacheEntry(client.cacheDir, ShotUrl, 200, "SHOT-BYTES")
  discard fetchArt(client, @[enrichment(twoImages())], root)
  let again = fetchArt(client, @[enrichment(twoImages())], root)
  client.close()
  doAssert again.games == 1
  doAssert again.fetched == 0
  doAssert again.skipped == 2
  doAssert again.failed == 0
  removeDir(root)

block a_image_that_will_not_come_is_reported_not_raised:
  let root = tempDir("missing")
  let client = initClient(tempDir("cache3"), delayMs = 0, offline = true)
  # Nothing cached for this one, so an offline fetch fails.
  writeCacheEntry(client.cacheDir, HeaderUrl, 403, "denied")
  let items = @[enrichment(ArtFacts(
    header: some initFact(MissingUrl, srcSteam, 1),
    screenshots: some initFact(@[Screenshot(thumbnail: HeaderUrl)], srcSteam, 1)))]
  let stats = fetchArt(client, items, root)
  client.close()
  doAssert stats.fetched == 0
  doAssert stats.failed == 2
  doAssert stats.failures.len == 2
  doAssert stats.failures[0].startsWith("42: header.jpg"),
    "a failure names the game and the file"
  doAssert stats.failures[1].startsWith("42: shot-01.jpg")
  doAssert stats.failures[1].contains("403"),
    "a refused status is a failure, unlike a store 404 which is an answer"
  removeDir(root)

block a_game_with_no_pictures_is_not_visited:
  let root = tempDir("none")
  let client = initClient(tempDir("cache4"), delayMs = 0, offline = true)
  let items = @[
    enrichment(ArtFacts(), appid = 1),
    enrichment(twoImages(), appid = 2),
    enrichment(twoImages(), appid = 3),
  ]
  writeCacheEntry(client.cacheDir, HeaderUrl, 200, "H")
  writeCacheEntry(client.cacheDir, ShotUrl, 200, "S")
  let stats = fetchArt(client, items, root, limit = 1)
  client.close()
  doAssert stats.games == 1, "limit counts games, not images"
  doAssert stats.fetched == 2, "and the whole game is fetched, not half of it"
  doAssert not dirExists(artDir(root, 3)), "nothing beyond the limit is visited"
  removeDir(root)

echo "tart: ok"
