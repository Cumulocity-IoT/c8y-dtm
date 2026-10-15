# Turns c8y_MicroserviceBilling measurements (one JSON object per input line)
# into billing rows for dtm-data-service.
#
# Arguments:
#   $names     {"<managed object id>": "<tenant id>"} for the measurement sources
#   $apps      {"<application id>": "<application name>"}, where known
#   $app       application ID to keep, or "" for every application reporting
#              dtmdata_measurements_* metrics
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
   | select($app == "" or .key == "c8y_MicroserviceBilling_" + $app)
   | select(.value | type == "object" and (keys | any(startswith("dtmdata_measurements_"))))
   | .value as $f
   | ($m.time | ms) as $t
   | {
       tenant: ($names[$m.source.id] // $m.source.id),
       tenantMo: $m.source.id,
       applicationId: (.key | ltrimstr("c8y_MicroserviceBilling_")),
       time: $m.time,
       ms: $t,
       day: ($t | utc)[0:10],
       month: ($t | utc)[0:7],
       id: $m.id,
       received: metric($f; "dtmdata_measurements_received"),
       created: metric($f; "dtmdata_measurements_created"),
       createdPersistent: metric($f; "dtmdata_measurements_created_persistent"),
       createdTransient: metric($f; "dtmdata_measurements_created_transient"),
       reprocessed: metric($f; "dtmdata_measurements_reprocessed"),
       reprocessedPersistent: metric($f; "dtmdata_measurements_reprocessed_persistent"),
       reprocessedTransient: metric($f; "dtmdata_measurements_reprocessed_transient")
     }
   | .application = ($apps[.applicationId] // .applicationId)
   | select(($keep | length) == 0 or (.tenant as $t | $keep | index($t)))
  ]
| if $groupBy == "records" then
    sort_by(.tenant, .ms)[]
    | {tenant, application, applicationId, time, id} + (. as $r | reduce metrics[] as $k ({}; .[$k] = $r[$k]))
  else
    # Rows are per tenant, not per application ID: a reinstalled service gets a
    # new ID, and its records still bill the same tenant.
    (if $groupBy == "day" then "day" elif $groupBy == "month" then "month" else null end) as $period
    | group_by([.tenant, (if $period then .[$period] else "" end)])
    | map(
        (.[0]) as $first
        | {
            tenant: $first.tenant,
            application: (map(.application) | unique | join(", ")),
            applicationIds: (map(.applicationId) | unique)
          }
          + (if $period then {period: $first[$period]} else {from: $from, to: $to} end)
          + sums
          + {
              reports: length,
              firstReport: (map(.ms) | min | utc),
              lastReport: (map(.ms) | max | utc)
            }
      )
    | sort_by(.tenant, (.period // ""))[]
  end
