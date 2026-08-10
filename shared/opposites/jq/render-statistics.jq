# Renders the statistics object as an aligned text block, one line per output row.
# Input:  the object produced by verification-statistics.jq
# Output: text lines (use jq -r)
def rpad(s; n): (s | tostring) as $s | $s + (if n > ($s | length) then (" " * (n - ($s | length))) else "" end);
def lpad(v; n): (v | tostring) as $s | (if n > ($s | length) then (" " * (n - ($s | length))) else "" end) + $s;
def row(name; val): "    " + rpad(name; 44) + lpad(val; 9);
def range3(a; b; c): (a | tostring) + " / " + (b | tostring) + " / " + (c | tostring);
def plural(n; word): (n | tostring) + " " + word + (if n == 1 then "" else "s" end);
def idList(ids): (ids | length) as $n
    | "source devices: " + ((ids | .[0:5]) | join(", "))
      + (if $n > 5 then " (and " + (($n - 5) | tostring) + " more)" else "" end);
# Explains every cause that leaves links without a verdict, and what it means
# for the data. "BROKEN" means the opposite references are definitely absent,
# "UNKNOWN" means the state could not be determined and needs another run.
{
  "CumulocityError":
    [ "The source device could not be read (deleted, or the request failed), so",
      "no opposite reference can exist for its links. BROKEN: these links point",
      "at a device that cannot hold a reverse index." ],
  "NoChildAdditionsError":
    [ "The source device exists but has no c8y_LinkedSeriesReverseIndex child",
      "addition at all. BROKEN: none of its links have an opposite reference." ],
  "MissingLinkedAssetsInChildAdditionError":
    [ "The child addition exists but carries no c8y_LinkedAssets fragment.",
      "BROKEN: none of its links have an opposite reference." ],
  "LinkedAssetsNotArrayOrEmptyError":
    [ "The child addition c8y_LinkedAssets is empty or not an array.",
      "BROKEN: none of its links have an opposite reference." ],
  "TooManyChildAdditionsError":
    [ "The source device has more than one c8y_LinkedSeriesReverseIndex child",
      "addition, so the one to check is ambiguous. UNKNOWN: inspect the devices",
      "listed above and remove the duplicates before verifying again." ],
  "NoVerificationResultError":
    [ "No verification record came back for the source device, so its links were",
      "never compared. UNKNOWN: usually an aborted request (--abortOnErrors) or",
      "an output template error, see verify-c8y-stderr.log and run verify again." ],
  "NoReferencesFieldError":
    [ "The child additions response contained neither a references nor a",
      "managedObjects array. UNKNOWN: unexpected response shape, see rawOutput",
      "in verify-errors.json." ],
  "ManagedObjectNotObjectError":
    [ "The first child addition reference held no readable managed object.",
      "UNKNOWN: unexpected response shape, see verify-errors.json." ]
} as $causeHelp
# --gapsOnly produces a statistics object that holds the measurement gap section only,
# because nothing was verified. Everything below the gap section is skipped then rather
# than rendered as a wall of nulls.
| (if .assets == null then [ "Measurement gap statistics" ] else
  [ "Verification statistics",
  "  Assets and their linked series",
  row("assets loaded"; .assets.loaded),
  row("... with a sourced linked series"; .assets.withSourceLinkedSeries),
  row("... that also have unsourced series"; .assets.withUnsourcedLinkedSeries),
  row("linked series defined on them"; .assets.linkedSeriesDefined),
  row("... with a source, verified below"; .assets.linkedSeriesWithSource),
  row("... without a source, nothing to verify"; .assets.linkedSeriesWithoutSource),
  row("sourced series per asset (min/avg/max)"; range3(.assets.linksPerAssetMin; .assets.linksPerAssetAvg; .assets.linksPerAssetMax)),
  "  Links (asset series to device series)",
  row("total"; .links.total),
  row("verified"; (.links.verified | tostring) + " (" + (.links.verifiedPct | tostring) + "%)"),
  row("missing (no entry in the child addition)"; .links.missing),
  row("unverifiable (no verdict, see below)"; .links.unverifiable),
  "  Source devices",
  row("referenced by links"; .devices.sourceDevices),
  row("with a verification record"; .devices.withVerificationRecord),
  row("with a reverse index child addition"; .devices.withChildAddition),
  row("without errors"; .devices.ok),
  row("with errors"; .devices.withErrors),
  row("links per device (min/avg/max)"; range3(.devices.linksPerDeviceMin; .devices.linksPerDeviceAvg; .devices.linksPerDeviceMax)),
  "  Reverse index (c8y_LinkedAssets entries)",
  row("stored entries"; .reverseIndex.storedEntries),
  row("stale entries (no matching live link)"; .reverseIndex.staleEntries),
  row("entries per child addition (min/avg/max)"; range3(.reverseIndex.entriesPerChildAdditionMin; .reverseIndex.entriesPerChildAdditionAvg; .reverseIndex.entriesPerChildAdditionMax)),
  "  Source series (device + fragment + series)",
  row("distinct"; .sourceSeries.distinct),
  row("targeted by exactly one link"; .sourceSeries.singleLink),
  row("targeted by multiple links"; .sourceSeries.multiLink),
  row("  of those, all links stored"; .sourceSeries.multiLinkAllStored),
  row("  of those, only one link stored"; .sourceSeries.multiLinkOnlyOneStored),
  row("  of those, some links stored"; .sourceSeries.multiLinkSomeStored),
  row("  of those, no links stored"; .sourceSeries.multiLinkNoneStored),
  row("max links on one source series"; .sourceSeries.maxLinksOnOneSourceSeries),
  "  Missing links",
  row("total"; .missingLinks.total),
  row("source series present anyway"; .missingLinks.sourceSeriesPresent),
  row("source series absent as well"; .missingLinks.sourceSeriesAbsent),
  row("distinct assets affected"; .missingLinks.distinctAssets),
  row("distinct source series affected"; .missingLinks.distinctSourceSeries) ]
+ [ "  Unverifiable links (a link that could not be given a pass or fail verdict,",
    "  because the reverse index of its source device could not be read at all)" ]
+ (if .links.unverifiable == 0 then [ "    none" ]
   else [ row("total"; .unverifiable.total),
          row("distinct devices affected"; .unverifiable.devices),
          row("distinct assets affected"; .unverifiable.assets) ]
        + (.unverifiable.byCause | to_entries | map(
           [ "    " + rpad(.key; 44)
               + lpad(plural(.value.links; "link"); 12)
               + ", " + plural(.value.devices; "device")
               + ", " + plural(.value.assets; "asset") ]
           + (($causeHelp[.key] // ["See verify-errors.json for the details of this error."])
              | map("        " + .))
           + [ "        " + idList(.value.deviceIds) ]) | add)
   end)
+ (if (.errorsByType | length) == 0 then [ "  Errors by type", "    none" ]
   else [ "  Errors by type" ] + (.errorsByType | to_entries | map(row(.key; plural(.value.devices; "device") + " / " + plural(.value.links; "link"))))
   end)
  end)
# Only present when verify ran with --measurementGaps.
+ (if .measurementGaps == null then []
   else [ "  Measurement gaps (device measurements that never reached the asset)",
          row("window looked at, from"; (.measurementGaps.window.dateFrom // "-")),
          row("window looked at, to"; (.measurementGaps.window.dateTo // "-")),
          row("links looked at"; .measurementGaps.links),
          row("... missing in the reverse index right now"; .measurementGaps.failingLinks),
          row("... selected with --gapsFor"; .measurementGaps.selectedLinks),
          row("probed"; .measurementGaps.probed),
          row("not probed (link limit reached)"; .measurementGaps.skipped),
          row("classified from the supported series index"; .measurementGaps.supportedSeriesShortcut),
          row("with a gap"; .measurementGaps.withGaps),
          row("without a gap"; .measurementGaps.withoutGaps),
          row("undetermined (probe or query failed)"; .measurementGaps.failed),
          row("capped by the point limit"; .measurementGaps.truncated),
          row("distinct assets affected"; .measurementGaps.distinctAssets) ]
        + (if .measurementGaps.approximate > 0 then
             [ row("boundary-only estimate (--measurementGaps)"; .measurementGaps.approximate),
               row("  ... of those, point count unknown"; .measurementGaps.unknownPointCountLinks) ]
           else [] end)
        + [ row("missing measurements in total (known counts only)"; .measurementGaps.totalMissingPoints),
            row("most missing on a single link (known counts only)"; .measurementGaps.maxMissingPointsOnOneLink),
            row("earliest gap starts at"; (.measurementGaps.earliestGapStart // "-")),
            row("latest gap ends at"; (.measurementGaps.latestGapEnd // "-")) ]
        + (.measurementGaps.byMethod | to_entries | map(row("  " + .key; plural(.value; "link"))))
        + [ "        assetEmpty: the asset series never received anything, the whole",
            "          extent of the device series is missing.",
            "        timestampDiff: both sides hold data, the reported ranges are the",
            "          timestamps present on the device and absent on the asset.",
            "        Nothing outside the window above was looked at, so 'without a gap'",
            "          only means 'no gap in that window'. Widen it with --dateFrom.",
            "        Measurements outside the tenant retention are already deleted, so a",
            "          reported range is an upper bound of what can still be recovered.",
            "        The asset side is queried with the fragment/series declared on the",
            "          asset unless --assetFragmentTemplate/--assetSeriesTemplate say",
            "          otherwise. A smart function that persists elsewhere makes every",
            "          link look empty, see OPPOSITES-CONTEXT.md." ]
        + (if .measurementGaps.approximate > 0 then
             [ "        Boundary-only estimate: point counts are unknown, and a gap the asset",
               "          series later recovered from is invisible. Rerun with",
               "          --measurementGapsExact for exact data." ]
           else [] end)
   end)
| .[]
