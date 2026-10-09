# Summarises one downloaded gap range as a single line of the trace.
# Input:  none (-n)
# Inputs: --argjson g               the query group from gap-reprocess-plan.jq
#         --argjson range           the 1-based index of the range
#         --argjson failed          whether the download itself failed
#         --argjson truncated       whether it hit C8Y_DTM_GAPS_MAX_POINTS
#         --slurpfile measurements  the raw response of the range
# Output: one record, appended to gap-reprocess-downloads-summary.json
#
# One line per range, so the whole download of a run can be read at a glance and lines up
# with gap-reprocess-plan.json by the range index. The per-measurement detail is in
# gap-reprocess-downloads.json.
#
# downloaded vs kept is the boundary check: an interior gap must drop exactly its two
# bounding measurements, no more. A range that downloaded nothing at all is the answer to
# "was the link broken or was the device off".
#
# The value summary is the quickest answer to "is this series actually changing". A
# distinct count of 1 over a whole range means the device really did send the same number
# every time, which for a setpoint series is normal and for a measured one is not - and
# either way it is a property of the data, not of the export.
def pointOf($m): (($m[$g.sourceFragment] // {})[$g.sourceSeries]);
def dropReason($m):
  if ($m.time | IN(($g.exclude // [])[])) then "boundary"
  elif $m.time > $g.rangeEnd then "afterRangeEnd"
  elif pointOf($m) == null then "seriesMissing"
  else null
  end;

($measurements | map({ m: ., drop: dropReason(.) })) as $rows
| ($rows | map(select(.drop == null))) as $kept
| ($kept | map(pointOf(.m) | .value)) as $values
| { range: $range,
    sourceId: $g.sourceId,
    sourceFragment: $g.sourceFragment,
    sourceSeries: $g.sourceSeries,
    rangeFrom: $g.dateFrom,
    rangeEnd: $g.rangeEnd,
    queryTo: $g.dateTo,
    assetIds: $g.assetIds,
    excludedTimes: ($g.exclude // []),
    failed: $failed,
    truncated: $truncated,
    downloaded: ($rows | length),
    kept: ($kept | length),
    dropped: ($rows | map(select(.drop != null) | .drop)
              | group_by(.) | map({ key: .[0], value: length }) | from_entries),
    firstTime: ($rows | map(.m.time) | min),
    lastTime: ($rows | map(.m.time) | max),
    values: { distinct: ($values | unique | length),
              min: ($values | map(select(type == "number")) | min),
              max: ($values | map(select(type == "number")) | max),
              samples: ($values | unique | .[0:5]),
              units: ($kept | map(pointOf(.m) | .unit) | unique) } }
