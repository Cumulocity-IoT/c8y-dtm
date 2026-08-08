# Computes the measurement gap statistics as a single JSON object.
# Input:  gap records from gap-diff.jq or gap-diff-fast.jq, slurped (jq -s)
# Output: { measurementGaps: { ... } }, merged into the verification statistics by
#         the caller so that the invariant of verification-statistics.jq stays intact.
#
# withGaps/withoutGaps key off ranges rather than missingPoints because
# gap-diff-fast.jq (the default, boundary-only estimate) confirms a gap without ever
# learning its point count: ranges is non-empty but missingPoints is null. Point-count
# totals below still only sum what is actually known, so they stay accurate in both
# modes rather than silently treating an unknown count as zero.
def gap: .measurementGap // {};
def gmethod: gap | (.method // "unknown");
def gmissingKnown: gap | (.missingPoints != null);
def gmissing: gap | (.missingPoints // 0);
def granges: gap | (.ranges // []);
{
  measurementGaps: {
    links: length,
    probed: (map(select(gmethod != "skipped")) | length),
    skipped: (map(select(gmethod == "skipped")) | length),
    withGaps: (map(select((granges | length) > 0)) | length),
    withoutGaps: (map(select(gmethod != "skipped" and gmethod != "enumerationFailed" and gmethod != "probeFailed" and (granges | length) == 0)) | length),
    approximate: (map(select((gap | .approximate) == true)) | length),
    unknownPointCountLinks: (map(select((granges | length) > 0 and (gmissingKnown | not))) | length),
    truncated: (map(select((gap | .truncated) == true)) | length),
    failed: (map(select(gmethod == "enumerationFailed" or gmethod == "probeFailed")) | length),
    byMethod: (group_by(gmethod) | map({ key: (.[0] | gmethod), value: length }) | from_entries),
    totalMissingPoints: (map(select(gmissingKnown) | gmissing) | add // 0),
    maxMissingPointsOnOneLink: (map(select(gmissingKnown) | gmissing) | max // 0),
    distinctAssets: (map(.assetId) | unique | length),
    earliestGapStart: (map(granges | map(.dateFrom)) | add // [] | min),
    latestGapEnd: (map(granges | map(.dateTo)) | add // [] | max)
  }
}
