# Parses a --gapsFor source that is JSON as a whole into link selectors.
# Input:  every JSON value of the source, slurped (jq -s), so this covers one object per
#         line (verify-errors.json, verify-result.json, --outputFile output), the same
#         values pretty printed, an array wrapping them, and a plain list of asset ids.
# Output: one selector per line, see gap-selectors.jq.
# Inputs: --argjson includeErrors / --argjson excludeErrors  see --gapsForError
# Needs jq -L <jq-dir> for the gap-selectors module.
include "gap-selectors";
. as $input
| $input[]
| (if type == "array" then .[] else . end)
| fromValue
| selectedError($includeErrors; $excludeErrors)
