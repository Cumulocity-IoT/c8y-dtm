# Attaches the measurement gap of every probed link to its entry in the verdict.
# Inputs: --slurpfile gaps  gap records from gap-diff.jq (without missingTimes)
# Input:  the verdicts of verify-match-links.jq, one per line (no slurp)
# Output: the same verdicts, with a measurementGap object added to each entry of
#         missingLinks that was probed. Everything else passes through unchanged.
def gapKey($sourceId):
  [ (.assetId // "" | tostring), (.fragment // "" | tostring), (.series // "" | tostring),
    ($sourceId // "" | tostring), (.sourceFragment // "" | tostring), (.sourceSeries // "" | tostring) ]
  | join("|");

($gaps | map({ key: .key, value: .measurementGap }) | from_entries) as $byKey
| if .error == "MissingLinkedSeriesInChildAdditionError" and (.missingLinks | type) == "array" then
      . as $r
      | .missingLinks |= map(
          ($byKey[gapKey($r.id)]) as $gap
          | if $gap == null then . else . + { measurementGap: $gap } end)
  else .
  end
