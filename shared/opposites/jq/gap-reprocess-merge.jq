# Merges the projections of the same measurement and emits the reprocess payloads.
# Input:  the { k, g, m } records of gap-reprocess-measurement.jq, one per line, SORTED
#         (jq -n, reads with inputs)
# Output: text lines of "<group>\t<measurement-json>" (use jq -r), where group is the
#         asset, the source device or "" - see gap-reprocess-measurement.jq
#
# The same device measurement can be reached through more than one gap range - several
# assets link the same source series, and one measurement can be missing several series.
# Sending it twice would run every smart function on it twice, so the records of one
# merge key are folded into a single payload with `*`, which unions the fragments.
#
# Sorting is what makes this streaming: the caller sorts the file lexicographically and k
# is the first field of every line, so the records of one key are contiguous and only one
# group is ever held in memory. A whole run's measurements are never slurped.
foreach (inputs, null) as $r
  ({ k: null, g: null, m: null, out: null };
   if $r == null then
     { k: null, g: null, m: null, out: (if .k == null then null else { g: .g, m: .m } end) }
   elif .k == null then { k: $r.k, g: $r.g, m: $r.m, out: null }
   elif $r.k == .k then { k: .k, g: .g, m: (.m * $r.m), out: null }
   else { k: $r.k, g: $r.g, m: $r.m, out: { g: .g, m: .m } }
   end;
   .out | select(. != null) | (.g + "\t" + (.m | tojson)))
