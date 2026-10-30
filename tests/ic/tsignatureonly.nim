discard """
  output: '''17 13 17 5 7 11'''
"""

import msignatureonly

const compileTimeValue = ctValue()
echo identity(17), " ", constant(), " ", compileTimeValue, " ",
  genericIdentity(5), " ", inlineValue(6), " ", addValues(5, 6)
