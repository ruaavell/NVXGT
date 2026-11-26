# VIctory NVIDIA RTX 2060 Compatibility Audit — Main Report

- **Audit date:** 2026-11-26
- **Repository:** `avatarmanz/VIctory-7900XTX`
- **Mode:** read-only. No source file, build file or asset was modified.
- **Deliverables:** this report plus `ARCHITECTURE_MAP.md`,
  `NVIDIA_COMPATIBILITY_MATRIX.md`, `RTX2060_HARDWARE_REPORT.md`,
  `MEMORY_ANALYSIS.md`, `SHADER_COMPATIBILITY_REPORT.md`,
  `PERFORMANCE_BOTTLENECKS.md`, `IMPLEMENTATION_ROADMAP.md`.
- **Target:** NVIDIA GeForce RTX 2060 6 GB (Turing TU106), 16 GB system RAM,
  Windows 10/11 x64, x86-64 with AVX2.

## 1. Executive verdict

The project **is not AMD-only**. A substantial amount of NVIDIA-aware code
already exists: host wave-width probing, wave64→wave32 splitting for compute,
mesh-shader capability gating, descriptor-heap capping, NVIDIA-specific format
stand-ins, NVIDIA shader-math workarounds, and explicit vendor logging.

It is, however, **AMD-tested and AMD-sized**. The only validated machine is an
RX 7900 XTX 24 GB with 64 GB of RAM (`README.md:25`, `docs/findings.md:3`). On
the requested RTX 2060 + 16 GB combination there are three independent
blockers before performance can even be discussed:

1. **Windows 10 cannot reach Shader Model 6.6 with the in-box D3D12 runtime.**
   Every translated pipeline uses SM 6.6 directly-indexed descriptor heaps
   (`pipeline/host.rs:1042-1043`). Windows 10's in-box D3D12 stops at SM 6.5,
   so root-signature serialization is refused. This repository contains **no
   Agility SDK loading path** (confirmed by a source-wide search for
   `Agility`, `D3D12Core`, `D3D12SDKVersion`, `D3D12SDKPath`). Windows 11 is
   fine; Windows 10 is not.
2. **16 GB of system RAM is far below what the current design needs.** The
   project documents about **35 GB of private memory** and recommends 64 GB
   (`README.md:33`). The design keeps host-side mirrors of title buffers,
   64 MiB texture blocks, descriptor heaps, upload arenas and a 3 GiB
   address-memory page pool. A port to 16 GB is a re-architecture of residency,
   not a configuration change.
3. **6 GB of VRAM is below the budgets hard-coded for a 24 GB card.** The
   texture queue reserves up to 2 GiB (capped at budget/4, about 1.4 GiB on a
   6 GB card), the render-target reserve defaults to 3,072 MiB
   (`resource.rs:1778-1781`), and buffer-card-copy room keeps up to 1 GiB.
   On a 6 GB budget those reservations alone can consume most of the card.

Beyond those, there are two confirmed NVIDIA correctness defects that will
affect image quality or stability even after the system boots:

- the view heap is capped at 1,000,000 descriptors, and because 262,144
  dynamic slots are carved out of the same heap, only **737,855 title slots**
  are actually mirrored (`descriptor/host.rs:1683-1690`). The title's heap is
  "a little over 1,000,000" and its highest observed slot is about 720,000, so
  the margin is only about 18k slots. Any title view above 737,855 is dropped
  and reads the null slot; shader indices between 737,855 and 999,998 read
  dynamic slots instead.
- indirect dispatch counts are clamped to 65,535 on every non-AMD card
  (`indirect.rs:279-282`). The title's 1440p tile lists ask for 67,440 and
  47,760 groups; the code's own comment records that the first list loses its
  last 1,905 tiles. That is a visible rendering defect on NVIDIA.

**Verdict:** Windows 11 + RTX 2060 is plausible after memory/scaling work and
the descriptor/indirect fixes. Windows 10 + RTX 2060 + 16 GB, on the current
tree, is **not viable** without the Agility SDK path and a dedicated 6 GB /
16 GB memory mode.

## 2. Method and evidence standard

### 2.1 What was inspected

- All crate manifests and the workspace manifest.
- Every `cfg(windows)` GPU entry point: device creation, queues, lists,
  descriptors, root signatures, pipelines, resources, textures, buffers,
  memory, residency, indirect draws.
- The complete shader front end and emitter: DXBC/DXIL parsing, GFX10 decode,
  IR, structurisation, resource tracking, lowering, DXIL container writing.
- Loader, HLE module list, configuration and policy.
- Test layout and CI workflows.
- Existing project documentation (`README.md`, `docs/architecture.md`,
  `docs/findings.md`, `docs/replay.md`, `docs/fork-ray-tracing.md`).
- Upstream VIctory NVIDIA issue/PR reports for cross-checking, clearly marked
  as external evidence.

### 2.2 What could not be done in this environment

| Limitation | Consequence |
|---|---|
| Host is Linux; project targets Windows x64 | No D3D12 device, no Windows loader, no GPU execution |
| No RTX 2060 or other NVIDIA GPU attached | No hardware measurements, no device-removal reproduction |
| No title files (and none may be included) | No gameplay, no real shader corpus, no frame capture |
| `cargo test` could not resolve dependencies offline (`blake3` missing from local registry) | No test suite was run; no claim of passing tests is made |
| The checkout has no `.git` metadata | Commit history, NVIDIA commits and PR state in this fork could not be audited |
| The two supplied ChatGPT share links return JavaScript-only shells | Their content could not be read or used |

Every finding below is therefore either (a) a direct source-code fact with
file/line evidence, (b) a documented project measurement, or (c) an external
vendor/upstream fact explicitly labelled as such. **No game compatibility test
is claimed to have passed.**

### 2.3 Severity scale

| Severity | Meaning on RTX 2060 + 16 GB |
|---|---|
| **S1 — blocker** | Cannot reach or sustain gameplay without a design change |
| **S2 — high** | Correctness/stability failure, or a major performance ceiling |
| **S3 — medium** | Works but with visible defects, elevated risk, or large wasted cost |
| **S4 — low** | Diagnostics, maintainability, or path only reachable with opt-in switches |

## 3. Findings register

### 3.1 Confirmed problems

#### F-01 — Windows 10 has no SM 6.6 / Agility SDK path (S1 on Windows 10)

**Evidence**

- `crates/victory-shader/src/emit/host.rs:107-116` —
  `create_preferred_device()` creates every device with
  `D3D_FEATURE_LEVEL_12_0`; nothing requests or loads an app-local D3D12
  runtime.
- `crates/victory-gpu/src/host.rs:1014` — the WARP path does the same.
- `crates/victory-gpu/src/pipeline/host.rs:1042-1043` — every host root
  signature sets
  `D3D12_ROOT_SIGNATURE_FLAG_CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED` and
  `D3D12_ROOT_SIGNATURE_FLAG_SAMPLER_HEAP_DIRECTLY_INDEXED`.
- `crates/victory-shader/src/emit/shader.rs:155-174` — translated shaders use
  SM 6.6 `ResourceDescriptorHeap[]` / `SamplerDescriptorHeap[]`.
- Source-wide search for `Agility`, `D3D12Core`, `D3D12SDKVersion`,
  `D3D12SDKPath`, `D3D12_ERROR_INVALID_REDIST` returns **no matches**.
- Upstream evidence: Marvisak/VIctory issue #1612 states Windows 10's in-box
  D3D12 stops at SM 6.5 and refuses these root signature flags (`c01`); PR
  #175 adds the Agility runtime and reports 43,008 of 43,008 draws where the
  unpatched build drew 0 on an RTX 2070 SUPER. This fork does not contain that
  path.

**Why it blocks**

On Windows 10 19044/19045, `D3D12SerializeVersionedRootSignature` fails with
the directly-indexed heap flags. `pipeline/host.rs:1052-1058` logs
`root signature: ...` and `host root signature refused` at line 600, then the
translated pipeline is refused. The title can reach menus but draws nothing.

**Reproduction (requires Windows 10 + RTX 2060)**

1. Build `cargo build --locked --profile diag -p victory --features diagnostics`.
2. Run `scripts\play.ps1 -Exe <title.exe>` on Windows 10 22H2.
3. Look for `host root signature refused` / root-signature text containing
   `c01`, and `0 of N` draws in the per-second line.

**Proposed fix**

Add an app-local Agility SDK deployment: ship `D3D12Core.dll` beside the
executable, export `D3D12SDKVersion`/`D3D12SDKPath`, and/or add an
`ID3D12SDKConfiguration1` loader selected by `VICTORY_D3D12_AGILITY` so test
binaries can use it too. Fail with a clear diagnostic when device creation
returns `D3D12_ERROR_INVALID_REDIST`.

**Regression risks**

- DLL deployment/licensing and asset-policy constraints (the DLLs must stay out
  of the repository).
- A pinned SDK version can be older than the Windows 11 in-box runtime; the
  loader must fall back correctly.
- Test executables need the same runtime or they will keep skipping SM 6.6
  tests.

---

#### F-02 — 16 GB system RAM is below the design's measured working set (S1)

**Evidence**

- `README.md:33` — "about 35 GB of private memory: **64 GB of RAM recommended**
  for now".
- `docs/findings.md:96` — "Memory, 40-46 GB private: lists' allocators 9 GB,
  windows 7, uploads 4".
- `crates/victory-gpu/src/memory.rs:84-88` — per-address page pool: 64 MiB
  arenas, up to 3 GiB of held pages (`MOST = 3 << 14`, 64 KiB pages).
- `crates/victory-gpu/src/pool.rs:30-34` — 64 MiB blocks, up to 64 spare
  blocks (4 GiB) when the card has room.
- `crates/victory-gpu/src/shadow.rs` — every title buffer a draw reads gets a
  persistent host copy for the life of the buffer.
- `crates/victory-gpu/src/residency.rs:4-12` — the optional low-memory mode is
  **off by default** and only engages below 3 GiB free RAM / 4 GiB commit.

**Explanation**

The layer mirrors console memory rather than mapping it. The largest consumers
are not leaks: they are list allocators, 4 MiB windows of title memory, upload
arenas, host buffer copies and staging blocks. Private memory in the high tens
of GB is expected behaviour on the validated 64 GB machine. A 16 GB machine will
hit commit exhaustion during world load long before gameplay.

**Reproduction**

Run the title with `VICTORY_MEMORY_MAP=1` on a 64 GB machine and read the
memory line; then constrain the process with a 16 GB job object or run on a
16 GB machine and observe allocation failures / paging.

**Proposed fix**

A dedicated low-memory profile: cap list allocators, shrink window and upload
arenas, evict idle host copies aggressively, reduce texture residency, and make
`VICTORY_RESIDENCY=1` semantics the default on ≤16 GB. This is a substantial
change, not a flag flip.

**Regression risks**

- More copies per frame if mirrors are evicted and rebuilt.
- Higher frame-time variance and more pipeline/texture stalls.
- Correctness risk where a shader still holds a stale mirror.

---

#### F-03 — 6 GB VRAM is below the hard-coded 24 GB-era budgets (S1)

**Evidence**

- `crates/victory-gpu/src/resource.rs:1707-1712` — texture floor
  `min(2 GiB, VRAM budget / 4)`; on a 6 GB card about 1.4 GiB.
- `crates/victory-gpu/src/resource.rs:1725-1755` — texture admission uses 90 %
  of the budget by default (`room_percent`), and 4 GiB when no budget is
  reported.
- `crates/victory-gpu/src/resource.rs:1758-1783` — render-target reserve
  `VICTORY_CARD_ROOM_FOR_TARGETS_MB` defaults to **3,072 MiB**.
- `crates/victory-gpu/src/shadow.rs:255-300` — card copies of title buffers
  keep up to 1 GiB (`SEEN = 1 << 30`), and copies may use 97 % of budget.
- `crates/victory-gpu/src/console.rs:24` — Series X profile reports 10 GiB
  GPU-optimal + 3.5 GiB standard to the title.
- `crates/victory-gpu/src/dxgi.rs:152-164` — the title is told it has those
  amounts.

**Explanation**

The title sizes its own resources for a 13.5 GB console budget. Even if the
host only creates resources lazily, the reserve constants assume a large card:
3 GiB of the 6 GB is reserved for future render targets before textures are
admitted, and texture admission can still use 90 % of the reported budget.
The result is either `E_OUTOFMEMORY`, driver eviction to shared memory (very
slow), or textures refused and rendered as placeholders.

**Reproduction**

On a 6 GB card, log `video_memory()` and `card_accounting`; enter the world and
watch `budget`/`used` and the "texture queue refused" counters. Upstream
evidence: issue #1612 section 5 says the world needs more video memory than
8 GB cards have; issue #1086 needed nine stacked changes to run on 12 GB.

**Proposed fix**

Scale `targets_room_kept`, texture floor, card-buffer room and pool spares to
the actual DXGI budget; add a mip/quality reduction mode (upstream PR #737
proposes `VICTORY_TEXTURE_MIP_DROP`); prefer the Series S texture profile; make
residency eviction active by default below 8 GB.

**Regression risks**

- Lower texture quality and more pop-in.
- Eviction/re-upload churn if the budget is too tight.
- Different title behaviour if the Series S profile changes renderer paths.

---

#### F-04 — NVIDIA descriptor heap cap leaves only 737,855 mirrored title slots (S2)

**Evidence**

- `crates/victory-gpu/src/descriptor/host.rs:1520-1528` —
  `PORTABLE_VIEWS = 1_000_000`; `UNCAPPED_VIEWS = 1 << 21` is used only if a
  2,097,152-slot heap can be created (AMD path).
- `crates/victory-gpu/src/descriptor/host.rs:1606` — `DYNAMIC = 1 << 18`
  (262,144 slots).
- `crates/victory-gpu/src/descriptor/host.rs:1614-1622` — on a capped heap,
  dynamic slots are reduced to `DYNAMIC`.
- `crates/victory-gpu/src/descriptor/host.rs:1658-1693` — with
  `null = 999_999`, `extra = 262_144`, and `count + extra > null`, the fitted
  title count becomes `null - extra = 737_855`.
- `crates/victory-gpu/src/descriptor/host.rs:1689` — warning:
  "host view heap capped at {size}; views past it read a null slot".
- `crates/victory-gpu/src/descriptor/host.rs:3261-3270` — a title slot past the
  host heap logs "title slot past the host heap" and returns `None`.
- `crates/victory-gpu/src/descriptor/host.rs:1551-1556` — comment records the
  title heap as "a little over 1,000,000" and an AMD heap of 1,507,328.

**Explanation**

On NVIDIA the heap is 1,000,000 descriptors. Dynamic slots for per-draw tables
are carved out of the same heap, leaving 737,855 title slots. The code comments
say the highest title slot seen is about 720,000, so the margin is roughly
18,000 slots. A title or scene that exceeds it loses descriptors: the mirror
returns `None`, the slot stays null, and draws read black/zero data. Shader
view indices are clamped to 999,999, not to the last mirrored title slot, so an
index in the dynamic range can also read an unrelated dynamic table.

**Reproduction**

On NVIDIA, log `host view heap capped at 1000000` and `title slot past the host
heap`. Enter dense world scenes; compare with the AMD `UNCAPPED_VIEWS` run.
Upstream issue #1305 comment item 4 reports the same class of problem on an
RTX 3060: "View heap capped at 1,000,000; shader indices clamped to
HEAP_VIEWS - 1 (2^21) can point past it."

**Proposed fix**

Either (a) shrink dynamic slots on capped heaps and reserve the full title
range, (b) remap title slots into a compacted heap with an indirection table
that shaders already consult, or (c) split the title heap across multiple
shader-visible heaps and switch per draw. Also clamp shader indices to the
last *mirrored* title slot, not merely the null slot.

**Regression risks**

- Dynamic-slot exhaustion (the code documents 2^16 and 2^17 both running out).
- Extra indirection cost in every descriptor lookup.
- Heap switching can stall the GPU on some hardware.

---

#### F-05 — Indirect dispatches above 65,535 groups are truncated on NVIDIA (S2)

**Evidence**

- `crates/victory-gpu/src/indirect.rs:270-282` — the title's tile lists are
  indirect dispatches of one group per tile; a captured 2560×1440 frame asks
  for 67,440 and 47,760. `widest(amd)` returns 1 << 20 only for AMD; every
  other vendor is clamped to 65,535.
- `crates/victory-gpu/src/indirect.rs:284-293` — the vendor check is
  `VendorId == 0x1002`.
- The comment at lines 274-275 states: "Cut to 65,535 the first list lost its
  last 1,905 tiles, the lowest of the picture."

**Explanation**

D3D12 does not validate indirect dispatch counts, so the layer substitutes a
clamp shader. On AMD it lets 2^20 groups through; on NVIDIA it cuts at 65,535.
This is a confirmed geometric/rendering defect on NVIDIA, not a performance
issue. It is scene- and resolution-dependent and will be more visible at
1440p than at 1080p.

**Reproduction**

Use the captured frame or a 1440p world scene; compare the bottom strip of the
picture with `VICTORY_INDIRECT_WIDE=1` on AMD. On NVIDIA, count refused records
in the frame line.

**Proposed fix**

Split a >65,535 indirect dispatch into multiple `ExecuteIndirect` calls or a
shader-side loop over group ranges, preserving record order and UAV visibility.
Do not simply raise the constant: NVIDIA hardware/driver limits are the reason
for the clamp.

**Regression risks**

- Extra submissions and CPU overhead.
- Ordering hazards between split dispatches.
- Indirect argument patching bugs.

---

#### F-06 — 64-bit typed/heap atomics are emitted without OPTIONS9/OPTIONS11 gating (S2, capability-dependent)

**Evidence**

- `crates/victory-shader/src/emit/lower.rs:11508-11510` — a wide image atomic
  sets `INT64 | ATOMIC_TYPED64 | ATOMIC_HEAP64` and uses `atomicBinOp.i64` /
  `atomicCompareExchange.i64` (lines 11535-11547).
- `crates/victory-shader/src/emit/shader.rs:586-597` — the flags are retained
  based on usage.
- `crates/victory-shader/src/emit/mod.rs` (header, lines 48-55) — documents
  that 64-bit texture atomics "require SM 6.6 atomic support on typed and
  descriptor-heap resources".
- Source-wide search: **no `D3D12_OPTIONS9`, `D3D12_OPTIONS11`,
  `AtomicInt64OnTypedResourceSupported`, or
  `AtomicInt64OnDescriptorHeapResourceSupported` query exists.**
- Microsoft's SM 6.6 specification says all three 64-bit atomic capabilities
  are optional (`D3D12_FEATURE_DATA_D3D12_OPTIONS9` and `OPTIONS11`).

**Explanation**

If the RTX 2060 driver does not report the typed-resource or
descriptor-heap 64-bit atomic capability, the pipeline is refused at creation
(or fails validation) when such a shader is used. Because the capability is
optional, the code must query it; it currently assumes it. Whether TU106
reports these bits with current drivers is **unverified** in this audit and
must be measured on the target card.

**Reproduction**

On the RTX 2060, query `D3D12_FEATURE_D3D12_OPTIONS9` and `OPTIONS11` and log
the two booleans; then run the shaders that use 64-bit image atomics (the
structure builder / ray-tracing paths are the likely users). A pipeline
creation failure with a 64-bit atomic requirement is the symptom.

**Proposed fix**

Query both structures once at device creation. If unsupported, either emulate
with 32-bit CAS where semantically possible, or refuse the affected pipeline
with a specific diagnostic instead of a generic creation failure.

**Regression risks**

- Emulation changes memory ordering and can be slower.
- Rejecting pipelines loses visual features.
- Capability probing must happen before shader translation/caching, or cached
  translations will be wrong for the host.

---

#### F-07 — Cross-lane operations in mesh shaders are unsupported (S3)

**Evidence**

- `crates/victory-shader/src/emit/lower.rs:5105-5110` — `cross_lane()` returns
  `Err("a cross-lane operation in a mesh shader")`.
- `crates/victory-shader/src/emit/lower.rs:421-425` — `MaskData::None` for
  mesh: "their lanes and waves (LDS per console wave) are the console's but no
  host wave size can be declared."
- `crates/victory-shader/src/emit/lower.rs:5256-5275` — mesh thread index uses
  `flattenedThreadIdInGroup`, and `lane_index()` masks it by the console wave
  size, which is a correct linear mapping but does not help wave intrinsics.

**Explanation**

The title's shaders currently all translate on the validated corpus
(`README.md:31`: 25,790 of 25,985; the rest are unused geometry shaders), so
this is not presently a blocker. It is a latent failure for any mesh shader
that uses `s_bcnt1`, `v_readfirstlane`, DPP, `ds_swizzle`, or wave reductions.
On a 32-lane NVIDIA mesh wave, the console's 64-lane assumptions cannot be
expressed with `WaveSize` (mesh shaders cannot declare a required wave size in
SM 6.6), so emulation through group-shared memory would be required.

**Reproduction**

Translate a mesh program containing a wave intrinsic with
`victory translate --list`; the refusal string appears in the failure tally.

**Proposed fix**

Group-shared-memory emulation of the specific cross-lane operations used, or
stage splitting (mesh → compute prepass) for those programs.

**Regression risks**

- Barriers inside mesh shaders can deadlock if lanes diverge.
- Additional LDS traffic and occupancy loss.
- Output ordering changes.

---

#### F-08 — The title is deliberately told it runs on AMD RDNA 2 (S3, by design)

**Evidence**

- `crates/victory-gpu/src/dxgi.rs:142-164` — adapter vendor is hard-coded
  `AMD = 0x1002`, name "VIctory console GPU", memory from the console profile.
- `crates/victory-gpu/src/device.rs:244-263` — feature query 0 returns "what an
  RDNA 2 GPU reports": tiled resources tier 3, resource binding tier 3,
  40-bit GPU addresses, resource heap tier 2, feature level 12_2 at line 101.
- `crates/victory-gpu/src/console.rs:24` — 10 GiB + 3.5 GiB Series X budget.

**Explanation**

This is console emulation, not a host assumption: the title must see the
console it was built for. The risk is that the title may enable AMD-specific
renderer paths (DCC/compression assumptions, FSR/upscaler selection, memory
budgets) that are not valid on NVIDIA. Nothing in the audit proves a specific
title branch is taken; it is a risk to test, not a confirmed defect.

**Reproduction**

Log the title's adapter queries and compare rendering with an adapter profile
that reports a generic PC GPU (not implemented). Check for AMD-only shader
paths or upscaler selection.

**Proposed fix**

Keep the AMD identity for compatibility, but audit the title's adapter-dependent
branches. If one is harmful on NVIDIA, add a narrowly scoped profile switch
rather than changing the default.

**Regression risks**

- Changing the reported vendor can change title behaviour unpredictably.
- The title may refuse to run or pick a different renderer.

---

#### F-09 — AMD descriptor decoding / `VICTORY_PORT_CBV` is AMD-only (S3, opt-in)

**Evidence**

- `crates/victory-gpu/src/book.rs:20` — "What the descriptors' bits mean is
  AMD's (RDNA 2 and 3); on another card nothing is decoded as an address we
  know, and nothing is said."
- `crates/victory-gpu/src/book.rs:424` — `decode()` interprets 32 descriptor
  bytes as an RDNA 2 buffer/texture descriptor.
- `crates/victory-gpu/src/descriptor/host.rs:3820-3840` — `move_raw()` only
  recognizes an AMD raw descriptor (address + byte count + flags); on NVIDIA it
  returns false and the twin is not moved.
- `crates/victory-gpu/src/port_cbv.rs:23` — constant buffers are read as raw
  bytes "with no end on AMD"; the port assumes AMD's unbounded raw view
  behaviour.

**Explanation**

`book.rs` is diagnostics only, so its failure on NVIDIA costs diagnostics, not
rendering. `port_cbv` is an opt-in renderer port (`VICTORY_PORT_CBV`), not one
of the default `play.ps1` settings. If a user enables it on NVIDIA, raw twin
views may be missing and constant-buffer reads can be wrong.

**Reproduction**

Run with `VICTORY_PORT_CBV=1` on NVIDIA and compare against the default; run
`VICTORY_SLOT_CHECK=1` and observe that no AMD descriptors are decoded.

**Proposed fix**

Gate `port_cbv` and AMD descriptor decoding on `VendorId == 0x1002`, or add an
NVIDIA descriptor decoder for diagnostics. Log once when a port is disabled
because the host is not AMD.

**Regression risks**

- Disabling a port on NVIDIA may leave a feature gap if it was silently load-
  bearing.
- An NVIDIA decoder must track descriptor layouts per driver/architecture.

---

#### F-10 — Two console pipeline-creation methods are unimplemented (S3)

**Evidence**

- `crates/victory-gpu/src/device.rs:355-405` — table slots `0x1c8` and `0x218`
  are bound to `unknown_pipeline`, which logs the description and returns
  `E_NOTIMPL`; the title "goes without that pipeline, silently".
- `crates/victory-gpu/src/device.rs:470-471` — table entries 57 and 67.

**Explanation**

This is platform-level missing functionality, not NVIDIA-specific. It is
recorded because upstream NVIDIA reports list the same two slots as
unimplemented and because a silently missing pipeline can explain visual gaps
that are otherwise attributed to the GPU vendor.

**Reproduction**

Search the log for "a pipeline creation method that is not implemented".

**Proposed fix**

Decode the description layout from logged words and implement the method, or
prove the title's fallback is acceptable.

**Regression risks**

- Returning an object the title did not expect can crash it; the current
  `E_NOTIMPL` is deliberately safe.

---

#### F-11 — Raw-twin views are unavailable on NVIDIA heaps (S3, suspected impact)

**Evidence**

- `crates/victory-gpu/src/descriptor/host.rs:1530-1542` — raw twins need a heap
  of `2 * RAW_TWINS` = 2^22 = 4,194,304 views.
- `crates/victory-gpu/src/descriptor/host.rs:1544-1600` — `probe_view_limit()`
  tries `fits(2 * RAW_TWINS)` first; on NVIDIA's 1,000,000 cap this fails, then
  `fits(UNCAPPED_VIEWS)` fails, so `views = PORTABLE_VIEWS` and
  `set_raw_views(0)`.
- `crates/victory-gpu/src/descriptor/host.rs:3760-3765` — a raw read through a
  structured view "gives zeros on NVIDIA (reported upstream with PR #193)".

**Explanation**

Without twins, shaders that pick a buffer by a computed heap index read the
title's slot in place. `make_twinned()` still makes the slot itself raw when
the view can be represented raw (`raw_window`), so not every case is broken.
The suspected gap is for constant-buffer views and views that cannot be made
raw: a computed-index raw read can return zeros instead of the buffer bytes.
This is a correctness risk that needs a targeted test, not a confirmed defect.

**Reproduction**

Construct a compute shader that picks a structured buffer by a non-uniform heap
index and reads it as `ByteAddressBuffer`; run on NVIDIA and compare with the
AMD result. Or run the existing `raw_loads_past_views`-style test on NVIDIA.

**Proposed fix**

A compact raw-twin scheme that fits in 1,000,000 views, or a shader-side
address table instead of descriptor twins.

**Regression risks**

- More indirection in hot shaders.
- Descriptor heap pressure.

---

### 3.2 Suspected problems (need measurement on RTX 2060)

| ID | Suspicion | Evidence | Why suspected, not confirmed |
|---|---|---|---|
| S-01 | CPU submission preparation remains above 33 ms even on a fast CPU | `docs/findings.md:10-13` measures 48 ms preparing thread on i9-12900K | Different CPU; no RTX 2060 measurement |
| S-02 | Pipeline creation stalls become worse on Turing | `docs/findings.md` pipeline stalls; `pipeline/host.rs` uses serial `CreatePipelineState`; `host.rs:1025-1042` documents driver background compilation | No NVIDIA timing data |
| S-03 | Descriptor mirroring cost scales with 400k slots/frame | `descriptor/host.rs:3240+` mirror path; `docs/findings.md` 400,000 slots, 40,000 mirrored | RTX 2060 CPU unknown; scene-dependent |
| S-04 | `mapped()`/`resident()` synchronous waits per allocation hurt | `host.rs:257-360` submits a copy and waits for mapping/residency | Cost per allocation on NVIDIA unmeasured |
| S-05 | 6 GB causes driver eviction rather than clean refusal | `resource.rs` budgets; `video_memory()` logs shared segment | Requires a 6 GB card trace |
| S-06 | Shader cache key may not cover all host capabilities | `lower.rs:1516-1519` `host_settings()` covers wave, view limit, raw views, RDNA float; no vendor/format/atomic caps | A cached translation could be reused across hosts with different caps; needs review |
| S-07 | `D3D12_HEAP_TYPE_GPU_UPLOAD` is unavailable on RTX 20 (no ReBAR) | `host.rs:9801-9815` probes OPTIONS16 | Fallback exists; performance impact unmeasured |
| S-08 | Long shader/pipeline work can trip the Windows TDR watchdog | `tdr.rs` exists; `docs/findings.md` mentions frames >200 ms during pipeline creation | No 2060 run |

### 3.3 Already implemented functionality relevant to NVIDIA

These are strengths, not gaps:

| Area | Evidence | Status |
|---|---|---|
| Host wave width probed from D3D12 | `host.rs:1046-1055` | Implemented |
| Wave64 compute split into 32-lane halves where legal | `lower.rs:1852-1890`; tests in `wave64_tests.rs` | Implemented, with explicit refusal cases |
| Mesh shader support gated on SM 6.6 + mesh tier | `host.rs:4116-4146`; `pipeline/host.rs:449` | Implemented |
| NVIDIA format stand-ins (B5G5R5A1, B4G4R4A4, R9G9B9E5) | `resource.rs:260-309` | Implemented |
| View-index clamping to a null slot | `shader.rs:150-180`; `descriptor/host.rs:1544-1600` | Implemented |
| Raw views for structured buffers at the title's slot | `descriptor/host.rs:3740-3812` | Implemented |
| NVIDIA shader math workarounds (`f32tof16` rounding, `fcmp uno`, cube axes, lane numbering) | `lower.rs:1488`, `4335`, `4407`, `4643`, `8643` | Implemented (some opt-in) |
| Descriptor heap limit probe and fallback | `descriptor/host.rs:1557-1600` | Implemented |
| Texture read-back for CPU-sampled shader writes | `docs/findings.md`; `texback.rs` | Implemented |
| Persistent shader cache + pipeline warm | `shader_cache.rs`; `apps/victory/src/warm.rs` | Implemented |
| Async submission / thin lists / relay | `queue/behind.rs`, `list.rs`, `host.rs` | Implemented, opt-in/default mix |

### 3.4 Hardware limitations (cannot be fixed in software)

| Limit | RTX 2060 | Consequence |
|---|---|---|
| VRAM | 6 GB GDDR6 | Title's Series X texture/render-target working set exceeds it; eviction or refusal |
| Memory bus | 192-bit, 336 GB/s | Far below RX 7900 XTX (~960 GB/s); texture/bandwidth-heavy scenes are GPU-bound |
| PCIe | 3.0 x16 (~16 GB/s) | Host↔device copies (mirrors, uploads, readback) cost roughly 2× a PCIe 4.0 link |
| ReBAR | Not supported on RTX 20 series | `D3D12_HEAP_TYPE_GPU_UPLOAD` unavailable; CPU-mapped card memory fallback |
| Wave width | 32 lanes | Console wave64 programs need splitting/emulation |
| Shader model | SM 6.6 via driver, not in-box Win10 | Needs Agility SDK on Windows 10 |
| Mesh shaders | Tier 1, SM 6.5+ | Supported; no compute fallback needed |
| Ray tracing | DXR 1.1 hardware | **Unused** by the current design (title RT is translated compute) |
| System RAM | 16 GB target | Below the measured 35 GB working set |

### 3.5 Missing functionality

| Missing item | Evidence | Needed for RTX 2060? |
|---|---|---|
| Agility SDK loading | no matches in tree | **Yes on Windows 10** |
| 6 GB / 16 GB memory profile | `README.md:33`; constants in `resource.rs` | **Yes** |
| Texture mip/quality drop | upstream PR #737; no local switch | Strongly recommended |
| Mesh cross-lane emulation | `lower.rs:5105-5110` | Only if a mesh shader needs it |
| NVIDIA descriptor decoder (diagnostics) | `book.rs:20` | No (diagnostics) |
| Native NVAPI/DLSS/DXR use | not present | No (optional) |
| Device slots `0x1c8`, `0x218` | `device.rs:355-405` | Unknown; currently silently skipped |

## 4. Highest-priority blockers, in order

1. **F-01 Windows 10 Agility SDK** — without it, nothing draws on the stated
   Windows 10 target. This is the smallest, highest-leverage change.
2. **F-02/F-03 16 GB / 6 GB memory mode** — without it, the world either fails
   to load or runs from shared memory at a few frames per second.
3. **F-04 descriptor heap cap** — fixes silent descriptor loss and possible
   device hangs on NVIDIA.
4. **F-05 indirect dispatch truncation** — fixes a visible rendering defect.
5. **F-06 64-bit atomic capability gating** — prevents opaque pipeline
   failures; cheap to add.
6. **Performance work (S-01..S-05)** — only meaningful after 1–5.

## 5. What would change this verdict

- A 16 GB machine successfully completing world load with a measured peak
  private working set below ~14 GB.
- A 6 GB card running the world without `E_OUTOFMEMORY` or sustained shared-
  memory thrash after budget scaling.
- A Windows 10 run with the Agility runtime showing root signatures accepted
  and draws > 0.
- A run showing that the title's highest descriptor slot stays below 737,855
  in all scenes.
- A 1440p tile-list capture showing no missing bottom tiles with the 65,535
  clamp.

Until those are measured, the audit's position is: **Windows 11 + RTX 2060 is
plausible with memory work; Windows 10 + 16 GB is not viable on the current
tree.**

## 6. Reproduction and verification caveats

No finding in this report was reproduced on NVIDIA hardware. The reproduction
steps are written for the target machine and should be executed in this order:

1. Log the host adapter, driver, Windows build, SM, mesh tier, wave lanes and
   OPTIONS9/OPTIONS11 (the code already logs most of these).
2. Run `victory translate --validate --pipelines` on the user's shader corpus.
3. Run menus only, then world load, then a dense street scene.
4. Capture the frame line, memory line and any device-removal data.

Do not treat a successful offline `victory translate` as a gameplay pass. It
only proves shader translation and host pipeline creation; it does not exercise
the title's runtime, memory pressure or frame loop.
