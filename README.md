# NVXGT — NVIDIA RTX 2060 Compatibility Project

<p align="center">
  <img
    src="https://github.com/user-attachments/assets/6ed5ec01-fe0a-4ff3-81a0-e9db5ef671b4"
    alt="NVXGT Project Logo"
    width="280"
  />
</p>

**NVXGT** is an NVIDIA-focused development fork of [VIctory](https://github.com/Marvisak/VIctory), a compatibility layer designed to run an Xbox Series title natively on Windows using game files supplied by the user.

This fork focuses on auditing, adapting, and optimizing the project for NVIDIA GPUs, with the **GeForce RTX 2060 (6 GB VRAM)** as its primary development and validation target.

The long-term objective is to make the project stable, efficient, and accessible on NVIDIA-based gaming PCs.

---

## Project Goals

The primary development target is the **NVIDIA GeForce RTX 2060**.

Our priorities are:

1. Audit the existing codebase and identify AMD-specific assumptions.
2. Establish NVIDIA GPU compatibility.
3. Fix rendering, synchronization, memory management, and shader translation issues.
4. Optimize CPU and GPU workloads.
5. Reduce frame times, stuttering, and VRAM consumption.
6. Improve visual consistency and rendering stability.
7. Establish a reproducible performance baseline.

### Performance Philosophy

**Stability first. Performance second. Visual quality third.**

The initial objective is to achieve a stable 30 FPS experience where hardware and software limitations allow it, without ray tracing.

Further optimization will target:
- Consistent frame pacing.
- Lower GPU and CPU overhead.
- Reduced shader compilation stutter.
- Efficient VRAM allocation.
- Faster resource uploads and synchronization.
- Improved texture streaming.
- Optional advanced rendering features.

No unverified performance figures are presented as achieved results.

---

## Target Hardware

| Component | Primary target |
|---|---|
| GPU | NVIDIA GeForce RTX 2060 |
| GPU Architecture | Turing |
| VRAM | 6 GB |
| GPU Vendor | NVIDIA |
| API | Direct3D 12 |
| Operating System | Windows 10 / 11 x64 |
| CPU | AVX2-capable processor |
| Memory | 16 GB minimum target, 32 GB recommended target |

Actual compatibility requirements will be established through hardware and feature-level testing.

### NVIDIA Compatibility Focus

The RTX 2060 is the primary reference GPU for this fork.

Development will investigate:

- NVIDIA Direct3D 12 driver behavior.
- Shader Model and mesh shader support.
- DXGI adapter selection.
- NVIDIA-specific GPU synchronization behavior.
- Resource barriers and descriptor management.
- VRAM allocation and memory pressure.
- Pipeline State Object creation and caching.
- Shader translation and compilation performance.

Features will only be considered supported after validation on actual NVIDIA hardware.

---

## Development Status

**Audit phase — 2026-11-26**

The project is currently in its initial NVIDIA compatibility audit phase.

The existing upstream and AMD-oriented implementations are being examined to identify platform assumptions, GPU-specific optimizations, rendering dependencies, and potential compatibility issues.

| Area | Status |
|---|---|
| Codebase audit | In progress |
| NVIDIA compatibility analysis | Planned |
| RTX 2060 hardware validation | Pending |
| Direct3D 12 compatibility | Under investigation |
| Shader translation validation | Pending |
| VRAM optimization | Planned |
| Rendering stability | Pending |
| CPU/GPU performance profiling | Planned |
| 30 FPS target | Not yet achieved or verified |

**Important:** No RTX 2060 performance benchmark or compatibility result should be considered confirmed until tested on physical hardware.

---

## Development Roadmap

### Phase 1 — Codebase Audit

- Examine the upstream VIctory architecture.
- Identify AMD-specific code and assumptions.
- Review Direct3D 12 implementation.
- Analyze shader translation and compilation.
- Examine resource management and synchronization.
- Identify potential NVIDIA driver compatibility issues.
- Document performance bottlenecks.

### Phase 2 — NVIDIA Compatibility

- Validate NVIDIA adapter detection.
- Verify required Direct3D 12 capabilities.
- Investigate shader compilation compatibility.
- Validate descriptor and resource management.
- Test GPU synchronization and barriers.
- Resolve NVIDIA-specific rendering issues.

### Phase 3 — RTX 2060 Optimization

- Optimize VRAM usage for the 6 GB memory budget.
- Reduce unnecessary CPU-GPU synchronization.
- Improve asynchronous resource handling.
- Optimize shader and pipeline caching.
- Investigate CPU-side bottlenecks.
- Reduce frame-time spikes and stuttering.

### Phase 4 — Rendering Stability

- Investigate lighting inconsistencies.
- Fix texture streaming delays.
- Address geometry and object flickering.
- Improve resource lifetime management.
- Validate rendering consistency across different environments.

### Phase 5 — Performance Validation

- Establish reproducible benchmarks.
- Compare performance before and after each optimization.
- Measure average FPS and frame times.
- Record GPU utilization and VRAM consumption.
- Test different graphics configurations.
- Work toward stable 30 FPS or better where achievable.

---

## Architecture and Optimization Priorities

NVXGT follows the original project's compatibility-layer approach rather than attempting to emulate an entire Xbox console.

The development focus is on improving how the existing runtime handles rendering, resource management, shader translation, and GPU execution on NVIDIA hardware.

Key investigation areas include:

- **Command Processing:** Reduce unnecessary overhead in command recording and submission.
- **Asynchronous Execution:** Investigate opportunities to distribute CPU workloads.
- **Shader Translation:** Improve translation compatibility and persistent shader caching.
- **Resource Management:** Reduce redundant transfers and synchronization.
- **Descriptor Management:** Optimize descriptor access and update operations.
- **Memory Management:** Keep GPU memory consumption within practical hardware limits.
- **Pipeline Caching:** Reduce compilation overhead and first-run stuttering.

Upstream optimizations will be evaluated individually rather than assumed to work identically on NVIDIA hardware.

---

## Building and Running

### Requirements

The expected development environment includes:

- Windows 10/11 x64.
- NVIDIA GeForce RTX 2060 or another supported Direct3D 12 GPU.
- A compatible NVIDIA driver.
- Rust toolchain.
- MSVC build tools.
- Git.
- A legally obtained copy of the game.

Specific GPU feature requirements must be verified against the selected hardware and driver.

### Clone the Repository

```powershell
git clone https://github.com/ruaavell/VIctory---NVIDIA-RTX-2060.git

cd VIctory---NVIDIA-RTX-2060
```

### Initial Configuration

```powershell
copy victory.example.toml victory.toml
```

Configure the required paths in `victory.toml`.

### Build

```powershell
cargo build --locked --profile diag -p victory --features diagnostics
```

### NVIDIA Adapter Selection

The runtime's adapter selection mechanism will be validated during the NVIDIA compatibility phase.

Where supported by the existing launcher:

```powershell
scripts\play.ps1 -More @{VICTORY_D3D12_ADAPTER='NVIDIA'}
```

Actual adapter selection and GPU feature support must be confirmed through runtime logs.

---

## Benchmarking and Testing

All performance claims must be backed by reproducible tests.

| Metric | Purpose |
|---|---|
| Average FPS | Overall performance |
| Frame time (ms) | Frame pacing and consistency |
| 1% lows | Performance stability |
| GPU utilization | GPU workload analysis |
| VRAM usage | Memory pressure |
| System RAM usage | Total memory requirements |
| Shader compilation time | First-run performance |
| Stuttering frequency | Real-world smoothness |

Benchmark results should include hardware specifications, driver version, game settings, rendering configuration, and test location.

---

## Repository Structure

The repository follows the original VIctory project architecture.

Relevant areas include:

- `crates/` — Runtime and supporting components.
- `docs/` — Technical documentation and investigation notes.
- `scripts/` — Build, launch, and development scripts.
- `target/` — Generated build output.

The exact structure may evolve as the NVIDIA compatibility work progresses.

---

## Project Principles

- NVIDIA hardware compatibility is the primary development focus.
- Performance improvements must be measurable.
- Stability takes priority over experimental optimizations.
- Experimental patches must remain reversible.
- Existing upstream functionality should be preserved where possible.
- Hardware-specific assumptions must be documented.
- No unsupported compatibility claims.
- Reproducible testing is preferred over speculative optimization.

---

## Credits and Acknowledgements

NVXGT builds upon the work of the original VIctory project and several community forks.

We acknowledge the contributions of:

- [Marvisak/VIctory](https://github.com/Marvisak/VIctory) — Original project, runtime architecture, Direct3D 12 backend, and shader recompiler.
- [fxceless/victory-fork](https://github.com/fxceless/victory-fork) — Previous fork and inherited contributions.
- [DexNom/VIctory](https://github.com/DexNom/VIctory) — Rendering and ray-tracing related improvements.
- [Belobug/VIctory-Belobug-AMD](https://github.com/Belobug/VIctory-Belobug-AMD) — AMD-oriented optimizations and rendering improvements.
- [FQY55kai/ZJOU-VICTORY](https://github.com/FQY55kai/ZJOU-VICTORY).
- [myokex/victory-amd](https://github.com/myokex/victory-amd) — Memory and resource-management contributions.
- Other developers and contributors whose work is preserved in the inherited commit history.

NVXGT aims to preserve attribution and maintain the project's development history.

---

## Legal Notice

This repository does not contain game files, copyrighted game assets, or proprietary game content.

Users must provide their own legally obtained game files.

NVXGT is an independent community development project. It is not affiliated with, endorsed by, or sponsored by NVIDIA, Microsoft, Xbox, or the game's developer or publisher.

All original third-party licenses and attribution requirements must be respected.

---

## License

GPL-3.0-or-later, inherited from the original VIctory project, subject to the licenses of individual components.

See [LICENSE](LICENSE) and the relevant documentation for details.

<p align="center">

**NVXGT**

*Built for NVIDIA. Optimized for Performance.*

**RTX 2060 — Our First Target.**

</p>
