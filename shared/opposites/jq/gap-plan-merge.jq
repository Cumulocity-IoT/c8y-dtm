# Joins the gap candidates of the failing links with those of --gapsFor and decides
# which of them are actually probed.
# Inputs: --slurpfile failing   candidates from gap-plan.jq
#         --slurpfile selected  candidates from gap-selection-plan.jq (may be empty)
#         --argjson maxLinks    maximum number of links to probe (0 or less = no limit)
# Output: the candidates, deduplicated by key, each with a probe flag.
#
# A link that is both failing and selected keeps origin "failing", so that its gap is
# still reported on the error line of the verification instead of a second time as a
# selected one.
#
# The order decides what survives C8Y_DTM_GAPS_MAX_LINKS, so it goes from the most
# specific question to the least: links that are missing from the reverse index right
# now, then links that were named one by one, then whole assets, then whole devices. A
# single device wide selector can carry hundreds of links and would otherwise leave no
# budget for the handful that were asked for by name.
[ $failing[], $selected[] ]
| group_by(.key)
| map((map(select(.origin == "failing")) | first) // .[0])
| sort_by([ (if .origin == "failing" then 0 else 1 end),
            (.selectionPrecision // 0),
            .assetId,
            .key ])
| [ to_entries[] | .value + { probe: ($maxLinks <= 0 or (.key < $maxLinks)) } ]
| .[]
