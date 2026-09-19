## The layout of the local art cache: where a game's pictures live and what the
## files inside are called.
##
## Pure, so the two sides that have to agree cannot drift: `ludexingest/art.nim`
## writes the files and `ludexui/catalog.nim` reads them. If the naming rule
## lived in the downloader alone, the window would have to guess it.
##
## One directory per Steam app id, because the app id is the join key everywhere
## else in this catalogue:
##
## .. code-block:: text
##
##   data/art/1264280/header.jpg
##   data/art/1264280/shot-01.jpg
##   data/art/1264280/shot-02.jpg
##
## A screenshot is stored once, at the URL the caller picked: the full-size
## image (1920x1080), because the window now shows one in a full-window viewer,
## and `imageUrl` falls back to the thumbnail when the store sent only that.

import std/[options, strutils]

import models

const
  DefaultArtDir* = "data/art"
  BackgroundStem* = "background"
  HeaderStem* = "header"
  ScreenshotStem* = "shot-"

func artDir*(root: string; appid: int): string =
  ## The directory holding one game's pictures.
  ##
  ## The separator is spelled out rather than taken from `std/os`, because the
  ## core does not import it: this module is pure, and the only consumer that
  ## touches the file system is the CLI on Linux.
  root & "/" & $appid

func extensionFromUrl*(url: string): string =
  ## The file extension the URL path ends in, lowercased, or `.img` when the URL
  ## does not carry a usable one. GTK sniffs the content, so the extension is for
  ## humans reading the cache directory, not for decoding.
  let path = url.split('?')[0]
  let dot = path.rfind('.')
  if dot < 0 or path.len - dot > 5 or path[dot..^1].contains('/'):
    return ".img"
  result = path[dot..^1].toLowerAscii

func backgroundFileName*(url: string): string =
  ## The store's wide page art, kept beside the header because it is the same
  ## picture family at a size worth showing on a detail page.
  BackgroundStem & extensionFromUrl(url)

func headerFileName*(url: string): string =
  HeaderStem & extensionFromUrl(url)

func screenshotFileName*(index: int; url: string): string =
  ## `shot-01.jpg`, numbered from one so the directory reads in order.
  ScreenshotStem & align($index, 2, '0') & extensionFromUrl(url)

func imageUrl*(shot: Screenshot): string =
  ## The URL worth downloading. The full-size picture is preferred so the
  ## viewer has pixels to show; the thumbnail is the fallback for a store that
  ## sent only that.
  if shot.full.len > 0: shot.full else: shot.thumbnail

func hasArt*(art: ArtFacts): bool =
  ## True when there is any picture URL to fetch or show.
  art.background.isSome or art.header.isSome or art.screenshots.isSome

func screenshotCount*(art: ArtFacts): int =
  if art.screenshots.isSome: art.screenshots.get.value.len else: 0
