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

# A read that stopped early still delivered a valid prefix, because the query is
# ascending and pages oldest first. It is therefore treated exactly like one that hit
# C8Y_DTM_GAPS_MAX_POINTS: usable as a lower bound rather than thrown away. Only a read
# that delivered nothing at all is unusable.
| ($probe.device.failed == true) as $dFailed
| ($probe.asset.failed == true) as $aFailed
| ($dFailed and ($dRaw | length) == 0) as $dUnusable
| ($aFailed and ($aRaw | length) == 0) as $aUnusable
| (($probe.device.truncated == true) or ($dFailed and ($dRaw | length) > 0)) as $dPartial
| (($probe.asset.truncated == true) or ($aFailed and ($aRaw | length) > 0)) as $aPartial

# The boundary probe already established whether the series holds anything in the
# window. An enumeration that comes back empty against a probe that found data did not
# observe an empty series, it failed to report one, and believing it would mean claiming
# "nothing is missing" (device side empty) or "everything is missing" (asset side empty).
# Neither may be claimed, so the link is reported as undetermined instead.
| ($bounds.device.last != null and ($dRaw | length) == 0) as $dEmptyButProbed
| ($bounds.asset.last != null and ($aRaw | length) == 0) as $aEmptyButProbed

| ($dRaw | isAscending) as $dOrdered
| (if $dOrdered then $dRaw else ($dRaw | sort) end) as $dSorted
| ($aRaw | map({ key: ., value: true }) | from_entries) as $aSet
# A partial asset enumeration only covers part of the window, and which part depends on
# the direction it was read in: oldest first leaves a prefix that ends at its newest
# timestamp, newest first leaves a suffix that starts at its oldest one. Device points
# outside what the asset side actually covered would be reported missing without
# evidence, so the comparison is clipped to the covered part.
| (if $aPartial and (($aRaw | length) > 0) then
      (if ($probe.asset.order // "asc") == "desc"
       then { start: ($aRaw | min), end: null }
       else { start: null, end: ($aRaw | max) } end)
   else { start: null, end: null } end) as $clip
| ($dSorted | map(select(($clip.end == null or . <= $clip.end)
                         and ($clip.start == null or . >= $clip.start)))) as $d
| ($d | length) as $n
| [ $d[] | ($aSet[.] == null) ] as $m
| [ range(0; $n) | select($m[.] and (. == 0 or ($m[. - 1] | not))) ] as $starts
| [ range(0; $n) | select($m[.] and (. == ($n - 1) or ($m[. + 1] | not))) ] as $ends
| [ range(0; ($starts | length))
    | { dateFrom: $d[$starts[.]], dateTo: $d[$ends[.]], points: ($ends[.] - $starts[.] + 1) } ] as $ranges
# Links that were never enumerated must never report a range, whatever timestamps
# were handed in: skipped and probeFailed are unknown, noSourceData has nothing to miss.
| ([ "skipped", "probeFailed", "noSourceData" ] | index($bounds.method) != null) as $noWork
| ($dUnusable or $aUnusable or $dEmptyButProbed or $aEmptyButProbed) as $enumFailed
| ($noWork or $enumFailed) as $failed
| ([ (if $dUnusable or $aUnusable then "The measurement query failed and returned nothing, no gap could be determined. See the trace stderr log and run verify again." else empty end),
     (if $dEmptyButProbed then "The device series enumeration returned no timestamps although the boundary probe found measurements up to " + ($bounds.device.last | tostring) + ". The read is not trusted, no gap is reported." else empty end),
     (if $aEmptyButProbed then "The asset series enumeration returned no timestamps although the boundary probe found measurements up to " + ($bounds.asset.last | tostring) + ". The read is not trusted, no gap is reported, as every device measurement would otherwise look missing." else empty end),
     (if $dPartial and ($probe.device.failed == true) then "The device series read stopped early with an error after " + (($dRaw | length) | tostring) + " timestamps, the reported gap is a lower bound." else empty end),
     (if $aPartial and ($probe.asset.failed == true) then "The asset series read stopped early with an error after " + (($aRaw | length) | tostring) + " timestamps, only the part of the window it covered was compared." else empty end),
     (if $probe.device.truncated == true then "The device series hit C8Y_DTM_GAPS_MAX_POINTS, the reported gap is a lower bound." else empty end),
     (if $probe.asset.truncated == true then "The asset series hit C8Y_DTM_GAPS_MAX_POINTS, only the part of the window it covered was compared." else empty end),
     (if $clip.end != null then "Only device measurements up to " + ($clip.end | tostring) + " were compared, the asset side was not read beyond that." else empty end),
     (if $clip.start != null then "Only device measurements from " + ($clip.start | tostring) + " on were compared, the asset side was not read before that." else empty end),
     (if ($probe.device.order // "asc") == "desc" then "The device series had to be read newest first: the oldest-first read returned nothing although the boundary probe found measurements." else empty end),
     (if ($probe.asset.order // "asc") == "desc" then "The asset series had to be read newest first: the oldest-first read returned nothing although the boundary probe found measurements." else empty end),
     (if ($dOrdered | not) then "The device measurements were not returned in ascending time order and had to be sorted." else empty end),
     (if ($dRaw | length) > 0 and ($dRaw | map(select(test("Z$") | not)) | length) > 0 then "Some timestamps are not UTC with a trailing Z, the coalescing of adjacent gaps may be off." else empty end)
   ]) as $notes
| $bounds
  + { measurementGap: (
        { method: (if $enumFailed then "enumerationFailed" else $bounds.method end),
          # first falls back to what was actually read, because the oldest boundary probe
          # is not sent in the exact mode: the enumeration reports it more precisely.
          device: { first: ($bounds.device.first // ($dSorted | first)), last: $bounds.device.last,
                    points: ($dSorted | length), truncated: $dPartial },
          asset: { first: ($bounds.asset.first // ($aRaw | min)), last: $bounds.asset.last,
                   points: ($aRaw | length), truncated: $aPartial },
          missingPoints: (if $failed then 0 else ($ranges | map(.points) | add // 0) end),
          ranges: (if $failed then [] else $ranges end),
          truncated: ($dPartial or $aPartial) }
        + (if $bounds.probeError != null then { probeError: $bounds.probeError } else {} end)
        + (if ($notes | length) > 0 then { notes: $notes } else {} end)) }
  + { missingTimes: (if $failed then [] else [ range(0; $n) | select($m[.]) | $d[.] ] end) }
  | del(.probeError)
