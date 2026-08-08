# Compares the measurement timestamps of one device series with the timestamps of the
# asset series it is linked to and reports the exact ranges in which measurements are
# missing on the asset.
# Inputs: --argjson bounds      one bounds record from gap-bounds.jq
#         --argjson probe       { device: {truncated, failed}, asset: {truncated, failed} }
#         --slurpfile deviceTimes  the device timestamps, oldest first
#         --slurpfile assetTimes   the asset timestamps
# Output: the bounds record plus a measurementGap object and the exact missingTimes.
#
# Timestamps are compared as strings. Both sides are read through the same API with
# the same serialisation, so the same instant always produces the same string and set
# membership is exact. Only the ordering used for coalescing depends on the format,
# and that is checked below instead of assumed.
def normalise: map(if type == "object" then .time else . end) | map(select(type == "string"));
def isAscending: . as $t | all(range(1; ($t | length)); $t[. - 1] <= $t[.]);

($deviceTimes | normalise) as $dRaw
| ($assetTimes | normalise) as $aRaw
| ($dRaw | isAscending) as $dOrdered
| (if $dOrdered then $dRaw else ($dRaw | sort) end) as $dSorted
| ($aRaw | map({ key: ., value: true }) | from_entries) as $aSet
# A truncated asset enumeration can only be compared up to its last timestamp,
# everything after it would be reported missing without evidence.
| (if ($probe.asset.truncated == true) and (($aRaw | length) > 0) then ($aRaw | max) else null end) as $windowEnd
| (if $windowEnd == null then $dSorted else ($dSorted | map(select(. <= $windowEnd))) end) as $d
| ($d | length) as $n
| [ $d[] | ($aSet[.] == null) ] as $m
| [ range(0; $n) | select($m[.] and (. == 0 or ($m[. - 1] | not))) ] as $starts
| [ range(0; $n) | select($m[.] and (. == ($n - 1) or ($m[. + 1] | not))) ] as $ends
| [ range(0; ($starts | length))
    | { dateFrom: $d[$starts[.]], dateTo: $d[$ends[.]], points: ($ends[.] - $starts[.] + 1) } ] as $ranges
# Links that were never enumerated must never report a range, whatever timestamps
# were handed in: skipped and probeFailed are unknown, noSourceData has nothing to miss.
| ([ "skipped", "probeFailed", "noSourceData" ] | index($bounds.method) != null) as $noWork
| (($probe.device.failed == true) or ($probe.asset.failed == true)) as $enumFailed
| ($noWork or $enumFailed) as $failed
| ([ (if $enumFailed then "The measurement query failed, no gap could be determined. See the trace stderr log and run verify again." else empty end),
     (if $probe.device.truncated == true then "The device series hit C8Y_DTM_GAPS_MAX_POINTS, the reported gap is a lower bound." else empty end),
     (if $probe.asset.truncated == true then "The asset series hit C8Y_DTM_GAPS_MAX_POINTS, only timestamps up to " + ($windowEnd | tostring) + " were compared." else empty end),
     (if ($dOrdered | not) then "The device measurements were not returned in ascending time order and had to be sorted." else empty end),
     (if ($dRaw | length) > 0 and ($dRaw | map(select(test("Z$") | not)) | length) > 0 then "Some timestamps are not UTC with a trailing Z, the coalescing of adjacent gaps may be off." else empty end)
   ]) as $notes
| $bounds
  + { measurementGap: (
        { method: (if $enumFailed then "enumerationFailed" else $bounds.method end),
          device: { first: $bounds.device.first, last: $bounds.device.last,
                    points: ($dSorted | length), truncated: ($probe.device.truncated == true) },
          asset: { first: $bounds.asset.first, last: $bounds.asset.last,
                   points: ($aRaw | length), truncated: ($probe.asset.truncated == true) },
          missingPoints: (if $failed then 0 else ($ranges | map(.points) | add // 0) end),
          ranges: (if $failed then [] else $ranges end),
          truncated: (($probe.device.truncated == true) or ($probe.asset.truncated == true)) }
        + (if $bounds.probeError != null then { probeError: $bounds.probeError } else {} end)
        + (if ($notes | length) > 0 then { notes: $notes } else {} end)) }
  + { missingTimes: (if $failed then [] else [ range(0; $n) | select($m[.]) | $d[.] ] end) }
  | del(.probeError)
