# Renders the measurementGap of one record as the trailing part of a console message.
# Included as a module by verification-error-messages.jq and gap-messages.jq, which both
# report the same gap in a different context (a failing link vs an explicitly selected
# one) and must not describe it differently.
# Input: a record carrying a measurementGap object, or none.
#
# Point counts are always estimates: they are the length of the gap divided by the
# interval of the series, never a count of measurements that were seen missing. The
# wording says so, because the number reads like a fact otherwise.
def gapSummary:
  (.measurementGap // null) as $g
  | if $g == null then ""
    elif ($g.method == "skipped") then ", measurement gap not determined (link limit reached)"
    elif ($g.method == "readFailed") then ", measurement gap could not be determined (the asset series could not be read)"
    elif ($g.method == "intervalUnknown") then
        ", measurement gap could not be determined (too few measurements to derive an interval, use --interval)"
    elif (($g.ranges | length) == 0) then
        ", no gap in the asset series (interval " + (($g.interval // 0) | tostring) + "s)"
    else ", "
         + (if $g.method == "assetEmpty" then "the asset series is empty in the whole window, "
            else "" end)
         + "missing measurements: "
         + (if $g.missingPoints == null then "unknown count"
            else "~" + (($g.missingPoints) | tostring) + " estimated" end)
         + " in " + (($g.ranges | length) | tostring) + " range" + (if ($g.ranges | length) == 1 then " " else "s between " end)
         + ($g.ranges[0].dateFrom | tostring) + " .. " + ($g.ranges[-1].dateTo | tostring)
         + (if $g.interval != null then " (interval " + ($g.interval | tostring) + "s, " + ($g.intervalSource | tostring) + ")" else "" end)
         + (if $g.truncated then " (truncated)" else "" end)
    end;
