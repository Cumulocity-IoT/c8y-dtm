# Turns the missing links of the verification into one gap candidate per link.
# Input:  the failing verdicts of verify-match-links.jq, slurped (jq -s)
# Output: one candidate per missing link:
#         { key, assetId, fragment, series, assetFragment, assetSeries,
#           sourceId, sourceFragment, sourceSeries, origin }
#
# The candidates of --gapsFor (gap-selection-plan.jq) have the same shape;
# gap-plan-merge.jq joins both and decides which of them are probed.
#
# The key carries both sides of the link (asset triple plus source triple) because
# neither side alone is unique: many asset series can point at the same source
# series, and a single asset could in broken data hold two entries for the same
# fragment and series with different sources. It is built from the DECLARED
# fragment/series so that gap-attach.jq can rebuild it from the verdict alone.
#
# fragment/series stay the declared values of c8y_LinkedSeries and are what gets
# reported. assetFragment/assetSeries are what the asset side is actually queried
# with: identical by default, different when an --assetFragmentTemplate /
# --assetSeriesTemplate describes a smart function that persists elsewhere (see
# link-records.jq). They fall back to the declared values when a template could not
# be resolved, which the caller reports separately.
[ (.[] | select(.error == "MissingLinkedSeriesInChildAdditionError")) ]
| sort_by(.id)
| [ .[]
    | . as $r
    | (.missingLinks // [])[]
    | { assetId: (.assetId // "" | tostring),
        fragment: (.fragment // "" | tostring),
        series: (.series // "" | tostring),
        assetFragment: (.measurementFragment // .fragment // "" | tostring),
        assetSeries: (.measurementSeries // .series // "" | tostring),
        sourceId: ($r.id // "" | tostring),
        sourceFragment: (.sourceFragment // "" | tostring),
        sourceSeries: (.sourceSeries // "" | tostring) }
    | . + { key: ([.assetId, .fragment, .series, .sourceId, .sourceFragment, .sourceSeries] | join("|")),
            origin: "failing" } ]
| .[]
