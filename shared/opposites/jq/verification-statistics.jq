# Computes the verification statistics as a single JSON object.
# Inputs: --slurpfile assets    the assets as loaded from the inventory
#         --slurpfile links     link records (see link-records.jq)
#         --slurpfile devices   records from verify-child-addition.jsonnet
#         --slurpfile result    verdicts from verify-match-links.jq
# Output: one object with the assets, links, devices, reverseIndex, sourceSeries,
#         missingLinks, unverifiable and errorsByType sections.
# Invariants: links.verified + links.missing + links.unverifiable == links.total
#             assets.linkedSeriesWithSource + assets.linkedSeriesWithoutSource
#                 == assets.linkedSeriesDefined
# A linked series without a source cannot have an opposite reference, so it is not a
# link and never verified. It is counted so that the totals reconcile: without it the
# output silently presents the sourced series as the whole population.
def pct(a; b): if (b | not) or b == 0 then 0 else ((a / b) * 1000 | round) / 10 end;
def avg1: if length == 0 then 0 else ((add / length) * 10 | round) / 10 end;
def liveKey: (.assetId // "" | tostring) + "|" + (.c8y_LinkedSeries.fragment // "" | tostring) + "|" + (.c8y_LinkedSeries.series // "" | tostring);
def entryKey: (.asset.id // "" | tostring) + "|" + (.asset.fragment // "" | tostring) + "|" + (.asset.series // "" | tostring);
def srcKey: (.c8y_LinkedSeries.source.fragment // "" | tostring) + "|" + (.c8y_LinkedSeries.source.series // "" | tostring);
def entrySrcKey: (.fragment // "" | tostring) + "|" + (.series // "" | tostring);
# The c8y_LinkedSeries entries of one asset, and whether an entry carries a source.
def seriesOf: if (.c8y_LinkedSeries | type) == "array" then .c8y_LinkedSeries else [] end;
def unsourced: select((type != "object") or ((.source | type) != "object") or (.source.id == null));
def verifiedLinks: map(if .error == null then (.linkCount // 0)
                       elif .error == "MissingLinkedSeriesInChildAdditionError" then ((.linkCount // 0) - (.missingCount // 0))
                       else 0 end) | add // 0;

($links | map({key: liveKey, value: true}) | from_entries) as $liveKeys
| ($devices | map(select(.linkedAssets != null)
      | {key: .id,
         value: (.linkedAssets | group_by(entrySrcKey) | map({key: (.[0] | entrySrcKey), value: length}) | from_entries)})
   | from_entries) as $storedPerSrcKey
| ($devices | map(select(.linkedAssets != null) | .linkedAssets | length)) as $entryCounts
| ($links | group_by(.id) | map(length)) as $linksPerDevice
| ($links | group_by(.assetId) | map(length)) as $linksPerAsset
| ($links
    | group_by([.id, srcKey])
    | map({ device: .[0].id, key: (.[0] | srcKey), links: length })
    | map(. + { stored: (($storedPerSrcKey[.device][.key]) // 0) })) as $srcGroups
| ($result | map(select(.error != null and .error != "MissingLinkedSeriesInChildAdditionError"))) as $deviceLevelErrors
| ($result | map(.missingLinks // []) | add // []) as $allMissing
| ($links | length) as $linkTotal
| ($result | verifiedLinks) as $verified
| ($deviceLevelErrors | map(.linkCount // 0) | add // 0) as $unverifiable
| {
    assets: {
      loaded: ($assets | length),
      withSourceLinkedSeries: ($links | map(.assetId) | unique | length),
      withUnsourcedLinkedSeries: ([$assets[] | select([seriesOf[] | unsourced] | length > 0)] | length),
      linkedSeriesDefined: ([$assets[] | seriesOf | length] | add // 0),
      linkedSeriesWithSource: ($links | length),
      linkedSeriesWithoutSource: ([$assets[] | seriesOf[] | unsourced] | length),
      linksPerAssetMin: ($linksPerAsset | min // 0),
      linksPerAssetAvg: ($linksPerAsset | avg1),
      linksPerAssetMax: ($linksPerAsset | max // 0)
    },
    links: {
      total: $linkTotal,
      verified: $verified,
      verifiedPct: pct($verified; $linkTotal),
      missing: ($result | map(.missingCount // 0) | add // 0),
      unverifiable: $unverifiable
    },
    unverifiable: {
      total: $unverifiable,
      devices: ($deviceLevelErrors | length),
      assets: ($deviceLevelErrors | map(.affectedAssets // []) | add // [] | unique | length),
      byCause: ($deviceLevelErrors
          | group_by(.error)
          | map({ key: .[0].error,
                  value: { links: (map(.linkCount // 0) | add // 0),
                           devices: length,
                           assets: (map(.affectedAssets // []) | add // [] | unique | length),
                           deviceIds: (map(.id) | unique) } })
          | from_entries)
    },
    devices: {
      sourceDevices: ($links | map(.id) | unique | length),
      withVerificationRecord: ($result | length),
      withChildAddition: ($devices | map(select(.linkedAssets != null)) | length),
      ok: ($result | map(select(.error == null)) | length),
      withErrors: ($result | map(select(.error != null)) | length),
      linksPerDeviceMin: ($linksPerDevice | min // 0),
      linksPerDeviceAvg: ($linksPerDevice | avg1),
      linksPerDeviceMax: ($linksPerDevice | max // 0)
    },
    reverseIndex: {
      storedEntries: ($entryCounts | add // 0),
      staleEntries: ($devices | map(select(.linkedAssets != null) | .linkedAssets | map(select($liveKeys[entryKey] == null)) | length) | add // 0),
      entriesPerChildAdditionMin: ($entryCounts | min // 0),
      entriesPerChildAdditionAvg: ($entryCounts | avg1),
      entriesPerChildAdditionMax: ($entryCounts | max // 0)
    },
    sourceSeries: {
      distinct: ($srcGroups | length),
      singleLink: ($srcGroups | map(select(.links == 1)) | length),
      multiLink: ($srcGroups | map(select(.links > 1)) | length),
      multiLinkAllStored: ($srcGroups | map(select(.links > 1 and .stored == .links)) | length),
      multiLinkOnlyOneStored: ($srcGroups | map(select(.links > 1 and .stored == 1)) | length),
      multiLinkSomeStored: ($srcGroups | map(select(.links > 1 and .stored > 1 and .stored < .links)) | length),
      multiLinkNoneStored: ($srcGroups | map(select(.links > 1 and .stored == 0)) | length),
      maxLinksOnOneSourceSeries: ($srcGroups | map(.links) | max // 0)
    },
    missingLinks: {
      total: ($allMissing | length),
      sourceSeriesPresent: ($allMissing | map(select(.sourceSeriesPresent)) | length),
      sourceSeriesAbsent: ($allMissing | map(select(.sourceSeriesPresent | not)) | length),
      distinctAssets: ($allMissing | map(.assetId) | unique | length),
      distinctSourceSeries: ($allMissing | map((.sourceFragment | tostring) + "|" + (.sourceSeries | tostring)) | unique | length)
    },
    errorsByType: ($result | map(select(.error != null))
        | group_by(.error)
        | map({ key: .[0].error,
                value: { devices: length,
                         links: (map(if .error == "MissingLinkedSeriesInChildAdditionError" then (.missingCount // 0) else (.linkCount // 0) end) | add // 0) } })
        | from_entries)
  }
