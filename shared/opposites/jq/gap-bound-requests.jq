# Builds the measurement boundary probes for every planned link: the oldest and the
# newest measurement of the device series and of the asset series.
# Input:  plan records from gap-plan.jq, one per line (no slurp)
# Inputs: --arg dateFrom / --arg dateTo  the widest window to probe in
#         --argjson probeFirst  false to ask only for the newest measurement of a series
# Output: one request object per probe, ready to be piped into `c8y api --method GET`,
#         which maps the url property of a piped object onto its --url flag:
#         { url, key, side, bound }
#
# Every query parameter value is encoded TWICE, which is not a mistake. go-c8y-cli
# decodes the query of a piped url once before it rebuilds the request, so the value has
# to survive one decoding still encoded. Series names make this load bearing:
#   ns=2;s=SiemensS7/A3_FUELLER/IST Temperatur   -> a single encoding leaves a literal
#     ';' that go-c8y-cli drops the whole parameter over, without a word, and the request
#     then asks for every series of the fragment instead of one
#   SOLL#PASTA_BIO                               -> a single encoding leaves a literal
#     '#' that truncates the url at that point, so the series is cut short AND every
#     parameter after it (pageSize, revert, valueFragmentType) is silently lost
# Two encodings put a correctly encoded %3B / %23 on the wire in both cases.
#
# Verify with --dryFormat curl, NOT with --dryFormat json:
#   c8y api --method GET --dry --dryFormat curl < request.json
# The json format renders .query already decoded, so it shows a bare '#' or ';' for a
# request that is perfectly fine on the wire, and looks identical for the encodings that
# are broken. Only the curl output is the url that is actually sent.
#
# The single-encoded form is what the flags of `c8y measurements list` need, see
# read_series in commands/migration/opposites: that path decodes once less.
#
# source/fragment/series are carried unencoded next to the url so that a traced request
# can be read without decoding it by hand. c8y api only consumes the url property.
#
# revert=true returns the newest measurement first, revert=false the oldest, which
# needs an explicit dateFrom/dateTo because the default sort order differs between
# the classic and the time series measurement store.
#
# probeDevice/probeAsset come from gap-supported-series.jq: a side whose series is known
# to be absent from the supported-series index of its managed object is not probed at
# all, gap-bounds.jq classifies it from the shortcut instead. Both are tested against
# false rather than for truth, so that a plan that never went through that pre-pass
# (--noSupportedSeries) probes both sides as before.
#
# probeFirst is false in the exact mode, where the oldest measurement is not asked for at
# all: the enumeration that follows reports it more precisely anyway, and the ascending
# query is the expensive one -- it sorts forward over the whole window, which on a time
# series store regularly runs into the server side query timeout, while the descending
# one answers from the newest bucket. Only the newest bound is needed to classify a link
# (an empty series has no newest measurement either).
def q: tostring | @uri | @uri;
select(.probe)
| . as $l
| [ (if $l.probeDevice != false then { side: "device", source: $l.sourceId, fragment: $l.sourceFragment, series: $l.sourceSeries } else empty end),
    (if $l.probeAsset  != false then { side: "asset",  source: $l.assetId,  fragment: $l.assetFragment,  series: $l.assetSeries  } else empty end) ][]
| . as $s
| (if $probeFirst then ("first", "last") else "last" end)
| { key: $l.key,
    side: $s.side,
    bound: .,
    source: $s.source,
    fragment: $s.fragment,
    series: $s.series,
    url: ("/measurement/measurements?source=" + ($s.source | q)
          + "&valueFragmentType=" + ($s.fragment | q)
          + "&valueFragmentSeries=" + ($s.series | q)
          + "&dateFrom=" + ($dateFrom | q)
          + "&dateTo=" + ($dateTo | q)
          + "&pageSize=1&revert=" + (if . == "last" then "true" else "false" end)) }
