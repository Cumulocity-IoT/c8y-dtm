# Finding measurement gaps caused by temporal opposites inconsistencies — options

Discussion document. It lays out the ways a gap can be found, what each one needs as
input, and what each one can and cannot see. It deliberately stops short of recommending
one; the trade-offs are the point.

**Where**: the `opposites-gap` command (split out of `opposites verify`).

**What is implemented today**: family B — the asset series is read on its own and judged
against an interval: declared with `--interval` (B1), otherwise sampled from the source
device series (B2, the default), otherwise taken from the asset series itself (B3', the
fallback). `--suggestIntervals` reports the sampling instead of acting on it. The family A
options that came before it (boundary probes, the exact two-sided diff) have been removed. Section 3 is kept because the constraints it records
about read direction and query budgets still apply to anything that reads measurements.

Facts are marked **CONFIRMED** (verified against the API, the source, or a real run on
`t1298412`) or **NEEDS CHECK** (plausible, not verified). Anything describing a change to
DTM or the data model is marked **NEW**.

## 1. The problem

A link is `asset.(fragment, series) ← device.(fragment, series)`. While that link is
absent from the device's `c8y_LinkedSeriesReverseIndex`, dtm-data-service does not copy
incoming measurements onto the asset. The consumer is a real-time notification consumer
with **no backfill** (CONFIRMED), so every measurement that arrives during the outage is
lost to the asset permanently unless it is re-submitted to
`POST /service/dtm/reprocess/measurements`.

The difficulty is that **the outage itself leaves no trace**. Once the reverse index is
repaired the link verifies clean, and nothing on the asset, the device or the index says
that it was ever broken, or for how long. DTM writes no audit records (CONFIRMED), so the
window has to be reconstructed, inferred, or recorded in advance.

Three fundamentally different things can be used to reconstruct it, and every option below
is one of them:

| Family | What it uses | What it fundamentally needs |
| --- | --- | --- |
| **A. Compare the two sides** | The device series and the asset series | Measurement data from **both** sides |
| **B. Infer from one side** | The asset series plus an expectation of how it should behave | An **expectation model** (cadence, max interval) |
| **C. Know when it broke** | Provenance: when the link was created, broken, repaired | **Temporal metadata** that must exist before the fact |

Family A is the only one that needs no new data and no assumptions, and it is the most
expensive. Family B trades data volume for an assumption. Family C is nearly free at query
time but only helps for outages that happen *after* it is introduced.

## 2. What every option needs regardless

Independently of the strategy, a gap statement is only meaningful with:

- **Link identity** — `assetId`, the asset-side `(fragment, series)`, `sourceId`, the
  source-side `(fragment, series)`. Neither side alone is unique: many assets can link the
  same source series (CONFIRMED, by design).
- **The asset-side fragment/series as actually persisted**, which is *not* necessarily the
  one declared in `c8y_LinkedSeries`. A custom smart function may persist elsewhere — on
  `t1298412` the SAP function writes `sap_category_name` / `sap_position_name#sap_characteristic_name`
  (CONFIRMED). Querying the declared values there returns nothing and makes every link look
  empty.
- **An explicit window** — `[dateFrom, dateTo]`. Nothing outside it is observed, so "no
  gap" always means "no gap in that window". `revert` requires a window anyway, and the
  default sort order differs between the classic and the time series store (CONFIRMED).
- **A retention caveat** — measurements older than the tenant's retention are already
  deleted. Any reported range is an upper bound on what can still be recovered.

And whatever localises the gap, **producing the reprocess payload always requires reading
the device measurements** in the resulting range: the payload is the original *device*
measurement, because dtm-data-service re-runs the smart functions on it and derives the
asset side from the reverse index itself (CONFIRMED). Deduplicate by measurement id — one
device measurement can carry several series and feed several assets.

## 3. Family A — compare the two sides

### A1. Boundary probes only

Ask for the oldest and newest measurement of each side (`pageSize=1`, `revert`).

- **Input**: link identity, window.
- **Cost**: 2–4 requests per link.
- **Finds**: an asset series that is entirely empty, and the current *trailing* gap
  (asset stopped at T, device continued past it).
- **Misses**: every interior gap, including one the asset later recovered from — both
  sides then report the same newest timestamp and nothing is reported at all. Never yields
  a point count.
- **Status**: was implemented as the default of `opposites verify --measurementGaps`,
  **removed** in favour of B1/B2 below.
- **Note**: the *descending* probe (`revert=true`) is cheap; the *ascending* one sorts
  forward over the whole window and has been observed to hit the server's query budget on
  `t1298412` (CONFIRMED). Classification only needs the descending one.

### A2. Exact point-by-point diff

Enumerate every timestamp of both series and take the set difference.

- **Input**: link identity, window.
- **Cost**: two full paged reads per link, 2000 measurements per page (CONFIRMED cap).
  This is the expensive option by orders of magnitude.
- **Finds**: every gap, exact missing point count, exact timestamps — directly usable to
  extract the reprocess payload.
- **Misses**: nothing within the window, but it is the option most exposed to server-side
  flakiness: on `t1298412` the ascending read has returned an empty page with exit code 0
  and nothing on stderr (CONFIRMED), which is indistinguishable from an empty series unless
  cross-checked against a boundary probe.
- **Status**: was implemented as `--measurementGapsExact`, **removed** in favour of
  B1/B2 below.

### A3. Presence per aggregation bucket

Use `GET /measurement/measurements/series?...&aggregationType=DAILY|HOURLY|MINUTELY` on
both sides and compare which buckets hold data at all.

- **Input**: link identity, window, bucket size.
- **Cost**: one request per side per link, independent of the number of measurements.
- **Finds**: the *location* of gaps at bucket resolution, including interior ones — the
  thing A1 cannot do and A2 pays dearly for.
- **Misses**: gaps shorter than a bucket, and partial buckets (a bucket with one asset
  measurement and 300 device measurements looks equally "present" on both sides). No point
  counts.
- **Status**: **not implemented**. NEEDS CHECK: that the series endpoint accepts the same
  fragment/series filtering shape used elsewhere, and how it behaves on the time series
  store; it returns min/max per bucket rather than counts.
- **Note**: this is the natural coarse pass in front of A2 — see §6.

### A4. Count comparison

Compare the number of measurements on each side over the window, or per bucket.

- **Input**: link identity, window, plus a counting parameter.
- **Cost**: one request per side per link *if* a cheap count exists.
- **Finds**: whether a gap exists and how large, without locating it.
- **Misses**: where the gap is. Equal counts do not strictly prove equal sets, though
  in practice a mismatch is a reliable positive.
- **Status**: **not implemented**. NEEDS CHECK: which counting parameter this tenant's
  store supports (`withTotalPages` / `withTotalElements`) and what it costs — total counts
  are frequently expensive on time series stores, which could remove the entire advantage.

## 4. Family B — infer from the asset side alone

The idea raised in discussion: **ask for the maximum acceptable time between two
measurements of a series**, then scan the asset series for intervals longer than that.

The attraction is that it reads only the **asset** side, which is the small side (a few
series per asset versus 200+ on a device, CONFIRMED on `t1298412`), and it finds interior
gaps that A1 cannot see, at a fraction of A2's cost. The cost is an assumption per series.

### B1. Operator-declared max interval — implemented

A table of `series → max acceptable interval`, supplied as input.

- **Input**: link identity, window, **and a per-series threshold**.
- **Cost**: one paged read of the asset series per link.
- **Finds**: every interval on the asset longer than the threshold.
- **Misses**: a gap shorter than the threshold. Produces **false positives** for any
  series that is genuinely irregular or event-driven — a machine that was switched off
  looks identical to a broken link.
- **Status**: implemented as `--interval` (`gap-intervals.jq`), as one value for the
  whole run rather than a table: `--interval 2m` judges every series against 2 minutes.
  The threshold is `interval * C8Y_DTM_GAPS_INTERVAL_TOLERANCE` (default 1.5), so the
  jitter of a regular series is not reported.
- **Open question**: who owns that table, and at what granularity — per series, per
  `sap_characteristic_name`, per device type, one global default? Only the global default
  exists today.

### B3'. Threshold derived from the asset series itself — implemented, the fallback

What `opposites-gap` falls back to when neither `--interval` nor a device sample gives
an interval: the interval is the **p95 of the asset series' own consecutive deltas** inside the window, and any hole
longer than `median * tolerance` is a gap. It is B3 without a separate reference period —
the series calibrates itself from the same window it is judged in, which works because a
gap is by definition the minority of the deltas and the median ignores it.

- **Input**: link identity, window; no human input.
- **Cost**: one paged read of the asset series per link.
- **Finds**: interior gaps, trailing gaps, leading gaps, and an entirely empty series.
- **Misses**: a series whose gaps are the majority of its deltas raises its own baseline,
  and a genuinely irregular series produces false positives. Fewer than two measurements
  give no estimate at all, reported as `intervalUnknown` rather than guessed.
- **Estimates rather than counts** the missing points, as gap length / interval.

### B2. Threshold derived from the device series — implemented, the default

Derive the expected cadence from the source series, then apply B1's scan to the asset.

- **Input**: link identity, window; no human input.
- **Cost**: the asset read, plus **one unpaged request** per distinct source series (the
  newest 200 measurements). Sampling a single series of a device costs the same as
  sampling one of an asset — the "device is the expensive side" caveat is about reading
  all 200+ of its series, not one.
- **Finds**: same as B1, self-calibrating per series, and the baseline is taken from the
  side that does *not* have the holes being looked for, which is what makes it better than
  B3'.
- **Misses**: same failure mode when the device cadence itself is irregular; a device that
  was off during the window produces a misleading baseline. It also assumes the smart
  function copies 1:1 in cadence — CONFIRMED on t1298412, where the asset-side p95 matched
  the device-side p95 exactly on all four analysed links.
- **Status**: implemented, and used whenever `--interval` is not declared.
  `--suggestIntervals` exposes the same sampling as a report instead of a decision.

### B3. Threshold derived from the asset's own healthy periods

Use the asset series' own interval distribution outside the suspected window (e.g. the
99th percentile interval) as the threshold.

- **Input**: link identity, window, plus a reference period assumed healthy.
- **Cost**: one asset read covering both periods.
- **Finds**: deviations from that series' own normal behaviour, which is the most
  faithful baseline available without external knowledge.
- **Misses**: a link that was *never* healthy has no baseline; a seasonal change in
  cadence reads as a gap.

### B4. Cross-series comparison on the same asset

A gap in one series of an asset while its sibling series kept flowing is strong evidence
of a link-level problem rather than a device outage — and the converse (all series stop
together) is strong evidence of a device outage rather than a broken link.

- **Input**: link identity, window, and the asset's other series.
- **Cost**: one asset read, all series at once.
- **Finds**: a discriminator that B1–B3 lack, and it costs almost nothing extra.
- **Misses**: nothing usable when the asset has only one linked series.
- **Note**: useful as a *classifier* on top of any option in this family rather than as a
  detector on its own.

## 5. Family C — record when the link was broken

These make the window a lookup instead of a measurement problem. All are forward-looking:
they cannot explain an outage that predates their introduction.

### C1. Temporal fields on the reverse-index entries — NEW

Give each `c8y_LinkedAssets` entry a `createdAt` (and, if entries are ever removed,
`removedAt`).

- **Input afterwards**: the device's reverse index alone.
- **Gives**: the exact moment copying started for each individual link. Combined with the
  asset-side "should have been copying since" (C2) it yields the gap window directly, with
  no measurement read at all for *detection*.
- **Requires**: a DTM change in `MeasurementSourceLinkService`, and agreement on what the
  bulk migration path (`opposites create`, which writes the array wholesale) stamps.
- **Open question**: entry-level timestamps survive a full-array overwrite only if the
  writer preserves them — the migration tool rewrites the whole array today (CONFIRMED).

### C2. Temporal fields on `c8y_LinkedSeries` — NEW

The asset side declares when the link was *intended* to be active (`linkedSince`, or an
explicit `activeFrom`).

- **Input afterwards**: the asset alone.
- **Gives**: the start of the window that C1 closes. Without it, C1 tells you when copying
  began but not when it *should* have begun.
- **Requires**: a model change plus whoever creates assets (the SAP integration here)
  populating it.

### C3. Audit trail on reverse-index writes — NEW

DTM emits an audit record or event per create/update/delete/reconcile of the index.

- **Input afterwards**: the audit/event log.
- **Gives**: the full history, including *breakages* — the only option that can answer
  "when did it stop working" rather than just "when was it fixed". Also identifies the
  writer, which is what the open question about who corrupts the index actually needs.
- **Requires**: the largest DTM change, plus retention on the audit data.

### C4. Migration tooling stamps its own runs

`opposites create` records when it repaired what — a fragment on the child addition, a
tenant option, or a retained run manifest.

- **Input afterwards**: that stamp.
- **Gives**: the gap **end** for everything a bulk repair touched, at device granularity,
  for free.
- **Requires**: no platform change — this repo only.
- **Note**: the child addition's own `creationTime` / `lastUpdated` already approximates
  this today, at device granularity, and is destroyed by any subsequent write.

### C5. Scheduled verification with retained traces

Run `opposites verify` on a schedule and keep the traces. A link that passes at T1 and
fails at T2 bounds the breakage; the reverse bounds the repair.

- **Input afterwards**: two or more timestamped traces.
- **Gives**: both ends of the window, bounded by the run interval — an hourly schedule
  bounds every gap to an hour, without touching the data model.
- **Requires**: no change to anything; only somewhere to keep the traces.
- **Note**: this is the cheapest member of family C and the only one that also covers
  breakages, at the cost of resolution.

### C6. Historical traces as a link selector — implemented

What exists today: a previous run's `verify-errors.json` (or a pasted log) names the links
that were broken, and the gap analysis is pointed at them after the repair
(`opposites-gap --for`, `--forError`).

- **Input**: one prior report.
- **Gives**: precisely *which* links to look at, which is the expensive part to guess.
  It gives no window on its own — the report's timestamp only bounds the repair from one
  side, so it still has to be combined with a family A or B option.

## 6. How the options compose

They are not exclusive, and the interesting designs are pipelines that spend the expensive
option only where a cheap one already pointed:

- **Select → measure**: C6 or C5 narrows to a handful of links; A2 answers exactly.
  (C6 is still how links are selected; the measuring half is now B1/B3'.)
- **Localise → confirm**: A3 or B finds candidate windows cheaply per link; A2 runs only
  inside those windows instead of the whole period. Turns the exact diff from
  "proportional to the window" into "proportional to the gap".
- **Detect → classify**: any detector, then B4 to separate "link was broken" from "device
  was off" before anyone is asked to act on it.
- **Record → look up**: C1+C2 (or C5) make detection unnecessary for future outages; the
  device read is then only needed to produce the reprocess payload.

## 7. Constraints that shape any choice

- **Retention** bounds recovery, not just detection. A perfectly located gap outside
  retention is not actionable.
- **The asset side may be transformed** by a smart function; every option in families A
  and B needs the persisted fragment/series, not the declared one.
- **Read direction matters on a time series store**: descending reads are cheap,
  ascending reads over a wide window hit the server's query budget and have been observed
  to fail silently (CONFIRMED on `t1298412`). Any option built on enumeration inherits
  this.
- **A device with no managed object** (`CumulocityError`) can never be analysed or
  repaired — those links need a data fix, not a gap analysis.
- **Multiple assets share source series** (CONFIRMED, by design), so per-link results must
  be deduplicated before reprocessing or the same measurement is submitted repeatedly.

## 8. Open questions for the discussion

1. Is a **bucket-resolution** answer (A3) enough to act on, or is an exact point list
   always required? This decides whether the expensive enumeration is needed at all.
2. For family B, **where would the expected interval come from** — declared per series by
   the data owner (B1), derived from the device (B2), or derived from history (B3)? And is
   a false positive on an irregular series acceptable?
3. Is **C5 (scheduled verify + retained traces)** sufficient, given it needs no model
   change? What run interval would bound gaps acceptably?
4. If temporal fields are added (C1/C2), **who writes them** — DTM only, or does the bulk
   migration path have to preserve them too?
5. Does anything already record when copying started or stopped that we have not looked
   at — dtm-data-service logs or metrics, the offload/lake target, or the SAP side?
6. Should detection aim to be **exhaustive** (every link, scheduled) or **on demand**
   (only links a report already flagged)? The two lead to very different cost profiles.
