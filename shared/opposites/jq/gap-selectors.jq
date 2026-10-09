# Maps one JSON value of a --gapsFor source onto link selectors.
# Included as a module by gap-selection.jq (a JSON object on one line of a text source)
# and gap-selection-json.jq (a source that is JSON as a whole), so that a previous run's
# output selects the same links whether it is compact, pretty printed or wrapped in an
# array.
#
# Output selectors (see gap-selection-plan.jq for how they are matched):
#   { assetId }                             every link of that asset
#   { assetId, fragment, series, sourceId }  exactly that link
#   { sourceId }                            every link pointing at that source device
# each carrying the errorType it came from when the source names one, so that
# --gapsForError can drop the errors that cannot be acted on. A selector without a
# discoverable error type (a bare asset id, a hand written link) is never filtered.
def withError($type): if $type == null then . else . + { errorType: ($type | tostring) } end;

# Keeps the selectors whose error type was asked for. include empty means every type,
# exclude drops types on top of that (CumulocityError by default: its device is gone, so
# there is nothing to repair and nothing to reprocess into).
def selectedError($include; $exclude):
  select(.errorType == null
         or ((($include | length) == 0 or (.errorType | IN($include[])))
             and ((.errorType | IN($exclude[])) | not)))
  | del(.errorType);

def fromValue:
  . as $v
  | if type == "number" then { assetId: (. | tostring) }
  elif type == "string" then (select(test("^[0-9]+$")) | { assetId: . })
  elif type != "object" then empty

  # A verdict of verify-match-links.jq, i.e. a line of verify-errors.json /
  # verify-result.json / the --outputFile output. Its own id is the source device, which
  # together with the asset triple identifies the link exactly.
  elif (.missingLinks | type) == "array" then
      .missingLinks[]
      | ({ assetId: (.assetId | tostring), fragment: .fragment, series: .series }
         + (if $v.id != null then { sourceId: ($v.id | tostring) } else {} end))
      | withError($v.error)

  # A link object, e.g. one entry of a missingLinks array pulled out by hand.
  elif .assetId != null then
      ({ assetId: (.assetId | tostring) }
       + (if .fragment != null and .series != null then { fragment: .fragment, series: .series } else {} end)
       + ((.sourceId // .id) as $source
          | if $source != null then { sourceId: ($source | tostring) } else {} end))
      | withError($v.error)

  # A verdict that passed selects nothing. It carries no asset triple, so taking its
  # device would pull in every link of every healthy device of a whole verify-result.json
  # -- thousands of links -- when what was asked for is the ones that were reported
  # broken.
  elif .verification != null then empty

  # A device level error (CumulocityError, NoChildAdditionsError, ...) carries no asset
  # triple either, so everything linked to that device is selected.
  elif .id != null then { sourceId: (.id | tostring) } | withError($v.error)
  else empty
  end;
