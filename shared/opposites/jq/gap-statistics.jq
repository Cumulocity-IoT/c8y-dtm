# Computes the measurement gap statistics as a single JSON object.
# Input:  gap records from gap-intervals.jq, slurped (jq -s)
# Inputs: --arg dateFrom / --arg dateTo  the window every measurement query was bound to
# Output: { measurementGaps: { ... } }, merged into the verification statistics by
#         the caller so that the invariant of verification-statistics.jq stays intact.
#
# window is reported because every timestamp below is relative to it: nothing outside
# [dateFrom, dateTo] was looked at, so an empty gap is only a statement about that window.
#
# The observed intervals are reported as a range because the whole method rests on the
# cadence of a series being regular. A minimum and a maximum that are far apart across
# the links say that it is not, and that the point counts below are guesses.
def gap: .measurementGap // {};
def gmethod: gap | (.method // "unknown");
def granges: gap | (.ranges // []);
def gmissing: gap | .missingPoints;
{
  measurementGaps: {
    window: { dateFrom: $dateFrom, dateTo: $dateTo },
    links: length,
    failingLinks: (map(select((.origin // "failing") == "failing")) | length),
    selectedLinks: (map(select(.origin == "selected")) | length),
    probed: (map(select(gmethod != "skipped")) | length),
    skipped: (map(select(gmethod == "skipped")) | length),
    withGaps: (map(select((granges | length) > 0)) | length),
    withoutGaps: (map(select(gmethod == "interval" and (granges | length) == 0)) | length),
    assetEmpty: (map(select(gmethod == "assetEmpty")) | length),
    truncated: (map(select((gap | .truncated) == true)) | length),
    failed: (map(select(gmethod == "readFailed" or gmethod == "intervalUnknown")) | length),
    byMethod: (group_by(gmethod) | map({ key: (.[0] | gmethod), value: length }) | from_entries),
    intervalSeconds: {
      min: (map(gap | .interval) | map(select(. != null)) | min),
      max: (map(gap | .interval) | map(select(. != null)) | max)
    },
    assetPoints: (map(gap | .asset.points // 0) | add // 0),
    estimatedMissingPoints: (map(select(gmissing != null) | gmissing) | add // 0),
    maxMissingPointsOnOneLink: (map(select(gmissing != null) | gmissing) | max // 0),
    unknownPointCountLinks: (map(select((granges | length) > 0 and gmissing == null)) | length),
    distinctAssets: (map(.assetId) | unique | length),
    earliestGapStart: (map(granges | map(.dateFrom)) | add // [] | min),
    latestGapEnd: (map(granges | map(.dateTo)) | add // [] | max)
  }
}
