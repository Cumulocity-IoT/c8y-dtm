# Opposites / Linked-Series Reverse Index — Agent Knowledge Base

General reference for AI agents working on "opposites" (linked-series reverse index)
tooling, or investigating issues with linked series / measurement copying. Written as
reference, not narrative — skip to the section you need. Facts are marked CONFIRMED
(verified against source code or live API responses) vs OPEN/VARIES (depends on
environment, needs checking per case).

## 1. Domain concept

A Cumulocity **asset** can declare a `c8y_LinkedSeries` fragment: an array of entries,
each saying "my series `(fragment, series)` mirrors a physical measurement coming from
device `source.id`'s series `(source.fragment, source.series)`". This is a **forward
link**, asset → device, stored on the asset.

The **"opposite"** is the reverse direction: given a device and one of its raw series,
which asset(s) consider it their source. This reverse mapping is stored as a
`c8y_LinkedSeriesReverseIndex` **child addition** on the **device**, with a
`c8y_LinkedAssets` array — one entry per (asset, source-series) link pointing back at
that device.

Three independent systems are involved:
- **DTM microservice** (`digital-twin-microservice`, deployed as app `dtm`) — owns the
  asset API and is the sole writer of `c8y_LinkedSeriesReverseIndex`.
- **dtm-data-service** — on every measurement ingested, consults the reverse index and,
  via a **smart function** (see §4 — this is the part most often missed), decides what
  measurement(s) actually get persisted for the linked asset(s).
- **This repo's `commands/migration/opposites`** — a migration-time tool that reads or
  bulk-writes the reverse index directly via raw Cumulocity inventory calls, bypassing
  DTM entirely. Used for initial migration and for verification/reporting, not an
  ongoing runtime component.

## 2. System architecture & ownership (CONFIRMED)

| System | Repo | Role | Writes reverse index? |
| --- | --- | --- | --- |
| DTM microservice | `/Users/twi/Projects/cumulocity-solution-enablement/microservices/java/digital-twin-microservice` | Owns the asset API, maintains the reverse index on asset create/update/delete | Yes — `MeasurementSourceLinkService` |
| dtm-data-service | `/Users/twi/Projects/dtm-data-service` | Consumes measurement-ingest notifications, matches against the reverse index, invokes a smart function to produce the persisted measurement | No — read-only, with a 60s cache |
| c8y-dtm (this repo) | `/Users/twi/Projects/c8y-dtm` | go-c8y-cli extension; `opposites` migration command creates/verifies/clears the reverse index in bulk | Yes — raw `c8y` CLI inventory writes, bypassing DTM |

No other writer of `c8y_LinkedSeriesReverseIndex`/`c8y_LinkedAssets` is known to exist —
confirmed by an exhaustive grep across all three repos. If a future issue looks like
something is corrupting the reverse index outside these two writers, that grep is cheap
to redo and worth repeating before assuming a new mechanism.

## 3. Data model (CONFIRMED)

Asset side — `c8y_LinkedSeries` array element (`common/.../fragments/LinkedSeries.java`):
```json
{
  "fragment": "c8y_Temperature", "series": "T", "label": "optional",
  "source": { "id": "9688123", "fragment": "c8y_Temperature", "series": "T", "type": "c8y_TemperatureMeasurement" }
}
```
- `fragment`/`series` on `LinkedSeries` itself: `@NotBlank`, required.
- `source.id`: must reference an existing managed object with `c8y_IsDevice` (checked by
  `AssetService.validateSourceIdsExist`, else `422 LinkedDeviceDoesNotExistException`).
  No other constraint on the source object — no type, no parent required.
- `source.type`: only enforced in practice, not by bean validation — see §6 traps.
- Arbitrary extra keys (e.g. `sap_category_name`, `sap_position_name`,
  `sap_characteristic_name`, `sap_managed_object_id`, ...) are commonly carried on each
  `LinkedSeries` entry by SAP-integrated tenants. **These extra fields can matter a lot
  more than they look** — see §4, they may be exactly what a custom smart function uses
  to decide the persisted measurement's real fragment/series.

Device side — `c8y_LinkedSeriesReverseIndex` child addition, `c8y_LinkedAssets` array
element (`common/.../fragments/LinkedAsset.java`):
```json
{
  "fragment": "bnp-avt", "series": "ns=3;s=A_Fasi_e_varie/Mbar_MaxTestaVuoto",
  "asset": { "id": "6174505", "fragment": "A~c257df...", "series": "5864", "label": "..." }
}
```
- `fragment`/`series` here are the **source** (device-side) triple; `asset.id` is the
  target asset.
- **Identity/equality key: `(fragment, series, asset.id)`.** This is a `Set<LinkedAsset>`,
  not a list — **multiple assets sharing one source triple is explicitly supported by
  design**, their entries simply differ by `asset.id`. `UniqueLinkedSeriesValidator` only
  rejects duplicates *within one asset's own* `c8y_LinkedSeries` list, never across
  assets. Do not assume multiple assets sharing a source series is a data-quality
  problem — it's a normal, valid configuration; verify with whoever owns the source data
  before treating it as a mapping mistake.

### Percent-encoding gotcha (CONFIRMED against `--dryFormat curl`)

Series names carry characters that are structural in a URL: OPC UA source series contain
`;` and `/` (`ns=3;s=A_Fasi_e_varie/Mbar_MaxTestaVuoto`), and SAP asset series contain `#`
(`SOLL#PASTA_BIO`). Both break differently and both break silently:
- a bare `;` makes go-c8y-cli **drop the whole parameter**, so the call returns every
  series of the fragment instead of one;
- a bare `#` **truncates the URL** at that point, so the series is cut short *and* every
  parameter after it (`pageSize`, `revert`, `valueFragmentType`) is lost.

| call | encoding | wire result for `SOLL#PASTA_BIO` |
| --- | --- | --- |
| `c8y measurements list --valueFragmentSeries` | **single** `@uri` | `...=SOLL%23PASTA_BIO` |
| `c8y api --method GET` with a piped URL | **double** `@uri` | `...=SOLL%23PASTA_BIO` |

The piped URL needs one encoding more because `c8y api` decodes it once before rebuilding
the request. A traced request therefore *looks* over-encoded (`SOLL%2523PASTA_BIO`) while
being exactly right — `gap-bound-requests.jq` carries the raw `source`/`fragment`/`series`
alongside the URL so this can be checked without decoding by hand.

**Verify with `--dry --dryFormat curl`, never with `--dryFormat json`.** The json format
renders `.query` *already decoded*, so a correct request shows a bare `#`/`;` and looks
identical to the broken encodings — it cannot distinguish them. Only the curl output is
the URL that is actually sent.

## 4. Smart functions in dtm-data-service (CONFIRMED — read this before any measurement-gap analysis)

dtm-data-service does not blindly copy an incoming device measurement onto the linked
asset verbatim. The actual flow:

1. A measurement is ingested for some device (Pulsar/notification-2.0 `CREATE` event).
2. dtm-data-service matches the measurement's `(fragment, series)` pairs against the
   device's `c8y_LinkedSeriesReverseIndex` entries (`notification-processor.service.ts`,
   `extractDeviceLinks`). Matching is `(fragment, series)` string equality, no "exactly
   one match" restriction — every matching link contributes.
3. For each matched link, a **smart function** is invoked with the incoming measurement
   and the linked-asset context, and the smart function decides what the actual
   *persisted* measurement looks like — its fragment, series, value, and any other
   shape it wants to produce.

**The bundled default smart function** (`src/worker/processor/smart-functions/onmessage.fn.ts`
in dtm-data-service, registered via `initializeBundledFunction()`) groups matches by
target `asset.id` and emits one derived measurement per asset, using the asset-side
`LinkedSeries` fragment/series as-is.

**Smart functions are pluggable and can be entirely custom per tenant/environment.**
A tenant may run its own smart function that transforms the measurement completely
differently — for example, deriving the persisted fragment/series from other metadata
carried on the `LinkedSeries` entry (the `sap_*` fields from §3) instead of from the
entry's own declared `fragment`/`series`. **A known real example**: a custom smart
function repo at `/Users/twi/Projects/sap-dtm-smartfunctions` persists measurements
under `fragment = sap_category_name`, `series` derived from
`sap_position_name` + `sap_characteristic_name` — **not** the asset's own
`c8y_LinkedSeries.fragment`/`.series` at all.

### Why this matters — do not skip this when investigating measurement gaps

`opposites verify --measurementGaps[Exact]` (and any manual `c8y measurements list`
check) queries measurements using the **asset's own declared** `fragment`/`series` from
`c8y_LinkedSeries`. **This is only correct if the active smart function actually persists
measurements under those values.** If a custom smart function transforms the fragment/
series (as in the example above), querying by the asset's declared values will *always*
return zero results — regardless of whether the link is working correctly. This looks
identical to "no measurements were ever copied," but has nothing to do with a broken
link, a broken copy mechanism, or a reverse-index bug.

**Before concluding a link isn't copying measurements, or a measurement gap is real:**
1. Find out which smart function is configured for the tenant/environment in question —
   the bundled default, or a custom one (check for a per-tenant/per-environment
   smart-functions repo or configuration; `sap-dtm-smartfunctions` is one known example,
   there may be others per customer).
2. Read that smart function's logic to determine the actual fragment/series (or other
   transformation) it persists measurements under.
3. Only then query/verify measurements using the correct, actual fragment/series — not
   the asset's declared `c8y_LinkedSeries` values, unless the smart function confirms
   those are used unchanged.

**Telling `opposites verify` about it** — `--assetFragmentTemplate` / `--assetSeriesTemplate`
take a template resolved against the `c8y_LinkedSeries` entry (`{prop}`, `{nested.prop}`)
and are what the asset side is then queried with. For the SAP smart function above:

```
--assetFragmentTemplate '{sap_category_name}' \
--assetSeriesTemplate   '{sap_position_name}#{sap_characteristic_name}' \
--sanitizeTemplate
```

`--sanitizeTemplate` replaces `[\s.,*\[\]()@$]` with `_` in every substituted value,
mirroring `sanitizeName()` — needed only when those characters occur in the SAP names.
The defaults, `{fragment}` / `{series}`, reproduce the declared values. A cheap way to
confirm the resolved pair is real: `c8y devices getSupportedSeries --device <assetId>`
must list it as `fragment.series` (e.g. `A.IST#PASTA_BIO`). Nothing else changes — the
reference verification still matches on the declared fragment/series, which is what the
reverse index stores.

This applies to any measurement-copy investigation, not just this repo's
`--measurementGaps` feature — any manual check of "did this link copy data" needs the
same care.

## 5. This repo's tooling (`c8y-dtm`)

### `commands/migration/opposites`

Modes: `create` / `clear` / `verify` / `get`.
- `create`: builds one `c8y_LinkedSeriesReverseIndex` child addition per source device
  via `c8y devices children create --childType addition --template ...` — a **raw,
  full-array overwrite**, not additive, not going through DTM. Refuses to run if any
  `c8y_LinkedSeriesReverseIndex` already exists tenant-wide (must `clear` first).
  `shared/opposites/jq/build-child-additions.jq` groups all links by source device and
  writes the complete `c8y_LinkedAssets` array in one shot — naturally preserves
  multiple assets sharing one source, since it includes every link found with no dedup.
- `clear`: deletes all `c8y_LinkedSeriesReverseIndex` objects tenant-wide.
- `verify`: reads the reverse index and cross-checks against every asset's own
  `c8y_LinkedSeries`, reporting `MissingLinkedSeriesInChildAdditionError` etc. Flags:
  `--stats`, `--traceDir DIR` (writes every intermediate JSON — always use this when
  debugging), `--measurementGaps` / `--measurementGapsExact` (see below and §4),
  `--id` (single asset).
- `get`: read-only dump of current opposite references.

Key jq programs, `shared/opposites/jq/`:
`verification-statistics.jq`, `render-statistics.jq`, `verify-match-links.jq`,
`verification-error-messages.jq`, `link-records.jq`, `explode-linked-series.jq`,
`build-child-additions.jq`, `gap-plan.jq`, `gap-selection.jq`, `gap-selection-json.jq`,
`gap-selection-plan.jq`, `gap-plan-merge.jq`, `gap-supported-series.jq`, `gap-bounds.jq`,
`gap-bound-requests.jq`, `gap-diff.jq`, `gap-diff-fast.jq`, `gap-statistics.jq`,
`gap-attach.jq`, `gap-messages.jq`, `gap-reprocess-plan.jq`, plus two modules that need
`jq -L "$JQ_DIR"`: `gap-summary.jq` (shared by the two message renderers) and
`gap-selectors.jq` (shared by the two `--gapsFor` parsers).

### Measurement-gap analysis (`--measurementGaps`/`--measurementGapsExact`)

For every `MissingLinkedSeriesInChildAdditionError`, reports the time range where the
device has measurements the asset never got a copy of.
- **Default (`--measurementGaps`)**: boundary-only — 4 cheap `pageSize=1` probes per
  link (oldest/newest of both sides). Fast, but only sees a single trailing gap and never
  learns an exact point count (`gap-diff-fast.jq`).
- **`--measurementGapsExact`**: full `--includeAll` timestamp read of both series,
  exact point-by-point diff (`gap-diff.jq`). Orders of magnitude more expensive — capped
  by `C8Y_DTM_GAPS_MAX_LINKS` (default 100) and `C8Y_DTM_GAPS_MAX_POINTS` (default
  500000). It sends only the *newest* boundary probe per side (2 instead of 4): the
  oldest one is an ascending sort over the whole window, which on a time series store
  regularly hits the server-side query timeout (`RemoteCommand ... expDate ...` in
  `probeError`), while the descending one answers from the newest bucket. The
  enumeration reports the oldest timestamp anyway.
- **Read direction (CONFIRMED on t1298412)**: the *ascending* measurement query
  (`--revert=false`, `$sort: {time: 1}`) is the one a time series store struggles with.
  On a busy device series it has been observed both to time out server-side and — worse —
  to return an **empty page with exit code 0 and nothing on stderr**, while the descending
  read of the very same series answers immediately. Every enumeration therefore retries
  newest-first when the oldest-first read returns nothing although the boundary probe
  found data, and `gap-diff.jq` clips a partial descending read as a *suffix* rather than
  a prefix. Symptom to recognise in a trace: `device.points: 0` next to a non-null
  `device.last`.
- **`verify-measurement-gap-enumerations.json`** (`--traceDir`) answers "were these
  measurements actually read": one record per enumerated series with the source, the
  fragment/series queried, the window, the read direction, the point count, first/last and
  the probe's `last` for comparison. `C8Y_DTM_GAPS_TRACE_TIMES=1` adds every timestamp
  (can be hundreds of thousands per link).
- **Trusting a read**: a link is classified from the newest boundary probe, so an
  enumeration that returns nothing while the probe found data is a failed read, not an
  empty series — reported as `enumerationFailed`, never as "no gap" (device side) or
  "everything missing" (asset side). An enumeration that stops early with an error still
  delivered a valid ascending prefix and is used as a lower bound, exactly like one that
  hit `C8Y_DTM_GAPS_MAX_POINTS`.
- **Both query the asset side using the asset's declared `c8y_LinkedSeries`
  fragment/series unless `--assetFragmentTemplate`/`--assetSeriesTemplate` say
  otherwise.** Per §4, the declared values are only meaningful if the active smart
  function actually persists measurements under them. Confirm the smart function in use
  before trusting a reported gap, or before reporting "zero measurements copied" as
  evidence of a broken link.
- **Window**: every measurement query is bound by `--dateFrom` (default `-2d`, absolute
  or relative) and `--dateTo` (default now). Nothing outside it is looked at, so "no gap"
  always means "no gap in that window" — the window is printed in `--stats` and stored in
  `verify-statistics.json` as `measurementGaps.window`. Widening it costs real time,
  which is exactly why the default is small.
- **Supported-series pre-pass**: before probing, the `c8y_SupportedSeries` of every asset
  and source device involved is read in one batched `c8y devices getSupportedSeries` call
  (`gap-supported-series.jq`). A series absent from that index never held a measurement,
  which classifies the link as `noSourceData` (0 probes) or `assetEmpty` (2 probes
  instead of 4). Used as a negative only: the index ignores the window, so a series
  present in it is still probed. If not one source device reports any supported series,
  the index is treated as unusable and every link is probed as before. `--noSupportedSeries`
  disables it. The output template must read the fragment with `std.get(output, ...)`:
  a device that cannot be read answers with an error object, and jsonnet aborts the whole
  batched call on a field that does not exist rather than yielding null for that one
  record — the symptom is a stray "Alternatively, jsonnet is more relaxed than json"
  block on stderr and an empty index for every id in the batch.
- **`--gapsFor SOURCE`** (implies `--measurementGaps`): also analyses links that are
  *not* failing right now. This is the flag for the normal repair sequence — a run
  reports broken links, `create` (or a reconcile) repairs the reverse index, and only
  afterwards does the question "what did those links never receive?" get asked, at which
  point they no longer appear as errors and nothing would be probed for them.
  `SOURCE` is a comma separated list of asset ids or a file holding a previous run's
  JSON, a pasted console log, or plain asset ids. **`verify-errors.json` and
  `verify-result.json` from `--traceDir` are the intended input** — they select exactly
  the links that were reported broken, and are accepted in any shape (one object per line
  as `trace_write` leaves them, pretty printed, or wrapped in an array; the file is
  slurped when it parses as JSON and read line by line when it does not). Verdicts that
  passed select nothing, so handing over a whole `verify-result.json` does not pull in
  every link of every healthy device. From a log line only the asset id (and the device
  id, if the line names one) is read — the `fragment.series` it also prints is joined by
  a dot that can occur inside the fragment, so splitting it again could select the wrong
  link; selecting the asset costs a few more probes and is always right. Only *which*
  links to look at comes from `SOURCE`:
  Selected links are reported as `MeasurementGap` (a gap was found), `NoMeasurementGap`
  (looked at, nothing missing) or `MeasurementGapUnknown` (never looked at, or the probe
  failed — *not* the same as "no gap"), findings first so the console line cap can only
  cut into the least interesting end. Under `C8Y_DTM_GAPS_MAX_LINKS` the probe budget
  goes to the currently failing links first, then to links named one by one, then to
  whole assets, then to whole devices — one device-wide selector (a `CumulocityError`
  line can carry hundreds of links) must not use up the budget before the named links are
  covered.
- **`--gapsForError TYPES`** decides which reported errors a `--gapsFor` source may
  select links from. The default is *every error except `CumulocityError`*: that one
  means the source device could not be read at all, so there is no reverse index to
  repair and nothing to reprocess into, while a single such line can carry hundreds of
  links. `all` keeps it, a comma separated list restricts to exactly those types. A
  selector with no discoverable error type (a bare asset id, a hand written link) is
  never filtered. Log lines are matched on the `...Error` token they print, verdicts on
  their `error` field.
- **`--gapsOnly`** (needs `--gapsFor`) determines the gaps without verifying anything:
  only the selected assets are read, one `inventory get` each, and the reverse index of
  their devices is never queried, so it does not load the tenant. It refuses to run when
  a selector names only a device, because finding that device's links means reading every
  asset anyway. What it cannot tell you is whether the reverse index is correct right now
  — a gap found in this mode is a statement about the data, not a verdict on the link.
  `--stats` then renders the measurement gap section only.
  source, fragment and series are always read from the asset as it is now, so a report
  of any age stays usable. Selected links are reported as `MeasurementGap` /
  `NoMeasurementGap` console lines and counted separately in `--stats`; they never change
  the verification verdict or the exit code. A link that is both failing and selected is
  reported once, on its error line.
- **`--missingMeasurementsFile FILE`**: downloads the *device* measurements behind the
  reported ranges (in exact mode filtered to the exact missing timestamps), deduplicates
  them by measurement id and writes `FILE.0001.json`, `FILE.0002.json`, … each holding
  `{"measurements":[...]}` ready for `POST /service/dtm/reprocess/measurements`
  (`ROLE_DIGITAL_TWIN_ADMIN`, max batch size 10000 by default,
  `C8Y_DTM_REPROCESS_BATCH_SIZE` / `C8Y_DTM_REPROCESS_MAX_MEASUREMENTS`). The payload is
  always the original device measurement — dtm-data-service re-runs the smart functions
  on it and derives the asset side from the reverse index itself, so **repair the reverse
  index first** (`opposites create`, or DTM's reconcile endpoints) or the reprocessed
  measurements land nowhere.

## 6. Known gotchas / tenant settings (CONFIRMED)

| Setting | Default | Effect |
| --- | --- | --- |
| `assets.linkedSeries.opposites.reconciliation.schedule` | `disabled` | Scheduled background reconciliation (`LinkedSeriesOppositeReconciliationScheduler`/`Runner`) — walks every asset with a linked-series source in a continuous cycle, re-running `reconcileOppositeLinks` for each. Check whether this is enabled on a given tenant before assuming the reverse index is static between `opposites` runs. |
| `assets.linkedSeries.opposites.reconciliation.schedule.mode` | `disabled` | Same job, doubly gated — check both. |
| `assets.linkedSeries.source.measurementType.mode` | **`required`** | If a `LinkedSeries.source` has no `type`, DTM looks up the device's last matching measurement to fill it in. If the device has never received one (e.g. a freshly created test device), asset creation fails `400 MeasurementTypeNotFoundException`. Always send `source.type` explicitly to skip this lookup when scripting asset creation. |
| `assets.permission.mode` | `external` | Under the default, plain asset create/update/delete needs **no** `ROLE_DIGITAL_TWIN_*` role — only ordinary Cumulocity inventory permissions, since the write runs as the calling user. Roles become mandatory only if set to `all`. |

Other confirmed facts:
- **No pre-registered asset type needed** to create an asset via DTM's API — `type` is an
  arbitrary string; `AssetDefinition` is a separate schema-governance concept never
  consulted on instance create.
- **No parent/hierarchy required** — a standalone asset is valid and the default state.
- **DTM's own asset-update semantics**: `PUT /assets/{id}` — omitting `c8y_LinkedSeries`
  leaves it untouched; sending `null` removes it entirely; sending a non-empty array
  replaces the whole list (full-replace at the asset level, not per-item merge — use the
  dedicated linked-series endpoints, `POST /assets/{id}/linkedSeries`, for per-item
  upserts).
- **dtm-data-service copy semantics**:
  - Pulsar/notification-2.0 consumer on measurement `CREATE` events — **pure real-time,
    no retroactive backfill**. A measurement that arrived before a link existed is gone
    forever for copy purposes (only a manual `POST /reprocess/measurements` can resubmit
    specific ones).
  - No "exactly one match" restriction on the reverse-index lookup — if N assets share a
    source triple, all N get a copy (subject to what the active smart function actually
    does, §4).
  - Reverse-index child additions are cached per device, default TTL 60s
    (`CACHE_CHILD_ADDITIONS_TTL_MS`) — negligible staleness window, rarely relevant to a
    multi-hour/day-scale investigation.
  - **"No measurements copied" is not automatically evidence of a broken link.** It can
    equally mean: (a) the smart function persists under a different fragment/series than
    assumed (§4 — check this first), (b) the series is genuinely low-frequency and simply
    hasn't posted a new value during the window being checked, or (c) the link was never
    actually correctly registered during any window a new measurement arrived. Always run
    a control check against an unrelated, known-good, unambiguous 1:1 linked series on
    the same tenant — if that also shows nothing, the problem is systemic (deployment,
    subscription, smart function misconfiguration), not specific to the link under
    investigation.

## 7. What to check when analyzing opposites errors

Ordered roughly by cost (cheapest/most informative first). Not every case needs every
step.

1. **Reproduce with `opposites verify --traceDir DIR --stats`.** Always capture a trace
   dir before doing anything else — every intermediate JSON is written and can be
   analyzed offline afterward, including if the live state changes later.
2. **Read the actual error type carefully** (`verify-errors.json`,
   `verification-error-messages.jq`'s output) — `MissingLinkedSeriesInChildAdditionError`
   (link genuinely absent from the reverse index) is a very different situation from
   `CumulocityError` (source device unreachable/deleted), `TooManyChildAdditionsError`,
   or `NoVerificationResultError`. Don't assume the "usual" cause without checking which
   error is actually present.
3. **For a missing link, check whether it shares its source triple with other assets**
   (`(source.id, source.fragment, source.series)` matching more than one asset's
   `c8y_LinkedSeries` entry). If so, this is a normal, supported configuration — do not
   assume it's a data-quality mistake without confirming with the data owner.
4. **Compare `childAdditionId` across trace dirs taken at different times, not just
   presence/absence of errors.** A stable id with a shrinking `c8y_LinkedAssets` count
   means the *same* object lost entries in place (worth investigating what wrote to it
   and when). A changed id means the object was deleted and recreated (e.g. by a
   `clean + create`, or some other process). These point at very different causes.
5. **Correlate `lastUpdated` timestamps** on the individual asset managed objects (not
   just the reverse-index object) against the reverse-index object's own `lastUpdated`.
   DTM does not (as of this writing) write its own audit records, so `lastUpdated` is
   the best available substitute for "what touched this and when." Look for what process
   actually performs asset updates in the environment (SAP integration, manual scripts,
   this repo's migration tooling, DTM's UI) before assuming which one is responsible.
6. **If a measurement-copy question is involved ("why is there no data on the asset"),
   go to §4 first** — confirm which smart function is active and what fragment/series it
   actually persists under, before trusting any `--measurementGaps` output or manual
   measurement query.
7. **Check the tenant's relevant settings** (§6 table) — reconciliation schedule/mode,
   permission mode, measurement-type mode — before assuming a particular mechanism is or
   isn't active.
8. **If a code-level bug in DTM itself is suspected**, check the deployed application
   version: `curl -u user:pass https://<tenant>/application/applicationsByName/dtm` (or
   `/application/applications/{id}`) → `activeVersionId`. Compare against
   `cumulocity-solution-enablement`'s git history/tags for the relevant service class to
   see whether a known fix postdates what's deployed. Note: version/binary detail
   endpoints beyond `activeVersionId` are management-tenant-scoped and 404/405 from a
   subtenant login — getting the actual release date/tag for a given `activeVersionId`
   usually requires asking the deploying team or checking CI/CD run history directly.
9. **If genuinely suspecting a concurrency/timing issue**, first confirm whether DTM
   actually runs more than one instance for the environment in question — a
   single-instance deployment rules out any cross-replica race, since
   `DeviceLockManager`'s in-JVM lock is then sufficient on its own.
10. **Ask, don't assume, who/what is actually driving the update pattern** in the
    environment under investigation (a specific SAP integration, a different ERP
    connector, manual scripts, this repo's migration tooling) — the exact sequence and
    API surface used varies per customer/environment and materially changes which code
    paths are even in play.

## 8. Verified DTM REST API surface (CONFIRMED against source)

Base path: `/service/dtm` (no `server.servlet.context-path` configured; platform proxies
under the app's `contextPath`). Errors: `{ "messages": ["..."] }`.

| Method | Path | Notes |
| --- | --- | --- |
| POST | `/assets` | Create. `type`/`name` arbitrary, no registry check. `c8y_LinkedSeries` array optional. |
| PUT | `/assets/{id}` | Full update. Omit `c8y_LinkedSeries` = untouched; `null` = removed; non-empty array = full replace. |
| DELETE | `/assets/{id}?deleteSubAssets=&deleteDevices=` | `deleteDevices=false` unless you explicitly want cascade into the source device. |
| GET | `/assets/{id}/linkedSeries` | List, with `Accept` negotiation for paginated vs plain. |
| POST | `/assets/{id}/linkedSeries` | Upsert array, matched by `(fragment, series)` — the dedicated individual-link endpoint. |
| DELETE | `/assets/{id}/linkedSeries?fragment=&series=` | Remove one. |
| GET/POST/PUT/DELETE | `/assets/{id}/linkedSeries/{fragment}/{series}/source[...]` | Source sub-resource; same underlying `MeasurementSourceLinkService` calls. |
| GET | `/assets/{id}/linkedSeries/verifyOpposite` | `204` consistent, `409` + `InconsistencyReport` if not. No DTM role required. |
| PUT | `/assets/{id}/linkedSeries/{fragment}/{series}/reconcileOpposite?removeMissingSourceId=` | Force a reconcile of one link. No DTM role required. |
| PUT | `/assets/{id}/linkedSeries/reconcileOpposite?removeMissingSourceId=` | Reconcile all of one asset's links. |
| GET | `/assets/linkedSeries/opposites/{deviceId}[?assetIds=&fragment=&series=]` | Reverse lookup: which assets does this device series link to. |

Roles: under default `assets.permission.mode=external`, plain create/update/delete need
no `ROLE_DIGITAL_TWIN_*` — only platform inventory roles, since the write runs as the
calling user. The dedicated *source* sub-resource endpoints (not whole-asset/whole-link
upsert) always require `ROLE_DIGITAL_TWIN_ASSETS_*`/`_LINKING_*` regardless of the
permission mode.

## 9. Useful commands

- `opposites verify --traceDir DIR --stats` — always start here.
- `c8y measurements list --device <id> --valueFragmentType <fragment> --valueFragmentSeries <series> --pageSize 1 --revert=false|true --select time` — cheap oldest/newest boundary probe (mind §4 on which fragment/series to actually use, and the percent-encoding note in §3).
- `c8y measurements list ... --includeAll --select time` — full timestamp listing, expensive, only when an exact count/diff is needed.
- `c8y inventory get --id <id> --select id,lastUpdated` — minimal-cost check of when any managed object (asset, device, or the reverse-index child addition itself) was last touched.
- `curl -u user:pass https://<tenant-host>/application/applicationsByName/dtm` — check a tenant's deployed `dtm` `activeVersionId`.
- `c8y dtm settings list --raw` (via DTM's own settings endpoint) — check tenant options from §6 directly.

## 10. File map

```
c8y-dtm (this repo)
├── commands/migration/opposites               # the migration CLI command (create/clear/verify/get)
├── shared/opposites/jq/*.jq                    # all jq transforms used by the opposites command
└── k6-opposite-concurrency/                    # write-path load/regression test harness (see its own README)

cumulocity-solution-enablement/microservices/java
├── digital-twin-microservice/.../controllers/AssetController.java
├── digital-twin-microservice/.../controllers/AssetLinkedSeriesController.java
├── digital-twin-microservice/.../controllers/AssetLinkedSeriesSourceController.java
├── digital-twin-microservice/.../controllers/AssetLinkedSeriesOppositeController.java
├── digital-twin-microservice/.../services/AssetService.java                # update()/doUpdate(), asset lock
├── digital-twin-microservice/.../services/MeasurementSourceLinkService.java # the reverse-index writer, device lock
├── digital-twin-microservice/.../utils/DeviceLockManager.java / AssetLockManager.java
├── digital-twin-microservice/.../scheduler/LinkedSeriesOppositeReconciliationScheduler.java / Runner.java
└── common/.../models/fragments/LinkedAsset.java / LinkedSeries.java        # identity keys, DTOs

dtm-data-service
├── src/worker/processor/notification-processor.service.ts   # measurement-ingest consumer, reverse-index matching
├── src/worker/processor/cache.service.ts                     # reverse-index cache (60s TTL)
├── src/worker/processor/smart-functions/onmessage.fn.ts       # BUNDLED DEFAULT smart function
└── src/worker/processor/reprocess.controller.ts               # manual POST /reprocess/measurements

sap-dtm-smartfunctions
└── (known example of a CUSTOM smart-function repo — check for an equivalent per
    tenant/environment before assuming the bundled default is what's actually running)
```
