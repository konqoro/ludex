## Tests for the batch boundary: one outcome per URL, keyed by the position it was
## added at, with an answer or a reason but never both.
##
## Offline mode is what makes this deterministic. A URL with a cache entry is
## answered without a socket and a URL without one is a recorded problem, so the
## whole contract — keys, order, counters, and the drain signal — is exercised
## with no network and no sleeping.

import std/[algorithm, options, os, strutils]

import ludexingest/[cache, fetch]

proc tempCache(name: string): string =
  result = getTempDir() / ("ludex-fetch-" & name & "-" & $getCurrentProcessId())
  removeDir(result)

const
  SeedOne = "https://example.test/one.json"
  SeedTwo = "https://example.test/two.json"
  Missing = "https://example.test/gone.json"

block cache_file_names_are_safe_and_readable:
  doAssert cacheFileName("https://a/b.json") == "https___a_b.json"
  doAssert cacheFileName("") == ""
  doAssert cacheFileName("plain") == "plain", "a safe name is left alone"
  doAssert cacheFileName("x".repeat(400)).len == 180, "long names are capped"

block a_cached_response_is_an_answer_that_names_its_request:
  let dir = tempCache("hit")
  let client = initClient(dir, delayMs = 0, offline = true)
  writeCacheEntry(dir, SeedTwo, 200, """{"tier":"gold"}""")
  let swept = fetchAll(client, @[SeedTwo], refresh = false)
  client.close()

  doAssert swept.outcomes.len == 1
  let outcome = swept.outcomes[0]
  doAssert outcome.key == 0, "the key is the position the URL was added at"
  doAssert outcome.url == SeedTwo, "and the outcome names the URL it is about"
  doAssert outcome.answer.isSome, "a cache entry is an answer"
  doAssert outcome.answer.get.status == 200
  doAssert outcome.answer.get.body.contains("gold")
  doAssert outcome.answer.get.cached, "and it knows where it came from"
  doAssert outcome.problem.len == 0, "an answer and a problem are exclusive"
  doAssert swept.stats.cached == 1
  doAssert swept.stats.requests == 0, "a cache hit sends nothing"

block a_miss_offline_is_a_problem_and_not_a_request:
  let dir = tempCache("miss")
  let client = initClient(dir, delayMs = 0, offline = true)
  let swept = fetchAll(client, @[Missing])
  client.close()

  let outcome = swept.outcomes[0]
  doAssert outcome.answer.isNone
  doAssert outcome.problem.contains("offline"), "the reason says what happened"
  doAssert outcome.problem.contains(Missing), "and which URL it happened to"
  doAssert swept.stats.requests == 0, "offline never sends anything"
  doAssert swept.stats.cached == 0

block one_outcome_per_url_in_the_order_given:
  # The batch boundary's promise: outcomes line up with the URLs, so a caller
  # that keys its own data by position can index straight into them.
  let dir = tempCache("order")
  let client = initClient(dir, delayMs = 0, offline = true)
  writeCacheEntry(dir, SeedOne, 200, "one")
  writeCacheEntry(dir, SeedTwo, 404, "")
  let urls = @[SeedOne, Missing, SeedTwo]
  let swept = fetchAll(client, urls)
  client.close()

  doAssert swept.outcomes.len == urls.len
  for index, outcome in swept.outcomes:
    doAssert outcome.key == index
    doAssert outcome.url == urls[index]
  doAssert swept.outcomes[0].answer.get.body == "one"
  doAssert swept.outcomes[1].answer.isNone, "the URL in the middle is missing"
  doAssert swept.outcomes[2].answer.isSome, "and the last one still answers"

block a_404_is_an_answer:
  # ProtonDB answers 404 for a game nobody reported: a fact worth keeping, and
  # not a reason to retry.
  let dir = tempCache("404")
  let client = initClient(dir, delayMs = 0, offline = true)
  writeCacheEntry(dir, SeedOne, 404, "")
  let swept = fetchAll(client, @[SeedOne])
  client.close()
  doAssert swept.outcomes[0].answer.isSome
  doAssert swept.outcomes[0].answer.get.status == 404
  doAssert swept.outcomes[0].answer.get.body.len == 0
  doAssert swept.outcomes[0].problem.len == 0

block a_sweep_hands_back_every_url_once_and_then_says_it_is_done:
  let dir = tempCache("stream")
  let client = initClient(dir, delayMs = 0, offline = true)
  writeCacheEntry(dir, SeedOne, 200, "one")
  let urls = @[SeedOne, Missing, SeedTwo]
  var sweep = initSweep(client, urls)

  var keys: seq[int] = @[]
  var urlsSeen: seq[string] = @[]
  while true:
    let outcome = sweep.next()
    if outcome.isNone:
      break
    keys.add outcome.get.key
    urlsSeen.add outcome.get.url
  client.close()

  keys.sort()
  urlsSeen.sort()
  doAssert keys == @[0, 1, 2], "every URL is answered exactly once"
  var sortedUrls = @[SeedOne, Missing, SeedTwo]
  sortedUrls.sort()
  doAssert urlsSeen == sortedUrls
  doAssert sweep.next().isNone, "and it stays drained when asked again"
  doAssert sweep.stats.elapsedMs >= 0

block an_empty_sweep_is_done_immediately:
  let dir = tempCache("empty")
  let client = initClient(dir, delayMs = 0, offline = true)
  var sweep = initSweep(client, newSeq[string]())
  doAssert sweep.next().isNone
  client.close()

block refresh_ignores_a_cache_entry:
  # `--offline --refresh` is a contradiction the caller can still write down: it
  # asks for the network without going to the network, so the answer is that
  # there is none. It must not silently serve the entry it was told to ignore.
  let dir = tempCache("refresh")
  let client = initClient(dir, delayMs = 0, offline = true)
  writeCacheEntry(dir, SeedOne, 200, "one")
  let swept = fetchAll(client, @[SeedOne], refresh = true)
  client.close()
  doAssert swept.outcomes[0].answer.isNone
  doAssert swept.stats.cached == 0

block a_corrupt_cache_file_is_a_miss:
  let dir = tempCache("corrupt")
  let client = initClient(dir, delayMs = 0, offline = true)
  createDir(dir)
  writeFile(cachePath(dir, SeedOne), "this is not a cache entry")
  doAssert readCacheEntry(dir, SeedOne).isNone
  let swept = fetchAll(client, @[SeedOne])
  client.close()
  doAssert swept.outcomes[0].answer.isNone, "junk is a miss, never a response"

block a_transient_status_in_the_cache_is_a_miss:
  # An older version of this client cached a terminal 429 or 5xx as if it were an
  # answer. Believing it now would be exactly the lie the write side refuses to
  # write: the URL has to be asked again.
  let dir = tempCache("transient")
  let client = initClient(dir, delayMs = 0, offline = true)
  writeCacheEntry(dir, SeedOne, 500, "the server was having a moment")
  writeCacheEntry(dir, SeedTwo, 429, "")
  let swept = fetchAll(client, @[SeedOne, SeedTwo])
  client.close()
  for outcome in swept.outcomes:
    doAssert outcome.answer.isNone, "a cached failure is not an answer"
    doAssert outcome.problem.contains("offline")
  doAssert swept.stats.cached == 0

block a_cache_write_leaves_no_temporary_file_behind:
  # The entry is written beside its name and renamed into place, so a killed run
  # cannot leave a truncated body that reads back as an answer.
  let dir = tempCache("atomic")
  writeCacheEntry(dir, SeedOne, 200, "one")
  var entries: seq[string] = @[]
  for path in walkFiles(dir / "*"):
    entries.add path.extractFilename
  doAssert entries == @[cacheFileName(SeedOne)],
    "one entry, and no half-written file next to it"
  doAssert readCacheEntry(dir, SeedOne).get.body == "one"

block a_client_is_owned_by_one_sweep_at_a_time:
  # Two sweeps sharing a client's window would interleave their requests, and
  # neither could tell whose answer arrived. That is refused, not guessed at.
  let dir = tempCache("owned")
  let client = initClient(dir, delayMs = 0, offline = true)
  writeCacheEntry(dir, SeedOne, 200, "one")
  var open = initSweep(client, @[SeedOne, SeedTwo])
  doAssertRaises FetchError:
    discard initSweep(client, @[SeedTwo])
  while open.next().isSome:
    discard
  client.close()

block a_drained_sweep_hands_the_client_back:
  let dir = tempCache("handback")
  let client = initClient(dir, delayMs = 0, offline = true)
  writeCacheEntry(dir, SeedOne, 200, "one")
  let first = fetchAll(client, @[SeedOne])
  doAssert first.outcomes[0].answer.isSome
  let second = fetchAll(client, @[SeedOne])
  doAssert second.outcomes[0].answer.isSome, "the next sweep is welcome"
  client.close()

block a_single_url_is_a_sweep_of_one:
  let dir = tempCache("single")
  let client = initClient(dir, delayMs = 0, offline = true)
  writeCacheEntry(dir, SeedOne, 200, "one")
  let hit = fetchAll(client, @[SeedOne])
  doAssert hit.outcomes[0].answer.get.status == 200
  doAssert hit.outcomes[0].answer.get.cached
  let miss = fetchAll(client, @[Missing])
  doAssert miss.outcomes[0].answer.isNone
  client.close()

echo "tfetch: ok"
