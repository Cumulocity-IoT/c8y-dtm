# Renders the sampled cadences of --suggestIntervals as an aligned text block.
# Input:  the sample records, slurped (jq -s): { sourceId, sourceFragment, sourceSeries,
#         links, assetIds, cadence }
# Inputs: --argjson tolerance / --argjson percentile / --argjson sampleSize
# Output: text lines (use jq -r)
#
# The point of the table is to make the shape of the series visible rather than to hand
# down a number: p50 far below p95 means the series arrives in bursts, and its median -
# what a naive derivation would use - is not its cadence at all.
include "gap-time";
def rpad(s; n): (s | tostring) as $s | $s + (if n > ($s | length) then (" " * (n - ($s | length))) else "" end);
def lpad(v; n): (v | tostring) as $s | (if n > ($s | length) then (" " * (n - ($s | length))) else "" end) + $s;
def num(v; n): lpad((if v == null then "-" else v end); n);

. as $rows
| [ $rows[] | select(.cadence != null) | .cadence.interval ] as $intervals
| ([ "Interval suggestions (sampled from the source device series, newest "
     + ($sampleSize | tostring) + " measurements in the window)",
     "",
     "  " + rpad("device"; 12) + rpad("series"; 46) + lpad("pts"; 5) + lpad("p50"; 9)
          + lpad("p90"; 9) + lpad("p95"; 9) + lpad("p99"; 9) + lpad("max"; 9) + lpad("suggest"; 10) ]
   + [ $rows[]
       | .cadence as $c
       | "  " + rpad(.sourceId; 12)
              + rpad((.sourceSeries | if length > 44 then .[0:41] + "..." else . end); 46)
              + (if $c == null then lpad("no sample"; 5 + 9 * 5 + 10)
                 else num($c.points; 5) + num($c.p50; 9) + num($c.p90; 9) + num($c.p95; 9)
                      + num($c.p99; 9) + num($c.max; 9) + num($c.interval; 10)
                 end) ]
   + [ "" ]
   + (if ($intervals | length) == 0 then
        [ "  Nothing could be sampled. The series named above hold fewer than two",
          "  measurements in --dateFrom/--dateTo, so no cadence can be derived from them." ]
      else
        [ "  Suggested for the whole run:  --interval " + (($intervals | max) | tostring) + "s"
          + (if ($intervals | min) != ($intervals | max)
             then "   (the series differ: " + (($intervals | min) | tostring) + "s .. "
                  + (($intervals | max) | tostring) + "s)"
             else "" end),
          "  A hole is then reported above " + ((($intervals | max) * $tolerance | round1) | tostring)
          + "s (--tolerance " + ($tolerance | tostring) + ").",
          "",
          "  The interval is the p" + ($percentile | tostring) + " of the time between two",
          "  measurements, i.e. the longest spacing that is still normal - not the median.",
          "  Take the LARGEST suggestion when one value has to cover every series: too small",
          "  reports normal spacing as a gap, too large only loses the shortest gaps." ]
      end)
   + [ "" ]
   # The consecutive deltas of each series, which is the thing to actually look at when a
   # suggestion is surprising. A repeating short/long alternation is a burst; a long value
   # sitting among otherwise equal ones is a gap in the source.
   + [ "  Time between consecutive measurements, first 12 of each sample (seconds):" ]
   + [ $rows[]
       | "    " + rpad(.sourceId; 12)
         + (if .cadence == null then "no sample"
            else (.cadence.sampleDeltas | map(tostring) | join("  ")) end) ]
   + [ "    from " + ([ $rows[] | select(.cadence != null) | .cadence.first ] | min // "-") + " on" ]
   + [ "" ]
   + ([ $rows[] | select(.cadence != null and .cadence.p50 != null and .cadence.p95 != null
                         and .cadence.p95 > .cadence.p50 * 4)
        | "  " + .sourceId + " " + .sourceSeries + ": p50 " + (.cadence.p50 | tostring)
          + "s but p95 " + (.cadence.p95 | tostring) + "s. Either it arrives in BURSTS, and "
          + (.cadence.p95 | tostring) + "s is the cadence, or it is missing measurements "
          + "throughout, and " + (.cadence.p50 | tostring) + "s is. The deltas above tell the "
          + "two apart: alternating short/long is a burst, an occasional long one is a gap." ])
   + ([ $rows[] | select(.cadence != null and .cadence.aboveThreshold > 0)
        | "  " + .sourceId + " " + .sourceSeries + " has "
          + (.cadence.aboveThreshold | tostring) + " hole(s) above the threshold in the sample "
          + "itself, so the SOURCE is not continuous either." ]))
| .[]
