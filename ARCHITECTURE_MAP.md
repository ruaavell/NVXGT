# VIctory Architecture Map

Audit date: 2026-11-26
Repository: `avatarmanz/VIctory-7900XTX` (local checkout; Git metadata was not
available to this host, so commit-level history could not be inspected)
Scope: read-only structural audit. No source file was modified.

## 1. What the project is

VIctory is not a conventional emulator. It runs the title's original x86-64
Windows/Xbox executable natively and replaces the console platform underneath
it: the loader maps and binds the PE image, `victory-hle` implements the Xbox
runtime services, `victory-gpu` presents a D3D12.X device and command stream to
the title on top of host D3D12, and `victory-shader` translates the console's
precompiled GFX10 shaders to DXIL. Console memory is treated as unified, so a
title GPU address is a CPU address and data is copied between title memory and
host GPU memory as needed.

The repository is a fork of Marvisak/VIctory through fxceless/victory-fork,
with renderer-port work specific to this tree.

## 2. Workspace size and layout

```text
Cargo workspace (resolver 3, edition 2024, rust 1.88, pinned toolchain 1.98.1)
├── crates/
│   ├── victory-core        456 lines      config, logging, asset policy
│   ├── victory-pe         1,635 lines      PE32+ / import-library reader
│   ├── victory-loader     6,387 lines      map, bind and start the title
│   ├── victory-hle       23,262 lines      Xbox API implementations
│   ├── victory-gpu     102,880 lines      D3D12.X → host D3D12
│   ├── victory-shader   50,805 lines      GFX10 → DXIL
│   ├── victory-formats    5,457 lines      texture layouts, BCPack, audio
│   ├── victory-pipeline     259 lines      converter trait + content cache
│   └── victory-game         243 lines      title-specific formats/hooks
├── apps/victory           3,873 lines      command-line front end
├── xtask                     462 lines      policy check, git hooks
└── tests/fixtures/hle-probe                stand-in "title" for loader tests
```

Totals: 228 Rust files, about 195,700 lines, 1,110 `#[test]` annotations.
Most GPU code is `#[cfg(windows)]`; the portable core, PE reader, loader
preparation, formats and shader front end can be exercised elsewhere.

## 3. Crate dependency graph

```text
                         apps/victory (CLI)
                    ┌──────────┬───────────┬──────────────┐
                    ▼          ▼           ▼              ▼
              victory-hle  victory-loader victory-shader victory-game
                    │          │      │           │            │
                    │          ▼      ▼           │            │
                    │     victory-pe  victory-core│            │
                    │          ▲                  │            │
                    ▼          │                  │            │
              victory-gpu ─────┴──────────────────┘            │
                │   │   │                                      │
                │   │   └── victory-pipeline ── victory-core   │
                │   └────── victory-formats                    │
                └────────── victory-core                        │
                                                               ▼
                                                        victory-formats

xtask: standalone (anyhow, clap, walkdir)
victory-hle also depends on opus-pure, zlib-rs, windows/windows-sys
victory-gpu depends on blake3, zlib-rs, windows/windows-sys
```

Exact edges from the crate manifests:

| Crate | Internal dependencies |
|---|---|
| `victory-core` | none |
| `victory-pe` | none |
| `victory-pipeline` | `victory-core` |
| `victory-formats` | none |
| `victory-shader` | none (feature `host` adds `windows`) |
| `victory-gpu` | `victory-core`, `victory-formats`, `victory-pipeline`, `victory-shader` |
| `victory-loader` | `victory-core`, `victory-pe` |
| `victory-hle` | `victory-gpu`, `victory-loader`, `victory-pe`, `victory-formats` |
| `victory-game` | none |
| `apps/victory` | `victory-core`, `victory-pe`, `victory-loader`, `victory-hle`, `victory-shader`, `victory-game` |
| `xtask` | none |

## 4. Entry points

### 4.1 CLI (`apps/victory/src/main.rs`)

`fn main()` at line 178 dispatches clap subcommands:

| Command | Handler | Purpose |
|---|---|---|
| `inspect` | `inspect::run` | PE headers, sections, imports, TLS, build id |
| `census` | `census::run` | classify every imported symbol against HLE coverage |
| `lib-exports` | `inspect::lib_exports` | list import-library exports |
| `shader-info` | `shader::run` | find/decode shader containers |
| `translate` | `translate::run` | translate shaders, optionally validate/build pipelines |
| `shaders` | `translate::precompile` | warm the persistent shader cache |
| `warm` | `warm::run` (Windows) | pre-create driver pipelines |
| `run` | `run::run` | prepare/map/bind, optionally `--execute` the title |
| `replay` | `replay::run` (Windows diagnostics) | replay a captured frame |
| `config` | `show_config` | print/check resolved paths |

### 4.2 Title startup (`apps/victory/src/run.rs` → `victory-loader`)

`victory_loader::prepare()` turns a copy of the image into a DLL-like module;
`victory_loader::windows::load` maps it; `resolve` binds every import through
`HleResolver`; `threads`/`tls` run DLL initialisers, TLS callbacks and the
entry point. `run --execute` installs the crash reporter
(`victory-loader/src/crash.rs`).

### 4.3 GPU device creation (`crates/victory-gpu/src/host.rs:1008`)

`Host::new` creates the real D3D12 device through
`victory_shader::emit::host::create_preferred_device` (adapter selection,
`D3D_FEATURE_LEVEL_12_0`), then probes wave lanes and AMD RDNA-ness. The
translated shaders target SM 6.6.

## 5. Subsystem map

### 5.1 Xbox executable loader

| File | Role |
|---|---|
| `crates/victory-loader/src/prepare.rs` | PE → loadable image; clears entry point/imports/TLS callbacks |
| `crates/victory-loader/src/windows.rs` | `LoadLibrary`-style mapping, title DLLs, bind report |
| `crates/victory-loader/src/resolve.rs` | `ImportResolver`, provenance |
| `crates/victory-loader/src/console_insn.rs` | emulate Zen 2-only instructions on Intel |
| `crates/victory-loader/src/console_insn_decode.rs` | decode CLZERO/RDPRU/MONITORX/EXTRQ etc. |
| `crates/victory-loader/src/tls.rs` | static TLS slot redirection |
| `crates/victory-loader/src/threads.rs` | thread start/end notifications |
| `crates/victory-loader/src/frame_rate.rs` | title frame pacing |
| `crates/victory-loader/src/resolution.rs` | render-resolution/upscaler policy |
| `crates/victory-loader/src/write_sites.rs`, `descriptor_sites.rs` | patched title code sites |
| `crates/victory-loader/src/crash.rs` | module+RVA crash reports, stack unwind |

### 5.2 Runtime services / HLE

`crates/victory-hle/src/registry.rs` is the import registry. Modules under
`crates/victory-hle/src/modules/`:

| Area | Module(s) |
|---|---|
| Graphics | `d3d12x.rs` |
| Memory | `xmem.rs`, `dstorage.rs` |
| Async / lifecycle | `xasync.rs`, `lifecycle.rs` |
| Files / storage | `files.rs`, `storage.rs`, `xpackage.rs`, `xstore.rs` |
| User / UI / input | `xuser.rs`, `xgameui.rs`, `gameinput.rs`, `xg.rs` |
| Runtime / system | `xgameruntime.rs`, `xsystem.rs`, `kernel.rs`, `rpcrt4.rs` |
| Audio / media | `apu.rs`, `audio.rs`, `dsp.rs`, `media.rs`, `speech.rs` |
| Network | `net.rs`, `xnetworking.rs` |
| Display | `display.rs` |
| Saves | `xgamesave.rs` |

`crates/victory-hle/src/host.rs` holds `HostPolicy` (which host DLLs pass
through). `crates/victory-hle/src/runtime.rs` wires the process-wide state.

### 5.3 GPU backend (`crates/victory-gpu/src`)

The device object (`device.rs`) exposes a D3D12.X vtable with console-only
methods added. The title's inlined command recording is defeated by keeping
list limits at zero, so every command becomes a method call (`lib.rs` docs).

| Concern | Files |
|---|---|
| Device / DXGI | `device.rs`, `dxgi.rs`, `console.rs`, `switch.rs`, `tdr.rs` |
| Command recording | `list.rs`, `list/`, `queue.rs`, `queue/behind.rs`, `timeline*` |
| Draws / dispatch | `draw.rs`, `indirect.rs`, `indirect/`, `primitive.rs`, `signature.rs` |
| Pipeline state | `pipeline.rs`, `pipeline/`, `root.rs`, `shader_cache.rs` |
| Descriptors | `descriptor.rs`, `descriptor/host.rs`, `book.rs`, `port_descriptors.rs` |
| Resources / heaps | `resource.rs`, `memory.rs`, `pool.rs`, `residency.rs`, `tiles.rs` |
| Textures | `texture.rs`, `texture/ahead.rs`, `texlate.rs`, `texstore.rs`, `texback.rs` |
| Buffer mirrors | `shadow.rs`, `watch.rs`, `inplace.rs`, `safecopy.rs`, `upload.rs` |
| Synchronisation | `fence.rs`, `frame.rs`, `queue.rs`, `queue/behind.rs` |
| Readback / landing | `land.rs`, `land/`, `host/`, `copystat.rs` |
| Renderer ports | `port.rs`, `port_cbv.rs`, `ambient.rs`, `lightprobe.rs` |
| Diagnostics | `capture.rs`, `replay/`, `book.rs`, `popwatch.rs`, `ab.rs`, `faultbook.rs` |

### 5.4 Shader recompiler (`crates/victory-shader/src`)

```text
DXBC container (dxbc.rs)
  └─ DXIL part (dxil.rs): LLVM bitcode + Xbox XDAT/xbop extras
       └─ GFX10 native code (zlib) → gfx10/ decoder (opcodes, fields, SP3 text)
            └─ native.rs: stage, wave64, VGPR/SGPR, root params, used resources
                 └─ spill.rs: registers spilled to memory, SGPR/VGPR layout
                      └─ ir.rs: SSA, one instruction per machine instruction
                           └─ structure.rs: EXEC → per-lane booleans/branches
                                ├─ resource.rs: descriptor/scalar trace to root params
                                ├─ io.rs: signatures, interpolation, mesh I/O
                                └─ emit/lower.rs: GPU semantics → DXIL operations
                                     ├─ emit/bitcode.rs: DXIL module writer
                                     ├─ emit/container.rs: DXBC/DXIL/PSV0/ISG1/OSG1/PSG1
                                     └─ emit/shader.rs: HostShader metadata
```

`emit/host.rs` can create a real host device and pipelines for offline
validation. `apps/victory/src/translate.rs` batch-runs every shader and tallies
failures; `shader_cache.rs` keys translations by translator version and host
settings.

### 5.5 Formats

`crates/victory-formats/src/texture.rs` implements console texture sizing and
tiling/detiling; `bcpack.rs` decodes BCPack; `xma.rs`/`xma/` decode audio.
`victory-pipeline` provides the content-addressed converter cache used by
offline asset conversion.

## 6. Runtime data flow (frame)

```text
title thread                         our worker(s)                      GPU
────────────                         ────────────                       ───
D3D12.X call
  → list.rs records command
  → descriptor/host.rs mirrors title descriptor records
  → shadow.rs copies changed title-memory pages to host buffers
  → texture.rs detiles changed title textures into staging
  → draw.rs builds host tables / indirect arguments
  → queue/behind.rs prepares submission on our thread
  → host.rs executes host command lists ───────────────────────────────► host D3D12
  → fence / frame pacing
  ← land.rs / texback.rs copy shader writes back to title memory
```

## 7. Import resolution order

From `docs/architecture.md` and `victory-hle/src/lib.rs`:

1. `victory-hle::modules` implementation (always wins);
2. host function if `HostPolicy` allows that DLL;
3. export of a DLL the title ships beside its executable;
4. generated stub (`--unimplemented trap|zero`).

`QueryApiImpl` serves runtime objects by provider/interface id; console-only
DLLs such as `xgameruntime.dll` are represented by pseudo handles.

## 8. Diagnostics and logging

- `victory-core/src/logging.rs` initialises `tracing`.
- `host.rs` logs adapter name, PCI vendor/device, dedicated VRAM, wave lanes,
  mesh/depth-bounds support, per-frame counters.
- `copystat.rs`, `timeline/`, `book.rs`, `faultbook.rs`, `popwatch.rs` collect
  per-phase timing and GPU-memory ownership.
- `VICTORY_PANEL`, `F3`, `docs/replay.md` provide on-screen and frame-replay
  diagnostics.
- `VICTORY_D3D12_DRED=light` enables device-removed breadcrumbs.

## 9. Test infrastructure layout

| Location | Kind |
|---|---|
| `crates/*/src/**` `#[cfg(test)]` modules | unit tests, the majority (1,110 annotations) |
| `crates/victory-gpu/tests/replay.rs` | GPU integration: record/replay a synthetic frame |
| `crates/victory-gpu/tests/replay_big.rs` | GPU stress: title-sized frame |
| `crates/victory-loader/tests/load_probe.rs` | loader against the `hle-probe` fixture |
| `crates/victory-loader/tests/title_dlls.rs` | title DLL mapping |
| `crates/victory-hle/tests/no_dll_planting.rs` | security/policy |
| `apps/victory/tests/census.rs` | import classification |
| `apps/victory/tests/translate_host_wave.rs` | host-wave selection/cache fingerprint |
| `tests/fixtures/hle-probe` | standalone fixture crate built on demand |
| `.github/workflows/ci.yml` | Windows-only: clippy, default tests, all-features tests |

## 10. Architectural observations relevant to NVIDIA

1. The GPU translation layer is a **copy-based** design: host buffers mirror
   title memory because host D3D12 cannot read console memory directly. Every
   buffer/texture that a draw reads is copied or kept in host memory. This is
   the main source of both RAM use and per-frame cost.
2. The shader pipeline is **ahead-of-time capable**: `victory shaders` fills a
   persistent cache, and `victory warm` pre-creates driver pipelines. This is
   important on NVIDIA because pipeline creation is expensive.
3. The host abstraction already contains **explicit NVIDIA branches**: wave
   width detection, mesh-shader gating, descriptor-heap capping, format
   stand-ins, raw-view workarounds and NVIDIA-specific shader math. The code is
   not AMD-only; it is AMD-tested.
4. There is **no host API for vendor-specific optimisation** (NVAPI, DLSS,
   RTX path). The title's ray tracing is translated compute work, not DXR, so
   RT cores are unused.
5. The console device presented to the title is deliberately an **AMD RDNA 2
   Series X** profile (`device.rs`, `dxgi.rs`, `console.rs`). This is a title
   compatibility decision, not a host assumption, but it means the title can
   request 10 GB + 3.5 GB of memory and AMD-only formats regardless of the
   actual 6 GB card.
