# Builds one c8y_LinkedSeriesReverseIndex payload per source device.
# Input:  all exploded assets, slurped (jq -s)
# Output: one { id, c8y_LinkedAssets } object per source device (streamed).
#         Each c8y_LinkedAssets entry carries the source fragment/series at the top
#         level and the asset side of the link under .asset (including .asset.id).
map({
    source_id: .c8y_LinkedSeries.source.id,
    linked_asset: (
        . as $parent |
        {
            asset: ($parent.c8y_LinkedSeries | del(.source) + {id: $parent.id})
        } + ($parent.c8y_LinkedSeries.source | del(.id))
    )
}) |
group_by(.source_id) |
map({
    id: .[0].source_id,
    c8y_LinkedAssets: map(.linked_asset)
}) | 
.[]
