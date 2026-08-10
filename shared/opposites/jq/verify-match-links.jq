# Matches every link against the c8y_LinkedAssets of its source device.
# Inputs: --slurpfile devices  records from verify-child-addition.jsonnet
#         --slurpfile links    link records (see link-records.jq)
# Output: one verdict object per source device (streamed, sorted by device id):
#         success              -> { verification: "success", linkCount, linkedAssetsCount, ... }
#         missing entries      -> { error: "MissingLinkedSeriesInChildAdditionError", missingCount, missingLinks }
#         no record for device -> { error: "NoVerificationResultError", linkCount, affectedAssets }
#         device level error   -> the device record plus linkCount and affectedAssets
# A link is identified by the ASSET side (asset.id + asset.fragment + asset.series).
# The source fragment/series alone is ambiguous: many assets and series can share the
# same source series on one device, which is what sourceSeriesPresent reports.
def linkKey: [(.assetId // "" | tostring), (.c8y_LinkedSeries.fragment // "" | tostring), (.c8y_LinkedSeries.series // "" | tostring)] | join("|");
def sourceKey: [(.c8y_LinkedSeries.source.fragment // "" | tostring), (.c8y_LinkedSeries.source.series // "" | tostring)] | join("|");
def entryAssetKey: [(.asset.id // "" | tostring), (.asset.fragment // "" | tostring), (.asset.series // "" | tostring)] | join("|");
def entrySourceKey: [(.fragment // "" | tostring), (.series // "" | tostring)] | join("|");
($devices | map(select(.id != null)) | INDEX(.id)) as $byDevice
| $links
| group_by(.id)
| map(
    ({ id: .[0].id, links: . }) as $group
    | ($group.links | length) as $linkCount
    | ($group.links | map(.assetId) | unique) as $assets
    | ($byDevice[$group.id]) as $device
    | if $device == null then
          { id: $group.id, error: "NoVerificationResultError", linkCount: $linkCount, affectedAssets: $assets }
      elif ($device.linkedAssets | type) != "array" then
          $device + { linkCount: $linkCount, affectedAssets: $assets }
      else
          ($device.linkedAssets | map({ key: entryAssetKey, value: true }) | from_entries) as $assetKeys
          | ($device.linkedAssets | map({ key: entrySourceKey, value: true }) | from_entries) as $sourceKeys
          | ($group.links | map(select($assetKeys[linkKey] == null))) as $missing
          | { id: $device.id, childAdditionId: $device.childAdditionId, type: $device.type,
              linkCount: $linkCount, linkedAssetsCount: ($device.linkedAssets | length) }
            + (if ($missing | length) == 0 then
                   { verification: "success" }
               else
                   { error: "MissingLinkedSeriesInChildAdditionError",
                     missingCount: ($missing | length),
                     missingLinks: ($missing | map({
                         assetId: .assetId,
                         fragment: .c8y_LinkedSeries.fragment,
                         series: .c8y_LinkedSeries.series,
                         sourceFragment: .c8y_LinkedSeries.source.fragment,
                         sourceSeries: .c8y_LinkedSeries.source.series,
                         sourceSeriesPresent: ($sourceKeys[sourceKey] != null)
                     }
                     # Only carried when an asset fragment/series template resolved to
                     # something other than the declared values, so that the verdict of a
                     # run without --assetFragmentTemplate/--assetSeriesTemplate keeps its
                     # shape. This is the fragment/series the measurement gap analysis
                     # queries on the asset, see link-records.jq.
                     + (if .measurementFragment != .c8y_LinkedSeries.fragment
                           or .measurementSeries != .c8y_LinkedSeries.series then
                            { measurementFragment: .measurementFragment,
                              measurementSeries: .measurementSeries }
                        else {} end))) }
               end)
      end
  )
| sort_by(.id)
| .[]
