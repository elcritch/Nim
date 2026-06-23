import producer_abi

let r = makeRenderer()
doAssert r.baseId == 1
doAssert r.name == "main"
doAssert r.size.x == 1'f32
doAssert r.size.y == 2'f32
doAssert rendererScale(r) == 1'f32
doAssert r.child.label == "child"
doAssert r.token.id == 7

r.baseId = 2
r.name = "imported"
r.size.x = 3'f32
r.size.y = 4'f32
r.scale = 5'f32
r.child.label = "nested"
r.token.id = 9

echo "R: ", $r
doAssert r.baseId == 2
doAssert r.name == "imported"
doAssert r.size.x == 3'f32
doAssert r.size.y == 4'f32
doAssert rendererScale(r) == 5'f32
doAssert r.child.label == "nested"
doAssert r.token.id == 9
