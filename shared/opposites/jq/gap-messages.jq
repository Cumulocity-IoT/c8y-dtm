# Turns the gap records of the links selected with --gapsFor into one console message
# each. Needs jq -L <jq-dir> for the gap-summary module.
# Input:  gap records from gap-diff.jq / gap-diff-fast.jq, slurped (jq -s)
# Output: text lines of "<label>\t<message>" (use jq -r)
#
# Only the selected links are reported here. A link that is failing right now already
# has its gap on the error line of the verification (verification-error-messages.jq),
# and reporting it twice would suggest two findings where there is one.
#
# A link that was never looked at (over C8Y_DTM_GAPS_MAX_LINKS) or whose probe failed is
# MeasurementGapUnknown, not NoMeasurementGap: nothing was measured, so "no gap" would be
# a claim the run cannot make.
#
# Lines are ordered by how much they say, findings first, so that the caller's line cap
# can only ever cut into the least interesting end of the list.
include "gap-summary";
def gapLabel:
  (.measurementGap.method // "unknown") as $m
  | if ([ "skipped", "probeFailed", "enumerationFailed", "unknown" ] | index($m)) != null then "MeasurementGapUnknown"
    elif ((.measurementGap.ranges // []) | length) > 0 then "MeasurementGap"
    else "NoMeasurementGap"
    end;
def rank: { "MeasurementGap": 0, "MeasurementGapUnknown": 1, "NoMeasurementGap": 2 }[.] // 3;

map(select(.origin == "selected") | . + { gapLabel: gapLabel })
| sort_by([ (.gapLabel | rank), .assetId, .key ])
| .[]
| .gapLabel
  + "\tasset " + (.assetId | tostring)
  + " series " + (.fragment | tostring) + "." + (.series | tostring)
  + (if .assetFragment != .fragment or .assetSeries != .series then
        " (read as " + (.assetFragment | tostring) + "." + (.assetSeries | tostring) + ")"
     else "" end)
  + " from " + (.sourceFragment | tostring) + "." + (.sourceSeries | tostring)
  + " of device " + (.sourceId | tostring)
  + gapSummary
