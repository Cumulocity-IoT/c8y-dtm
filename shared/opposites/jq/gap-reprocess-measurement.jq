# Projects one downloaded device measurement onto the reprocess payload of one gap range,
# once per asset that reported the range.
# Input:  the device measurements of the range, one per line
# Inputs: --argjson g        the query group from gap-reprocess-plan.jq
#         --arg groupBy     "none", "asset" or "device", see the merge key below
# Output: one { k, g, m } record per measurement (per asset of the range when the output
#         is grouped by asset), for gap-reprocess-merge.jq
#
# Only the series the gap is about survives. A device measurement commonly carries several
# series (and several fragments), of which the link that was broken is one; sending the
# others back through the reprocess endpoint would re-run every smart function on data
# that was never missing. The envelope (source, time, type, id) is kept as it was - it is
# what identifies the measurement - and every OTHER fragment is dropped.
#
# g is what the output is split by, and k is the merge key that decides how a measurement
# missing several series is put back together:
#   none   -> g "", k the measurement id. Everything is merged, the measurement is sent
#             once with every series that is missing anywhere.
#   asset  -> g the asset, k asset + measurement id, so each asset's file carries exactly
#             the series that asset is missing. One record per asset of the range, and a
#             measurement two assets are both missing is written to both files.
#   device -> g the source device, k device + measurement id. A measurement belongs to
#             exactly one device, so this splits without duplicating anything, and the
#             series missing on any asset of that device are merged into one payload.
#             This is the unit reprocessing actually works in: the payload is the device's
#             own measurement, and dtm-data-service derives every asset from it.
select((.time | IN($g.exclude[]) | not) and .time <= $g.rangeEnd)
| . as $m
| (($m[$g.sourceFragment] // {}) | with_entries(select(.key == $g.sourceSeries))) as $series

# The query asked for this fragment and series, so an answer without them is not a
# measurement of the gap. Dropped rather than sent as an empty payload.
| select(($series | length) > 0)

# Everything that is not a fragment (id, time, type, self, ...) plus source, which is the
# one envelope field that is itself an object.
| ($m
   | with_entries(select((.value | type) != "object" or .key == "source"))
   | .[$g.sourceFragment] = $series) as $projected

| ($m.id // ([ $g.sourceId, $g.dateFrom, (input_line_number | tostring) ] | join("|"))) as $mid
| if $groupBy == "asset" then
      $g.assetIds[] | { k: (. + "|" + $mid), g: ., m: $projected }
  elif $groupBy == "device" then
      { k: ($g.sourceId + "|" + $mid), g: $g.sourceId, m: $projected }
  else
      { k: $mid, g: "", m: $projected }
  end
