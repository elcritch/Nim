discard """
  targets: "c"
  cmd: "nim c --app:lib --compileOnly $options $file"
  ccodecheck: "'_ZN30texportnimabi_transparent_refs12makeRendererE'"
  ccodecheck: "'_ZN30texportnimabi_transparent_refs13rendererScaleE3refIN30texportnimabi_transparent_refs24RenderercolonObjectType_EE'"
  ccodecheck: "'TokenNimAbiHookDestroy'"
  ccodecheck: "'N_LIB_EXPORT N_CDECL\\(void, NimMain\\)\\(void\\)'"
  ccodecheck: "! @'NimMainInit'"
  ccodecheck: "! @'DllMain'"
"""

type
  Vec2* = object
    x*, y*: float32

  Token* = object
    id*: int

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

discard makeRenderer()
