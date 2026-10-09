# Records one downloaded device measurement in the trace, exactly as the tenant returned
# it, together with the gap range it was downloaded for and whether it made it into the
# reprocess payload.
# Input:  the device measurements of one gap range, one per line
# Inputs: --argjson g      the query group from gap-reprocess-plan.jq
#         --argjson range  the 1-based index of the range within gap-reprocess-plan.json
# Output: one record per measurement, appended to gap-reprocess-downloads.json
#
# A dropped measurement is written to the trace rather than filtered out of it. "The
# device sent this and it was NOT reprocessed, because it is the measurement that bounds
# the gap" is exactly the fact that makes a reported gap checkable from the trace alone,
# and it is invisible in the reprocess batches, which hold only what was kept.
#
# kept mirrors the selection of gap-reprocess-measurement.jq, condition for condition and
# in the same order, so that the two can only disagree if one is changed without the
# other.
#
# value and unit are lifted out of the raw measurement because they are what a reader
# scans for; measurement holds the untouched response, every fragment and series of it,
# so the trace also serves as the data.
def pointOf($m): (($m[$g.sourceFragment] // {})[$g.sourceSeries]);

. as $m
| pointOf($m) as $point
| (if ($m.time | IN(($g.exclude // [])[])) then "boundary"
   elif $m.time > $g.rangeEnd then "afterRangeEnd"
   elif $point == null then "seriesMissing"
   else null
   end) as $dropped
| { range: $range,
    sourceId: $g.sourceId,
    sourceFragment: $g.sourceFragment,
    sourceSeries: $g.sourceSeries,
    rangeFrom: $g.dateFrom,
    rangeEnd: $g.rangeEnd,
    queryTo: $g.dateTo,
    assetIds: $g.assetIds,
    time: $m.time,
    id: $m.id,
    value: ($point | if . == null then null else .value end),
    unit: ($point | if . == null then null else .unit end),
    kept: ($dropped == null),
    droppedBecause: $dropped,
    measurement: $m }
