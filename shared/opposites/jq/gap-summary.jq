# Renders the measurementGap of one record as the trailing part of a console message.
# Included as a module by verification-error-messages.jq and gap-messages.jq, which both
# report the same gap in a different context (a failing link vs an explicitly selected
# one) and must not describe it differently.
# Input: a record carrying a measurementGap object, or none.
def gapSummary:
  (.measurementGap // null) as $g
  | if $g == null then ""
    elif ($g.method == "skipped") then ", measurement gap not determined (link limit reached)"
    elif ($g.method == "probeFailed" or $g.method == "enumerationFailed") then
        ", measurement gap could not be determined (" + ($g.method | tostring) + ")"
    elif ($g.method == "noSourceData") then ", no measurements on the source series"
    elif (($g.ranges | length) == 0) then ", no missing measurements on the asset"
    else ", missing measurements: "
         + (if $g.missingPoints == null then "unknown count (boundary estimate)"
            else (($g.missingPoints // 0) | tostring) + " points" end)
         + " in " + (($g.ranges | length) | tostring) + " range" + (if ($g.ranges | length) == 1 then " " else "s between " end)
         + ($g.ranges[0].dateFrom | tostring) + " .. " + ($g.ranges[-1].dateTo | tostring)
         + (if $g.truncated then " (truncated)" else "" end)
         + (if $g.approximate == true then ", run with --measurementGapsExact for exact data" else "" end)
    end;
