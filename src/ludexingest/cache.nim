## The on-disk response cache: one file per URL, holding the status line and the
## body.
##
## .. code-block:: text
##
##   HTTP/1.1 200
##
##   {"tier":"platinum","score":0.71,"total":31}
##
## The status is kept, not just the body, because a `404` from ProtonDB means
## "nobody has reported this game" — an answer worth remembering instead of
## re-asking. Whether a *given* status is worth caching at all is the session's
## policy, not the format's: `fetch.nim` caches answers and refuses to cache a
## transient failure, so a rerun retries it.
##
## A corrupt or unreadable file is a miss, not an exception. The cache is a
## convenience that must never be able to fail a run on its own, and the same
## rule is why reading is a pure function over a string (`parseCacheEntry`) with
## the file access around it.
##
## The file name is the sanitized URL, readable on purpose: a cache directory you
## can eyeball beats one full of digests, and the endpoints this caches are short
## enough that sanitizing keeps names unique as well as safe.

import std/[options, os, strutils]

when defined(posix):
  proc cRename(source, dest: cstring): cint {.importc: "rename",
    header: "<stdio.h>".}
    ## `rename(2)`, the only way to publish a file atomically. Nim's `moveFile`
    ## would do the same, but its effect signature includes `Exception`, which is
    ## wider than this module's contract can allow.

const MaxNameLength = 180

type
  CachedResponse* = object
    ## What one cache file holds. This is the *stored* form: it cannot say
    ## whether the response came from the network, because a file on disk knows
    ## nothing about that. `fetch.Fetch` is the answer the callers get, and it
    ## carries that provenance.
    status*: int
    body*: string

func cacheFileName*(url: string): string =
  ## A filesystem-safe name for a URL.
  for ch in url:
    result.add(if ch in {'A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_'}: ch
               else: '_')
  if result.len > MaxNameLength:
    result = result[0..<MaxNameLength]

func cachePath*(dir, url: string): string =
  ## The cache file for a URL under `dir`.
  ##
  ## No suffix is appended: the sanitized URL already carries one for every
  ## endpoint this caches, and `x.json.json` is just noise.
  dir / cacheFileName(url)

func parseStatus(text: string): Option[int] {.raises: [].} =
  ## Parses a three-digit HTTP status without raising, so a corrupt cache file
  ## is a miss rather than an exception.
  if text.len == 0 or text.len > 3:
    return none(int)
  var value = 0
  for ch in text:
    if ch notin {'0'..'9'}:
      return none(int)
    value = value * 10 + (ord(ch) - ord('0'))
  result = some(value)

func parseCacheEntry(content: string): Option[CachedResponse] {.raises: [].} =
  ## Reads back the `<status>\n\n<body>` shape that `writeCacheEntry` writes.
  let separator = content.find("\n\n")
  if separator < 0:
    return none(CachedResponse)
  let header = content[0..<separator].splitWhitespace
  if header.len < 2:
    return none(CachedResponse)
  let status = parseStatus(header[1])
  if status.isNone:
    return none(CachedResponse)
  result = some CachedResponse(status: status.get,
                               body: content[separator + 2..^1])

proc readCacheEntry*(dir, url: string): Option[CachedResponse]
    {.raises: [].} =
  ## Reads a cached response, treating an unreadable file as a cache miss.
  let path = cachePath(dir, url)
  if fileExists(path):
    let content = try:
                    readFile(path)
                  except CatchableError:
                    ""
    result = parseCacheEntry(content)

proc writeCacheEntry*(dir, url: string; status: int; body: string)
    {.raises: [IOError].} =
  ## Writes one cache entry, creating the directory if it is not there yet.
  ##
  ## This is the only definition of the on-disk shape, so the fetch path and
  ## anything seeding a cache for an offline run both come through here. A
  ## failure is an `IOError`, the closest thing the environment has to offer:
  ## the fetch layer translates it into its own error type at its own boundary,
  ## which is where a caller can say what a cache write failure means.
  ##
  ## The bytes are written beside the final name and renamed into place, so a run
  ## killed mid-write cannot leave a truncated body that later reads back as an
  ## answer. The temporary name carries a `~`, which `cacheFileName` can never
  ## produce, so no URL can look it up. Where no atomic rename is bound, the entry
  ## is written in place and a torn write stays possible.
  try:
    createDir(dir)
    let path = cachePath(dir, url)
    let target = when defined(posix): path & "~tmp" else: path
    # Header and body are written separately: joining them would copy the whole
    # body (a picture is 50-200 KB, and a sweep is thousands of them) for a
    # string that exists only to be written out and dropped.
    let file = open(target, fmWrite)
    try:
      file.write("HTTP/1.1 " & $status & "\n\n")
      file.write(body)
    finally:
      file.close()
    when defined(posix):
      if cRename(target.cstring, path.cstring) != 0:
        raise newException(IOError, "cannot publish " & path & ": " &
                           osErrorMsg(osLastError()))
  except CatchableError as error:
    raise newException(IOError, "cannot cache " & url & ": " & error.msg)
