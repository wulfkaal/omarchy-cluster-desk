# Telemetry contract

Cluster Desk accepts the existing GB10 telemetry v1/v2 formats. The validator
in `collector.ts` is authoritative: object shapes are closed, missing optional
groups are allowed, and unknown or malformed fields reject the whole document.
Input is UTF-8 JSON in a local regular file, at most 128 KiB, 4,096 structure nodes
and depth 8. Duplicate keys, including escaped duplicates, are rejected.

## Common values

`producedAt` and `fetchedAt` are real UTC RFC3339 timestamps ending in `Z` or
`+00:00`. The receiver/publisher stamps `fetchedAt` after successful collection;
leaving that timestamp unchanged makes an old feed visibly stale.

Numbers are finite and nonnegative unless noted; counters and byte sizes are
integers. Percentages are 0–100. IDs are 1–64 ASCII letters, digits, `_` or `-`,
starting with a letter or digit. Strings are at most 64 UTF-16 code units, have
normalized whitespace and no controls. Strings render as plain text.

## v2 envelope

Required: `v: 2`, `producedAt`, `fetchedAt`, `nodes`, `cluster`.
Optional: `fleet`.

`nodes` contains 1–3 entries sorted by unique `name`:

- Unreachable: exactly `name`, `address`, `reachable: false`, `reason` (an ID).
- Reachable: `name`, `address`, `reachable: true`, `host` (display string),
  `sys`, `workloads`; optionally `gpu`, `gpuProcs`, `models`, `agents`,
  `residentAgents` and `residentModelCount`.

`sys`: `load1`, `load5`, `load15`, `procs`, `cores` (positive integer),
`memUsedBytes`, `memTotalBytes`.

`gpu`: `name`, `utilPct`, `memUtilPct`, `tempC`, `powerW`, `smClockMhz`.
No GPU group means unknown/unavailable.

`workloads`: up to eight rows of `name`, `cpuPct`, `memPct`, sorted descending
by `cpuPct`. CPU can reach 100 × cores; it is not a whole-machine percentage.

`gpuProcs`: up to eight rows of `pid`, `usedBytes`, `name`, descending by usedBytes.

`models`: up to eight rows of `name`, `vram`, `ctx`, `params`, `quant`, descending
by vram. Optional `residentModelCount` is the total; models contains its first
eight rows. Model presence is an observation, not a request to load it.

`cluster`: exactly `nodes`, `nodesUp`, `cores`, `memUsedBytes`, `memTotalBytes`,
`gpusBusy`. Totals must match the reachable nodes; `gpusBusy` counts GPUs whose
utilPct is at least 1. Unreachable nodes contribute no measured totals.

## Optional fleet

Required when present: `total` (0–100), `models` (at most total), `tiers` and
`nodes` (ID → count maps each summing to total). v2 also requires
`residentByNode`: the same node keys, with counts or null for unknown.

Optional `roster` has exactly total entries, sorted by unique ID:
`id`, `model`, `tier`, `node`, `resident` (boolean or null).
Tier/node must exist in their count maps.

Optional per-agent historical metrics: `pairs`, `wildCorrect`, `poolCorrect`,
`consensus`, `dissent`, `ties`, `burn`, `mint`, `wildLatencyS`, `poolElapsedS`.
Correctness and consensus are fractions 0–1. Burn/mint can be signed.
Omitted metrics stay unavailable; they are not replaced with zero.

Additional legacy optional groups are accepted: `residentAgents`,
`residentModels`, `residentModelCount`, `metrics`, `nodeEndpoints`,
`tierTimeouts`, `inferenceOptions`, `taskBaselines`, `taskAnalysis`,
`modelCatalogue`, `concurrencyCaps`, `concurrencyReason`. These retain the strict
GB10 contract implemented and tested in `collector.ts`; publishers should omit
them unless they supply those specific observations. In particular, residency
counts and task-analysis totals must reconcile rather than being inferred by
the dashboard.

## v1 compatibility

Required: `v: 1`, `producedAt`, `fetchedAt`, `host` (the sys object above),
`workloads`. Optional: `gpu`, `gpuProcs`, `models`, `fleet`, `agents`.
It represents one node. Legacy `agents` is a busy/idle/offline summary with up to
four ID-sorted `lastActivity` rows (`id`, `line`, up to 140 code units).

## Publisher responsibilities

Collect on your own schedule and atomically replace the local file. Do not point
the plugin at an SSH pipe, device or network URL. A remote publisher or sync tool
should finish writing before renaming. Missing, unreadable or invalid input
produces an unavailable state; a valid old file remains visible with STALE.

The feed is displayed to anyone who can see the desktop. Redact sensitive data
at the publisher. The dashboard does not send feed contents anywhere.
