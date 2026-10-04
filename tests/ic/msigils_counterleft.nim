import std/macrocache

const ids = CacheCounter"ic_sigils_counter_test"
static: ids.inc()
const leftId* = ids.value
