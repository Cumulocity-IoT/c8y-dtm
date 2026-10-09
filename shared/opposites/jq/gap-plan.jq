# Decides which of the selected links are actually read.
# Input:  the candidates of gap-selection-plan.jq, slurped (jq -s)
# Inputs: --argjson maxLinks  maximum number of links to read (0 or less = no limit)
# Output: the candidates, deduplicated by key, each with a probe flag.
#
# The order decides what survives C8Y_DTM_GAPS_MAX_LINKS, so it goes from the most
# specific question to the least: links that were named one by one, then whole assets,
# then whole devices. A single device wide selector can carry hundreds of links and would
# otherwise leave no budget for the handful that were asked for by name.
group_by(.key)
| map(.[0])
| sort_by([ (.selectionPrecision // 0), .assetId, .key ])
| [ to_entries[] | .value + { probe: ($maxLinks <= 0 or (.key < $maxLinks)) } ]
| .[]
