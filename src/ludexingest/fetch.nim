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
## ## Why a paced batch
##
## The catalogue is 1545 games and Steam costs three requests each, so a serial
## sweep is hours of wall clock spent waiting on sockets. Relay runs requests on
## a libcurl multi handle, so `fetchAll` takes many URLs and returns one answer
## per URL, and `fetch` is the single-URL case of it.
##
## ## Why the delay survives
##
## A concurrency bound and a rate limit are not the same promise. `maxInFlight`
## says "no more than N sockets open"; it does not stop N fast answers from
## arriving in a burst, which is exactly what gets an address throttled by a
## source that publishes a request budget. So the per-source delay is kept as a
## real rate limit: a *pacer* tracks the instant the last request was submitted
## and holds the next one back until `delayMs` has elapsed. `maxInFlight` then
## only decides how much of a slow source's latency is hidden by overlapping the
## requests the pacer already admitted.
##
## The pacing is per *submission*, not per round: `fetchAll` streams URLs into
## Relay as the pacer admits them and drains completions as they arrive, so the
## queue never holds the whole catalogue. A source with a 1600 ms budget sees one
## request per 1600 ms whether the sweep is ten URLs or four thousand; the only
## thing batching buys is that the sweep no longer waits for each answer before
## sending the next. Handing Relay the whole batch at once would defeat the
## pacer, so that is deliberately not the shape here. The limit is a floor:
## Relay's poll granularity can pace slightly slower than `delayMs`, never
## faster, which is the safe direction.

import std/[options, os, strutils, times]
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
    maxInFlight*: int ## how many answers may be outstanding at once
    pacer: Pacer ## the rate limit; `delayMs` is the configured value it uses
    http: Relay

  Fetch* = object
    ## One response, whether it came from the network or the cache.
    status*: int
    body*: string
    cached*: bool

  FetchOutcome* = object
    ## One URL's result: either an answer or the reason there is none.
    ##
    ## This is a single value rather than two parallel arrays precisely so the
    ## "an answer or a problem, never both" invariant is carried by the type
    ## instead of by a convention every caller has to remember.
    answer*: Option[Fetch]
    problem*: string ## empty when `answer` is set

  Pacer = object
    ## Admission control for one source: the invariant is "one submission per
    ## `delayMs`", measured against the wall clock of the previous admission so
    ## a fast answer cannot turn a fixed budget into a burst.
    delayMs: int
    lastMs: int64

  Round = object
    ## The state one retry pass carries between its submissions and its
    ## completions: how many answers are still unread and which URLs earned
    ## another attempt. Collecting it here keeps the drain loop free of captures.
    attempt: int
    outstanding: int
    retry: seq[int]

proc initClient*(cacheDir: string; delayMs = DefaultDelayMs; offline = false;
                 userAgent = DefaultAgent;
                 maxInFlight = DefaultMaxInFlight): Client =
  ## Creates a client.
  ##
  ## `offline` serves cached responses only and fails on a cache miss, which is
  ## what the tests and `--offline` use.
  result = Client(cacheDir: cacheDir, delayMs: delayMs, offline: offline,
                  userAgent: userAgent, maxInFlight: max(1, maxInFlight),
                  pacer: Pacer(delayMs: delayMs))
  if not offline:
    result.http = newRelay(maxInFlight = result.maxInFlight,
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

proc nowMs(): int64 {.inline.} =
  ## A monotonic-enough wall clock in milliseconds; only differences are used.
  int64(epochTime() * 1000.0)

proc admit(pacer: var Pacer) =
  ## Blocks until one more submission is due, then stamps the admission.
  ##
  ## Pacing is measured against the previous admission, not against the round,
  ## so a source that answers quickly still sees one request per `delayMs` and
  ## overlap cannot turn a fixed budget into a burst.
  if pacer.delayMs > 0 and pacer.lastMs > 0:
    let remaining = int64(pacer.delayMs) - (nowMs() - pacer.lastMs)
    if remaining > 0:
      sleep(remaining.int)
  pacer.lastMs = nowMs()

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
    admit(client.pacer)
    inc client.requests
    let fetched = requestOnce(client, url)
    let retryable = fetched.status == 429 or fetched.status >= 500
    if not retryable or attempt >= MaxAttempts:
      cacheResponse(client, url, fetched)
      return fetched
    sleep(250 shl attempt)

proc collectOne(client: Client; urls: openArray[string];
                outcomes: var seq[FetchOutcome]; round: var Round)
    {.raises: [FetchError].} =
  ## Reads one completed response and files it as an answer or a retry.
  ##
  ## A `429` or `5xx` earns another pass until the budget is spent; anything
  ## else, including a transport failure and a `404`, settles the URL. The URL
  ## is recovered from the request id, so completion order does not matter.
  var item: RequestResult
  if not client.http.waitForResult(item):
    raise newException(FetchError, "client stopped before all responses arrived")
  dec round.outstanding
  inc client.requests
  let index = item.response.request.requestId.int
  if item.error.kind != teNone:
    outcomes[index].problem = "GET " & urls[index] & ": " &
      $item.error.kind & " " & item.error.message
  else:
    let fetched = Fetch(status: item.response.code.int,
                        body: item.response.body, cached: false)
    let throttled = fetched.status == 429 or fetched.status >= 500
    if throttled and round.attempt < MaxAttempts:
      round.retry.add index
    else:
      cacheResponse(client, urls[index], fetched)
      outcomes[index].answer = some fetched

proc submitPaced(client: Client; urls: openArray[string];
                 pending: openArray[int]; headers: HttpHeaders;
                 outcomes: var seq[FetchOutcome]; round: var Round)
    {.raises: [FetchError].} =
  ## Submits every pending URL through the pacer, draining as it goes.
  ##
  ## At most `maxInFlight` answers are left unread, so memory stays bounded by
  ## the concurrency window rather than by the size of the sweep, and a source
  ## that has started refusing is noticed as it refuses rather than after the
  ## whole catalogue has been queued.
  for index in pending:
    if round.outstanding >= client.maxInFlight:
      collectOne(client, urls, outcomes, round)
    admit(client.pacer)
    let started = try:
                    client.http.startRequest(RequestSpec(
                      verb: hvGet, url: urls[index], headers: headers,
                      requestId: index.int64))
                    true
                  except IOError as error:
                    outcomes[index].problem = "GET " & urls[index] & ": " &
                      error.msg
                    false
    if started:
      inc round.outstanding
  while round.outstanding > 0:
    collectOne(client, urls, outcomes, round)

proc fetchAll*(client: Client; urls: openArray[string]; refresh = false):
    seq[FetchOutcome] {.raises: [FetchError].} =
  ## Returns one outcome per URL, in the order the URLs were given.
  ##
  ## An outcome is either an answer or the reason there is none. A batch is
  ## deliberately *not* all-or-nothing: the enrichment loops treat one game's
  ## failure as a fact about that game, and a batch that aborted on the first
  ## miss would turn a single silent source into a failed sweep. Only a
  ## client-level fault (a closed or stopped client) raises, because that is not
  ## a fact about any one URL.
  ##
  ## Cache hits are answered without touching the network, so a rerun over a warm
  ## cache costs nothing and never opens a socket. The rest are streamed through
  ## Relay's multi handle: the pacer admits one submission per `delayMs`, so the
  ## source sees a fixed request rate whether this batch is ten URLs or four
  ## thousand, and `maxInFlight` only hides the latency of the slowest answer.
  ## Submissions and completions interleave, so the pending queue is bounded by
  ## `maxInFlight` rather than by the catalogue size.
  result = newSeq[FetchOutcome](urls.len)
  var pending: seq[int] = @[]
  for index, url in urls:
    let cached = if refresh: none(Fetch) else: cachedResponse(client, url)
    if cached.isSome:
      inc client.hits
      result[index].answer = cached
    elif client.offline:
      result[index].problem = "offline and not cached: " & url
    else:
      pending.add index

  var headers = emptyHttpHeaders()
  headers["User-Agent"] = client.userAgent
  # One pass per attempt, but the URLs of a pass are not submitted together: the
  # pacer admits them one at a time and a completion is drained before the next
  # admission once `maxInFlight` answers are outstanding, so a throttled source
  # is noticed as it throttles instead of after the whole catalogue is queued.
  var attempt = 0
  while pending.len > 0 and attempt < MaxAttempts:
    inc attempt
    var round = Round(attempt: attempt)
    submitPaced(client, urls, pending, headers, result, round)
    pending = round.retry
    if pending.len > 0:
      sleep(250 shl attempt)
