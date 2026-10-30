## Experimental LMDB backing for IC module BIFs. Marker files continue to
## provide the paths and modification times used by nifmake.
when defined(icLmdb):
  import std/[os, strutils, syncio, tables]

  {.passl: "-llmdb".}
  type
    Env {.importc: "MDB_env", header: "<lmdb.h>", incompleteStruct.} = object
    Txn {.importc: "MDB_txn", header: "<lmdb.h>", incompleteStruct.} = object
    Dbi = cuint
    Val {.importc: "MDB_val", header: "<lmdb.h>", bycopy.} = object
      size {.importc: "mv_size".}: csize_t
      data {.importc: "mv_data".}: pointer
    Database = object
      env: ptr Env
      dbi: Dbi

  {.push cdecl, importc, header: "<lmdb.h>".}
  proc mdb_env_create(env: ptr ptr Env): cint
  proc mdb_env_set_mapsize(env: ptr Env; size: csize_t): cint
  proc mdb_env_set_maxreaders(env: ptr Env; readers: cuint): cint
  proc mdb_env_open(env: ptr Env; path: cstring; flags: cuint; mode: cuint): cint
  proc mdb_reader_check(env: ptr Env; dead: ptr cint): cint
  proc mdb_txn_begin(env: ptr Env; parent: ptr Txn; flags: cuint; txn: ptr ptr Txn): cint
  proc mdb_txn_commit(txn: ptr Txn): cint
  proc mdb_txn_abort(txn: ptr Txn)
  proc mdb_dbi_open(txn: ptr Txn; name: cstring; flags: cuint; dbi: ptr Dbi): cint
  proc mdb_get(txn: ptr Txn; dbi: Dbi; key, value: ptr Val): cint
  proc mdb_put(txn: ptr Txn; dbi: Dbi; key, value: ptr Val; flags: cuint): cint
  proc mdb_strerror(err: cint): cstring
  {.pop.}

  const
    ReadOnly = 0x20000'u32 # MDB_RDONLY
    NoTls = 0x200000'u32   # MDB_NOTLS: several retained read transactions per thread
    NotFound = -30798.cint # MDB_NOTFOUND
    Marker = "IC LMDB BIF\n"

  var databases = initTable[string, Database]()

  proc check(rc: cint; operation: string) =
    if rc != 0:
      raise newException(IOError, operation & ": " & $mdb_strerror(rc))

  proc isModuleBif*(path: string): bool =
    path.endsWith(".s.bif") or path.endsWith(".t.bif")

  proc database(path: string): Database =
    let dir = parentDir(path) / ".ic-lmdb"
    if databases.hasKey(dir): return databases[dir]
    createDir(dir)
    var db = Database()
    check mdb_env_create(addr db.env), "lmdb env create"
    when sizeof(pointer) == 8:
      check mdb_env_set_mapsize(db.env, csize_t(64'u64 * 1024 * 1024 * 1024)), "lmdb mapsize"
    else:
      check mdb_env_set_mapsize(db.env, csize_t(1024 * 1024 * 1024)), "lmdb mapsize"
    check mdb_env_set_maxreaders(db.env, 8192), "lmdb maxreaders"
    check mdb_env_open(db.env, dir.cstring, NoTls, 0o664), "lmdb open " & dir
    var dead = 0.cint
    check mdb_reader_check(db.env, addr dead), "lmdb reader check"
    var txn: ptr Txn = nil
    check mdb_txn_begin(db.env, nil, ReadOnly, addr txn), "lmdb begin"
    check mdb_dbi_open(txn, nil, 0, addr db.dbi), "lmdb dbi open"
    check mdb_txn_commit(txn), "lmdb dbi commit"
    databases[dir] = db
    result = db

  proc putBif*(path, content: string; stable: bool) =
    let db = database(path)
    let name = extractFilename(path)
    var key = Val(size: csize_t(name.len), data: cast[pointer](name.cstring))
    var value = Val(size: csize_t(content.len), data: cast[pointer](content.cstring))
    var old = Val()
    var txn: ptr Txn = nil
    check mdb_txn_begin(db.env, nil, 0, addr txn), "lmdb write begin"
    let found = mdb_get(txn, db.dbi, addr key, addr old)
    if found != 0 and found != NotFound:
      mdb_txn_abort(txn)
      check found, "lmdb get"
    let changed = found == NotFound or old.size != value.size or
                  (content.len > 0 and not equalMem(old.data, value.data, content.len))
    if changed:
      let rc = mdb_put(txn, db.dbi, addr key, addr value, 0)
      if rc != 0:
        mdb_txn_abort(txn)
        check rc, "lmdb put"
      check mdb_txn_commit(txn), "lmdb commit"
    else:
      mdb_txn_abort(txn)
    if changed or not stable or not fileExists(path):
      writeFile(path, Marker)

  proc borrowBif*(path: string): tuple[data: pointer, size: int] =
    ## A retained read transaction keeps borrowed pages valid for the compiler
    ## process lifetime, matching the existing BIF mmap lifetime. LMDB values
    ## are not guaranteed to be aligned, so copy only unaligned values.
    result = (nil, 0)
    let db = database(path)
    let name = extractFilename(path)
    var key = Val(size: csize_t(name.len), data: cast[pointer](name.cstring))
    var value = Val()
    var txn: ptr Txn = nil
    check mdb_txn_begin(db.env, nil, ReadOnly, addr txn), "lmdb read begin"
    let rc = mdb_get(txn, db.dbi, addr key, addr value)
    if rc != 0:
      mdb_txn_abort(txn)
      check rc, "lmdb get " & path
    result.size = int(value.size)
    if (cast[uint](value.data) and 7) == 0:
      result.data = value.data
      # Deliberately retain txn: the tokens and lazy names borrow its pages.
    else:
      result.data = alloc(result.size)
      copyMem(result.data, value.data, result.size)
      mdb_txn_abort(txn)

  when defined(icLmdbBlocks):
    type Snapshot* = ref object
      db: Database
      txn: ptr Txn
      name: string

    proc getValue(txn: ptr Txn; db: Database; name: string): Val =
      var key = Val(size: csize_t(name.len), data: cast[pointer](name.cstring))
      result = Val()
      let rc = mdb_get(txn, db.dbi, addr key, addr result)
      if rc != 0: check rc, "lmdb get " & name

    proc beginSnapshot*(path: string): Snapshot =
      new result
      result.db = database(path)
      result.name = extractFilename(path)
      check mdb_txn_begin(result.db.env, nil, ReadOnly, addr result.txn), "lmdb snapshot"

    proc record*(s: Snapshot; suffix: string): tuple[data: pointer, size: int] =
      let val = getValue(s.txn, s.db, s.name & suffix)
      (val.data, int(val.size))

    proc putRecords*(path, manifest: string; blocks: openArray[string]; stable: bool) =
      let db = database(path)
      let name = extractFilename(path)
      var txn: ptr Txn = nil
      check mdb_txn_begin(db.env, nil, 0, addr txn), "lmdb write begin"
      var key = Val(size: csize_t(name.len), data: cast[pointer](name.cstring))
      var value = Val(size: csize_t(manifest.len), data: cast[pointer](manifest.cstring))
      var old = Val()
      let found = mdb_get(txn, db.dbi, addr key, addr old)
      if found != 0 and found != NotFound:
        mdb_txn_abort(txn)
        check found, "lmdb get"
      let changed = found == NotFound or old.size != value.size or
                    (manifest.len > 0 and not equalMem(old.data, value.data, manifest.len))
      if changed:
        var rc = mdb_put(txn, db.dbi, addr key, addr value, 0)
        if rc == 0:
          for i, blockData in blocks:
            let blockKey = name & "#" & $i
            var k = Val(size: csize_t(blockKey.len), data: cast[pointer](blockKey.cstring))
            var v = Val(size: csize_t(blockData.len), data: cast[pointer](blockData.cstring))
            rc = mdb_put(txn, db.dbi, addr k, addr v, 0)
            if rc != 0: break
        if rc != 0:
          mdb_txn_abort(txn)
          check rc, "lmdb put"
        check mdb_txn_commit(txn), "lmdb commit"
      else:
        mdb_txn_abort(txn)
      if changed or not stable or not fileExists(path):
        writeFile(path, Marker)
