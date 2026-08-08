# Builds the measurement boundary probes for every planned link: the oldest and the
# newest measurement of the device series and of the asset series.
# Input:  plan records from gap-plan.jq, one per line (no slurp)
# Inputs: --arg dateFrom / --arg dateTo  the widest window to probe in
# Output: one request object per probe, ready to be piped into `c8y api --method GET`,
#         which maps the url property of a piped object onto its --url flag:
#         { url, key, side, bound }
#
# Every query parameter value is encoded TWICE, which is not a mistake. Source series
# names are OPC UA node ids such as
#   ns=2;s=SiemensS7/A3_FUELLER/IST Temperatur Fuller Produkt
# and go-c8y-cli decodes the query of a piped url twice before it rebuilds the
# request. A single encoding therefore leaves a literal ';' in the query that Go's
# query parser rejects, and go-c8y-cli drops the whole parameter without a word. The
# request would then silently ask for every series of the fragment instead of one.
# Verify with:
#   c8y api --method GET --dry --dryFormat json < request.json | jq -r .query
# and check that valueFragmentSeries is present and holds the original series name.
# The single-encoded form is what the flags of `c8y measurements list` need, see
# enumerate_series_times in commands/migration/opposites.
#
# revert=true returns the newest measurement first, revert=false the oldest, which
# needs an explicit dateFrom/dateTo because the default sort order differs between
# the classic and the time series measurement store.
def q: tostring | @uri | @uri;
select(.probe)
| . as $l
| [ { side: "device", source: $l.sourceId, fragment: $l.sourceFragment, series: $l.sourceSeries },
    { side: "asset",  source: $l.assetId,  fragment: $l.fragment,       series: $l.series } ][]
| . as $s
| ("first", "last")
| { key: $l.key,
    side: $s.side,
    bound: .,
    url: ("/measurement/measurements?source=" + ($s.source | q)
          + "&valueFragmentType=" + ($s.fragment | q)
          + "&valueFragmentSeries=" + ($s.series | q)
          + "&dateFrom=" + ($dateFrom | q)
          + "&dateTo=" + ($dateTo | q)
          + "&pageSize=1&revert=" + (if . == "last" then "true" else "false" end)) }
