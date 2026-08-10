# Turns the selectors of --gapsFor into gap candidates, by matching them against the
# links that are actually on the assets right now.
# Input:  the link records of link-records.jq, slurped (jq -s)
# Inputs: --slurpfile selection  selectors from gap-selection.jq
# Output: one candidate per matched link, same shape as gap-plan.jq's, with
#         origin "selected".
#
# Everything the gap analysis needs is taken from the live link, never from the
# selector: a link that was reported broken weeks ago is looked at with the source,
# fragment and series it has today. The selector only says WHICH links to look at, which
# is why a stale report stays usable after the reverse index was repaired.
# "." is the selector here, $l the link it is tested against. A selector that names
# neither an asset nor a device would match every link and is dropped instead.
def selects($l):
  (.assetId != null or .sourceId != null)
  and (.assetId == null or .assetId == ($l.assetId | tostring))
  and (.sourceId == null or .sourceId == ($l.id | tostring))
  and (.fragment == null or .fragment == $l.c8y_LinkedSeries.fragment)
  and (.series == null or .series == $l.c8y_LinkedSeries.series);

# How precisely a selector asked for a link, lower is more precise. A single device wide
# selector can pull in hundreds of links (every link of a device that failed to load, for
# instance), which under C8Y_DTM_GAPS_MAX_LINKS would otherwise crowd out the handful of
# links that were named one by one. gap-plan-merge.jq probes in this order.
def precision:
  if .fragment != null and .series != null then 0
  elif .assetId != null then 1
  else 2
  end;

. as $links
| [ $links[]
    | . as $l
    | ([ $selection[] | select(selects($l)) | precision ] | min) as $precision
    | select($precision != null)
    | { assetId: ($l.assetId // "" | tostring),
        fragment: ($l.c8y_LinkedSeries.fragment // "" | tostring),
        series: ($l.c8y_LinkedSeries.series // "" | tostring),
        assetFragment: ($l.measurementFragment // $l.c8y_LinkedSeries.fragment // "" | tostring),
        assetSeries: ($l.measurementSeries // $l.c8y_LinkedSeries.series // "" | tostring),
        sourceId: ($l.id // "" | tostring),
        sourceFragment: ($l.c8y_LinkedSeries.source.fragment // "" | tostring),
        sourceSeries: ($l.c8y_LinkedSeries.source.series // "" | tostring) }
    | . + { key: ([.assetId, .fragment, .series, .sourceId, .sourceFragment, .sourceSeries] | join("|")),
            origin: "selected",
            selectionPrecision: $precision } ]
| .[]
