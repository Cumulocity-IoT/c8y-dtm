# Explodes one asset into one record per c8y_LinkedSeries entry that has a source device.
# Input:  a single asset object (streamed, one per line) with a c8y_LinkedSeries array
# Output: the same asset repeated once per linked series, with c8y_LinkedSeries
#         replaced by that single entry. Entries without source.id are dropped.
. as $parent | 
.c8y_LinkedSeries[] as $item | 
select($item.source.id != null) | 
$parent | 
.c8y_LinkedSeries = $item
