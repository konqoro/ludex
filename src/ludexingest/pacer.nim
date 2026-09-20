## Admission control for one source: the rate limit, and nothing else.
##
## A concurrency bound and a rate limit are different promises, and this module
## exists so the difference is a type rather than a comment. Relay's
## `maxInFlight` says "no more than N sockets are open"; it does not stop N fast
## answers from arriving as a burst, which is exactly what gets an address
## throttled by a source that publishes a request budget. A `Pacer` is the other
## promise: one submission per `delayMs`, measured against the previous
## *admission*, so a fast answer cannot turn a fixed budget into a burst and a
## slow one cannot add to the spacing.
##
## The clock is a parameter, not a call inside. `dueInMs` and `admit` are
## functions of (state, timestamp), so the floor is pinned by a test with an
## injected clock instead of asserted in prose, and the sleeping belongs to
## whoever owns the work: a pacer that slept would be untestable and would also
## be lying about who waits.
##
## ## Why a floor, and not a token bucket
##
## A token bucket with capacity c allows c submissions in one instant and then
## the same average. Measured against the sweep that motivates the delay here —
## Steam, ~200 requests per five minutes, 1600 ms as the floor — the bucket's
## whole gain is the first c-1 intervals: four seconds out of a sweep that takes
## hours, because the average is what governs and the floor already delivers the
## average. What it costs is margin: the source's window budget is a sliding
## window, so a bucket that spends c requests at once can only be more likely to
## trip it, never less. `hold` keeps the part of a bucket that is actually
## useful — a source that answers 429 is telling us our idea of its budget is too
## generous, and every admission, not just the one that was refused, is pushed
## back.

import std/monotimes

type
  Pacer* = object
    ## The rate limit for one source. Times are `monoMs` values.
    delayMs*: int
      ## The floor between two submissions; 0 means no pacing at all, which is
      ## what a source that answers once for the whole dataset wants.
    lastMs: int64
      ## When the last submission was admitted. 0 means "never", which is why a
      ## fresh pacer admits immediately.
    holdUntilMs: int64
      ## A cooldown the source itself asked for; no admission before this.

proc monoMs*(): int64 =
  ## The monotonic clock in milliseconds.
  ##
  ## A `proc` rather than a `func`, because reading a clock is not pure — which
  ## is exactly why the pacer takes the timestamp as a parameter instead of
  ## calling this itself. Monotonic on purpose: a rate limit measured against the
  ## wall clock can jump backwards under NTP and admit a burst it has already
  ## spent. `MonoTime` always carries nanosecond ticks, whatever the platform's
  ## clock granularity is, so dividing is exact enough for a delay measured in
  ## milliseconds.
  ticks(getMonoTime()) div 1_000_000

func dueInMs*(pacer: Pacer; nowMs: int64): int64 =
  ## Milliseconds still to wait before the next submission is due; 0 means now.
  ##
  ## The result is never negative, so a caller can use it as a sleep without
  ## clamping: a submission that arrived late is due immediately.
  if pacer.delayMs > 0 and pacer.lastMs > 0:
    result = max(result, int64(pacer.delayMs) - (nowMs - pacer.lastMs))
  result = max(result, pacer.holdUntilMs - nowMs)

proc admit*(pacer: var Pacer; nowMs: int64) =
  ## Stamps an admission. The caller has already waited out `dueInMs`.
  pacer.lastMs = nowMs

proc hold*(pacer: var Pacer; nowMs: int64; ms: int) =
  ## Pushes every admission back by `ms` from `nowMs`.
  ##
  ## A 429 is the source refusing us, so the honest answer is to slow the whole
  ## sweep down rather than to retry one URL at the same rate. A hold only ever
  ## extends the wait: two holds in a row keep the later one.
  if ms > 0:
    pacer.holdUntilMs = max(pacer.holdUntilMs, nowMs + int64(ms))
