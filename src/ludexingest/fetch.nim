## Cached, paced, bounded HTTP: the only module in the project that opens a
## socket.
##
## Three promises, three types. `relay`'s `maxInFlight` bounds how many sockets
## are open; a `Pacer` bounds how often one may be used; a `Sweep` owns one batch
## of URLs and the client's window while it runs. The client owns the cache, the
## rate limit and the one relay handle, so it survives across batches and the CLI
## makes exactly one per command.
##
## The batch primitive is a stream, because relay's own queue is unbounded and
## memory must be bounded by the window rather than by the batch:
##
## .. code-block:: nim
##
##   var sweep = initSweep(client, urls)
##   while true:
##     let outcome = sweep.next()   # blocks until an answer is ready
##     if outcome.isNone: break     # every URL answered and the window empty
##     use(outcome.get)             # key, url, and an answer or a problem
##
## `next` yields in completion order, so every outcome names its request (`key`
## and `url`) instead of relying on position. An outcome is an answer or the
## reason there is none, never both, and one URL's failure never discards
## another's answer. `fetchAll` is the small-batch convenience that reorders into
## submission order by holding every body; use the stream for pictures.
##
## A transient status (`429`, `5xx`) earns up to `MaxAttempts` paced retries with
## backoff, then ends as a problem naming the status; everything else, including
## `404`, is an answer. Answers are remembered in the cache, problems are not, and
## a transport failure is a problem that is not retried. A client-level fault (a
## stopped relay worker, or silence longer than twice relay's own request timeout)
## is raised as `FetchError`, never attributed to a URL.
##
## `docs/DESIGN.md` §7.4 owns the measurements, the rejected shapes and the cost
## of the relay dependency.

import std/[deques, monotimes, options, os, tables]

import relay

import ./[cache, pacer]

const
  DefaultAgent* = "ludex/0.1 (+https://github.com/ageralis/ludex)"
  DefaultDelayMs* = 250
  DefaultMaxInFlight* = 4
    ## How many answers may be outstanding at once.
  MaxAttempts = 4
    ## Submissions a single URL gets before a transient failure is final.
  TimeoutMs = 30000
    ## How long relay gives one request; `StallMs` is derived from it.
  PollMs = 50
    ## The longest the sweep waits without looking for a finished request.
  StallMs = 2 * TimeoutMs
    ## Silence longer than this, with submissions outstanding, is a stopped
    ## client rather than a slow source.

type
  FetchError* = object of CatchableError
    ## Raised for a client-level fault, never for a per-URL failure.

  Client* = ref object
    ## One source session: a cache, a rate limit, a retry policy and one relay
    ## handle. Created per source, closed when the command is done with it.
    cacheDir*: string
    offline*: bool
      ## Serve cached answers only; a miss is a problem, never a request.
    userAgent*: string
    maxInFlight*: int
      ## The transport bound relay is given and the sweep's window is sized to.
    pacer: Pacer
    http: Relay
    nextRequestId: int64
      ## Sweep-independent, so a result this client never issued is dropped
      ## rather than misattributed to a live sweep.
    sweepOpen: bool
      ## Whether a sweep owns this client's window right now.

  Fetch* = object
    ## One response, whether it came off the wire or out of the cache.
    status*: int
    body*: string
    cached*: bool

  FetchOutcome* = object
    ## One URL's result: either an answer or the reason there is none, never
    ## both. `key` and `url` name the request, because a streaming sweep hands
    ## outcomes back in completion order.
    key*: int
    url*: string
    answer*: Option[Fetch]
    problem*: string ## empty when `answer` is set

  SweepStats* = object
    ## What one sweep cost, as opposed to the client's lifetime.
    requests*: int ## requests actually sent, cache hits excluded
    cached*: int ## answers served from the disk cache
    retries*: int ## admissions that were not a URL's first attempt
    cacheErrors*: int ## answers that could not be written to the cache
    elapsedMs*: int64 ## wall clock from `initSweep` to the moment it drained

  SweepResult* = object
    ## A finished sweep: one outcome per URL, in the order they were given.
    outcomes*: seq[FetchOutcome]
    stats*: SweepStats

  Pending = object
    ## One URL the sweep still owes an answer for.
    url: string
    key: int
    attempt: int ## submissions so far; anything above 1 is a retry
    dueAtMs: int64 ## not before this (a retry waits out its backoff)

  Sweep* = object
    ## One paced batch of URLs, driven by `next`.
    ##
    ## A value object, not a `ref`: copying it would fork the bookkeeping of
    ## requests already in flight, so it is driven by `var` and left alone.
    client: Client
    refresh: bool
    startedMs: int64
    headers: HttpHeaders
    queue: Deque[Pending] ## not yet admitted, in the order they were added
    inFlight: Table[int64, Pending] ## submitted and not yet read
    ready: Deque[FetchOutcome] ## answered and not yet taken by the caller
    lastResultMs: int64 ## when a finished request last arrived
    stopped: bool ## the wall clock is stopped once, on the way out
    stats*: SweepStats

proc monoMs(): int64 {.inline.} =
  ## The sweep's monotonic clock, in milliseconds. It lives here because the
  ## pacer takes the timestamp as a parameter and the sweep owns the waiting.
  ticks(getMonoTime()) div 1_000_000

proc initClient*(cacheDir: string; delayMs = DefaultDelayMs; offline = false;
                 userAgent = DefaultAgent;
                 maxInFlight = DefaultMaxInFlight): Client =
  ## Creates one source session. `delayMs` is the source's request budget as the
  ## floor between two submissions; 0 means no pacing.
  result = Client(cacheDir: cacheDir, offline: offline, userAgent: userAgent,
                  maxInFlight: max(1, maxInFlight),
                  pacer: Pacer(delayMs: max(0, delayMs)))
  if not offline:
    result.http = newRelay(maxInFlight = result.maxInFlight,
                           defaultTimeoutMs = TimeoutMs)

proc close*(client: Client) =
  ## Releases the connection pool and any sweep's claim on it. Safe to call more
  ## than once; relay's own `close` waits for queued and in-flight work.
  if client.http != nil:
    client.http.close()
    client.http = nil
  client.sweepOpen = false

func isTransient(status: int): bool {.inline.} =
  ## `429` and `5xx`; everything else, including `404`, is an answer.
  status == 429 or status >= 500

func backoffMs(attempt: int): int {.inline.} =
  ## One retry's wait, doubling per attempt: 500 ms, then 1000, then 2000.
  250 shl attempt

proc initSweep*(client: Client; urls: openArray[string]; refresh = false): Sweep =
  ## Opens a sweep over `urls`, keyed by position: `urls[i]` is `key` `i`.
  ##
  ## A client's window belongs to one sweep at a time, so a second sweep on a
  ## busy client is refused rather than interleaved. `refresh` ignores the cache.
  if not client.offline and client.http == nil:
    raise newException(FetchError, "client is closed")
  if client.sweepOpen:
    raise newException(FetchError,
      "this client already has a sweep open: drive it to `none`, or close it")
  client.sweepOpen = true
  result.client = client
  result.refresh = refresh
  result.startedMs = monoMs()
  result.lastResultMs = result.startedMs
  result.headers = emptyHttpHeaders()
  result.headers["User-Agent"] = client.userAgent
  result.queue = initDeque[Pending](urls.len)
  for index, url in urls:
    result.queue.addLast(Pending(url: url, key: index, attempt: 1))

proc stopClock(sweep: var Sweep) {.inline.} =
  ## Ends the sweep once: stamps its duration and releases the client's window.
  if not sweep.stopped:
    sweep.stats.elapsedMs = max(monoMs() - sweep.startedMs, 0)
    sweep.stopped = true
  sweep.client.sweepOpen = false

proc answerFromCache(sweep: var Sweep; item: Pending): bool {.raises: [].} =
  ## Answers one item from the cache when there is an entry, and says whether it
  ## did. A cache hit costs no request, so it is not paced. A cached transient
  ## (an old entry written before the write side refused to store one) is a miss.
  if sweep.refresh:
    return false
  let cached = cache.readCacheEntry(sweep.client.cacheDir, item.url)
  if cached.isNone or isTransient(cached.get.status):
    return false
  inc sweep.stats.cached
  sweep.ready.addLast(FetchOutcome(key: item.key, url: item.url,
    answer: some Fetch(status: cached.get.status, body: cached.get.body,
                       cached: true)))
  result = true

proc cacheAnswer(sweep: var Sweep; url: string; fetched: Fetch) {.raises: [].} =
  ## Remembers an answer. A write failure is counted, never raised: the answer is
  ## already in hand, and losing it over a disk problem would waste the request.
  try:
    cache.writeCacheEntry(sweep.client.cacheDir, url, fetched.status,
                          fetched.body)
  except IOError:
    inc sweep.stats.cacheErrors

proc submit(sweep: var Sweep; item: sink Pending) {.raises: [].} =
  ## Hands one admitted URL to relay. A relay that refuses it (`startRequest`
  ## raises `IOError` on a closed client) becomes this URL's problem, so it stays
  ## a fact about the sweep rather than an exception out of it.
  let requestId = sweep.client.nextRequestId
  inc sweep.client.nextRequestId
  let started = try:
                  sweep.client.http.startRequest(RequestSpec(
                    verb: hvGet, url: item.url, headers: sweep.headers,
                    requestId: requestId))
                  true
                except IOError as error:
                  sweep.ready.addLast(FetchOutcome(key: item.key, url: item.url,
                    problem: "GET " & item.url & ": " & error.msg))
                  false
  if started:
    sweep.inFlight[requestId] = item
    inc sweep.stats.requests
    if item.attempt > 1:
      inc sweep.stats.retries

proc take(sweep: var Sweep; item: sink RequestResult) {.raises: [].} =
  ## Files one finished request as an answer, a retry or a problem. Takes the
  ## result by `sink` because an answer body is the biggest value here and the
  ## caller is done with it.
  sweep.lastResultMs = monoMs() # anything arriving is progress, even a refusal
  let requestId = item.response.request.requestId
  var pending: Pending
  if not sweep.inFlight.pop(requestId, pending):
    # Unreachable: `initSweep` refuses a client that already has a sweep open.
    assert false, "result for a request this sweep does not own"
    return
  if item.error.kind != teNone:
    sweep.ready.addLast(FetchOutcome(key: pending.key, url: pending.url,
      problem: "GET " & pending.url & ": " & $item.error.kind & " " &
               item.error.message))
    return
  let status = item.response.code.int
  if isTransient(status):
    if status == 429:
      # A 429 is about us, not this URL, so it pushes every admission back.
      sweep.client.pacer.hold(monoMs(), backoffMs(pending.attempt))
    if pending.attempt < MaxAttempts:
      pending.dueAtMs = monoMs() + int64(backoffMs(pending.attempt))
      inc pending.attempt
      sweep.queue.addLast(pending) # to the back: a retry jumps nobody's place
      return
    sweep.ready.addLast(FetchOutcome(key: pending.key, url: pending.url,
      problem: "GET " & pending.url & ": HTTP " & $status & " after " &
               $MaxAttempts & " attempts"))
    return
  let fetched = Fetch(status: status, body: item.response.body, cached: false)
  sweep.cacheAnswer(pending.url, fetched)
  sweep.ready.addLast(FetchOutcome(key: pending.key, url: pending.url,
                                   answer: some fetched))

proc waitForFinished(sweep: var Sweep; dueMs: int64;
                     item: var RequestResult): bool {.raises: [FetchError].} =
  ## Waits a slice for one finished request, the slice being the smaller of the
  ## time until the pacer admits the next submission and `PollMs`. Blocking
  ## outright would starve the pacer and let the window run empty exactly when
  ## answers are slower than `delayMs`.
  ##
  ## Polling never sees relay's "the worker stopped" return value, so silence is
  ## bounded here instead: every accepted request ends within relay's timeout, so
  ## a much longer silence with submissions outstanding is a stopped client.
  let slice = if dueMs > 0: min(dueMs, int64(PollMs)) else: int64(PollMs)
  sleep(max(slice, 1).int)
  result = sweep.client.http.pollForResult(item)
  if not result and sweep.inFlight.len > 0 and
      monoMs() - sweep.lastResultMs > StallMs:
    raise newException(FetchError, "no answer for " & $(StallMs div 1000) &
                       " seconds with requests outstanding")

proc step(sweep: var Sweep) {.raises: [FetchError].} =
  ## One transition of the sweep: file a finished request, then answer or submit
  ## the queue head, then wait out whatever is left.
  if sweep.inFlight.len > 0:
    var waiting: RequestResult
    if sweep.client.http.pollForResult(waiting):
      sweep.take(waiting)
      return

  let now = monoMs()
  var dueMs: int64 = 0
  if sweep.queue.len > 0:
    dueMs = max(sweep.client.pacer.dueInMs(now),
                sweep.queue.peekFirst.dueAtMs - now)
    var item = sweep.queue.popFirst()
    if sweep.answerFromCache(item):
      return
    if sweep.client.offline:
      sweep.ready.addLast(FetchOutcome(key: item.key, url: item.url,
        problem: "offline and not cached: " & item.url))
      return
    if dueMs <= 0 and sweep.inFlight.len < sweep.client.maxInFlight:
      sweep.client.pacer.admit(now)
      sweep.submit(item)
      return
    sweep.queue.addFirst(item) # not yet: it keeps its place at the head

  if sweep.inFlight.len > 0:
    var finished: RequestResult
    if sweep.waitForFinished(dueMs, finished):
      sweep.take(finished)
  elif sweep.queue.len > 0:
    sleep(dueMs.int)

proc next*(sweep: var Sweep): Option[FetchOutcome] {.raises: [FetchError].} =
  ## The next answer, blocking until one is ready. `none` means the sweep is
  ## drained: every URL has been answered and the window is empty.
  if not sweep.client.offline and sweep.client.http == nil:
    raise newException(FetchError, "client is closed")
  while sweep.ready.len == 0 and sweep.queue.len + sweep.inFlight.len > 0:
    sweep.step()
  if sweep.ready.len > 0:
    result = some sweep.ready.popFirst()
  else:
    sweep.stopClock()

proc fetchAll*(client: Client; urls: openArray[string]; refresh = false):
    SweepResult {.raises: [FetchError].} =
  ## Fetches every URL and returns one outcome per URL, in the order given.
  ##
  ## This holds every body in memory at once; `initSweep` and `next` are the
  ## streaming form for pictures.
  var sweep = initSweep(client, urls, refresh)
  result.outcomes = newSeq[FetchOutcome](urls.len)
  while true:
    let outcome = sweep.next()
    if outcome.isNone:
      break
    result.outcomes[outcome.get.key] = outcome.get
  result.stats = sweep.stats
