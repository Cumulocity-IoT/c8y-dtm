# Finds the measurement gaps of ONE asset series from the cadence of that series alone.
# Input:  nothing (jq -n)
# Inputs: --argjson link       the plan record of the link (gap-plan-merge.jq)
#         --slurpfile times    the asset measurements read for it, { time } objects or
#                              plain timestamp strings, in any order
#         --arg dateFrom / --arg dateTo  the window that was read
#         --argjson interval   the interval in seconds (declared with --interval, or the
#                              one sampled from the source device), or null to fall back to
#                              deriving it from this series itself
#         --arg intervalSource where a non-null interval came from, "declared" or "device"
#         --argjson percentile which percentile of the deltas is the derived interval
#         --argjson tolerance  a delta counts as a gap above interval * tolerance
#         --argjson truncated / --argjson failed  how the read ended
# Output: the link record plus a measurementGap object.
#
# The assumption this rests on, and the reason it is so much cheaper than comparing the
# two sides: measurements of one series arrive at a fixed interval (two minutes on
# t1298412, give or take a few seconds). Anything markedly longer than that interval is
# time in which the asset received nothing, which is exactly what a broken reverse index
# looks like. Only the ASSET side is read for this - a few series per asset instead of
# the 200+ of a device.
#
# What it cannot tell apart is a broken link from a device that was switched off: both
# leave the same hole. Downloading the device measurements of the reported ranges settles
# that afterwards - an empty download means the device was silent, not that the link was
# broken.
#
# The caller supplies the interval: the value of --interval, or the p95 of the deltas of
# this link's own SOURCE DEVICE series, which is the same cadence where the link is
# healthy and is not affected by the gaps being looked for. Only when neither is available
# is it derived from the asset series here, and then from the same p95 rather than the
# median: a series arriving in bursts (two measurements two seconds apart every two
# minutes, as on t1298412) has a median of 2s and a real cadence of 120s.
# Needs jq -L <jq-dir> for the gap-time module.
include "gap-time";
def atLeast($n): if . < $n then $n else . end;

($dateFrom | toEpoch) as $windowFrom
| ($dateTo | toEpoch) as $windowTo
| ($times | toPoints) as $p
| ($p | length) as $n
| ($p | deltasOf) as $deltas
| ($deltas | intervalOf($percentile; $tolerance)) as $observed
| ($interval // $observed) as $step
| (if $step == null or $step <= 0 then null else $step * $tolerance end) as $threshold

# A read that stopped early still delivered a valid suffix - the query is descending, so
# it pages newest first. It bounds the gap from one side rather than being thrown away,
# and only the part of the window it actually covered is judged.
| (if ($truncated or ($failed and $n > 0)) and $n > 0 then $p[0].at else $windowFrom end) as $coveredFrom

| (if $failed and $n == 0 then "readFailed"
   elif $n == 0 then "assetEmpty"
   elif $threshold == null then "intervalUnknown"
   else "interval"
   end) as $method

# A read that returned nothing at all did not observe an empty series, it failed to
# report one. Claiming the whole window as a gap on the strength of that would put every
# measurement of the device into the reprocess batches.
| (if $method == "readFailed" then []
   elif $n == 0 then
     # Nothing at all in the window. The whole window is missing, whatever the cadence
     # was supposed to be; how many points that is can only be said when --interval
     # declared one, since the series itself gave none.
     [ { dateFrom: $dateFrom, dateTo: $dateTo,
         seconds: (($windowTo - $windowFrom) | round1),
         missingPoints: (if $step == null then null
                         else ((($windowTo - $windowFrom) / $step | floor) | atLeast(1)) end),
         edge: "window" } ]
   elif $threshold == null then []
   else
     [ (if ($p[0].at - $coveredFrom) > $threshold then
          { dateFrom: $dateFrom, dateTo: $p[0].time,
            seconds: (($p[0].at - $coveredFrom) | round1),
            missingPoints: ((($p[0].at - $coveredFrom) / $step | floor) | atLeast(1)),
            edge: "leading" }
        else empty end),
       (range(1; $n)
        | select(($p[.].at - $p[. - 1].at) > $threshold)
        | { dateFrom: $p[. - 1].time, dateTo: $p[.].time,
            seconds: (($p[.].at - $p[. - 1].at) | round1),
            # Both ends of an interior gap are measurements that DID arrive, so the
            # number of intervals between them is one more than the missing points.
            missingPoints: (((($p[.].at - $p[. - 1].at) / $step | round) - 1) | atLeast(1)),
            edge: null }),
       (if ($windowTo - $p[$n - 1].at) > $threshold then
          { dateFrom: $p[$n - 1].time, dateTo: $dateTo,
            seconds: (($windowTo - $p[$n - 1].at) | round1),
            missingPoints: ((($windowTo - $p[$n - 1].at) / $step | floor) | atLeast(1)),
            edge: "trailing" }
        else empty end) ]
   end) as $ranges

| [ (if $failed and $n > 0 then
        "The asset series read stopped early with an error after " + ($n | tostring)
        + " measurements, only the part of the window it covered was judged."
      else empty end),
    (if $truncated then
        "The asset series hit C8Y_DTM_GAPS_MAX_POINTS. It is read newest first, so only "
        + "the window from " + $p[0].time + " on was judged."
      else empty end),
    (if $method == "intervalUnknown" then
        "The series holds " + ($n | tostring) + " measurement(s) in the window, which is "
        + "not enough to derive an interval from. Declare one with --interval, or widen "
        + "--dateFrom."
      else empty end),
    (if $method == "assetEmpty" and $interval == null then
        "The series is empty in the whole window, so it has no interval of its own. The "
        + "missing point count is unknown; declare an interval with --interval for an estimate."
      else empty end),
    (if $interval != null and $observed != null and ($observed > $interval * $tolerance) then
        "The interval this series actually runs at (" + ($observed | round1 | tostring)
        + "s) is longer than the one it was judged by (" + ($interval | tostring) + "s) allows. "
        + "Either that interval is wrong for this series, or the series is missing measurements "
        + "throughout."
      else empty end),
    # The other direction, which is the one that fails silently: too coarse an interval
    # reports nothing wrong, it just stops seeing the shorter gaps.
    (if $interval != null and $observed != null and ($interval > $observed * $tolerance) then
        "The interval this series was judged by (" + ($interval | tostring) + "s) is well above "
        + "the one it actually runs at (" + ($observed | round1 | tostring) + "s), so holes "
        + "shorter than " + (($interval * $tolerance) | round1 | tostring) + "s were not reported. "
        + "Run --suggestIntervals and lower --interval to see them."
      else empty end) ] as $notes

| $link
  + { measurementGap:
      ({ method: $method,
         interval: (if $step == null then null else ($step | round1) end),
         intervalSource: (if $step == null then null
                          elif $interval != null then $intervalSource
                          else "asset" end),
         observedInterval: (if $observed == null then null else ($observed | round1) end),
         asset: { first: ($p | first | .time), last: ($p | last | .time),
                  points: $n, truncated: ($truncated or $failed) },
         # null rather than 0 whenever nothing was established: "unknown how many" must
         # not read as "none". A method that judged the series reports 0 as a finding.
         missingPoints: (if $method == "readFailed" or $method == "intervalUnknown" then null
                         else ($ranges | map(.missingPoints)
                               | if any(. == null) then null else (add // 0) end)
                         end),
         ranges: $ranges,
         truncated: ($truncated or $failed) }
       + (if ($notes | length) > 0 then { notes: $notes } else {} end)) }
