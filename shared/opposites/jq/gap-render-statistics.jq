# Renders the measurement gap statistics as an aligned text block, one line per row.
# Input:  the object produced by gap-statistics.jq
# Output: text lines (use jq -r)
def rpad(s; n): (s | tostring) as $s | $s + (if n > ($s | length) then (" " * (n - ($s | length))) else "" end);
def lpad(v; n): (v | tostring) as $s | (if n > ($s | length) then (" " * (n - ($s | length))) else "" end) + $s;
def row(name; val): "    " + rpad(name; 44) + lpad(val; 9);
def plural(n; word): (n | tostring) + " " + word + (if n == 1 then "" else "s" end);
(
   [ "Measurement gap statistics",
     "  Measurement gaps (holes in the cadence of the asset series)",
          row("window looked at, from"; (.measurementGaps.window.dateFrom // "-")),
          row("window looked at, to"; (.measurementGaps.window.dateTo // "-")),
          row("links looked at"; .measurementGaps.links),
          row("asset series read"; .measurementGaps.probed),
          row("not read (link limit reached)"; .measurementGaps.skipped),
          row("asset measurements read in total"; .measurementGaps.assetPoints),
          row("interval used, shortest (s)"; (.measurementGaps.intervalSeconds.min // "-")),
          row("interval used, longest (s)"; (.measurementGaps.intervalSeconds.max // "-")),
          row("with a gap"; .measurementGaps.withGaps),
          row("... of those, empty for the whole window"; .measurementGaps.assetEmpty),
          row("without a gap"; .measurementGaps.withoutGaps),
          row("undetermined (read failed or no interval)"; .measurementGaps.failed),
          row("capped by the point limit"; .measurementGaps.truncated),
          row("distinct assets affected"; .measurementGaps.distinctAssets),
          row("missing measurements, estimated total"; .measurementGaps.estimatedMissingPoints),
          row("most missing on a single link (estimated)"; .measurementGaps.maxMissingPointsOnOneLink),
          row("gaps of unknown size"; .measurementGaps.unknownPointCountLinks),
          row("earliest gap starts at"; (.measurementGaps.earliestGapStart // "-")),
          row("latest gap ends at"; (.measurementGaps.latestGapEnd // "-")) ]
        + (.measurementGaps.byMethod | to_entries | map(row("  " + .key; plural(.value; "link"))))
        + [ "        interval: the asset series was read and judged against its own",
            "          cadence. A hole longer than interval * tolerance is a gap.",
            "        assetEmpty: the asset series holds nothing in the whole window, so",
            "          the whole window is reported as one gap.",
            "        intervalUnknown: too few measurements to derive an interval from,",
            "          and none was declared with --interval. Nothing is claimed.",
            "        Point counts are ESTIMATES: gap length divided by the interval, not",
            "          measurements that were seen to be missing. What is actually there",
            "          to recover is what --missingMeasurementsFile downloads.",
            "        A gap only means the ASSET received nothing. A device that was",
            "          switched off looks exactly the same; the download of the device",
            "          measurements behind the range settles it, an empty one means the",
            "          device was silent as well.",
            "        Nothing outside the window above was looked at, so 'without a gap'",
            "          only means 'no gap in that window'. Widen it with --dateFrom.",
            "        Measurements outside the tenant retention are already deleted, so a",
            "          reported range is an upper bound of what can still be recovered.",
            "        The asset side is queried with the fragment/series declared on the",
            "          asset unless --assetFragmentTemplate/--assetSeriesTemplate say",
            "          otherwise. A smart function that persists elsewhere makes every",
            "          link look empty, see OPPOSITES-CONTEXT.md." ]
)
| .[]
