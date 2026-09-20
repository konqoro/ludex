## Cached, paced, bounded HTTP: the only module in the project that opens a
## socket.
##
## ## Three promises, three types
##
## A concurrency bound and a rate limit are not the same promise, so they are no
## longer the same loop:
##
## * `relay`'s `maxInFlight` is *transport*: how many sockets may be open. It
##   does not stop four fast answers from arriving as a burst.
## * A `Pacer` (`ludexingest/pacer.nim`) is the *rate limit*: one submission per
##   `delayMs`, which is what a source that publishes a request budget actually
##   sees. It belongs to the client because it is a property of the source being
##   asked, and it therefore survives across sweeps: two sweeps against one
##   source cannot double that source's rate.
## * A `Sweep` is the *batch*: it owns the pending URLs, the client's window
##   while it runs, and the outcomes. Nothing else owns those.
##
## One `Client` is one source session: its cache, its rate limit, its retry
## policy and its one `relay` handle. The CLI makes exactly one per command.
##
## ## The batch contract
##
## .. code-block:: nim
##
##   var sweep = initSweep(client, urls)
##   while true:
##     let outcome = sweep.next()      # blocks until an answer is ready
##     if outcome.isNone: break        # nothing is owed any more
##     use(outcome.get)                # key, url, and an answer or a problem
##
## * `next` yields one outcome per URL in *completion* order, and every outcome
##   names the request it belongs to: `key`, the URL's position in the batch, and
##   the URL itself. Reordering into submission order would mean holding bodies
##   in memory, which is the one thing this shape exists to avoid.
## * An outcome is either an answer or the reason there is none, never both, and
##   one URL's failure never discards another's answer: a batch is not
##   all-or-nothing. A *client-level* fault (the relay worker stopped) raises
##   `FetchError`, because that is not a fact about any one URL.
## * `next` returns `none` exactly when every URL has been answered and the
##   client's window is empty again. A sweep owns that window while it runs, so
##   drive it to `none`, or `close` the client, which drains what is outstanding.
## * Memory is bounded by `maxInFlight` answer bodies, not by the size of the
##   batch: a caller that writes each body out and drops it can sweep gigabytes
##   of pictures (`ludex art` does exactly that). `fetchAll` is the deliberate
##   exception — it holds every body and says so — and is for small JSON answers.
## * Retries stay inside the rate limit. A URL that earns one goes to the back of
##   the queue with a backoff and is admitted through the pacer like any other
##   submission, so a `5xx` on one game cannot stall the sweep, and a retry
##   cannot make the source see a burst. A `429` additionally holds *every*
##   admission back: the source is refusing us, and retrying one URL at the same
##   rate is not an answer to that.
##
## ## Waiting
##
## Relay waits for a result the way a socket library does: blocking, or not at
## all. What a sweep is waiting for is whichever comes first — a finished
## request, or the moment the rate limit admits the next submission — so it
## waits in slices (`PollMs`), each sleep the smaller of the two. Blocking on a
## result would be simpler than that and wrong twice over: with answers slower
## than `delayMs` it would let the window run empty, and an empty window is
## exactly where overlap was supposed to be doing the work. Because polling
## never sees relay's "the worker stopped" return value, the sweep bounds
## silence instead (`StallMs`) and reports a stopped client once, as the one
## failure that is not about a URL.
##
## ## Answers, problems, and the cache
##
## A status the source may answer differently in a moment is *transient*: `429`
## and `5xx`. Those earn up to `MaxAttempts` submissions with exponential
## backoff, and if the last one is still transient the URL ends as a problem
## naming the status. Everything else — `2xx`, `404` — is an answer. A transport
## failure (timeout, DNS, TLS) is a problem too, and is not retried: a timeout is
## a fact about the connection rather than about the game, and retrying a
## 30-second timeout three times would triple the worst case of a sweep.
##
## Caching follows the same line: answers are remembered, problems are not. A
## `429` or a `5xx` written to the cache is a lie the next run believes, so the
## run that hits one is the run that retries it.
##
## ## Rejected shapes, and why
##
## * The whole batch handed to relay at once. Relay's queue is unbounded and its
##   dispatcher is what applies `maxInFlight`, so the sweep could not notice a
##   source refusing until that queue drained, and the pacer would race the
##   dispatcher instead of owning the schedule.
## * A `seq[FetchOutcome]` as the only primitive. Convenient, and right for small
##   answers — `fetchAll` is still that — but it holds every body, which is why
##   `ludex art` used to fetch one picture at a time and could overlap nothing.
## * An iterator (`for outcome in client.sweep(urls)`) reads better than a
##   cursor. `break` out of a `for` over an inline iterator skips the iterator's
##   remaining code, and a sweep that stops early leaves results undrained in a
##   *shared* relay instance; the state has to be an object the caller drives
##   explicitly, or the lifecycle is a trap.
## * A token bucket for the rate limit: see `ludexingest/pacer.nim` for the
##   arithmetic. It buys a few seconds on a sweep that takes hours and spends
##   margin against the source's real window budget.
## * Counting requests on the client and reporting them as a run's cost. The
##   counters here are cumulative session totals; a run's cost is the sweep's.
##   Taking it from the client only looked right because the CLI makes one client
##   per command.

import std/[deques, options, os, tables]

import relay

import ./[cache, pacer]

const
  DefaultAgent* = "ludex/0.1 (+https://github.com/ageralis/ludex)"
  DefaultDelayMs* = 250
  DefaultMaxInFlight* = 4
    ## How many answers may be outstanding at once. The pacer decides how often
    ## a request may be sent; this only decides how much of a slow source's
    ## latency is hidden by overlapping requests it already admitted.
  MaxAttempts = 4
    ## Submissions a single URL gets before a transient failure is final.
  TimeoutMs = 30000
    ## How long relay gives one request. Named here because the sweep's stall
    ## bound is derived from it: a request relay accepted always ends in a
    ## result within this, so silence for twice as long is not a slow source.
  PollMs = 50
    ## The longest the sweep waits without looking for a finished request. It
    ## bounds how late an answer can reach the caller; every sleep is
    ## `min(remaining, PollMs)`, so it never makes a submission late for the
    ## pacer.
  StallMs = 2 * TimeoutMs
    ## Silence longer than this, with submissions outstanding, is a client that
    ## stopped rather than a source that is slow.

type
  FetchError* = object of CatchableError
    ## Raised when a request cannot be completed, or when the client itself
    ## fails. A per-URL failure inside a sweep is an outcome, not this.

  Client* = ref object
    ## One source session: a cache, a rate limit, a retry policy and one relay
    ## handle. Created per source, closed when the command is done with it.
    cacheDir*: string
    offline*: bool
      ## Serve cached answers only; a miss is a problem, never a request.
    userAgent*: string
    requests*: int
      ## Requests this session has sent, cache hits excluded.
    hits*: int
      ## Answers this session has served from the cache.
    maxInFlight*: int
      ## The transport bound, passed to relay and used to size the window a
      ## sweep is allowed to keep outstanding.
    pacer: Pacer
    http: Relay
    nextRequestId: int64
      ## Sweep-independent: a result whose id this client never issued can only
      ## come from a sweep that was abandoned mid-flight, and is dropped rather
      ## than misattributed.

  Fetch* = object
    ## One response, whether it came off the wire or out of the cache.
    status*: int
    body*: string
    cached*: bool

  FetchOutcome* = object
    ## One URL's result: either an answer or the reason there is none.
    ##
    ## A single value rather than two parallel arrays, so "an answer or a
    ## problem, never both" is carried by the type instead of by a convention
    ## every caller has to remember. `key` and `url` name the request, because a
    ## streaming sweep hands outcomes back in completion order.
    key*: int
    url*: string
    answer*: Option[Fetch]
    problem*: string ## empty when `answer` is set

  SweepStats* = object
    ## What one sweep cost. The client's counters are session totals; these are
    ## the run's, which is what a summary line is talking about.
    requests*: int ## requests actually sent, cache hits excluded
    cached*: int ## answers served from the disk cache
    retries*: int ## admissions that were not a URL's first attempt
    cacheErrors*: int ## answers that could not be written to the cache
    elapsedMs*: int64 ## from the first admission to the last answer

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
    ## A value object rather than a `ref`: copying it would fork the bookkeeping
    ## of requests that are already in flight, so it is driven by `var` and left
    ## alone. The client it borrows is the shared, long-lived part.
    client: Client
    refresh: bool
    startedMs: int64
    headers: HttpHeaders
    queue: Deque[Pending] ## not yet admitted, in the order they were added
    inFlight: Table[int64, Pending] ## submitted and not yet read
    ready: Deque[FetchOutcome] ## answered and not yet taken by the caller
    lastResultMs: int64 ## when a finished request last arrived; stall bound
    stats*: SweepStats

proc initClient*(cacheDir: string; delayMs = DefaultDelayMs; offline = false;
                 userAgent = DefaultAgent;
                 maxInFlight = DefaultMaxInFlight): Client =
  ## Creates one source session.
  ##
  ## `delayMs` is the source's request budget expressed as the floor between two
  ## submissions; 0 means no pacing, which suits a source that answers once for
  ## the whole dataset. `offline` never opens a socket and treats a cache miss as
  ## a problem.
  result = Client(cacheDir: cacheDir, offline: offline, userAgent: userAgent,
                  maxInFlight: max(1, maxInFlight),
                  pacer: Pacer(delayMs: max(0, delayMs)))
  if not offline:
    result.http = newRelay(maxInFlight = result.maxInFlight,
                           defaultTimeoutMs = TimeoutMs)

proc close*(client: Client) =
  ## Releases the connection pool. Safe to call more than once.
  ##
  ## Relay's own `close` waits for queued and in-flight work, so this is also the
  ## way out of a sweep that was abandoned half-drained.
  if client.http != nil:
    client.http.close()
    client.http = nil

proc cachePath*(client: Client; url: string): string =
  ## The cache file this session would use for `url`, so a caller can point at it
  ## without knowing the naming rule.
  cache.cachePath(client.cacheDir, url)

proc writeCacheEntry*(client: Client; url: string; status: int; body: string)
    {.raises: [FetchError].} =
  ## Writes one entry into this session's cache.
  ##
  ## The tests seed a cache through here, which is what lets the whole pipeline
  ## run offline.
  try:
    cache.writeCacheEntry(client.cacheDir, url, status, body)
  except IOError as error:
    raise newException(FetchError, error.msg)

func isTransient(status: int): bool {.inline.} =
  ## A status the source is asking us to come back for: `429` (too many
  ## requests) or a `5xx` (the server is having a moment). Everything else is an
  ## answer, including `404`, which is a fact about the game rather than a
  ## failure of the request.
  status == 429 or status >= 500

func backoffMs(attempt: int): int {.inline.} =
  ## One retry's wait, doubling per attempt: 500 ms after the first submission,
  ## then 1000, then 2000.
  250 shl attempt

proc initSweep*(client: Client; urls: openArray[string]; refresh = false): Sweep =
  ## Opens a sweep over `urls`, keyed by position: `urls[i]` is `key` `i`.
  ##
  ## `refresh` ignores cache entries and fetches every URL again. Only one sweep
  ## at a time may use a client — the client's window is what a sweep owns — so
  ## the second one is a programming error, not a runtime state to handle.
  if not client.offline and client.http == nil:
    raise newException(FetchError, "client is closed")
  result.client = client
  result.refresh = refresh
  result.startedMs = monoMs()
  result.lastResultMs = result.startedMs
  result.headers = emptyHttpHeaders()
  result.headers["User-Agent"] = client.userAgent
  result.queue = initDeque[Pending](urls.len)
  for index, url in urls:
    result.queue.addLast(Pending(url: url, key: index, attempt: 1))

func pending*(sweep: Sweep): int =
  ## How many URLs the sweep still owes an answer for; 0 means it is drained.
  sweep.queue.len + sweep.inFlight.len

proc answerFromCache(sweep: var Sweep; item: var Pending): bool {.raises: [].} =
  ## Answers the head of the queue from the cache when there is an entry, and
  ## says whether it did.
  ##
  ## A cache hit costs no request and is therefore not paced: a warm rerun must
  ## not be slowed down by a rate limit that exists for sockets. On a hit the
  ## item's URL moves into the outcome, because the queue item is dropped.
  if sweep.refresh:
    return false
  let cached = cache.readCacheEntry(sweep.client.cacheDir, item.url)
  if cached.isNone:
    return false
  inc sweep.stats.cached
  inc sweep.client.hits
  sweep.ready.addLast(FetchOutcome(
    key: item.key, url: move item.url,
    answer: some Fetch(status: cached.get.status, body: cached.get.body,
                       cached: true)))
  result = true

proc cacheAnswer(sweep: var Sweep; url: string; fetched: Fetch) {.raises: [].} =
  ## Remembers an answer. A cache write failure is counted, never raised: the
  ## answer is already in hand, and losing it over a disk problem would waste the
  ## request that earned it.
  try:
    cache.writeCacheEntry(sweep.client.cacheDir, url, fetched.status,
                          fetched.body)
  except IOError:
    inc sweep.stats.cacheErrors

proc submit(sweep: var Sweep; item: sink Pending) {.raises: [].} =
  ## Hands one admitted URL to relay, or records why it could not be handed over.
  ##
  ## Handing it over one at a time is what keeps relay's own queue empty: the
  ## sweep holds only what the pacer has already admitted and the window still
  ## has room for. A relay that refuses the request (`startRequest` raises
  ## `IOError` for a closed client) becomes this URL's problem, so it stays a
  ## fact about the sweep rather than an exception out of it.
  let client = sweep.client
  let requestId = client.nextRequestId
  inc client.nextRequestId
  let started = try:
                  client.http.startRequest(RequestSpec(
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
    inc client.requests
    if item.attempt > 1:
      inc sweep.stats.retries

proc take(sweep: var Sweep; item: sink RequestResult) {.raises: [].} =
  ## Files one finished request as an answer, a retry or a problem.
  ##
  ## Takes the result by `sink` because it is the last thing the caller does with
  ## it: an answer body is the biggest value in this module, and copying it here
  ## would be for nothing.
  let requestId = item.response.request.requestId
  var pending: Pending
  if not sweep.inFlight.pop(requestId, pending):
    # Only reachable when two sweeps share one client, which the API forbids:
    # the id belongs to a sweep that was abandoned mid-flight.
    assert false, "result for a request this sweep does not own"
    return
  if item.error.kind != teNone:
    sweep.ready.addLast(FetchOutcome(key: pending.key, url: pending.url,
      problem: "GET " & pending.url & ": " & $item.error.kind & " " &
               item.error.message))
    return
  let status = item.response.code.int
  if isTransient(status):
    if pending.attempt < MaxAttempts:
      let waitMs = backoffMs(pending.attempt)
      inc pending.attempt
      pending.dueAtMs = monoMs() + int64(waitMs)
      sweep.queue.addLast(pending) # to the back: a retry jumps nobody's place
      if status == 429:
        sweep.client.pacer.hold(monoMs(), waitMs)
      return
    sweep.ready.addLast(FetchOutcome(key: pending.key, url: pending.url,
      problem: "GET " & pending.url & ": HTTP " & $status & " after " &
               $MaxAttempts & " attempts"))
    return
  var fetched = Fetch(status: status, body: item.response.body, cached: false)
  sweep.cacheAnswer(pending.url, fetched)
  sweep.ready.addLast(FetchOutcome(key: pending.key, url: pending.url,
                                   answer: some fetched))

proc waitForFinished(sweep: var Sweep; dueMs: int64;
                     item: var RequestResult): bool {.raises: [FetchError].} =
  ## Waits a slice for one finished request, and says whether one arrived.
  ##
  ## Relay has no wait-with-timeout: it offers a blocking wait and a poll. The
  ## sweep waits in slices instead, and the slice is the smaller of the time
  ## until the rate limit admits the next submission and `PollMs` — so an answer
  ## reaches the caller promptly, and a submission lands on the pacer's deadline
  ## rather than after it. Blocking outright would be simpler and wrong: with
  ## answers slower than `delayMs` it lets the window run empty, and that is
  ## exactly the case where overlapping is the only throughput there is.
  ##
  ## The price of polling is that relay's "the worker stopped" return value is
  ## never seen, so silence is bounded here instead: every request relay accepts
  ## ends in a result within its own timeout, so a much longer silence with
  ## submissions outstanding is a stopped client, reported once for the whole
  ## sweep rather than once per URL.
  let slice = if dueMs > 0: min(dueMs, int64(PollMs)) else: int64(PollMs)
  sleep(max(slice, 1).int)
  result = sweep.client.http.pollForResult(item)
  if result:
    sweep.lastResultMs = monoMs()
  elif sweep.inFlight.len > 0 and monoMs() - sweep.lastResultMs > StallMs:
    raise newException(FetchError, "no answer for " & $(StallMs div 1000) &
                       " seconds with requests outstanding")

proc step(sweep: var Sweep) {.raises: [FetchError].} =
  ## One transition of the sweep, in priority order:
  ##
  ## 1. Answer the head of the queue from the cache, which costs no request and
  ##    is therefore not paced.
  ## 2. Submit it, when the rate limit and the window both allow.
  ## 3. Take one finished request, waiting for it in the way that does not
  ##    starve the pacer (`waitForFinished`).
  ## 4. With nothing on the wire, sleep out the rate limit, because that is the
  ##    only thing left to wait for.
  let now = monoMs()
  var dueMs: int64 = 0
  if sweep.queue.len > 0:
    dueMs = sweep.client.pacer.dueInMs(now)
    dueMs = max(dueMs, sweep.queue.peekFirst.dueAtMs - now)
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
  ## The next answer, blocking until one is ready.
  ##
  ## `none` means the sweep is drained: every URL has been answered and the
  ## client's window is empty. That is the only exit a caller needs.
  if not sweep.client.offline and sweep.client.http == nil:
    raise newException(FetchError, "client is closed")
  while sweep.ready.len == 0 and pending(sweep) > 0:
    sweep.step()
  if sweep.ready.len > 0:
    result = some sweep.ready.popFirst()
  else:
    sweep.stats.elapsedMs = monoMs() - sweep.startedMs

proc fetchAll*(client: Client; urls: openArray[string]; refresh = false):
    SweepResult {.raises: [FetchError].} =
  ## Fetches every URL and returns one outcome per URL, in the order given.
  ##
  ## This holds every body in memory at once, which makes it the right call for a
  ## few thousand JSON answers and the wrong one for pictures; `initSweep` and
  ## `next` are the streaming form. Memory is bounded by the batch here, on
  ## purpose and in the open.
  var sweep = initSweep(client, urls, refresh)
  result.outcomes = newSeq[FetchOutcome](urls.len)
  var answered = 0
  while answered < urls.len:
    let outcome = sweep.next()
    if outcome.isNone:
      break
    var item = outcome.get
    result.outcomes[item.key] = item
    inc answered
  assert answered == urls.len, "a drained sweep answers every URL it was given"
  result.stats = sweep.stats

proc fetch*(client: Client; url: string; refresh = false): Fetch
    {.raises: [FetchError].} =
  ## The single-URL case of a sweep, and the one place a missing answer raises:
  ## a caller that asked for exactly one thing has no per-URL result to inspect.
  ## A `404` is still an answer, not a failure.
  var sweep = initSweep(client, [url], refresh)
  let outcome = sweep.next()
  if outcome.isNone:
    raise newException(FetchError, "no answer for " & url)
  if outcome.get.answer.isNone:
    raise newException(FetchError, outcome.get.problem)
  result = outcome.get.answer.get
