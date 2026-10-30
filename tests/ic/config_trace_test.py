#!/usr/bin/env python3
"""Run with a compiler built with -d:nimIcConfigTrace as the sole argument."""
import ast
import json
import pathlib
import subprocess
import sys
import tempfile

nim = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="nim config trace ") as tmp:
    root = pathlib.Path(tmp)
    main = root / "main.nim"
    inc = root / "inc.nim"
    helper = root / "helper.nim"
    inc.write_text("when defined(probeInclude): discard\n")
    (root / "input.txt").write_text("probe data")
    helper.write_text('''import std/[macros, compilesettings, os]
template templateProbe*() =
  when defined(probeTemplate): discard
macro macroProbe*(arg: untyped): untyped =
  let name = arg.strVal
  let setting = if name.len > 0: SingleValueSetting.backend else: SingleValueSetting.command
  let seqSetting = if name.len > 0: MultipleValueSetting.searchPaths else: MultipleValueSetting.lazyPaths
  discard querySetting(setting)
  discard querySettingSeq(seqSetting)
  discard getEnv(name)
  result = quote do:
    when defined(probeMacro): discard
const importedValue* {.intdefine.} = 9
macro definitionProbe*(): untyped =
  discard querySetting(SingleValueSetting.backend)
  result = newStmtList()
''')
    main.write_text('''import helper
include inc
templateProbe()
macroProbe("IC_CONFIG_TRACE_TEST_MISSING")
const probeValue {.strdefine.} = "fallback"
const probeInt {.intdefine.} = 3
const probeBool {.booldefine.} = false
when defined(probeFlag): discard
when defined(linux) or defined(freebsd) or defined(openbsd) or defined(netbsd) or
     defined(macosx) or defined(windows): discard
{.define: probeMutation.}
when defined(probeMutation): discard
{.undef: probeMutation.}
when defined(probeMutation): discard
const fileValue = staticRead("input.txt")
static:
  doAssert fileValue == "probe data"
  echo probeValue, ":", probeInt, ":", probeBool, ":", importedValue
''')

    def run(*flags):
        p = subprocess.run([str(nim), "check", "--hints:off", "--skipUserCfg",
                            "--skipParentCfg", *flags, str(main)],
                           text=True, capture_output=True, check=True)
        records = [line.split("\t") for line in p.stderr.splitlines()
                   if line.startswith("IC_CONFIG_")]
        assert all(int(r[1]) > 0 for r in records)
        return records, p.stdout

    absent, output = run()
    assert "fallback:3:false:9" in output
    present, output = run("-d:probe_flag", "-d:probeValue=hello world", "-d:probeInt=7",
                          "-d:probeBool=true")
    assert "hello world:7:true:9" in output

    helper_only = subprocess.run([str(nim), "check", "--hints:off", "--skipUserCfg",
                                  "--skipParentCfg", str(helper)],
                                 text=True, capture_output=True, check=True)
    helper_records = [line.split("\t") for line in helper_only.stderr.splitlines()
                      if line.startswith("IC_CONFIG_UNTRACKED_V1\t")]
    # This query can be evaluated during semantic checking of the macro's
    # definition, before a caller exists.
    assert any(ast.literal_eval(r[5]) == "querySetting" and
               ast.literal_eval(r[2]) == str(helper) and ast.literal_eval(r[6]) == ""
               for r in helper_records)

    def find(records, kind, name):
        return [r for r in records if r[0] == kind and ast.literal_eval(r[5]) == name]

    for records, expected in ((absent, "0"), (present, "1")):
        flag = find(records, "IC_CONFIG_DEFINED_V2", "probeFlag")
        assert flag and all(r[6] == expected for r in flag)
        included = find(records, "IC_CONFIG_DEFINED_V2", "probeInclude")
        assert included and all(ast.literal_eval(r[2]) == str(main) and
                                ast.literal_eval(r[3]) == str(inc) and r[6] == "0"
                                for r in included)
        mutation = find(records, "IC_CONFIG_DEFINED_V2", "probeMutation")
        assert [r[6] for r in mutation] == ["1", "0"]
        for reason in ("defineMutation", "undefMutation"):
            mutations = find(records, "IC_CONFIG_UNTRACKED_V1", reason)
            assert any(ast.literal_eval(r[2]) == str(main) for r in mutations), mutations
        for name in ("probeTemplate", "probeMacro"):
            observed = find(records, "IC_CONFIG_DEFINED_V2", name)
            assert observed and all(ast.literal_eval(r[2]) == str(main) and r[6] == "0"
                                    for r in observed)
        imported = find(records, "IC_CONFIG_VALUE_V2", "importedValue")
        assert imported and any(ast.literal_eval(r[2]) == str(main) and r[7] == "false"
                                for r in imported), imported
        for reason in ("querySetting", "querySettingSeq", "getEnv", "staticRead"):
            observed = find(records, "IC_CONFIG_UNTRACKED_V1", reason)
            assert observed, reason
            if reason == "staticRead":
                assert any(ast.literal_eval(r[2]) == str(main) for r in observed), observed
            else:
                assert any(ast.literal_eval(r[6]) == str(main) for r in observed), (reason, observed)
        target = ("freebsd" if sys.platform.startswith("freebsd") else
                  "openbsd" if sys.platform.startswith("openbsd") else
                  "netbsd" if sys.platform.startswith("netbsd") else
                  "linux" if sys.platform.startswith("linux") else
                  "macosx" if sys.platform == "darwin" else
                  "windows" if sys.platform == "win32" else None)
        if target is not None:
            target_records = find(records, "IC_CONFIG_DEFINED_V2", target)
            assert target_records and all(r[6] == "1" for r in target_records)
    for name, magic, value in (("probeValue", "mStrDefine", "hello world"),
                               ("probeInt", "mIntDefine", "7"),
                               ("probeBool", "mBoolDefine", "true")):
        missing = find(absent, "IC_CONFIG_VALUE_V2", name)
        found = find(present, "IC_CONFIG_VALUE_V2", name)
        assert missing and all(r[6:] == [magic, "false", ""] for r in missing)
        assert found and all(r[6:8] == [magic, "true"] and
                             ast.literal_eval(r[8]) == value for r in found)

    exec_probe = root / "exec_probe.nim"
    exec_probe.write_text('const value = staticExec("echo icConfigTrace")\n'
                          'static: doAssert value.strip() == "icConfigTrace"\n')
    # staticExec is intentionally suppressed by `nim check`; compile only to
    # exercise its VM opcode without running the generated program.
    exec_probe.write_text('import std/strutils\n' + exec_probe.read_text())
    p = subprocess.run([str(nim), "c", "--compileOnly", "--hints:off",
                        "--skipUserCfg", "--skipParentCfg",
                        "--nimcache:" + str(root / "exec_cache"), str(exec_probe)],
                       text=True, capture_output=True, check=True)
    assert any(r[0] == "IC_CONFIG_UNTRACKED_V1" and
               ast.literal_eval(r[5]) == "staticExec"
               for r in (line.split("\t") for line in p.stderr.splitlines()))

    (root / "trackdep.nim").write_text('''const icTrackedValue {.intdefine.} = 4
when defined(icTrackedFlag):
  type Data* = array[icTrackedValue, int]
else:
  type Data* = array[1, int]
''')
    trackmain = root / "trackmain.nim"
    trackmain.write_text("import trackdep\nvar value: Data\ndiscard value.len\n")
    def track(cache, value=5):
        return subprocess.run([str(nim), "track", "--hints:off", "--skipUserCfg",
                               "--skipParentCfg", "--nimcache:" + str(cache),
                               "-d:icJobs=1", "-d:icTrackedFlag", f"-d:icTrackedValue={value}",
                               str(trackmain)], text=True, capture_output=True, check=True)

    p = track(root / "trackcache")
    lines = (p.stdout + "\n" + p.stderr).splitlines()
    records = [line[line.index("IC_CONFIG_"):].split("\t") for line in lines
               if "IC_CONFIG_" in line]
    flag = find(records, "IC_CONFIG_DEFINED_V2", "icTrackedFlag")
    value = find(records, "IC_CONFIG_VALUE_V2", "icTrackedValue")
    assert any(r[6] == "1" and ast.literal_eval(r[2]) == str(root / "trackdep.nim")
               for r in flag), flag
    assert any(r[7] == "true" and ast.literal_eval(r[8]) == "5" and
               ast.literal_eval(r[2]) == str(root / "trackdep.nim") for r in value), value

    def manifest(cache):
        docs = [json.loads(path.read_text()) for path in cache.rglob("*.configtrace.json")]
        return next(doc for doc in docs if doc["project"] == str(root / "trackdep.nim"))

    first = manifest(root / "trackcache")
    assert first["version"] == 1 and first["scope"] == "process" and not first["complete"]
    assert any(e["kind"] == "defined" and e["key"] == "icTrackedFlag" and e["value"] == "1"
               for e in first["observations"])
    assert any(e["kind"] == "defined" and e["context"] == "<compiler>" and
               e["key"] == "icNoIfaceGate" for e in first["observations"])
    assert any(e["kind"] == "value" and e["key"] == "icTrackedValue" and '"5"' in e["value"]
               for e in first["observations"])
    track(root / "trackcache2")
    assert first == manifest(root / "trackcache2")
    changed = track(root / "trackcache", value=6)
    assert '"icTrackedValue"\tmIntDefine\ttrue\t"6"' in changed.stdout + changed.stderr
    manifests = [json.loads(path.read_text()) for path in (root / "trackcache").rglob("*.configtrace.json")]
    variants = [doc for doc in manifests if doc["project"] == str(root / "trackdep.nim")]
    assert len(variants) == 2 and all(not doc["complete"] for doc in variants)

print("config trace probe passed")
