# Folds the boundary probe responses back onto the plan records and decides how the
# gap of each link has to be determined.
# Inputs: --slurpfile plan    plan records from gap-plan.jq
#         --slurpfile probes  probe responses, each { url, key, side, bound, response }
# Output: one bounds record per planned link:
#         { key, assetId, fragment, series, assetFragment, assetSeries, sourceId,
#           sourceFragment, sourceSeries, supportedSeriesShortcut,
#           method, device: { first, last }, asset: { first, last }, probeError }
#
# method decides the work that follows:
#   skipped        the link was not probed (over C8Y_DTM_GAPS_MAX_LINKS)
#   probeFailed    at least one boundary probe errored or returned nothing
#   noSourceData   the device series holds no measurements, so nothing can be missing
#   assetEmpty     the asset series is empty, every device measurement is missing
#   timestampDiff  both sides hold data, the timestamps have to be compared
#
# A side that gap-supported-series.jq already classified was never probed, so only the
# probes that were actually requested (probeDevice/probeAsset) are expected back. Missing
# responses for a side that WAS requested still mean probeFailed.

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
| ($l.probeDevice != false) as $wantDevice
| ($l.probeAsset  != false) as $wantAsset
# Only the newest bound decides anything, so only its failure is fatal. A failed oldest
# probe (the ascending query, the one that runs into server side timeouts) leaves first
# unknown and is reported as a note, rather than throwing away a link whose gap can still
# be determined. In the exact mode the oldest probe is not even sent.
| ([ (if $wantDevice then $dLast else empty end),
     (if $wantAsset  then $aLast else empty end) ]
   | map(if . == null then "no response for one of the boundary probes" else (. | probeError) end)
   | map(select(. != null)) | first) as $err
| ([ (if $wantDevice and $probeFirst then $dFirst else empty end),
     (if $wantAsset  and $probeFirst then $aFirst else empty end) ]
   | map(if . == null then "no response for the oldest measurement probe" else (. | probeError) end)
   | map(select(. != null)) | first) as $errFirst
| ($dFirst | if . == null then null else probeTime end) as $deviceFirst
| ($dLast  | if . == null then null else probeTime end) as $deviceLast
| ($aFirst | if . == null then null else probeTime end) as $assetFirst
| ($aLast  | if . == null then null else probeTime end) as $assetLast
| ($l | del(.probe, .probeDevice, .probeAsset))
  + { device: { first: $deviceFirst, last: $deviceLast },
      asset: { first: $assetFirst, last: $assetLast },
      probeError: (if $l.probe then ($err // $errFirst) else null end),
      # Classified on the newest measurement of each side: a series with no newest
      # measurement in the window holds nothing in it, which is the same question the
      # oldest probe would have answered, only cheaper and without the timeout.
      method: (if ($l.probe | not) then "skipped"
               elif $err != null then "probeFailed"
               elif $l.supportedSeriesShortcut != null then $l.supportedSeriesShortcut
               elif $deviceLast == null then "noSourceData"
               elif $assetLast == null then "assetEmpty"
               else "timestampDiff"
               end) }
