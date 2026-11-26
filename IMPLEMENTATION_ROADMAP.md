# Implementation Roadmap — RTX 2060

Status: **proposal only. No implementation was started.** The audit's final
instruction was to present findings and wait for approval before modifying
source.

The ordering below is deliberate: each phase removes a blocker or produces the
measurement needed for the next. Nothing here replaces AMD paths or changes
defaults for the validated RX 7900 XTX machine; NVIDIA-specific behaviour
should be selected by capability, not by a hard-coded vendor branch where
possible.

## Phase 0 — Baseline measurement on the target (1–2 days)

**Goal:** stop guessing. Produce a trace from Windows 11 + RTX 2060 + 16 GB.

| Task | Where | Output |
|---|---|---|
| Log adapter, driver, Windows build, SM, mesh tier, wave lanes | mostly existing `host.rs:1083-1091`, `4116-4146` | startup log |
| Query and log OPTIONS9/OPTIONS11 atomic capabilities | new probe near `host.rs:1046` | capability booleans |
| Run `victory translate --validate --pipelines` on the user's corpus | `apps/victory/src/translate.rs` | pass/fail tally |
| Run menus only, then world load, then a dense scene | `scripts/play.ps1` | frame/memory lines |
| Record peak private bytes, local/shared VRAM, H2D/D2H bytes | existing `video_memory`, `copystat` | CSV/log |
| Capture TDR/device-removed events | `tdr.rs`, DRED | crash log |

**Gate 0:** a complete trace exists. If Windows 10 is the only OS available,
record the root-signature failure too; it confirms F-01 on this exact card.

## Phase 1 — Windows 10 Agility SDK (2–4 days)

**Fixes:** F-01. **Priority: highest**, because without it Windows 10 cannot
draw at all.

| Task | Suggested location | Notes |
|---|---|---|
| Add app-local D3D12 runtime deployment | new `apps/victory/src/agility.rs` + build step | Mirror upstream #175's approach: export `D3D12SDKVersion`/`D3D12SDKPath`, fetch `Microsoft.Direct3D.D3D12` |
| Or load through `ID3D12SDKConfiguration1` | near `create_preferred_device` (`emit/host.rs:107`) | `VICTORY_D3D12_AGILITY=<folder>` for test binaries |
| Fail clearly on `D3D12_ERROR_INVALID_REDIST` | `host.rs:1017` | Tell the user to deploy the runtime |
| Report runtime presence in `victory config` | `apps/victory/src/main.rs:253` | Operator visibility |
| Make tests use it | `emit/host.rs` test harness | Otherwise SM 6.6 tests keep skipping |

**Gate 1:** on Windows 10 19045 + RTX 2060, root signatures serialize and the
menus draw more than 0 frames. On Windows 11 the existing in-box path still
works.

**Risks:** DLL licensing/asset policy; pinned SDK vs. newer in-box runtime;
test executables need the same loader.

## Phase 2 — 6 GB / 16 GB memory mode (1–2 weeks)

**Fixes:** F-02, F-03, S-05.

| Task | Suggested location | Acceptance |
|---|---|---|
| Scale `targets_room_kept` to DXGI budget | `resource.rs:1758-1783` | no fixed 3 GiB reserve on 6 GB |
| Scale texture floor and pool spares | `resource.rs:1707-1712`, `pool.rs:30-37` | peak VRAM below budget |
| Make `VICTORY_RESIDENCY=1` default on ≤16 GB / ≤8 GB VRAM | `residency.rs:19-22` | low-memory budgets active automatically |
| Cap address pages and list allocator retention | `memory.rs:84-88`, `host.rs` list retention | peak private bytes measured |
| Evict idle host copies and textures explicitly | `shadow.rs`, `resource.rs` | no unbounded growth |
| Add texture mip/quality drop | `texture.rs`, `resource.rs` | 25–75% texture memory reduction (upstream #737 estimate) |
| Try Series S profile on 6 GB | `console.rs:24`, `victory.toml` | world loads |

**Gate 2:** on 16 GB RAM / 6 GB VRAM, the title completes world load without
`E_OUTOFMEMORY`, without sustained shared-memory thrash, and with peak private
bytes below ~14 GB. This gate is likely to require more than constants; if it
fails, stop and re-scope before performance work.

**Risks:** texture pop-in, lower quality, more copies, correctness if a mirror
is evicted while a shader still references it.

## Phase 3 — Descriptor heap correctness on NVIDIA (3–5 days)

**Fixes:** F-04, F-11 (partly).

| Task | Suggested location | Acceptance |
|---|---|---|
| Stop carving dynamic slots out of the title's range on a capped heap | `descriptor/host.rs:1658-1693` | title slots up to the full count mirrored |
| Clamp shader indices to the last mirrored title slot | `shader.rs:150-180`, `set_view_heap_limit` | no index into dynamic range by accident |
| Add a compaction/indirection table if the full range cannot fit | `descriptor/host.rs` | no null reads at high slot counts |
| Add a bounded raw-twin scheme or a shader address table | `descriptor/host.rs:1530-1600` | computed-index raw reads correct on NVIDIA |

**Gate 3:** a dense scene logs no `title slot past the host heap`, and a test
that reads a picked structured buffer returns the same bytes on NVIDIA as on
AMD.

**Risks:** dynamic table exhaustion; extra indirection cost; heap switching
stalls.

## Phase 4 — Indirect dispatch splitting (3–5 days)

**Fixes:** F-05.

| Task | Suggested location | Acceptance |
|---|---|---|
| Detect records >65,535 groups | `indirect.rs`, clamp shader source | counted |
| Split into multiple `ExecuteIndirect` calls or a shader-side range loop | `indirect.rs`, `indirect/batch.rs` | all tiles dispatched |
| Preserve record order and UAV visibility | indirect path | no holes/duplicates |
| Keep AMD's 2^20 path unchanged | `widest()` | no regression on 7900 XTX |

**Gate 4:** the 1440p tile-list scene renders the bottom 1,905 tiles that are
currently lost, with no new device hang and no measurable frame-time
regression on AMD.

**Risks:** extra submissions, ordering hazards, argument patching bugs.

## Phase 5 — Capability gating for 64-bit atomics and derivatives (1–2 days)

**Fixes:** F-06, S-06 partly.

| Task | Suggested location | Acceptance |
|---|---|---|
| Query OPTIONS9 and OPTIONS11 once | `host.rs` next to OPTIONS1 | logged booleans |
| Reject or emulate unsupported 64-bit atomics | `lower.rs:11508-11547`, `shader.rs:586-597` | pipeline failure is explicit, not opaque |
| Query `DerivativesInMeshAndAmplificationShadersSupported` | same | mesh/compute derivative shaders gated |
| Include capabilities in the shader cache key | `lower.rs:1516-1519` | moving cache between GPUs is safe |

**Gate 5:** on RTX 2060, either the affected shaders create pipelines, or the
log names the missing capability and the title degrades gracefully.

**Risks:** emulation cost/ordering; rejecting pipelines loses features.

## Phase 6 — Performance (2–6 weeks, measurement-driven)

**Fixes:** S-01..S-04, plus texture/upload inefficiencies.

Only start after Gates 1–5. Suggested order by expected payoff:

1. Reduce bytes moved: dirty-page texture uploads instead of whole-texture
   re-uploads (`texture.rs`).
2. Reduce descriptor work: fewer per-draw table rebuilds, better use of the
   write-site patches (`port_descriptors.rs`).
3. Reduce landing/copy traffic: batch more, avoid redundant ranges
   (`land.rs`, relay).
4. Revisit CPU preparation: split work further only if measurements show it is
   still above frame budget (`queue/behind.rs`, `host.rs:3215+`).
5. Skip passes that do nothing without ray tracing (`docs/findings.md`).
6. Pipeline warm-up discipline: ship a warmed cache per driver/build.

**Gate 6:** measured improvement on RTX 2060, not a claim. Target order:
playable world first, then 1080p 20 fps, then 1080p 30 fps. Do not promise
1440p 30 fps on a 6 GB 2060.

## Phase 7 — Optional / out of scope

These are **not** recommended for the first NVIDIA bring-up:

- NVAPI / DLSS / Reflex integration.
- DXR acceleration structures to replace the title's compute BVH.
- A mesh-to-compute fallback (RTX 2060 has mesh shaders; not needed).
- Replacing the AMD descriptor decoder or renderer ports.
- Copying upstream PRs wholesale. Use them as references and re-derive against
  this fork's IR and heap model.

## Priority summary

| Priority | Work | Blocker removed |
|---|---|---|
| P0 | Measurement | none (enables everything) |
| P1 | Agility SDK | Windows 10 |
| P2 | 16 GB / 6 GB memory mode | capacity |
| P3 | Descriptor heap fix | NVIDIA correctness |
| P4 | Indirect split | NVIDIA correctness |
| P5 | Atomic capability gating | opaque pipeline failures |
| P6 | Performance | frame rate |
| P7 | Optional NV features | none |

## What must not happen

- Do not change the validated AMD defaults without capability gating.
- Do not remove AMD paths, ports or diagnostics.
- Do not claim a gameplay pass from a successful shader batch.
- Do not treat 16 GB as a config flag; it is a residency redesign.
- Do not merge upstream NVIDIA PRs without checking them against this fork's
  different wave, heap and IR models.

## Approval point

The audit ends here. The recommended first change is Phase 1 (Agility SDK),
because it is small, independently testable, and unblocks every Windows 10
measurement. Phase 2 should not begin until the Phase 1 trace confirms the
target machine can draw.
