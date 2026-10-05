## Optional eligibility accounting, including modules that have no body jobs.
import std/[tables, json]

var bodyCensusEnabled* {.threadvar.}: bool
var decisions {.threadvar.}: Table[(string, uint64), string]

proc bodyDecision*(module: string; ordinal: uint64; reason: string) =
  if bodyCensusEnabled: decisions[(module, ordinal)] = reason

proc finishBodyCensus*(): string =
  result = ""
  if not bodyCensusEnabled: return
  var modules = initTable[string, CountTable[string]]()
  for key, reason in decisions:
    modules.mgetOrPut(key[0], initCountTable[string]()).inc reason
  for module, counts in modules:
    var reasons = newJObject()
    for reason, count in counts: reasons[reason] = %count
    result.add "ICBODYSTATS " & $(%*{"module": module, "reasons": reasons}) & "\n"
  decisions.clear()
  bodyCensusEnabled = false
