# RTX 2060 Hardware Report

Target: NVIDIA GeForce RTX 2060 6 GB (TU106, Turing), 16 GB system RAM,
Windows 10/11 x64, x86-64 with AVX2.

This report is an engineering assessment. No RTX 2060 measurement was made in
this audit.

## 1. Hardware profile

| Property | Value | Consequence for VIctory |
|---|---|---|
| GPU | TU106, Turing, compute capability 7.5 | SM 6.6 capable with current drivers |
| CUDA cores | 1,920 | About one tenth of an RX 7900 XTX's FP32 throughput |
| FP32 | ~6.5 TFLOP/s | Translated compute work (culling, BVH, lighting) is expensive |
| RT cores | 30 (first generation) | **Unused**: this layer does not use DXR |
| Tensor cores | 240 | **Unused**: no DLSS integration |
| VRAM | 6 GB GDDR6 | Below the title's Series X working set |
| Memory bus | 192-bit, 336 GB/s | Roughly one third of the validated card's bandwidth |
| PCIe | 3.0 x16, ~15.75 GB/s | Host↔device mirrors and uploads are roughly 2× slower than PCIe 4.0 |
| Resizable BAR | Not supported on RTX 20 series | `D3D12_HEAP_TYPE_GPU_UPLOAD` unavailable; CPU-mapped card memory falls back |
| Max power | ~160 W | Not a constraint for correctness |
| Display outputs | 1× HDMI 2.0b, 3× DP 1.4 | 1440p and 4K output are possible, but not at the target frame rate |

## 2. Feature support vs. what the layer requires

| Requirement | RTX 2060 | Layer requirement | Evidence in tree |
|---|---|---|---|
| D3D12 feature level | 12_2 | 12_0 device creation | `emit/host.rs:107-116` |
| Shader Model | 6.6 (driver-dependent) | SM 6.6 | `emit/mod.rs:1-6` |
| Windows 10 runtime | In-box SM 6.5 only | SM 6.6 + Agility | no Agility path in tree |
| Windows 11 runtime | In-box SM 6.6 | SM 6.6 | — |
| Mesh shaders | Tier 1 | Required for mesh pipelines | `host.rs:4116-4146` |
| Wave width | 32 | 32/64 handled | `host.rs:1046-1055` |
| Descriptor heap | 1,000,000 views | Layer assumes up to 2,097,152 on AMD | `descriptor/host.rs:1522-1528` |
| Tiled resources | Tier 3 | Tier 2+ for levels-on-demand | `tiles.rs:87-96` |
| 64-bit typed atomics | Must be queried | Emitted unconditionally | `lower.rs:11508-11547` |
| DXR | 1.1 | Not used | title RT is compute |
| AVX2 | Yes on any CPU that pairs with this GPU | Used for compares/copies | `safecopy.rs`, `shadow.rs` |

## 3. The two hard walls

### 3.1 6 GB of VRAM

The title is told it has a Series X GPU budget of 10 GiB + 3.5 GiB
(`console.rs:24`, `dxgi.rs:152-164`). The host budgets are sized for a 24 GB
card:

- texture admission floor: up to 2 GiB, capped at VRAM/4 ≈ 1.4 GiB on 6 GB
  (`resource.rs:1707-1712`);
- render-target reserve: 3,072 MiB by default (`resource.rs:1778-1781`);
- card buffer-copy reserve: up to 1 GiB (`shadow.rs:255-300`);
- texture pool spares: up to 64 × 64 MiB = 4 GiB when the card has room
  (`pool.rs:30-34`).

On a 6 GB budget, the 3 GiB target reserve plus 1.4 GiB texture floor plus
normal render targets and buffers exceed the card before streaming textures are
considered. The likely outcomes, in order, are:

1. `E_OUTOFMEMORY` from resource creation;
2. the driver moving resources to shared system memory (very slow);
3. textures refused or evicted, producing placeholders/pop-in.

Upstream evidence agrees: issue #1612 section 5 states the world needs more
video memory than many 8 GB cards have; issue #1086 needed nine stacked changes
to run on a 12 GB card.

### 3.2 16 GB of system RAM

`README.md:33` documents ~35 GB of private memory on the validated 64 GB
machine. `docs/findings.md:96` breaks it down as lists' allocators 9 GB,
windows 7 GB, uploads 4 GB, with the rest in host buffer/texture copies and
staging. These are by design, not leaks:

- every host buffer a draw reads has a persistent shadow (`shadow.rs:1-20`);
- texture staging is pooled in 64 MiB blocks (`pool.rs`);
- address-based memory keeps up to 3 GiB of 64 KiB pages (`memory.rs:84-88`);
- upload arenas and list allocators are retained (`upload.rs`, `list.rs`).

A 16 GB machine will page heavily or fail allocation during world load. The
in-tree low-memory mode (`VICTORY_RESIDENCY=1`, `residency.rs:4-22`) is off by
default and only reacts below 3 GiB free RAM / 4 GiB commit — far too late for
a 16 GB system under this load.

## 4. Performance expectation (analytical, not measured)

The validated RX 7900 XTX run is ~53 ms/frame in a city street, with the card
busy ~41 ms and the CPU preparation thread ~48 ms (`README.md:27`,
`docs/findings.md:10-13`).

The RTX 2060 is roughly one third to one half of the 7900 XTX in memory
bandwidth and far below it in compute. For this workload, which is dominated by
memory traffic, copies and translated compute rather than fixed-function
raster, a 2–4× slowdown of the card-side work is a reasonable planning range.
That puts a 1440p frame at roughly 80–160 ms (6–12 fps) **before** VRAM
thrashing. At 1080p the pixel work falls by ~44%, but CPU preparation, copies
and the title's simulation remain; 15–25 fps is a plausible optimistic range
on a fast CPU, and 30 fps is unlikely without substantial renderer work.

These are estimates. The audit does not claim a measured RTX 2060 frame rate.

## 5. CPU side

The layer's frame cost is not only GPU. On the validated i9-12900K the
submission-preparation thread alone takes 48 ms, above the 33 ms needed for
30 fps (`docs/findings.md:10-13`). A typical RTX 2060 pairing (Ryzen 5 2600 /
i5-9400F class) has lower single-thread performance and fewer cores than the
i9, so CPU preparation is likely to remain a wall even at 1080p. AVX2 is
present on all plausible pairings, so the vectorised compares work, but the
descriptor mirroring, write-watch and landing work still scale with the scene.

## 6. Recommended target configuration (for testing, not implementation)

| Setting | Recommendation | Reason |
|---|---|---|
| OS | **Windows 11** for the first NVIDIA bring-up | Avoids the Agility SDK blocker; SM 6.6 is in-box |
| Windows 10 | Only with an Agility SDK build | In-box D3D12 stops at SM 6.5 |
| Driver | Current NVIDIA Game Ready / Studio | SM 6.6 and bug fixes |
| Resolution | 1920×1080 first, then 1440p | 6 GB VRAM and bandwidth |
| Console profile | Try Series S after Series X | Smaller texture budget; changes title behaviour |
| Ray tracing | Off | RT cores unused; ~1/3 slower per docs |
| Page file | Large fixed page file (32 GB+) | 16 GB RAM cannot hold the working set |
| Shader warm-up | Run `victory shaders` and `victory warm --used` before play | Avoids driver pipeline stalls |
| Adapter selection | `VICTORY_D3D12_ADAPTER=NVIDIA` on hybrid systems | Prevents choosing an iGPU |

## 7. What is genuinely good news for Turing

- Mesh shaders exist on RTX 2060, so the missing compute fallback in this tree
  is **not** required.
- SM 6.6 is supported by Turing drivers, so the shader model itself is not the
  problem on Windows 11.
- The layer already probes wave width and handles 32-lane hosts.
- The layer already handles NVIDIA's refusal of B5G5R5A1/B4G4R4A4/R9G9B9E5
  render targets.
- Descriptor heap capping and null-slot clamping exist, even if the arithmetic
  needs correction for NVIDIA.

## 8. Bottom line

The RTX 2060 is **feature-compatible** with the translated shader model and
mesh pipeline on Windows 11. It is **not capacity-compatible** with the
current memory design, and it is **not runtime-compatible** with Windows 10
without the Agility SDK. The 6 GB card and 16 GB system are the limiting
resources, not the GPU's feature set.
