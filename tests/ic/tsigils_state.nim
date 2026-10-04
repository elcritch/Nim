discard """
  description: '''IC module actors isolate compile-time environment and reused worker state'''
"""

#? metamorphic

#!FILE left.nim
import std/os
static:
  delEnv("NIM_IC_SIGILS_TEST_LOCAL")
  putEnv("NIM_IC_SIGILS_TEST_LOCAL", "left")
  doAssert getEnv("NIM_IC_SIGILS_TEST_LOCAL") == "left"
  when defined(posix):
    doAssert staticExec("sleep 0.05; printf '%s' \"$NIM_IC_SIGILS_TEST_LOCAL\"") == "left"
  doAssert getEnv("NIM_IC_SIGILS_TEST_LOCAL") == "left"
proc valueLeft*(): int = 20

#!FILE right.nim
import std/os
static:
  delEnv("NIM_IC_SIGILS_TEST_LOCAL")
  putEnv("NIM_IC_SIGILS_TEST_LOCAL", "right")
  doAssert getEnv("NIM_IC_SIGILS_TEST_LOCAL") == "right"
  when defined(posix):
    doAssert staticExec("sleep 0.05; printf '%s' \"$NIM_IC_SIGILS_TEST_LOCAL\"") == "right"
  doAssert getEnv("NIM_IC_SIGILS_TEST_LOCAL") == "right"
proc valueRight*(): int = 22

#!FILE main.nim
import left, right
echo valueLeft() + valueRight()
#!STEP expect: 42

#!FILE left.nim
import std/os
static:
  delEnv("NIM_IC_SIGILS_TEST_LOCAL")
  putEnv("NIM_IC_SIGILS_TEST_LOCAL", "edited")
proc valueLeft*(): int = 40
#!STEP expect: 62
