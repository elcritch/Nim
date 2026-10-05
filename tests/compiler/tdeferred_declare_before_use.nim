discard """
  action: reject
  cmd: "nim c --hint:Processing:off $options $file"
  errormsg: "undeclared identifier: 'later'"
  matrix: "--deferBodies:on --errorMax:1 --ic:off; --deferBodies:on --errorMax:1 --ic:on"
"""

proc before(): int = later()
proc later(): int = 2
discard before()
