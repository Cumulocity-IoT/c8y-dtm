# Folds the boundary probe responses back onto the plan records and decides how the
# gap of each link has to be determined.
# Inputs: --slurpfile plan    plan records from gap-plan.jq
#         --slurpfile probes  probe responses, each { url, key, side, bound, response }
# Output: one bounds record per planned link:
#         { key, assetId, fragment, series, sourceId, sourceFragment, sourceSeries,
#           method, device: { first, last }, asset: { first, last }, probeError }
#
# method decides the work that follows:
#   skipped        the link was not probed (over C8Y_DTM_GAPS_MAX_LINKS)
#   probeFailed    at least one boundary probe errored or returned nothing
#   noSourceData   the device series holds no measurements, so nothing can be missing
#   assetEmpty     the asset series is empty, every device measurement is missing
#   timestampDiff  both sides hold data, the timestamps have to be compared

# The response shape of `c8y api` depends on whether go-c8y-cli unwraps the
# collection, so accept the body, the unwrapped array and a single item alike.
def probeTime:
  (.response // null) as $r
  | if ($r | type) == "object" and (($r.measurements // null) | type) == "array" then ($r.measurements[0].time // null)
    elif ($r | type) == "array" then (($r[0] // {}).time // null)
    elif ($r | type) == "object" and ($r.time != null) then $r.time
    else null
    end;
def probeError:
  (.response // null) as $r
  | if ($r | type) != "object" then null
    elif $r.errorType != null then (($r.message // $r.errorType) | tostring)
    elif $r.error != null then ($r.error | tostring)
    else null
    end;

($probes | map({ key: (.key + "|" + .side + "|" + .bound), value: . }) | from_entries) as $byProbe
| $plan[]
| . as $l
| ($byProbe[$l.key + "|device|first"]) as $dFirst
| ($byProbe[$l.key + "|device|last"])  as $dLast
| ($byProbe[$l.key + "|asset|first"])  as $aFirst
| ($byProbe[$l.key + "|asset|last"])   as $aLast
| ([$dFirst, $dLast, $aFirst, $aLast] | map(if . == null then "no response for one of the boundary probes" else (. | probeError) end)
   | map(select(. != null)) | first) as $err
| ($dFirst | if . == null then null else probeTime end) as $deviceFirst
| ($dLast  | if . == null then null else probeTime end) as $deviceLast
| ($aFirst | if . == null then null else probeTime end) as $assetFirst
| ($aLast  | if . == null then null else probeTime end) as $assetLast
| ($l | del(.probe))
  + { device: { first: $deviceFirst, last: $deviceLast },
      asset: { first: $assetFirst, last: $assetLast },
      probeError: (if $l.probe then $err else null end),
      method: (if ($l.probe | not) then "skipped"
               elif $err != null then "probeFailed"
               elif $deviceFirst == null then "noSourceData"
               elif $assetFirst == null then "assetEmpty"
               else "timestampDiff"
               end) }
