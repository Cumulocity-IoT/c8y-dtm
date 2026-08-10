# Parses a --gapsFor source that is not JSON as a whole into link selectors.
# Input:  the raw lines of the source (jq -R, no slurp)
# Inputs: --argjson includeErrors / --argjson excludeErrors  see --gapsForError
# Output: one selector per line, see gap-selectors.jq
# Needs jq -L <jq-dir> for the gap-selectors module.
#
# This is the fallback of gap-selection-json.jq and handles a pasted console log, a list
# of ids, and a file that mixes both. A line that is itself JSON is still parsed as such,
# so a log with the odd JSON line in it stays usable.
#
# From a log line only the ids are read, never the "fragment.series" it also prints:
# that pair is joined by a dot that may itself occur in the fragment, so splitting it
# again would silently select the wrong link or none at all. A line naming an asset and a
# device narrows to the links between exactly those two; naming only an asset selects all
# of its links, which is a few more probes and always right.
#
# The bare id fallback only applies to a line that is nothing but ids, so that the
# numbers in a prose log line ("Found 23 unique source devices") are not mistaken for
# asset ids. Empty lines and lines starting with # are ignored, so a selection file can
# be commented and a log can be pasted with its blank lines.
include "gap-selectors";
def fromText:
  . as $line
  | (capture("asset (?<id>[0-9]+)") // null) as $asset
  | (capture("device (?<id>[0-9]+)") // null) as $device
  | (capture("(?<type>[A-Za-z][A-Za-z0-9_]*Error)") // null) as $error
  | if $asset != null or $device != null then
        ((if $asset != null then { assetId: $asset.id } else {} end)
         + (if $device != null then { sourceId: $device.id } else {} end))
        | withError(if $error == null then null else $error.type end)
    elif test("^[0-9]+([,;[:space:]]+[0-9]+)*$") then
        ($line | splits("[,;[:space:]]+") | select(length > 0) | { assetId: . })
    else empty
    end;

sub("^\\s+"; "") | sub("\\s+$"; "")
| select(length > 0 and (startswith("#") | not))
| if startswith("{") or startswith("[") then
      (fromjson? // empty) | (if type == "array" then .[] else . end) | fromValue
  else
      fromText
  end
| selectedError($includeErrors; $excludeErrors)
