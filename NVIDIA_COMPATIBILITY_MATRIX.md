# NVIDIA Compatibility Matrix — RTX 2060 (Turing)

Companion to `AUDIT_REPORT.md`. Every row states the requirement, what the
RTX 2060 provides, what the code does, and the resulting status.

Status legend:

- **OK** — implemented and expected to work on RTX 2060.
- **OK\*** — implemented, but gated by a capability or an opt-in switch; verify.
- **RISK** — works in some cases, known correctness/performance defect.
- **BLOCKER** — will not work on the stated target without a code change.
- **N/A** — feature not used by this design.

## 1. Target hardware baseline

| Property | RTX 2060 (TU106) | Source / note |
|---|---|---|
| Architecture | Turing, compute capability 7.5 | NVIDIA Turing specification |
| Shader model | SM 6.6 with current drivers; Windows 11 in-box, Windows 10 needs Agility SDK | Microsoft `D3D_SHADER_MODEL` docs; upstream #1612 |
| Feature level | 12_2 (DX12 Ultimate) | NVIDIA RTX 20 series specification |
| Wave/warp width | 32 lanes | D3D12 `WaveLaneCountMin/Max` = 32/32 |
| Mesh shaders | Tier 1 (SM 6.5+) | Turing supports DX12 Ultimate mesh shading |
| Ray tracing | DXR 1.1 hardware | Turing RT cores; unused by this design |
| Resource binding tier | 3 | Turing whitepaper; 1,000,000 shader-visible views |
| Tiled resources | Tier 3 (reserved resources supported) | Turing / D3D12 tier table |
| Max samplers in heap | 2,048 | D3D12 invariant |
| VRAM | 6 GB GDDR6, 192-bit, 336 GB/s | NVIDIA specification |
| PCIe | 3.0 x16 (~15.75 GB/s) | NVIDIA specification |
| Resizable BAR | Not on RTX 20 series | NVIDIA/board vendor documentation |
| Max 2D texture | 16,384 × 16,384 | D3D12/Turing limits |

## 2. Feature matrix

### 2.1 D3D12 runtime and shader model

| # | Feature | Requirement | RTX 2060 | Code behaviour | Status |
|---|---|---|---|---|---|
| 1 | Shader Model 6.6 | D3D12 runtime + driver | Yes (driver 471.41+; Win11 in-box; Win10 Agility) | Translates to SM 6.6 (`emit/mod.rs:1-6`) | **OK\*** on Win11, **BLOCKER** on Win10 |
| 2 | Agility SDK runtime | App-local `D3D12Core.dll` + `D3D12SDKVersion`/`D3D12SDKPath` on Win10 | Not shipped by this tree | No loader anywhere | **BLOCKER** (Win10 only) |
| 3 | Directly-indexed descriptor heaps | SM 6.6 dynamic resources | Yes | Root flags set unconditionally (`pipeline/host.rs:1042-1043`) | **OK** on Win11 / with Agility |
| 4 | `ResourceDescriptorHeap[]` / `SamplerDescriptorHeap[]` | SM 6.6 | Yes | Used for all title descriptors (`shader.rs:155-180`) | **OK\*** |
| 5 | `WaveSize` attribute | SM 6.6, optional per stage | Supported for compute; **not allowed for mesh** in SM 6.6 | Compute cross-lane programs declare `WaveSize(32)`; mesh refuses cross-lane (`lower.rs:5106`) | **OK** for compute, **RISK** for mesh |
| 6 | `D3D12_OPTIONS19` query | Agility SDK 1.7xx or newer runtime | Not on older runtimes | Query failure treated as "feature off" (`pipeline/host.rs:458-470`) | **OK\*** |

### 2.2 Mesh and compute

| # | Feature | Requirement | RTX 2060 | Code behaviour | Status |
|---|---|---|---|---|---|
| 7 | Mesh shaders | `D3D12_OPTIONS7.MeshShaderTier != NOT_SUPPORTED`, SM 6.6 | Tier 1 | `mesh_shaders()` requires both (`host.rs:4116-4146`); mesh pipeline refused otherwise (`pipeline/host.rs:449`) | **OK** |
| 8 | Mesh output limits | 256 vertices, 256 primitives, 32 KiB | Same class of limits | Clamps maxima to lane count and 32 KiB (`lower.rs:5186-5215`) | **OK** |
| 9 | Mesh cross-lane intrinsics | Not expressible with `WaveSize` in mesh | 32-lane host waves | Refused (`lower.rs:5105-5110`) | **RISK** (latent) |
| 10 | Compute shaders | SM 6.0+ | Yes | Translated with console group size; wave size declared when needed | **OK** |
| 11 | Compute derivatives / quad ops | SM 6.6 optional capability | Turing? Must query | Emitted for pixel/compute where used; no `OPTIONS9.Derivatives...` query | **RISK** (capability unverified) |
| 12 | 64-bit integer ops | `OPTIONS1.Int64ShaderOps` | Turing supports 64-bit integer shader ops | Used; no query | **OK\*** |
| 13 | 64-bit atomics on typed resources | `OPTIONS9.AtomicInt64OnTypedResourceSupported` (optional) | Unverified | Emitted unconditionally (`lower.rs:11508-11547`) | **RISK / possible BLOCKER** |
| 14 | 64-bit atomics on descriptor-heap resources | `OPTIONS11.AtomicInt64OnDescriptorHeapResourceSupported` (optional) | Unverified | Emitted unconditionally | **RISK / possible BLOCKER** |

### 2.3 Waves and lane operations

| # | Feature | Requirement | RTX 2060 | Code behaviour | Status |
|---|---|---|---|---|---|
| 15 | Wave32 | Native | Yes | Host width probed (`host.rs:1046-1055`) | **OK** |
| 16 | Wave64 console programs | Emulate on 32-lane host | No native wave64 | Split into two 32-lane host waves where cross-lane traffic stays within halves (`lower.rs:1852-1890`) | **OK** for legal programs |
| 17 | Wave64 crossing halves (`v_mbcnt`, `v_readlane`, `ds_permute`, masks as data) | Needs 64-lane wave or emulation | 32 lanes | Refused, or LDS split with barriers where every lane reaches them (`lower.rs:1867-1890`) | **RISK** |
| 18 | DPP rows / `ds_swizzle` / `v_permlane16` | Confined to 32-lane halves | 32 lanes | Handled within halves | **OK** |
| 19 | LDS/shared memory | Group shared, barriers | Yes | Emitted as DXIL groupshared; barriers inserted when split (`lower.rs:1069-1170`) | **OK\*** |
| 20 | Quad/helper-lane reads | Pixel quad model | NVIDIA helper lanes differ from AMD | Quad reads used; AMD-specific zero-helper assumption documented (`lower.rs:5323`) | **OK\*** |

### 2.4 Descriptors, root signatures and bindings

| # | Feature | Requirement | RTX 2060 | Code behaviour | Status |
|---|---|---|---|---|---|
| 21 | Shader-visible view heap | 1,000,000 max on NVIDIA | 1,000,000 | `PORTABLE_VIEWS` + dynamic carve-out leaves 737,855 title slots (`descriptor/host.rs:1522,1683-1690`) | **RISK** (high) |
| 22 | Sampler heap | 2,048 | 2,048 | Uses 2,048, reserves 2,047 as null (`descriptor/host.rs:1651-1666`) | **OK** |
| 23 | Root signature flags | Directly indexed heaps | Yes | Set unconditionally | **OK\*** |
| 24 | Root signature size/cost | 64 DWORD | Yes | User data is root constants per stage; no explicit cap in code | **RISK** if user data > ~60 DWORDs |
| 25 | Root descriptors (CBV/SRV/UAV) | Supported | Yes | Used for the title's root views; some become one-view tables (`pipeline/host.rs:520-545`) | **OK** |
| 26 | Raw twins for picked buffers | 4,194,304-view heap | Not available (1M cap) | Twins disabled on NVIDIA (`descriptor/host.rs:1544-1600`) | **RISK** (suspected correctness) |
| 27 | Structured buffer raw reads | Raw view must start 16-byte aligned, whole dwords | NVIDIA raw-through-structured reads are wrong | Slot itself is made raw when possible (`descriptor/host.rs:3740-3812`) | **OK\*** |
| 28 | Constant buffer views | 256-byte alignment | NVIDIA requires it | Checked; warns and refuses unaligned (`descriptor/host.rs:4310-4325`) | **OK** |
| 29 | Descriptor heap cap warning | — | — | Logs once (`descriptor/host.rs:1689`) | **OK** (diagnostic) |

### 2.5 Command submission and GPU work

| # | Feature | Requirement | RTX 2060 | Code behaviour | Status |
|---|---|---|---|---|---|
| 30 | Indirect draw/dispatch | `ExecuteIndirect` | Yes | Custom clamp/batch compute path | **OK** |
| 31 | Indirect dispatch >65,535 groups | Hardware/driver limit | 65,535 per dimension | Non-AMD clamped to 65,535 (`indirect.rs:279-282`); title asks 67,440 | **RISK / confirmed image defect** |
| 32 | Indirect mesh dispatch | `DispatchMesh` indirect | Supported | Budget/clamp path; `DispatchMesh(x,1,1)` | **OK\*** |
| 33 | GPU synchronization | Fences, queue signals | Yes | Fence ring, async submit thread, relay (`queue/behind.rs`) | **OK\*** |
| 34 | Resource barriers | Explicit states | Yes | Translated from console states; `legal_state()` filters forbidden bits (`host.rs:9636-9660`) | **OK** |
| 35 | Enhanced barriers | Not required | Not used | Legacy `ResourceBarrier` | **OK** |
| 36 | Command lists per frame | Many, multi-threaded | Driver handles | Lists recorded by title threads, prepared on worker | **OK\*** |
| 37 | TDR/watchdog | Default 2 s | Same | `tdr.rs` logs; long pipeline creation can exceed it | **RISK** |

### 2.6 Formats, textures and memory

| # | Feature | Requirement | RTX 2060 | Code behaviour | Status |
|---|---|---|---|---|---|
| 38 | B5G5R5A1 / B4G4R4A4 render targets | Not supported for RT/UAV on NVIDIA | Refused | 8-bit RGBA stand-in (`resource.rs:260-309`) | **OK** (implemented) |
| 39 | R9G9B9E5 render target | Not supported by PC GPUs | Refused | RGBA16F stand-in (`resource.rs:260-309`) | **OK** (implemented) |
| 40 | Typed UAV load of more formats | `OPTIONS.TypedUAVLoadAdditionalFormats` | Turing supports | Assumed/used | **OK** |
| 41 | Rasterizer-ordered views | `OPTIONS.ROVsSupported` | Turing supports | Emitted for ordered UAV sections | **OK** |
| 42 | Conservative rasterization | Tier 3 | Turing supports | Reported to title; used only if title asks | **OK** |
| 43 | Tiled/reserved resources | Tier 2+ for levels-on-demand | Turing tier 3 | `VICTORY_LEVELS_ON_DEMAND` opt-in; checks tier (`tiles.rs:87-96`) | **OK\*** |
| 44 | Sparse/tile mappings into custom heaps | Refused by D3D12 | Refused | `inplace.rs` warns "never call them" | **OK** (guarded) |
| 45 | `D3D12_HEAP_TYPE_GPU_UPLOAD` | OPTIONS16, ReBAR | Not on RTX 20 | Probed; falls back to shared buffer (`host.rs:9801-9815`) | **OK** (perf cost) |
| 46 | Max texture size | 16,384 | 16,384 | Console textures within limit | **OK** |
| 47 | Texture residency | 6 GB | 6 GB | Budgets sized for 24 GB (`resource.rs:1707-1783`) | **BLOCKER** |

### 2.7 Ray tracing

| # | Feature | Requirement | RTX 2060 | Code behaviour | Status |
|---|---|---|---|---|---|
| 48 | DXR acceleration structures | DXR 1.1 | Yes | **Not used**; the title's BVH builder is translated compute (`pipeline.rs:265`, `memory.rs`) | **N/A** |
| 49 | RTX hardware ray tracing | RT cores | Yes | Unused; `-RayTracing` runs the title's compute light path | **N/A** (perf disadvantage) |
| 50 | `VICTORY_BVH_BUILDER=1` | Compute + memory | Yes | Off by default; opt-in, quarantined (`pipeline.rs:304-341`) | **OK\*** |

## 3. What the code gets right on NVIDIA

These were verified in source and should not be re-litigated:

1. **Wave width is not hard-coded to 64.** `Host::new` reads
   `D3D12_FEATURE_DATA_D3D12_OPTIONS1` and calls `set_host_max_wave`
   (`host.rs:1046-1055`).
2. **Mesh is not assumed present.** `mesh_shaders()` checks both OPTIONS7 and
   SM 6.6 (`host.rs:4116-4146`), and `HostPipeline::new` refuses a mesh
   pipeline with a specific message (`pipeline/host.rs:449`).
3. **NVIDIA's 1M descriptor cap is probed, not assumed.** `probe_view_limit()`
   tries 2^21 and 2^22 heaps (`descriptor/host.rs:1557-1600`).
4. **NVIDIA format refusals are already handled** with stand-ins
   (`resource.rs:260-309`).
5. **NVIDIA shader math differences are documented and partly handled**:
   `f32tof16` rounding (`lower.rs:1488,4335`), `fcmp uno` (`lower.rs:4407`),
   non-consecutive lane numbering (`lower.rs:4643`), cube axes
   (`lower.rs:8643`).
6. **Raw structured views are made raw where the host allows** to avoid
   NVIDIA's zero-returning structured-through-raw read
   (`descriptor/host.rs:3740-3812`).
7. **Adapter selection can be forced** with `VICTORY_D3D12_ADAPTER`, and
   offline translation records the host wave width
   (`apps/victory/src/main.rs:215-224`).

## 4. External NVIDIA work compared (not blindly copied)

The checkout has no Git history, so this compares the current tree against
public upstream reports. These are **external** and must not be assumed present
or correct for this fork.

| Upstream item | What it addresses | Present in this tree? | Relevance to RTX 2060 |
|---|---|---|---|
| Marvisak/VIctory #175 — load D3D12 Agility SDK on Windows 10 | SM 6.6 / directly-indexed root signatures | **No** (`Agility`/`D3D12Core` absent) | **Critical** on Windows 10 |
| Marvisak/VIctory #961 — mesh compute fallback | GPUs without mesh shaders (GTX 10, Polaris) | **No** (`MESH_FALLBACK` absent) | **Not needed** for RTX 2060 (Turing has mesh) |
| Marvisak/VIctory #189 — wave64 emulation on wave32 | 64-lane console compute | Partially: this fork has its own split-wave implementation (`lower.rs:1852-1890`) | **Relevant**; do not blindly replace |
| Marvisak/VIctory #940 — mesh lane numbering | 64-lane mesh programs on NVIDIA | This fork maps mesh thread IDs itself (`lower.rs:5256-5275`), but refuses cross-lane ops | **Relevant**; compare behaviour |
| Marvisak/VIctory #737 — texture mip drop for 6–8 GB | VRAM pressure | **No** (`TEXTURE_MIP_DROP` absent) | **High** value |
| Marvisak/VIctory #193 — raw reads through structured views / stride table | NVIDIA zero reads | Raw-view workaround present (`descriptor/host.rs:3740`); runtime stride table partly present | **Relevant** |
| Marvisak/VIctory #336 — 2^18 dynamic slots | Dynamic table exhaustion | Present (`descriptor/host.rs:1606`) | Interacts with the 1M cap (F-04) |
| Marvisak/VIctory #1133 — heap view cap handling | 1M cap / clamp past heap | **Not present** as described; this fork has its own clamp | **Directly relevant** to F-04 |
| Marvisak/VIctory #1612 / #1305 reports | Windows 10, 6–8 GB, NVIDIA hangs | External evidence | Confirms the failure modes above |

**Conclusion of comparison:** the missing Agility path and the lack of a
low-VRAM mode are the two upstream fixes with the clearest RTX 2060 payoff.
The wave64 and mesh work should be treated as *reference implementations to
compare against*, not copied, because this fork's IR and lane model differ.

## 5. Compatibility verdict by scenario

| Scenario | Menus | World load | Sustained gameplay |
|---|---|---|---|
| Windows 11, RTX 2060, 16 GB, current tree | Likely | Likely fails (RAM/VRAM) | No |
| Windows 11, RTX 2060, 32 GB, current tree | Likely | Possible with paging | Not 30 fps at 1440p; 1080p unproven |
| Windows 10, RTX 2060, 16 GB, current tree | **No draws** (SM 6.5) | No | No |
| Windows 10 + Agility, RTX 2060, 32 GB | Yes | Possible | Needs F-02..F-06 |
| Windows 11 + Agility, RTX 2060, 32 GB, F-02..F-06 fixed | Yes | Plausible | Target of the roadmap |

No row in this table is a tested gameplay result. They are engineering
assessments from the source and external reports.
