# Timestamp and cadence helpers shared by the gap analysis.
# Module: include with `include "gap-time";` and jq -L <jq-dir>.

# Parses an ISO-8601 timestamp into epoch seconds, keeping the fractional part and
# honouring a UTC offset. strptime/mktime always work in UTC, which is what makes this
# portable. Returns null for anything that is not a timestamp.
def toEpoch:
  (capture("^(?<d>\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})(?<f>\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$") // null) as $m
  | if $m == null then null
    else (($m.d + "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)
         + (("0" + ($m.f // ".0")) | tonumber)
         - (if ($m.z // "Z") == "Z" then 0
            else ($m.z | capture("^(?<sg>[+-])(?<oh>[0-9]{2}):?(?<om>[0-9]{2})$")
                  | ((.oh | tonumber) * 3600 + (.om | tonumber) * 60) * (if .sg == "-" then -1 else 1 end))
            end)
    end;

def round1: if . == null then null else (. * 10 | round) / 10 end;

# Measurement objects or bare timestamp strings -> [{time, at}], oldest first, deduplicated.
# Series are read newest first (see read_series), so this is where the order is restored.
def toPoints:
  map(if type == "object" then .time else . end)
  | map(select(type == "string"))
  | map({ time: ., at: toEpoch })
  | map(select(.at != null))
  | sort_by(.at) | unique_by(.at);

# The time between consecutive measurements. Zeros are dropped: two measurements at the
# very same instant say nothing about the cadence, and they would drag every percentile
# below them towards zero.
def deltasOf: . as $p | [ range(1; ($p | length)) | $p[.].at - $p[. - 1].at ] | map(select(. > 0));

def pctl($p): if length == 0 then null else (sort | .[(((length - 1) * $p / 100) | floor)]) end;

# The interval of a series: the longest spacing that still counts as NORMAL, which is
# what a gap has to be measured against. That is a high percentile of the deltas, NOT the
# median - a series that arrives in bursts (two measurements two seconds apart every two
# minutes, as on t1298412) has a median of 2s and a real cadence of 120s, and judging it
# by the median reports every normal pause as a gap.
#
# One refinement pass then removes the deltas that are themselves gaps before taking the
# percentile again, so that a series which is partly gap does not raise its own baseline.
# It only converges while gaps are the minority of the deltas; beyond that the estimate
# grows too large, which loses small gaps rather than inventing them.
def intervalOf($percentile; $tolerance):
  map(select(. > 0)) as $d
  | if ($d | length) == 0 then null
    else ($d | pctl($percentile)) as $seed
      | ($d | map(select(. <= $seed * $tolerance))) as $normal
      | (if ($normal | length) == 0 then $seed else ($normal | pctl($percentile)) end)
    end;

# The full picture of one series' cadence, for --suggestIntervals and the trace.
def cadenceOf($percentile; $tolerance):
  . as $p
  | ($p | deltasOf) as $d
  | ($d | intervalOf($percentile; $tolerance)) as $interval
  | (if $interval == null then null else $interval * $tolerance end) as $threshold
  | { points: ($p | length),
      first: ($p | first | .time), last: ($p | last | .time),
      deltas: ($d | length),
      p50: ($d | pctl(50) | round1), p90: ($d | pctl(90) | round1),
      p95: ($d | pctl(95) | round1), p99: ($d | pctl(99) | round1),
      min: ($d | min | round1), max: ($d | max | round1),
      interval: ($interval | round1),
      threshold: ($threshold | round1),
      # Deltas of the sample that the suggestion would already call a gap. On the device
      # side this is the sample's own view of how clean the source is.
      aboveThreshold: (if $threshold == null then 0 else ($d | map(select(. > $threshold)) | length) end),
      # The raw shape, because no percentile shows whether "p50 2s, p95 118s" is a series
      # that arrives in pairs or one that is missing every other measurement. Reading a
      # dozen consecutive deltas answers that at a glance.
      sampleDeltas: ($d[0:12] | map(round1)),
      sampleTimes: ($p[0:6] | map(.time)) };
