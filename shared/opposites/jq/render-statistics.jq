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
| [ "Verification statistics",
  "  Assets",
  row("with c8y_LinkedSeries"; .assets.withLinkedSeries),
  row("with a source-linked series"; .assets.withSourceLinkedSeries),
  row("links per asset (min/avg/max)"; range3(.assets.linksPerAssetMin; .assets.linksPerAssetAvg; .assets.linksPerAssetMax)),
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
| .[]
