type
  Resource* = object
    id*: int

proc `=destroy`(x: var Resource) =
  x.id = 0

proc `=copy`(dest: var Resource; src: Resource) {.error.}

proc makeResource(id: int): Resource {.exportnimabi.} =
  Resource(id: id)

discard makeResource(1)
