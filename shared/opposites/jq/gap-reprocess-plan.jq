# Turns the reported gaps into the list of measurement queries needed to download the
# device measurements behind them, ready to be sent to the reprocess endpoint of
# dtm-data-service.
# Inputs: --slurpfile records  gap records from gap-intervals.jq
# Output: one query per (source series, range):
#         { sourceId, sourceFragment, sourceSeries, dateFrom, dateTo, exclude, assetIds }
#
# The payload of POST /service/dtm/reprocess/measurements is the ORIGINAL DEVICE
# measurement, not the asset measurement: dtm-data-service re-runs the smart functions on
# an ingested device measurement and derives the asset side from the reverse index. So
# everything here is queried on the device, never on the asset.
#
# Records are grouped by source series AND range, because several assets commonly link
# the same device series and then report the very same gap. Grouping downloads it once
# for all of them, which is also what reprocessing does: one device measurement feeds
# every link that matches it. Overlapping (not identical) ranges are left alone here and
# settled by the deduplication over measurement ids.
#
# exclude holds the two asset timestamps that bound an interior gap. They are the
# measurements that DID arrive, so the device measurements at those instants must not be
# reprocessed - the query itself cannot exclude them, both bounds of a measurement query
# are inclusive. A range that starts or ends at the window edge has no measurement there
# and excludes nothing.
#
# dateTo is bumped to the next full second because the range ends ON a timestamp that
# must be covered and the fractional part is dropped by the conversion. The overshoot is
# removed again by exclude, or is missing on the asset as well.
def plusOneSecond:
  sub("\\.[0-9]+Z$"; "Z")
  | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime + 1 | strftime("%Y-%m-%dT%H:%M:%S.000Z");

[ $records[]
  | . as $r
  | (.measurementGap.ranges // [])[] as $range
  | select($range.dateFrom != null and $range.dateTo != null)
  | { sourceId: ($r.sourceId | tostring),
      sourceFragment: ($r.sourceFragment | tostring),
      sourceSeries: ($r.sourceSeries | tostring),
      dateFrom: $range.dateFrom,
      dateTo: $range.dateTo,
      assetId: $r.assetId,
      exclude: [ (if $range.edge == "leading" or $range.edge == "window" then empty else $range.dateFrom end),
                 (if $range.edge == "trailing" or $range.edge == "window" then empty else $range.dateTo end) ] } ]
| map(. + { groupKey: ([.sourceId, .sourceFragment, .sourceSeries, .dateFrom, .dateTo] | join("|")) })
| group_by(.groupKey)
| map({ sourceId: .[0].sourceId,
        sourceFragment: .[0].sourceFragment,
        sourceSeries: .[0].sourceSeries,
        dateFrom: .[0].dateFrom,
        dateTo: (.[0].dateTo | plusOneSecond),
        rangeEnd: .[0].dateTo,
        assetIds: (map(.assetId) | unique),
        exclude: (map(.exclude) | add | unique) })
| .[]
