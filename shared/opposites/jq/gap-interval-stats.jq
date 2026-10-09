# The cadence of one sampled series.
# Input:  nothing (jq -n)
# Inputs: --slurpfile times      the sampled measurements, { time } objects or strings
#         --argjson percentile   which percentile is the interval
#         --argjson tolerance    a delta above interval * tolerance is a gap
# Output: one cadence object, or null when the sample holds nothing usable.
# Needs jq -L <jq-dir> for the gap-time module.
include "gap-time";
($times | toPoints) as $p
| if ($p | length) < 2 then null else ($p | cadenceOf($percentile; $tolerance)) end
