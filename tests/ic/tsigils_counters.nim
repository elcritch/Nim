discard """
  output: "distinct counters"
  cmd: "nim ic $options $file"
"""

import msigils_counterleft, msigils_counterright

doAssert leftId != rightId
echo "distinct counters"
