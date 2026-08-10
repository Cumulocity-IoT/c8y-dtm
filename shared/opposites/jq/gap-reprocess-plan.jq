# Turns the reported gaps into the list of measurement queries needed to download the
# device measurements behind them, ready to be sent to the reprocess endpoint of
# dtm-data-service.
# Inputs: --slurpfile records  gap records from gap-diff.jq / gap-diff-fast.jq
#         --slurpfile points   the exact missing timestamps per link (exact mode only,
#                              empty in the boundary-only mode)
# Output: one query per (source series, range):
#         { sourceId, sourceFragment, sourceSeries, dateFrom, dateTo, times, assetIds }
#
# The payload of POST /service/dtm/reprocess/measurements is the ORIGINAL DEVICE
# measurement, not the asset measurement: dtm-data-service re-runs the smart functions on
# an ingested device measurement and derives the asset side from the reverse index. So
# everything here is queried on the device, never on the asset.
#
# Records are grouped by source series AND range, because several assets commonly link
# the same device series and then report the very same gap. Grouping downloads it once
# and unions the missing timestamps of all of them, which is also what reprocessing does:
# one device measurement feeds every link that matches it. Overlapping (not identical)
# ranges are left alone here and settled by the deduplication over measurement ids.
#
# dateTo is bumped to the next full second because the range ends ON a measurement that
# must be included, and the fractional part is dropped by the conversion. The overshoot
# is harmless: in exact mode the times filter removes it, in boundary-only mode anything
# after the range end is missing on the asset as well.
def plusOneSecond:
  sub("\\.[0-9]+Z$"; "Z")
  | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime + 1 | strftime("%Y-%m-%dT%H:%M:%S.000Z");

($points | map({ key: .key, value: (.times // []) }) | from_entries) as $timesByKey
| [ $records[]
    | . as $r
    | (.measurementGap.ranges // [])[] as $range
    | select($range.dateFrom != null and $range.dateTo != null)
    | { sourceId: ($r.sourceId | tostring),
        sourceFragment: ($r.sourceFragment | tostring),
        sourceSeries: ($r.sourceSeries | tostring),
        dateFrom: $range.dateFrom,
        dateTo: $range.dateTo,
        assetId: $r.assetId,
        times: ($timesByKey[$r.key] // []
                | map(select(. >= $range.dateFrom and . <= $range.dateTo))) } ]
| map(. + { groupKey: ([.sourceId, .sourceFragment, .sourceSeries, .dateFrom, .dateTo] | join("|")) })
| group_by(.groupKey)
| map({ sourceId: .[0].sourceId,
        sourceFragment: .[0].sourceFragment,
        sourceSeries: .[0].sourceSeries,
        dateFrom: .[0].dateFrom,
        dateTo: (.[0].dateTo | plusOneSecond),
        rangeEnd: .[0].dateTo,
        assetIds: (map(.assetId) | unique),
        # Empty means "take everything in the range", which is what the boundary-only
        # mode can offer. In exact mode the union of the timestamps of every link in the
        # group is the exact set to keep.
        times: (map(.times) | add // [] | unique) })
| .[]
