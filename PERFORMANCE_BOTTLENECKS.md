# Performance Bottlenecks

Companion to `AUDIT_REPORT.md`. Figures quoted as "measured" come from the
project's own RX 7900 XTX / i9-12900K documentation. RTX 2060 figures are
explicitly analytical estimates.

## 1. Baseline frame model

From `docs/findings.md:10-22` and `README.md:27-31`, on the validated machine:

| Component | Time | Notes |
|---|---|---|
| Frame | ~53 ms (city street) | about 19 fps |
| Submission-preparation thread | ~48 ms | "It is the wall" |
| GPU busy | ~41 ms | next wall |
| List calls | 36,000/frame, 230 ms of work over 8 threads | 67,000 calls / 430 ms in a chase |
| Descriptor slots examined | ~400,000/frame | ~40,000 mirrored |
| Shader-write landing | ~16 MB/frame | dwords, on its own thread |

A 30 fps target is 33 ms. On the validated machine **both** the preparation
thread and the GPU are already above it. This is not a GPU-only problem.

## 2. CPU submission preparation

### 2.1 Where the time goes (measured)

`docs/findings.md:14-19`:

- 18 ms: steps of the lists;
- 10 ms: refreshes of host copies;
- 7 ms: steps done on the card;
- 6 ms: waiting for descriptor records;
- 5 ms: asking the write watch;
- 4 ms: copies in card memory;
- 4 ms: title bytes under shader writes.

### 2.2 Code paths

| Cost | Code | Why it exists |
|---|---|---|
| List translation | `list.rs`, `host.rs:2914+` (`VICTORY_THIN`) | D3D12.X commands become host commands |
| Host-copy refresh | `shadow.rs` `copy_stale`, `watch.rs` | Title writes must reach the GPU |
| Descriptor records | `descriptor/host.rs:3240-3350` `mirror` | Descriptor heaps are title memory |
| Write watch | `watch.rs` | Detect title writes at page granularity |
| Landing | `land.rs`, `host.rs:2555+` (`VICTORY_RELAY`) | Shader writes must return to title memory |
| Card steps | `host/card_steps.rs` | Fills/copies done on the GPU instead of waiting |
| Submission join | `queue/behind.rs`, `host.rs:3215+` (`VICTORY_JOIN_PARTS`) | Prepare submissions off the title thread |

### 2.3 Software inefficiencies (fixable)

1. **Descriptor scanning still dominates some frames.** The code mirrors only
   changed records, but the title writes many slots. `docs/findings.md` records
   400,000 slots looked at for ~40,000 mirrored. A byte-checked write-site
   patch exists for the constants/descriptor ports, but it is opt-in.
2. **Whole-texture re-upload.** `texture.rs` documents that a change detiles
   the whole texture, not just written pages. This multiplies both CPU detile
   time and upload bandwidth.
3. **Retained allocators and windows.** The memory report covers the capacity
   side; on the CPU side, large retained structures hurt cache locality and
   increase page-fault cost.
4. **Lock contention.** `descriptor/host.rs` documents a per-slot lock added
   because one heap lock was the top wait (5.6% of recording-thread time).
   `HostHeap::mirror`, `next`, `kept` remain hot.
5. **Synchronous mapping/residency.** `host.rs:257-360` submits a copy and waits
   for every new allocation. `docs/findings.md` says a tenth of a millisecond
   to some; at thousands of allocations a frame this matters.

### 2.4 RTX 2060 projection

The RTX 2060 will usually be paired with a slower CPU than an i9-12900K. The
preparation thread's 48 ms is therefore likely to grow, not shrink. At 1080p the
GPU work falls, but CPU preparation does not. **CPU preparation is expected to
remain the frame-rate wall on the target machine even after GPU fixes.**

## 3. GPU execution

### 3.1 Measured

- ~41 ms card busy on a 24 GB RX 7900 XTX at 1440p.
- Card passes are dominated by copies, clears, translated compute (culling,
  lighting, BVH when enabled) and the title's render passes.
- The project measured that many "passes run for nothing without rays"
  (`docs/findings.md`, next steps).

### 3.2 Hardware vs software

| Bottleneck | Classification |
|---|---|
| 6 GB VRAM / 336 GB/s bandwidth | **Hardware** — cannot be fixed in software |
| PCIe 3.0 host↔device copies | **Hardware** — about half the validated link's bandwidth |
| No ReBAR / GPU-upload heap | **Hardware** — fallback costs copies |
| Translated compute instead of native RDNA | **Software design** — inherent to porting |
| Redundant passes without ray tracing | **Software** — could be skipped |
| Unnecessary blits/copies | **Software** — measurable and fixable |
| Shader occupancy/register pressure on Turing | **Hardware + compiler** — needs profiling |
| Descriptor/buffer reads through clamp shaders | **Software** — overhead added by the port |

### 3.3 RTX 2060 projection

At 1440p, the 2060 has roughly one third of the memory bandwidth and a small
fraction of the compute of the 7900 XTX. A 2–4× increase over 41 ms is a
reasonable planning range: **80–160 ms of GPU work**, before VRAM eviction.
At 1080p, pixel work drops ~44%, so **45–90 ms** is a plausible range. Neither
reaches 33 ms without reducing work (resolution, effects, passes, ray tracing
off).

These are estimates, not measurements.

## 4. Shader compilation and pipeline creation

### 4.1 Behaviour

- Translation is CPU-side and cacheable (`shader_cache.rs`).
- Driver pipeline creation is the expensive part; `victory warm` pre-creates
  `ID3D12PipelineState` objects.
- `host.rs:1025-1042` documents driver background compilation causing
  1,000–1,200 ms frames while it runs.
- `docs/findings.md` records stalls of 270–660 s per session, almost all while
  new pipelines were made, and frames >200 ms.

### 4.2 On Turing

Turing's driver compiles DXIL to SASS; this is typically slower than RDNA's
compiler for a large pipeline set. The project's own mitigation (warm cache) is
essential. A 6 GB card may also evict the driver's shader cache under memory
pressure, causing recompilation.

### 4.3 Mitigations already present

- `victory shaders` pre-translates every shader.
- `victory warm --used` pre-creates pipelines used by earlier runs.
- `VICTORY_PIPELINE_BOOK=1` records pipelines.
- Pipeline library support exists for mesh pipelines (`pipeline/library.rs`).

## 5. Descriptor management

| Cost | Evidence | Classification |
|---|---|---|
| Mirroring up to 1M slots | `descriptor/host.rs:3240+` | Software, scales with title |
| 1M cap causing null reads | F-04 | Software defect |
| 262,144 dynamic slots | `descriptor/host.rs:1606` | Software design |
| No raw twins on NVIDIA | F-11 | Software limitation |
| Heap bind/switch | `SetDescriptorHeaps` per list | Hardware/driver |
| Descriptor heap memory ~32 MB | 1M × 32 B | Minor |

Descriptor work is a CPU cost, not a GPU cost, on this design. It is a prime
target for the renderer ports (`VICTORY_PORT_DESCRIPTORS`) and for reducing
per-draw table rebuilds.

## 6. Memory transfers, texture uploads and readbacks

| Transfer | Path | Cost driver | Classification |
|---|---|---|---|
| Title buffer → host buffer | `shadow.rs`, write-watch pages | 64 KiB page granularity, AVX2 compare | Software + PCIe |
| Host buffer → title buffer | `land.rs`, relay | Shader-written dwords | Software + PCIe |
| Texture detile → staging → host texture | `texture.rs` | Whole texture on any change | Software (fixable) |
| Texture readback for CPU sampling | `texback.rs` | Needed for physics/heightmaps | Essential |
| Address-memory pages | `memory.rs` | 64 KiB pages, up to 3 GiB | Software design |
| Indirect clamp/batch buffers | `indirect/` | Small | Minor |

PCIe 3.0 on the 2060 roughly doubles the per-byte cost of the validated
machine's PCIe 4.0 link. Any optimisation that reduces bytes moved is worth
more on this target than on the 7900 XTX.

## 7. Synchronisation and worker scheduling

| Mechanism | File | Observation |
|---|---|---|
| Fence ring / frame wait | `fence.rs`, `frame.rs` | 30 fps pacing by default; title controls interval |
| Async submission | `queue/behind.rs` | Prepares/sends on our thread; needs relay |
| Join parts | `host.rs:3215+` | Spreads list parts over threads |
| Relay | `host.rs:2555+` | Lands shader writes on its own thread |
| Descriptor per-slot locks | `descriptor/host.rs` | Reduced contention, still hot |
| List scratch | `host.rs:1971-1975` | 4 MiB chunks per list |

The measured 48 ms preparation thread is the sum of these. The "join parts"
and "relay" work already moved most of it off the title thread; further gains
require reducing the work, not just moving it.

## 8. Ranked bottlenecks for RTX 2060

| Rank | Bottleneck | Type | Evidence |
|---|---|---|---|
| 1 | 6 GB VRAM / texture residency | Hardware + software budgets | F-03, `resource.rs` |
| 2 | GPU throughput at 1440p | Hardware | 2060 vs 7900 XTX |
| 3 | 16 GB RAM paging | Hardware capacity | F-02 |
| 4 | CPU submission preparation | Software | 48 ms measured |
| 5 | Pipeline creation stalls | Software/driver | `docs/findings.md` |
| 6 | Descriptor mirroring / heap cap | Software defect | F-04 |
| 7 | Whole-texture re-upload | Software | `texture.rs` |
| 8 | Indirect truncation (correctness, not speed) | Software defect | F-05 |
| 9 | PCIe 3.0 copy bandwidth | Hardware | 2060 spec |
| 10 | Redundant no-ray passes | Software | `docs/findings.md` |

## 9. What to measure before optimising

1. Frame time, CPU preparation, GPU busy, and present interval on the RTX 2060.
2. Peak private bytes and peak local/non-local VRAM per scene.
3. Number of descriptor slots mirrored vs. read per frame.
4. Bytes copied H2D and D2H per frame (including texture re-uploads).
5. Pipeline creation count and wall time during world load.
6. TDR/device-removed events.
7. Whether frames are GPU-bound or preparation-bound (the existing frame line
   distinguishes them).

Without those numbers, any optimisation on this target is speculative. The
project already has the instrumentation (`copystat`, `timeline`, `book`,
`VICTORY_PANEL`, replay); the audit recommends using it rather than adding new
counters first.
