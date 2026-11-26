# Memory Analysis — 16 GB RAM / 6 GB VRAM

Companion to `AUDIT_REPORT.md`. This is a static source/code audit plus the
project's own measurements. No allocation was profiled on the target machine.

## 1. Why the layer uses so much memory

The console has one unified memory. The PC does not. The layer's central
strategy is therefore to keep a **host-side copy** of the title memory that the
GPU reads, and to keep a **CPU-side snapshot** of the memory the GPU writes:

```text
title memory (CPU)  ──copy──►  host buffer/texture (VRAM or shared)
        ▲                              │
        └────── copy back ─────────────┘
```

This is a porting design, not an emulator design, but it means peak memory is
the sum of title memory, host mirrors, staging, descriptor heaps, command
allocators and caches. `README.md:33` records the measured result: **~35 GB of
private memory** on the validated 64 GB machine.

## 2. Largest allocators

| Allocator | Location | Sizing | Essential? |
|---|---|---|---|
| Title memory mirrors (buffers) | `shadow.rs:1-20`, `Shadow` struct | One host buffer per title buffer a draw reads, full buffer size | Mostly; can be evicted/compressed |
| Host textures | `resource.rs` `hosted()`, `Host` in `texture.rs` | One host texture per title texture used, all mips/array slices | Mostly; levels-on-demand can reduce |
| Texture/staging pool | `pool.rs:30-37` | 64 MiB blocks; up to 64 spare texture blocks (4 GiB) and 8 staging blocks | Block size is a trade-off; spare counts are tunable |
| Address-memory page pool | `memory.rs:80-90` | 64 MiB arenas; up to 3 GiB of 64 KiB pages | Only for address-based shader access; could be capped |
| Descriptor heaps | `descriptor/host.rs:1625-1700` | 1,000,000 views × 32 B ≈ 32 MB per view heap, plus sampler heap (2,048 × 32 B), plus dynamic/raw twins | Essential, but the 1M cap is NV-specific |
| Command allocators/lists | `host.rs:1278-1340`; `list.rs` | One pair per list, plus preludes; retained until reset | Essential; count can be bounded |
| List scratch | `host.rs:1971-1975` | 4 MiB chunks (first 256 KiB), one set per list | Essential for submissions; pooling helps |
| Upload arenas | `upload.rs:1-40` | 4 MiB arenas cut into 64 KiB blocks | Essential for address-based uploads |
| Windows of title memory | `shadow.rs` (`window_card_for`) | 4 MiB windows of title memory, cached | Necessary for non-buffer pages; can be evicted |
| Shader/pipeline caches | `shader_cache.rs`, `apps/victory/src/warm.rs` | On disk, not private RAM | Not a RAM cost |
| Indirect budgets/batches | `indirect.rs`, `indirect/batch.rs` | Small (256 B budgets, batch buffers) | Essential |

## 3. Measured breakdown (validated machine)

From `docs/findings.md:96`:

| Consumer | Bytes |
|---|---|
| Lists' allocators | ~9 GB |
| Windows of title memory | ~7 GB |
| Uploads | ~4 GB |
| Everything else (host buffers, textures, heaps, staging, process) | remainder of 40–46 GB private |

The README's 35 GB figure and the findings' 40–46 GB figure are different runs
and scenes; treat the range as 35–46 GB. **This is not a leak.** The code
retains memory deliberately:

- `keep_freed()` keeps empty blocks and freed card memory while there is room
  (`host.rs:385-405`);
- `pool.rs` keeps up to 64 spare texture blocks when the card is below 85% use;
- `memory.rs` keeps pages "for the rest of the run" where it cannot prove they
  are gone (documented shortcut);
- `shadow.rs` keeps a buffer's copy for the buffer's lifetime.

The project itself says the figure is private memory, not leaked memory, and
the audit agrees: the design is capacity-hungry by construction.

## 4. Is 16 GB feasible?

### 4.1 RAM budget arithmetic

A 16 GB Windows machine has roughly 13–14 GB of usable commit after the OS,
driver and background processes. The title's own data plus the layer's mirrors
must fit in that. The validated run needs 35–46 GB. Even if every cache were
evicted perfectly, the essential mirrors of title buffers and textures alone
are in the tens of GB on the Series X profile.

Therefore **16 GB is not a tuning problem; it is a design gap.** A 16 GB mode
would need at least:

1. A smaller title profile (Series S textures and render targets).
2. Demand-paged mirrors: only the pages a submission reads, evicted after use.
3. A hard cap on address-memory pages (currently 3 GiB).
4. Much smaller list allocator retention (currently ~9 GB).
5. No 4 GiB texture pool spare reserve.
6. Aggressive eviction of idle host textures and staging blocks.

Items 2 and 4 are architectural. Item 3 and 5 are constants. Item 1 changes
what the title renders.

### 4.2 VRAM budget arithmetic on 6 GB

Assume DXGI reports a local budget of ~5.5–6.0 GB.

| Reservation | Default | On 6 GB |
|---|---|---|
| Texture floor (`min(2 GiB, budget/4)`) | 2 GiB | ~1.4 GiB |
| Render-target reserve (`targets_room_kept`) | 3,072 MiB | 3,072 MiB (not scaled) |
| Card buffer copies (`card_room_kept`) | up to 1 GiB | up to 1 GiB |
| Texture pool spares | up to 4 GiB if <85% used | can consume most of the card |
| Descriptor heaps | ~32 MB + samplers | ~32 MB |
| Actual textures/targets/buffers | rest | negative headroom |

The 3 GiB target reserve is over half the card on its own. With the 1 GiB
buffer reserve and 1.4 GiB texture floor, the layer can account for ~5.4 GiB
before a single world texture is admitted. In practice the code's 90% room
check and the actual usage counters interact, but the direction is clear:
**the budgets must be scaled to the real DXGI budget before a 6 GB run is
meaningful.**

## 5. Copies and duplication

### 5.1 Known duplication

| Duplication | Where | Why it exists | Possible reduction |
|---|---|---|---|
| Every title buffer has a full host mirror | `shadow.rs` | Host GPU cannot read title memory | Page-granular mirrors, eviction |
| Every title texture has a full host copy | `resource.rs` | Same | Mip/level streaming, `VICTORY_LEVELS_ON_DEMAND` |
| Constant buffers copied per submission | `port_cbv.rs`/`draw.rs` | Host needs 256-byte-aligned views | `VICTORY_PORT_CBV` reads title bytes in place (AMD-specific) |
| Texture staging buffer per upload | `texture.rs` | Detile into host layout | Pooled already; reduce re-uploads |
| GPU→CPU landing buffers | `host.rs` relay | Shader writes must reach title memory | Dword-granular already; batch more |
| `before` snapshots for written ranges | `shadow.rs` | Detect what shaders changed | Only written ranges are kept |

### 5.2 Unnecessary CPU/GPU copies (potential)

- Whole-texture re-upload on any page change: `texture.rs` documents
  "a change detiles the whole texture, not the pages written". This is a
  confirmed shortcut, not a leak. It multiplies upload traffic and staging
  memory for large textures.
- `mapped()` submits a tiny copy and waits for the queue after each new
  allocation (`host.rs:257-360`). This is a synchronisation cost more than a
  memory cost, but it also forces residency.
- Windows of title memory are retained "for the rest of the run" where the
  layer cannot prove they are gone (`memory.rs` header). This is the 7 GB
  consumer.

## 6. Memory-mapping and residency behaviour

| Mechanism | Location | Behaviour |
|---|---|---|
| Write-watch | `watch.rs` | Title writes are detected per 64 KiB page |
| Read-only guards | `watch.rs`/`inplace.rs` | Alternative detection for pages that cannot be watched |
| `MakeResident` | `host.rs:341-385` | Every new resource is made resident explicitly, then a copy is submitted and waited for |
| `SetResidencyPriority` | not used | No priority hints; the driver decides eviction |
| `Evict` | not used | The layer does not explicitly evict; it relies on release and the driver |
| `OpenExistingHeapFromAddress` | `inplace.rs` | Opt-in; locks pages into RAM, so not a 16 GB win |
| `D3D12_HEAP_TYPE_GPU_UPLOAD` | `host.rs:9801+` | Unavailable on RTX 20 (no ReBAR) |

The absence of explicit `Evict`/residency priorities is notable on a 6 GB
card: the layer can only free resources by dropping references, and the driver
may move the rest to shared memory. A low-VRAM mode should use
`ID3D12Device::Evict` and `SetResidencyPriority` deliberately.

## 7. Caches and unbounded growth

| Cache | Bound | Risk |
|---|---|---|
| Texture pool | 64 spare blocks (4 GiB) | Bound is too high for 6 GB |
| Staging pool | 8 blocks (512 MiB) | Moderate |
| Address pages | 3 GiB (49,152 pages) | Large for 16 GB |
| Freed card memory | kept while room | Can pin VRAM |
| Descriptor heap | 1M views | Fixed, ~32 MB |
| `book.rs` gone entries | 400,000 entries | Diagnostics only; can be large |
| Shader cache | on disk | Not RAM; can fill disk |
| Pipeline cache | on disk/driver | Not RAM; first-run cost |

No unbounded in-process leak was found in the audited paths. The one
"unbounded" behaviour is documented retention ("for the rest of the run") and
is a deliberate correctness trade-off.

## 8. Essential vs. optimizable

### Essential

- Host mirrors for buffers a draw reads (correctness).
- Host textures for textures a draw samples (correctness).
- Descriptor heaps (correctness).
- Command allocators/lists (correctness).
- At least one staging block per concurrent upload.

### Optimizable without changing rendering

- Scale all reserves to the actual DXGI budget.
- Lower `SPARE_KEPT`/`STAGING_KEPT` on <8 GB cards.
- Cap address pages far lower on 16 GB systems.
- Evict idle mirrors instead of retaining for the run.
- Reuse list allocators more aggressively.
- Convert whole-texture uploads to dirty-page uploads.

### Optimizable only by changing rendering

- Series S texture profile.
- Mip drop / lower texture quality (upstream PR #737 idea).
- Fewer render targets / lower resolution.
- Disabling ray-traced indirect light (already optional).

## 9. Leak assessment

**No confirmed leak.** The high private-memory figure matches the documented
design and the project's own accounting. Two things can look like leaks and are
not:

1. retained freed card memory (`keep_freed`), which is intentional to avoid
   device loss on stale descriptor reads;
2. address-memory pages retained for the run, which is a documented shortcut.

A real leak would show unbounded growth within a single scene; the project's
memory line does not report that. The audit did not run a leak detector, so
this is an assessment, not a proof.

## 10. Priorities for a 6 GB / 16 GB mode

1. Scale `targets_room_kept`, texture floor, card-buffer room and pool spares
   from the DXGI budget.
2. Add a low-VRAM texture quality mode (mip drop / Series S profile).
3. Cap address-memory pages and list allocator retention.
4. Add explicit `Evict`/residency priorities for idle host copies.
5. Make `VICTORY_RESIDENCY=1` the default below 8 GB VRAM or 16 GB RAM.
6. Measure peak private bytes and VRAM per scene on the RTX 2060 before
   changing architecture further.
