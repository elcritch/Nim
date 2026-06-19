discard """
  targets: "c"
  ccodecheck: "'_ZN23texportnimabi_accessors4nameE3refIN23texportnimabi_accessors24RenderercolonObjectType_EE'"
  ccodecheck: "'_ZN23texportnimabi_accessors5scaleE3refIN23texportnimabi_accessors24RenderercolonObjectType_EE'"
  ccodecheck: "'_ZN23texportnimabi_accessors5childE3refIN23texportnimabi_accessors24RenderercolonObjectType_EE'"
  ccodecheck: "'_ZN23texportnimabi_accessors5labelE3refIN23texportnimabi_accessors21ChildcolonObjectType_EE'"
"""

type
  Vec2* = object
    x*, y*: float32

  Child* = ref object
    label*: string

  Renderer* = ref object
    name*: string
    size*: Vec2
    scale*: float32
    child*: Child
    privateLayers: seq[int]

proc newRenderer(): Renderer {.exportnimabi.} =
  Renderer(
    name: "main",
    size: Vec2(x: 1'f32, y: 2'f32),
    scale: 1'f32,
    child: Child(label: "child"))

let r = newRenderer()

doAssert name(r) == "main"
`name=`(r, "other")
doAssert name(r) == "other"

doAssert size(r).x == 1'f32
`scale=`(r, 3'f32)
doAssert scale(r) == 3'f32

doAssert label(child(r)) == "child"
