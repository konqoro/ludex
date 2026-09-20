## Tests for the rate limit itself.
##
## The floor is a promise about the *network* — "one request per 1600 ms" — which
## a test suite can neither sleep through nor be allowed to check against a live
## source. So the pacer takes the time as a parameter and this file pins the
## schedule with an injected clock: no server, no sleeping, and the same numbers
## the live measurement later checks from the server side.

import std/assertions

import ludexingest/pacer

block the_first_submission_is_immediate:
  let pacer = Pacer(delayMs: 1600)
  doAssert dueInMs(pacer, 0) == 0,
    "nothing has been admitted yet, so nothing is held back"

block a_clock_reading_of_zero_is_still_a_floor:
  # The reason "has anything been admitted" is a flag and not a sentinel value: a
  # monotonic clock can read 0, and a pacer that mistook that for "never" would
  # skip the floor on the second submission.
  var pacer = Pacer(delayMs: 1600)
  admit(pacer, 0)
  doAssert dueInMs(pacer, 0) == 1600
  doAssert dueInMs(pacer, 1599) == 1

block one_submission_per_delay:
  var pacer = Pacer(delayMs: 1600)
  admit(pacer, 10_000)
  doAssert dueInMs(pacer, 10_000) == 1600
  doAssert dueInMs(pacer, 10_800) == 800
  doAssert dueInMs(pacer, 11_599) == 1
  doAssert dueInMs(pacer, 11_600) == 0, "the floor is the delay, not more"

block the_floor_is_measured_from_the_previous_admission:
  # The invariant that makes this a rate limit rather than a sleep after each
  # round: a slow answer must not add another delay on top, and a fast answer
  # must not shorten the gap.
  var pacer = Pacer(delayMs: 1600)
  admit(pacer, 0)
  doAssert dueInMs(pacer, 5000) == 0, "a slow answer is already past the floor"
  admit(pacer, 5000)
  doAssert dueInMs(pacer, 5001) == 1599

block a_zero_delay_never_holds_anything:
  # A source that answers once for the whole dataset has no budget to respect.
  var pacer = Pacer(delayMs: 0)
  admit(pacer, 42)
  doAssert dueInMs(pacer, 42) == 0

block a_hold_pushes_every_admission_back:
  # A 429 is the source saying our idea of its budget is wrong; the hold is the
  # whole-sweep answer to it, not a penalty on one URL.
  var pacer = Pacer(delayMs: 250)
  admit(pacer, 1000)
  hold(pacer, 1200, 2000)
  doAssert dueInMs(pacer, 1200) == 2000
  doAssert dueInMs(pacer, 3199) == 1
  doAssert dueInMs(pacer, 3200) == 0

block a_hold_never_shortens_the_delay:
  var pacer = Pacer(delayMs: 1600)
  hold(pacer, 0, 100)
  admit(pacer, 200)
  doAssert dueInMs(pacer, 200) == 1600, "the delay still applies after a hold"
  hold(pacer, 300, 50)
  doAssert dueInMs(pacer, 300) == 1500, "and a second, shorter hold adds nothing"
  hold(pacer, 300, 5000)
  doAssert dueInMs(pacer, 300) == 5000, "while a longer one does"

echo "tpacer: ok"
