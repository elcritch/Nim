discard """
  output: '''12 16 30 25'''
"""

import msignatureclosure
echo nestedCapture(9), " ", nestedTwice(9), " ", nestedLocals(4), " ",
  nestedIndex("\x20\x25")
