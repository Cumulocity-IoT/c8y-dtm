# Turns the missing links of the verification into one plan record per link and
# decides which of them are probed for measurement gaps.
# Input:  the failing verdicts of verify-match-links.jq, slurped (jq -s)
# Inputs: --argjson maxLinks  maximum number of links to probe (0 or less = no limit)
# Output: one plan record per missing link:
#         { key, assetId, fragment, series, sourceId, sourceFragment, sourceSeries, probe }
#
# The key carries both sides of the link (asset triple plus source triple) because
# neither side alone is unique: many asset series can point at the same source
# series, and a single asset could in broken data hold two entries for the same
# fragment and series with different sources.
[ (.[] | select(.error == "MissingLinkedSeriesInChildAdditionError")) ]
| sort_by(.id)
| [ .[]
    | . as $r
    | (.missingLinks // [])[]
    | { assetId: (.assetId // "" | tostring),
        fragment: (.fragment // "" | tostring),
        series: (.series // "" | tostring),
        sourceId: ($r.id // "" | tostring),
        sourceFragment: (.sourceFragment // "" | tostring),
        sourceSeries: (.sourceSeries // "" | tostring) }
    | . + { key: ([.assetId, .fragment, .series, .sourceId, .sourceFragment, .sourceSeries] | join("|")) } ]
| [ to_entries[] | .value + { probe: ($maxLinks <= 0 or (.key < $maxLinks)) } ]
| .[]
