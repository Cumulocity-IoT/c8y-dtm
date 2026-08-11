# Projects an exploded asset onto the minimal link record used by the verification.
# Input:  an exploded asset (see explode-linked-series.jq)
# Inputs: --arg fragmentTemplate / --arg seriesTemplate  placeholder templates for the
#           fragment and the series a measurement is actually persisted under on the
#           asset, resolved against the c8y_LinkedSeries entry. "{fragment}" / "{series}"
#           reproduce the declared values, which is the default.
#         --argjson sanitizeTemplate  true to replace [\s.,*\[\]()@$] with "_" in every
#           substituted value, mirroring the sanitizeName() of the SAP smart function.
# Output: { c8y_LinkedSeries, assetId, id, measurementFragment, measurementSeries }
#         where id is the SOURCE DEVICE id, which is what c8y inventory children list is
#         piped on.
#
# measurementFragment/measurementSeries are ONLY used to query measurements on the asset
# (opposites-gap). The reference verification keeps matching on the declared
# fragment/series, because that is what the reverse index stores; it passes the defaults
# so that measurementFragment/measurementSeries simply reproduce the declared values. They are null when a
# placeholder of the template resolves to nothing, so that the caller can report the
# incomplete templates instead of querying a half-substituted series name.
def placeholders($tpl): [ $tpl | scan("\\{([^{}]+)\\}") | .[0] ];
def sanitize: if $sanitizeTemplate then gsub("[\\s.,*\\[\\]()@$]"; "_") else . end;
def resolve($tpl; $entry):
  if ([ placeholders($tpl)[] | . as $p | select(($entry | getpath($p | split("."))) == null) ] | length) > 0 then
      null
  else
      $tpl | gsub("\\{(?<p>[^{}]+)\\}"; (.p | split(".")) as $path | ($entry | getpath($path) | tostring | sanitize))
  end;
. as $asset
| .c8y_LinkedSeries as $entry
| {
  "c8y_LinkedSeries": $entry,
  "assetId": $asset.id,
  "id": $entry.source.id,
  "measurementFragment": resolve($fragmentTemplate; $entry),
  "measurementSeries": resolve($seriesTemplate; $entry)
}
