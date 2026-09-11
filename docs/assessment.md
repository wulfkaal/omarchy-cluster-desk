# Standalone extraction assessment

## Result

The workspace-10 dashboard was already registered separately as `wulfkaal.gb10`,
but its source lived in an Infomarchy fork/worktree. It can be an independent
Omarchy plugin without changes to Infomarchy or the remote cluster.

The standalone boundary is the local telemetry file. Publishers supply observations;
the plugin validates and displays them. No live deployment data or earlier Git
history is included in this repository.

## Findings and changes

| Finding | Implemented change |
| --- | --- |
| The cluster UI used only the cluster snapshot, but ran the full Infomarchy collector. | Removed local `/proc` scanning, agent history parsing, Git/GitHub checks, network checks and Ollama polling. The collector only reads the configured local file. |
| InfoModel retained unused approval, session, clipboard and preview actions. | Removed those actions and helpers; retained theme colors, bounded framing and byte formatting. |
| A developer's absolute home-directory path was the feed default. | No default feed path; `CLUSTER_DESK_TELEMETRY`, with the old variable as a compatibility fallback. |
| Workspace 10 and the GB10 title were fixed. | Configurable workspace and title; defaults retain workspace 10. |
| The v2 parser required exactly three fixed node names. | Accept 1–3 uniquely named, lexically ordered nodes with reconciled totals. |
| Node and agent colors were fixed. | Use the current theme's ANSI colors and foreground. |
| Upstream history, unused datasets and development reports obscured the plugin boundary. | New repository containing only runtime files, focused tests, synthetic examples and documentation. MIT attribution retained. |
| Tests mostly asserted source strings. | Retained parser boundary tests and added an offline collector run and actual offscreen QML rendering/interaction checks. |

The reader shrank from 2,014 to approximately 360 lines; the QML data model from
468 to 190 lines. No new runtime dependency is introduced.

## Intentionally separate

The existing GB10 exporter is cluster-specific: SSH topology, local model
inventory, historical analysis and fleet configuration belong to the producer.
It continues to publish the same file on this machine. Those scripts, host
addresses, historical results and operational notes are not distributed here.
Other users provide a publisher that conforms to the documented JSON contract.
This repository is the dashboard, not a cluster provisioning or transport tool.

## Limits

- The compact grid is bounded at 100 agents and the node summary at three nodes.
  Very small screens or large font scales may show the existing overflow notice.
- Workspace display follows the focused workspace, as in the source plugin;
  independent multi-monitor workspace presentation is not implemented.
- The wallpaper layer supports still images. Animated/video wallpaper support
  from newer Infomarchy is not part of this extraction.
- The input read is byte-bounded and checks elapsed time between reads; a blocking
  network filesystem read cannot be interrupted synchronously. Use a local file.
- Optional historical task metrics retain the GB10 schema and its assumptions.
  They are not measurements of current agent correctness or future capability.
- The live source refreshes independently of the optional Infomarchy REMOTE card.
  Publishing this plugin does not add a remote roster card to Infomarchy.
