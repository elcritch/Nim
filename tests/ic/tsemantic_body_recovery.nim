discard """
  description: '''IC: recover a procedure body used at compile time after an edit'''
"""

#? metamorphic

#!FILE helper.nim
func value*(): int = 11

#!FILE main.nim
import helper
const baked = value()
echo baked, " ", value()
#!STEP expect: 11 11

#!FILE helper.nim
func value*(): int = 29
#!STEP expect: 29 29
