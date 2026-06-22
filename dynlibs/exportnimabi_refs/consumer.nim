import producer_abi

proc touchRenderer*(r: Renderer) {.exportc.} =
  r.baseId = 2
  r.name = "imported"
  r.size.x = 3'f32
  r.size.y = 4'f32
  r.scale = 5'f32
  r.child.label = "nested"
  r.token.id = 9
