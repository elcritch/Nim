type
  Vec2* = object
    x*, y*: float32

  Token* = object
    id*: int

  Box*[T] = object
    value*: T

  Child* = ref object
    label*: string

  Base* = ref object of RootObj
    baseId*: int

  Renderer* = ref object of Base
    name*: string
    size*: Vec2
    scale*: float32
    child*: Child
    token*: Token
    privateLayers: seq[int]

proc `=destroy`(x: var Token) =
  x.id = 0

proc makeRenderer*(): Renderer {.exportnimabi.} =
  Renderer(
    baseId: 1,
    name: "main",
    size: Vec2(x: 1'f32, y: 2'f32),
    scale: 1'f32,
    child: Child(label: "child"),
    token: Token(id: 7))

proc rendererScale*(r: Renderer): float32 {.exportnimabi.} =
  r.scale

proc `$`*(r: Renderer): string {.exportnimabi.} =
  echo "TEST"
  result = "Renderer2(" & repr(r) & ")"

proc makeIntBox*(): Box[int] {.exportnimabi.} =
  Box[int](value: 42)

proc makeStringBox*(): Box[string] {.exportnimabi.} =
  Box[string](value: "generic")

proc boxIntValue*(box: Box[int]): int {.exportnimabi.} =
  box.value

proc boxStringLen*(box: Box[string]): int {.exportnimabi.} =
  box.value.len

discard makeRenderer()
