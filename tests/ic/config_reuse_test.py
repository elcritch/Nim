#!/usr/bin/env python3
"""End-to-end reuse/invalidation checks; pass a nimIcConfigReuse compiler in bin/."""
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile

nim = pathlib.Path(sys.argv[1]).resolve()
if os.name != "posix":
    print("config reuse probe skipped (POSIX file locks required)")
    sys.exit(0)


def checked(args, **kwargs):
    p = subprocess.run(args, text=True, capture_output=True, **kwargs)
    if p.returncode:
        raise AssertionError(f"{args!r}\n{p.stdout}\n{p.stderr}")
    return p


with tempfile.TemporaryDirectory(prefix="nim config reuse ") as tmp:
    root = pathlib.Path(tmp)
    cache = root / "cache"
    app = root / "app"
    main = root / "main.nim"

    def write(name, text):
        path = root / name
        path.write_text(text)
        return path

    write("included.nim", "const included* = 2\n")
    leaf = write("leaf.nim", "include included\nfunc leafValue*(): int = included\n")
    dep = write("dep.nim", '''const probeSize* {.intdefine.} = 3
const probeText* {.strdefine.} = "default"
const probeBool* {.booldefine.} = false
when defined(chosen):
  func compileValue*(): int = 20
else:
  func compileValue*(): int = 10
type Data* = array[probeSize, int]
template fromTemplate*(): int =
  when defined(templateFlag): 100
  else: 0
''')
    consumer = write("consumer.nim", '''import dep
const computed* = compileValue() + fromTemplate()
''')
    main.write_text('import dep, consumer, leaf\n'
                    'echo computed, ":", default(Data).len, ":", probeText, ":", probeBool, ":", leafValue()\n')

    def command(flags=(), *, project=main, chosen_cache=cache, out=app,
                reuse=True, frontend=False):
        return [str(nim), "track" if frontend else "ic", "--hints:off",
                "--skipUserCfg", "--skipParentCfg", "--nimcache:" + str(chosen_cache),
                "-d:icJobs=2", *(["-d:icConfigReuse"] if reuse else []),
                *([] if frontend else ["--out:" + str(out)]), *flags, str(project)]

    def run(flags=(), **kwargs):
        p = checked(command(flags, **kwargs))
        hits = {line.removeprefix("IC config reuse: hit ")
                for line in p.stderr.splitlines() if line.startswith("IC config reuse: hit ")}
        return p, hits

    def output(path=app):
        return checked([str(path)]).stdout.strip()

    def compare(flags=(), **kwargs):
        p, hits = run(flags, **kwargs)
        expected = output(kwargs.get("out", app))
        fresh = root / "fresh-app"
        checked(command(flags, project=kwargs.get("project", main),
                        chosen_cache=root / ("fresh-" + str(compare.count)),
                        out=fresh, reuse=False))
        compare.count += 1
        assert output(fresh) == expected
        return p, hits, expected
    compare.count = 0

    p, hits, value = compare()
    assert not hits and value == "10:3:default:false:2"
    assert "fallback " in p.stderr
    p, hits, value = compare(["-d:unrelated=1"])
    assert {str(leaf), str(dep), str(consumer), str(main)} <= hits, p.stderr
    _, hits = run(["-d:unrelated=2"], frontend=True)
    assert str(leaf) in hits and str(dep) in hits
    for flags, expected in [(["-d:chosen"], "20:3:default:false:2"),
                            (["-d:probe_size=5", "-d:probeText=hello world", "-d:probeBool=true"],
                             "10:5:hello world:true:2"),
                            (["-d:templateFlag"], "110:3:default:false:2")]:
        p, hits, value = compare(flags)
        assert value == expected and str(consumer) not in hits, (flags, value, p.stderr)
        assert (str(dep) in hits) == (flags == ["-d:templateFlag"]), (flags, p.stderr)
        assert str(leaf) in hits
    # Presence, absence and opposing-switch order are resolved before querying.
    _, _, value = compare(["-d:chosen", "-u:chosen", "-d:anotherUnused"])
    assert value == "10:3:default:false:2"
    _, _, value = compare(["-u:chosen", "-d:chosen", "-d:anotherUnused"])
    assert value == "20:3:default:false:2"
    _, hits = run(["-u:unrelated", "-d:removedUnused"])
    assert {str(leaf), str(dep), str(consumer), str(main)} <= hits
    # A -> B -> A must restore the correct binary even with a warm backend.
    run()
    assert output() == "10:3:default:false:2"
    _, hits = run()
    assert not hits  # no-op: nifmake does not even launch semantic children.

    # Source/include edits and a private body consumed at compile time invalidate.
    write("included.nim", "const included* = 7\n")
    _, hits, value = compare(["-d:sourceEdit"])
    assert value.endswith(":7") and str(leaf) not in hits
    dep.write_text(dep.read_text().replace("int = 10", "int = 12"))
    _, hits, value = compare(["-d:bodyEdit"])
    assert value.startswith("12:") and str(consumer) not in hits

    # Imported macros and indirect external inputs must fall back.
    write("input.txt", "first")
    hazard = write("hazard.nim", 'const external* = staticRead("input.txt")\n')
    hazardmain = write("hazardmain.nim", 'import hazard\necho external\n')
    p, _, value = compare(project=hazardmain)
    assert value == "first" and "untracked staticRead" in p.stderr
    write("input.txt", "second")
    p, hits, value = compare(["-d:externalSwitch"], project=hazardmain)
    assert value == "second" and str(hazard) not in hits
    write("macrohelper.nim", '''import std/[macros, os]
macro externalValue*(): untyped = newLit(getEnv("NIM_IC_REUSE_PROBE"))
''')
    macromain = write("macromain.nim", 'import macrohelper\necho externalValue()\n')
    os.environ["NIM_IC_REUSE_PROBE"] = "macro-one"
    p, _, value = compare(project=macromain)
    assert value == "macro-one" and "fallback " + str(macromain) in p.stderr
    os.environ["NIM_IC_REUSE_PROBE"] = "macro-two"
    _, hits, value = compare(["-d:macroSwitch"], project=macromain)
    assert value == "macro-two" and str(macromain) not in hits

    ast_value = write("ast_value.nim", 'import std/macros\n'
                      'proc constantAst(): int {.compileTime.} =\n'
                      '  let node = newLit(7)\n  node.intVal.int\n'
                      'const astResult* = constantAst()\n')
    ast_main = write("ast_main.nim", "import ast_value\necho astResult\n")
    compare(project=ast_main)
    p, hits, value = compare(["-d:astUnused"], project=ast_main)
    assert value == "7" and str(ast_value) not in hits
    mutation = write("mutation.nim", '''{.define: localProbe.}
when defined(localProbe):
  const value* = 9
{.undef: localProbe.}
''')
    mutationmain = write("mutationmain.nim", 'import mutation\necho value\n')
    run(project=mutationmain)
    p, hits, value = compare(["-d:mutationSwitch"], project=mutationmain)
    assert value == "9" and str(mutation) not in hits and "Mutation" in p.stderr

    # Changed import selection, nested branches and missing optional imports.
    write("backend_a.nim", "const backend* = 1\n")
    write("backend_b.nim", "const backend* = 2\n")
    switch = write("switch.nim", '''when defined(selectBackend):
  when defined(selectSecond): import backend_b
  else: import backend_a
else: import backend_a
export backend
''')
    switchmain = write("switchmain.nim", "import switch\necho backend\n")
    compare(project=switchmain)
    _, hits, value = compare(["-d:selectBackend", "-d:selectSecond"], project=switchmain)
    assert value == "2" and str(switch) not in hits

    # A dependency's compile-time write can change a consumer's resolution
    # after the independent driver scan, even if its exported BIF is unchanged.
    generated = root / "generated"
    generated.mkdir()
    generated_file = generated / "late_resolved.nim"
    write("late_resolved.nim", "const lateValue* = 1\n")
    # Put the fallback in a separate search path so it does not beat the newly
    # generated module through the importer's own directory.
    late_fallback = root / "late-fallback"
    late_fallback.mkdir()
    (root / "late_resolved.nim").rename(late_fallback / "late_resolved.nim")
    producer = write("producer.nim", 'static:\n  when defined(generateShadow):\n'
                     f'    writeFile({json.dumps(str(generated_file))}, "const lateValue* = 2\\n")\n'
                     'const producerValue* = 0\n')
    late_main = write("late_main.nim", "import producer, late_resolved\necho producerValue + lateValue\n")
    late_paths = ["--path:" + str(late_fallback), "--path:" + str(generated)]
    _, _, value = compare(late_paths, project=late_main)
    assert value == "1"
    _, hits, value = compare([*late_paths, "-d:generateShadow"], project=late_main)
    assert value == "2" and str(late_main) not in hits
    # SCCs are published/restored together. All members remain in the bundle.
    cycle_a = write("cycle_a.nim", 'import cycle_b {.cyclic.}\nfunc a*(): int = 4\n')
    cycle_b = write("cycle_b.nim", 'import cycle_a {.cyclic.}\nfunc b*(): int = a() + 1\n')
    cyclemain = write("cyclemain.nim", 'import cycle_a, cycle_b\necho b()\n')
    compare(project=cyclemain)
    p, hits, value = compare(["-d:cycleUnused"], project=cyclemain)
    assert value == "5" and ({str(cycle_a), str(cycle_b)} & hits), p.stderr

    # A new file earlier on the search path changes resolved module identity.
    earlier = root / "earlier"
    later = root / "later"
    earlier.mkdir()
    later.mkdir()
    (later / "resolved.nim").write_text("const resolvedValue* = 1\n")
    resolutionmain = write("resolutionmain.nim", "import resolved\necho resolvedValue\n")
    paths = ["--path:" + str(later), "--path:" + str(earlier)]
    _, _, value = compare(paths, project=resolutionmain)
    assert value == "1"
    (earlier / "resolved.nim").write_text("const resolvedValue* = 2\n")
    _, _, value = compare([*paths, "-d:resolutionUnused"], project=resolutionmain)
    assert value == "2"

    # Config file branches must be re-evaluated for command-line define changes.
    configdir = root / "configured"
    configdir.mkdir()
    configmain = configdir / "main.nim"
    configmain.write_text('const fromConfig {.intdefine.} = 0\necho fromConfig\n')
    (configdir / "main.nim.cfg").write_text('@if configChoice:\n  define:fromConfig=9\n@else:\n  define:fromConfig=4\n@end\n')
    _, _, value = compare(project=configmain)
    assert value == "4"
    _, _, value = compare(["-d:configChoice"], project=configmain)
    assert value == "9"
    # Target aliases are observed, while a target change selects another base.
    targetdep = write("targetdep.nim", "when defined(posix):\n  const targetValue* = 7\nelse:\n  const targetValue* = 9\n")
    targetmain = write("targetmain.nim", "import targetdep\necho targetValue\n")
    compare(project=targetmain)
    _, hits, value = compare(["-d:targetUnused"], project=targetmain)
    assert value == "7" and str(targetdep) in hits
    _, hits, value = compare(["-d:posix"], project=targetmain)
    assert value == "7" and str(targetdep) not in hits
    _, hits = run(["--cpu:i386"], project=targetmain, frontend=True)
    assert not hits
    # Main-module context and a different entry point cannot share candidates.
    role = write("role.nim", 'when isMainModule:\n  echo "entry"\nelse:\n  const roleValue* = 7\n')
    _, _, value = compare(project=role)
    assert value == "entry"
    rolemain = write("rolemain.nim", "import role\necho roleValue\n")
    _, hits, value = compare(["-d:roleUnused"], project=rolemain)
    assert value == "7" and str(role) not in hits
    # Non-define options and compiler-controlled special defines stay in base.
    _, hits = run(["--checks:off", "-d:optionUnused"])
    assert not hits
    _, hits = run(["-d:release", "-d:releaseUnused"])
    assert not hits

    _, hits = run(["-d:icNoIfaceGate"], frontend=True)
    assert not hits
    # Corruption, missing publication metadata and malformed manifests miss.
    def leaf_variants():
        for path in cache.glob("ic-config-variants-v1/*/variant-*/manifest.json"):
            doc = json.loads(path.read_text())
            if doc["plan"]["project"] == str(leaf):
                yield path, doc

    for path, doc in leaf_variants():
        semantic = next(name for name in doc["artifacts"] if name.endswith(".s.bif"))
        (path.parent / semantic).write_bytes(b"corrupted")
    _, hits, value = compare(["-d:corruptUnused"])
    assert str(leaf) not in hits and value.endswith(":7")
    for path, doc in leaf_variants():
        # Correct digest but structurally invalid metadata must also miss.
        doc["queries"] = []
        raw = (json.dumps(doc) + "\n").encode()
        path.write_bytes(raw)
        (path.parent / "READY").write_text(hashlib.sha256(raw).hexdigest() + "\n")
    _, hits = run(["-d:malformedUnused"])
    assert str(leaf) not in hits
    for path, _ in leaf_variants():
        (path.parent / "READY").unlink(missing_ok=True)
    _, hits = run(["-d:missingUnused"])
    assert str(leaf) not in hits

    # Concurrent builds share candidates but serialize the active cache and
    # config snapshot publication. Use distinct outputs for observable results.
    jobs = []
    for i, flags in enumerate((["-d:concurrentA"], ["-d:chosen", "-d:concurrentB"])):
        out = root / ("concurrent-" + str(i))
        jobs.append((subprocess.Popen(command(flags, out=out), text=True,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE), out))
    results = []
    for proc, out in jobs:
        stdout, stderr = proc.communicate(timeout=120)
        assert proc.returncode == 0, stdout + stderr
        results.append(output(out))
    assert results == ["12:3:default:false:7", "20:3:default:false:7"]

print("config reuse probe passed")
