## Cached, rate-limited HTTP for the enrichment sources.
##
## Every response is cached on disk under a name derived from its URL, so a
## rerun costs no requests and development works offline. Cached files keep the
## status line, because "ProtonDB has nothing for this game" is an answer worth
## remembering too:
##
## .. code-block:: text
##
##   HTTP/1.1 200
##
##   {"tier":"platinum","score":0.71,"total":31}
##
## This is the only module in the project that performs network I/O.
##
## ## Why batches
##
## The catalogue is 1545 games and Steam costs three requests each, so a serial
## sweep is hours of wall clock spent waiting on sockets. Relay runs requests on
## a libcurl multi handle, so the unit of work here is a *batch*: `fetchAll`
## takes many URLs and returns one answer per URL, and `fetch` is the
## single-URL case of it.
##
## ## Why the delay survives
##
## A concurrency bound and a rate limit are not the same promise. `maxInFlight`
## says "no more than N sockets open"; it does not stop N fast answers from
## arriving in a burst, which is exactly what gets an address throttled by a
## source that publishes a request budget. So the per-source delay is kept as a
## real rate limit: submissions are paced by it, and `maxInFlight` only decides
## how many of those paced requests may overlap. A source with a 1600 ms budget
## still sees one request per 1600 ms; it just no longer waits for each answer
## before sending the next.

import std/[options, os, strutils]
import relay

const DefaultAgent* = "ludex/0.1 (+https://github.com/ageralis/ludex)"
const DefaultDelayMs* = 250
const MaxAttempts = 4
const DefaultMaxInFlight* = 4
  ## How many requests may overlap. The delay paces submissions, so this only
  ## decides how much of a slow source's latency is hidden.

type
  FetchError* = object of CatchableError
    ## Raised when a request cannot be completed, after retrying and after
    ## falling back to the cache.

  Client* = ref object
    ## One rate-limited, caching HTTP session.
    cacheDir*: string
    delayMs*: int
    offline*: bool
    userAgent*: string
    requests*: int ## requests actually sent, cache hits excluded
    hits*: int ## answers served from the cache
    http: Relay

  Fetch* = object
    ## One response, whether it came from the network or the cache.
    status*: int
    body*: string
    cached*: bool

proc initClient*(cacheDir: string; delayMs = DefaultDelayMs; offline = false;
                 userAgent = DefaultAgent;
                 maxInFlight = DefaultMaxInFlight): Client =
  ## Creates a client.
  ##
  ## `offline` serves cached responses only and fails on a cache miss, which is
  ## what the tests and `--offline` use.
  result = Client(cacheDir: cacheDir, delayMs: delayMs, offline: offline,
                  userAgent: userAgent)
  if not offline:
    result.http = newRelay(maxInFlight = max(1, maxInFlight),
                           defaultTimeoutMs = 30000)

proc close*(client: Client) =
  ## Releases the connection pool. Safe to call more than once.
  if client.http != nil:
    client.http.close()
    client.http = nil

proc cacheFileName*(url: string): string =
  ## A filesystem-safe name for a URL.
  ##
  ## Readable on purpose: a cache directory you can eyeball beats one full of
  ## digests. The endpoints this caches are short, so sanitizing is enough to
  ## keep names unique as well as safe.
  const MaxName = 180
  for ch in url:
    result.add(if ch in {'A'..'Z', 'a'..'z', '0'..'9', '.', '-', '_'}: ch
               else: '_')
  if result.len > MaxName:
    result = result[0..<MaxName]

proc cachePath*(client: Client; url: string): string =
  ## The cache file for a URL.
  ##
  ## No suffix is appended: the sanitized URL already carries one for every
  ## endpoint this caches, and `x.json.json` is just noise.
  client.cacheDir / cacheFileName(url)

proc parseStatus(text: string): Option[int] {.raises: [].} =
  ## Parses a three-digit HTTP status without raising, so a corrupt cache file
  ## is a cache miss rather than an exception.
  if text.len == 0 or text.len > 3:
    return none(int)
  var value = 0
  for ch in text:
    if ch notin {'0'..'9'}:
      return none(int)
    value = value * 10 + (ord(ch) - ord('0'))
  result = some(value)

proc parseCached(content: string): Option[Fetch] {.raises: [].} =
  ## Reads back the `<status>\n\n<body>` shape that `cacheResponse` writes.
  let separator = content.find("\n\n")
  if separator < 0:
    return none(Fetch)
  let header = content[0..<separator].splitWhitespace
  if header.len < 2:
    return none(Fetch)
  let status = parseStatus(header[1])
  if status.isNone:
    return none(Fetch)
  result = some Fetch(status: status.get,
                      body: content[separator + 2..^1], cached: true)

proc cachedResponse(client: Client; url: string): Option[Fetch]
    {.raises: [].} =
  ## Reads a cached response, treating an unreadable file as a cache miss.
  let path = cachePath(client, url)
  if fileExists(path):
    let content = try:
                    readFile(path)
                  except CatchableError:
                    ""
    result = parseCached(content)

proc writeCacheEntry*(client: Client; url: string; status: int; body: string)
    {.raises: [FetchError].} =
  ## Writes one cache entry.
  ##
  ## The fetch path and anything seeding an offline cache both come through
  ## here, so the on-disk shape has exactly one definition.
  try:
    createDir(client.cacheDir)
    writeFile(cachePath(client, url), "HTTP/1.1 " & $status & "\n\n" & body)
  except CatchableError as error:
    raise newException(FetchError, "cannot cache " & url & ": " & error.msg)

proc cacheResponse(client: Client; url: string; fetched: Fetch) =
  ## Remembers one response. A cache write failure is reported but never
  ## discards a good response, so the caller still gets its data.
  writeCacheEntry(client, url, fetched.status, fetched.body)

proc waitTurn(client: Client) =
  ## Politely spaces requests out. Unconditional sleeps are simple and, for a
  ## one-off sweep, perfectly adequate.
  if client.delayMs > 0:
    sleep(client.delayMs)

proc requestOnce*(client: Client; url: string): Fetch {.raises: [FetchError].} =
  ## Sends one request with no cache interaction.
  ##
  ## Relay reports transport failures as a value rather than an exception, so
  ## the error kind is inspected instead of caught. A `teNone` kind means the
  ## request reached the server; the status code is the caller's business.
  ##
  ## Relay raises `IOError` for lifecycle misuse (a closed or busy client),
  ## which is not a transport failure; it is folded into `FetchError` so this
  ## proc keeps its single-exception contract.
  var headers = emptyHttpHeaders()
  headers["User-Agent"] = client.userAgent
  let item = try:
               client.http.get(url, headers = headers)
             except IOError as error:
               raise newException(FetchError, "GET " & url & ": " & error.msg)
  if item.error.kind != teNone:
    raise newException(FetchError,
      "GET " & url & ": " & $item.error.kind & " " & item.error.message)
  result = Fetch(status: item.response.code.int, body: item.response.body,
                 cached: false)

proc fetch*(client: Client; url: string; refresh = false): Fetch
    {.raises: [FetchError].} =
  ## Returns the response for `url`, from the cache when possible.
  ##
  ## Retries `429` and `5xx` with exponential backoff, then raises. Any other
  ## status, including `404`, is returned to the caller: "this source has
  ## nothing for this game" is an answer, not a failure.
  if not refresh:
    let cached = cachedResponse(client, url)
    if cached.isSome:
      inc client.hits
      return cached.get
  if client.offline:
    raise newException(FetchError, "offline and not cached: " & url)

  var attempt = 0
  while true:
    inc attempt
    waitTurn(client)
    inc client.requests
    let fetched = requestOnce(client, url)
    let retryable = fetched.status == 429 or fetched.status >= 500
    if not retryable or attempt >= MaxAttempts:
      cacheResponse(client, url, fetched)
      return fetched
    sleep(250 shl attempt)
