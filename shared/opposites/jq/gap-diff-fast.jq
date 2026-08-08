# Approximates the measurement gap of one link from its boundary probe alone, without
# reading a single individual timestamp. This is the default of --measurementGaps; the
# full point-by-point diff of gap-diff.jq is only run for --measurementGapsExact.
# Input:  one bounds record from gap-bounds.jq (not slurped, one object per call)
# Output: the bounds record plus a measurementGap object and an always-empty
#         missingTimes, so the record is a drop-in replacement for gap-diff.jq's output
#         wherever exact per-point data isn't required (gap-attach.jq, gap-statistics.jq).
#
# What this can and cannot tell you:
# - assetEmpty:    the asset series never received anything, so the whole extent of the
#                   device series ([device.first, device.last]) is missing. Exact, no
#                   approximation needed: an empty series has no point count to give.
# - timestampDiff:  only the current trailing gap is visible, from the moment the asset
#                   series last reported to the moment the device series last reported.
#                   A gap the asset series later recovered from (received data again
#                   after an earlier interruption) is invisible here by construction:
#                   both "last" timestamps agree, so no gap is reported at all.
# - Point counts are never known without reading the actual timestamps, so
#   missingPoints is left null rather than guessed. Consumers must treat a null
#   missingPoints together with a non-empty ranges array as "gap confirmed, size
#   unknown", not as "no gap".
.method as $method
| ([ "skipped", "probeFailed", "noSourceData" ] | index($method) != null) as $noWork
| (if $noWork then []
   elif .method == "assetEmpty" then
     [ { dateFrom: .device.first, dateTo: .device.last, points: null } ]
   elif .method == "timestampDiff" and .device.last != null and .asset.last != null
        and .device.last > .asset.last then
     [ { dateFrom: .asset.last, dateTo: .device.last, points: null } ]
   else []
   end) as $ranges
| . + { measurementGap: (
      { method: .method,
        device: { first: .device.first, last: .device.last },
        asset: { first: .asset.first, last: .asset.last },
        missingPoints: null,
        ranges: $ranges,
        truncated: false,
        approximate: true }
      + (if .probeError != null then { probeError: .probeError } else {} end)
      + (if ($ranges | length) > 0 then
            { notes: [ "Boundary-only estimate (--measurementGaps): the exact point count is",
                       "unknown, and a gap the asset series later recovered from would not",
                       "show up here. Rerun with --measurementGapsExact for exact data." ] }
         else {} end)) }
  + { missingTimes: [] }
  | del(.probeError)
