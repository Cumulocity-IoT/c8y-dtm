# Turns c8y_MicroserviceBilling measurements (one JSON object per input line)
# into dtmdata usage rows. dtm-data-service reports its values under the
# fragment c8y_MicroserviceBilling_<applicationId> as dtmdata_measurements_*.
# The application ID changes when the service is reinstalled, so every ID is
# read and summed into the same tenant.
#
# Arguments:
#   $names     {"<managed object id>": "<tenant id>"} for the measurement sources
#   $groupBy   records | tenant | day | month
#   $from, $to the requested range, copied into tenant rows
#   $tenants   comma-separated tenant IDs to keep, or ""

# ISO-8601 with Z or a +hh:mm offset and any fraction -> epoch milliseconds (UTC).
def ms: capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.(?<f>[0-9]+))?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")
  | ((.d + "Z") | fromdateiso8601) * 1000
    + (((.f // "0") + "000")[0:3] | tonumber)
    - (if (.z // "Z") == "Z" then 0
       else (if .z[0:1] == "-" then -1 else 1 end)
            * ((.z[1:3] | tonumber) * 3600 + (.z[-2:] | tonumber) * 60) * 1000
       end);

def utc: (. / 1000 | floor | todate);

# A metric is stored as {"value": n}; a missing one counts as 0.
def metric($f; $name): ($f[$name].value // 0);

def metrics: [
  "received", "created", "createdPersistent", "createdTransient",
  "reprocessed", "reprocessedPersistent", "reprocessedTransient"
];

def sums: . as $rows
  | reduce metrics[] as $k ({}; .[$k] = ($rows | map(.[$k]) | add // 0));

($tenants | split(",") | map(select(length > 0))) as $keep
| [inputs
   | . as $m
   | to_entries[]
   | select(.key | startswith("c8y_MicroserviceBilling_"))
   | select(.value | type == "object" and (keys | any(startswith("dtmdata_measurements_"))))
   | .value as $f
   | ($m.time | ms) as $t
   | {
       tenant: ($names[$m.source.id] // $m.source.id),
       time: $m.time,
       ms: $t,
       day: ($t | utc)[0:10],
       month: ($t | utc)[0:7],
       received: metric($f; "dtmdata_measurements_received"),
       created: metric($f; "dtmdata_measurements_created"),
       createdPersistent: metric($f; "dtmdata_measurements_created_persistent"),
       createdTransient: metric($f; "dtmdata_measurements_created_transient"),
       reprocessed: metric($f; "dtmdata_measurements_reprocessed"),
       reprocessedPersistent: metric($f; "dtmdata_measurements_reprocessed_persistent"),
       reprocessedTransient: metric($f; "dtmdata_measurements_reprocessed_transient")
     }
   | select(($keep | length) == 0 or (.tenant as $t | $keep | index($t)))
  ]
| if $groupBy == "records" then
    sort_by(.tenant, .ms)[]
    | {tenant, time} + (. as $r | reduce metrics[] as $k ({}; .[$k] = $r[$k]))
  else
    (if $groupBy == "day" then "day" elif $groupBy == "month" then "month" else null end) as $period
    | group_by([.tenant, (if $period then .[$period] else "" end)])
    | map(
        {tenant: .[0].tenant}
        + (if $period then {period: .[0][$period]} else {from: $from, to: $to} end)
        + sums
      )
    | sort_by(.tenant, (.period // ""))[]
  end
