discard """
  joinable: false
  cmd: "nim c --threads:on -r $options $file"
  matrix: "--mm:arc --undef:useFork; --mm:atomicArc --undef:useFork; --mm:arc -d:useFork"
"""

import std/[os, osproc, streams, strutils, tempfiles, atomics]

type Work = object
  executable, directory, parent: string

var finished: Atomic[int]

proc run(work: Work) {.thread.} =
  for i in 0..<16:
    let child = startProcess(work.executable, workingDir = work.directory,
                            args = ["cwd"], options = {poStdErrToStdOut})
    child.inputStream.close()
    let actual = child.outputStream.readAll().strip()
    doAssert child.waitForExit() == 0
    child.close()
    doAssert actual == work.directory, actual
    doAssert getCurrentDir() == work.parent
  discard finished.fetchAdd(1)

if paramCount() > 0:
  echo getCurrentDir()
else:
  let parent = getCurrentDir()
  let dir = expandFilename(createTempDir("nim_osproc_cwd_", ""))
  try:
    # A failed exec after chdir used to leave the parent in the child's cwd.
    var failed = false
    try:
      let child = startProcess(dir / "missing", workingDir = dir)
      child.close()
    except OSError:
      failed = true
    doAssert failed
    doAssert getCurrentDir() == parent

    var threads: array[4, Thread[Work]]
    for i in 0..<threads.len:
      let working = dir / $i
      createDir(working)
      createThread(threads[i], run,
        Work(executable: getAppFilename(), directory: working, parent: parent))
    while finished.load() != threads.len:
      doAssert getCurrentDir() == parent
      sleep(1)
    joinThreads(threads)
    doAssert getCurrentDir() == parent
  finally:
    removeDir(dir)
