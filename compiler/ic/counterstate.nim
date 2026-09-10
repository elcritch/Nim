#
#           The Nim Compiler
#        (c) Copyright 2026 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## A CacheCounter read depends on the program's preceding compile-time actions,
## including sibling modules. Until IC can track and replay that global history
## incrementally, these programs require a single semantic compilation session.

import std/[os, syncio]
import ../[options, pathutils]

proc counterSessionFile*(conf: ConfigRef): string =
  getNimcacheDir(conf).string / "ic.counter-session"

proc requireCounterSession*(conf: ConfigRef) =
  if conf.cmd == cmdM and conf.icProject.len > 0 and
      not conf.icWholeProject and not conf.ideActive:
    # Stop before observing or allocating an invalid value. The driver waits
    # for its children, detects this request even after a failed frontend run,
    # and retries from the project root with all modules in the same process.
    writeFile(counterSessionFile(conf), "")
    quit(1)
