# Decides, from the supported-series index of the asset and of the source device, which
# boundary probes of a planned link can be skipped because the series demonstrably never
# held a measurement.
# Inputs: --slurpfile plan       plan records from gap-plan.jq
#         --slurpfile supported  { id, supportedSeries } records, supportedSeries is the
#                                c8y_SupportedSeries array or null when the lookup failed
# Output: the plan records plus
#         { supportedSeriesShortcut, probeDevice, probeAsset }
#
# c8y_SupportedSeries holds one string per series, joined as fragment + "." + series
# ("A.IST#PASTA_BIO" is fragment "A", series "IST#PASTA_BIO"). That join is ambiguous to
# take apart again, because a fragment may itself contain a dot, so the lookup composes
# the same string and tests for membership instead of ever splitting one.
#
# The index is only ever used as a NEGATIVE, for two reasons:
# - it covers all of time and ignores --dateFrom/--dateTo, so a present series says
#   nothing about the window being looked at and still has to be probed,
# - an absent series means the managed object never received a measurement for it, which
#   is exactly what the probe would have found out, four requests later.
# A device without the source series has nothing that could be missing (noSourceData) and
# needs no probe at all. An asset without its series is missing everything the device has
# (assetEmpty), but the device bounds are still needed to report the range.
( $supported
  | map(select(.id != null and (.supportedSeries | type) == "array")
        | { key: (.id | tostring),
            value: (.supportedSeries | map({ key: (. | tostring), value: true }) | from_entries) })
  | from_entries ) as $byId
| $plan[]
| . as $l
| ($byId[$l.sourceId]) as $deviceSeries
| ($byId[$l.assetId]) as $assetSeries
| (if $deviceSeries != null and $deviceSeries[$l.sourceFragment + "." + $l.sourceSeries] == null then "noSourceData"
   elif $assetSeries != null and $assetSeries[$l.assetFragment + "." + $l.assetSeries] == null then "assetEmpty"
   else null
   end) as $shortcut
| $l + { supportedSeriesShortcut: (if $l.probe then $shortcut else null end),
         probeDevice: ($l.probe and $shortcut != "noSourceData"),
         probeAsset: ($l.probe and $shortcut == null) }
