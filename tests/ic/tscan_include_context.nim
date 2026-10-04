discard """
  description: '''IC: parallel scans preserve include context and reuse edited parses'''
"""

#? metamorphic

#!FILE mainvalue.nim
proc contextValue*(): string = "main"

#!FILE importedvalue.nim
proc contextValue*(): string = "imported"

#!FILE shared.nim
when isMainModule:
  import mainvalue
else:
  import importedvalue

#!FILE worker.nim
include shared
proc workerValue*(): string = contextValue()

#!FILE main.nim
include shared
import worker
echo contextValue(), " ", workerValue()
#!STEP expect: main imported
# Allow the backend's recorded body-dependency edges to settle before no-op.
#!STEP expect: main imported
#!STEP expect: main imported; noop

# The include is parsed only once even though it has two guard contexts.
#!FILE shared.nim
when isMainModule:
  import mainvalue
else:
  import importedvalue
proc decorated(): string = contextValue() & "!"

#!FILE worker.nim
include shared
proc workerValue*(): string = decorated()

#!FILE main.nim
include shared
import worker
echo decorated(), " ", workerValue()
#!STEP expect: main! imported!
#!STEP expect: main! imported!
#!STEP expect: main! imported!; noop

#!FILE importedvalue.nim
proc contextValue*(): string = "edited"
#!STEP expect: main! edited!

# Exercise the same cache through the process fallback.
#!FLAGS -d:icProcesses
#!STEP expect: main! edited!
