discard """
  action: compile
  matrix: "--app:lib"
"""

# The IC driver must forward the application kind to both `nim m` and
# `nim nifc` children. Defines such as `library` and `dll` are insufficient:
# codegen also needs `optGenDynLib` in order to link a shared library.
when not compileOption("app", "lib"):
  {.error: "nim ic did not forward --app:lib to the child compiler".}

proc icDynlibAnswer*(): cint {.exportc, dynlib.} =
  42
