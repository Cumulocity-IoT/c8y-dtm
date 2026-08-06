# Projects an exploded asset onto the minimal link record used by the verification.
# Input:  an exploded asset (see explode-linked-series.jq)
# Output: { c8y_LinkedSeries, assetId, id } where id is the SOURCE DEVICE id, which is
#         what c8y inventory children list is piped on.
{
  "c8y_LinkedSeries": .c8y_LinkedSeries,
  "assetId": .id,
  "id": .c8y_LinkedSeries.source.id
}
