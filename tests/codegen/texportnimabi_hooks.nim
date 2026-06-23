discard """
  targets: "c"
  ccodecheck: "'N_LIB_EXPORT N_NIMCALL\\(void, _ZN19texportnimabi_hooks25ResourceNimAbiHookDestroyE3varIN19texportnimabi_hooks8ResourceEE\\)'"
  ccodecheck: "'N_LIB_PRIVATE N_NIMCALL\\(void, eqdestroy'"
"""

type
  Resource = object
    id: int

proc `=destroy`(x: var Resource) =
  x.id = 0

proc `=copy`(dest: var Resource; src: Resource) {.error.}

proc makeResource(id: int): Resource {.exportnimabi.} =
  Resource(id: id)

discard makeResource(1)
