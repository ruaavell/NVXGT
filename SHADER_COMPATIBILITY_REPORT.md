# Shader Compatibility Report

Companion to `AUDIT_REPORT.md`. Source evidence only; no shader corpus or NVIDIA
GPU was available in this audit.

## 1. Pipeline

| Stage | File | Function | Output |
|---|---|---|---|
| Container parse | `crates/victory-shader/src/dxbc.rs` | `Container::parse` | DXBC parts (`DXIL`, `STAT`, `PSV0`, `ISG1`, `OSG1`, `PSG1`, `SFI0`, `HASH`) |
| Program parse | `dxil.rs` | `DxilProgram::parse` | LLVM bitcode, Xbox `XDAT`/`xbop` extras, shader kind, SM |
| Native extraction | `native.rs:430` | `native_programs` | Decoded GFX10 programs (stage, wave64, VGPR/SGPR, root params, used resources) |
| GFX10 decode | `gfx10/opcodes.rs`, `gfx10/fields.rs`, `gfx10/sp3.rs` | opcode/field tables | Instruction stream |
| Register spill | `spill.rs:29` | `build` | Program with spilled SGPR/VGPR layout |
| IR | `ir.rs:132` | `build` | SSA, one instruction per machine instruction |
| Structurisation | `structure.rs:459` | `structure` | EXEC → per-lane booleans, lane branches, uniform branches |
| Resource tracking | `resource.rs:201` | `track` | Descriptors/scalars traced to root parameters |
| I/O raising | `io.rs:197` | `raise` | Signatures, interpolation, mesh I/O |
| Lowering | `emit/lower.rs` | `lower` | DXIL-level operations, wave/LDS/quads |
| DXIL emission | `emit/bitcode.rs`, `emit/container.rs` | module writer, `psv` | SM 6.6 DXBC container |
| Batch/validation | `emit/mod.rs:401` | `translate`; `apps/victory/src/translate.rs` | `HostShader` + failure tally |

`TRANSLATOR_VERSION` (`lib.rs:19`) is part of the cache key and must be bumped
whenever a shader's emitted DXIL or host binding changes.

The project reports that **25,790 of 25,985** shaders translate; the remainder
are unused geometry shaders (`README.md:31`). That is the strongest evidence
that the translation pipeline is complete for the current title. It does not
prove that all programs behave *correctly* on NVIDIA.

## 2. Input format

An Xbox Series shader is a normal DXBC container whose `DXIL` part carries:

- LLVM bitcode (possibly with console-only intrinsics);
- an `XDAT` table before the bitcode;
- an `xbop` compiler-options blob after it;
- a zlib-compressed GFX10 native program that the translator uses in general,
  because the bitcode may reference console-only intrinsics (`lib.rs:1-10`).

The translator therefore does **not** trust the bitcode as portable DXIL. It
decodes the actual GFX10 machine code. That is the right call for NVIDIA: the
console bitcode was produced for RDNA 2 and is not a PC shader.

## 3. Wave and lane handling

| Console construct | NVIDIA 32-lane handling | Evidence | Status |
|---|---|---|---|
| Wave32 program | Runs natively at 32 | `host.rs:1046-1055` | OK |
| Wave64 compute, cross-lane traffic inside 32-lane halves | Runs as two host waves; lanes relabelled | `lower.rs:1852-1890`; `wave64_tests.rs` | OK |
| Wave64 compute, traffic across halves (`v_mbcnt`, `v_readlane`, `v_writelane`, `ds_permute`, masks as data) | Refused unless split/barrier rules hold | `lower.rs:1855-1890` | RISK |
| Wave64 with LDS shared without barriers | Group barrier before every LDS access, only where every lane reaches it | `lower.rs:1867-1890` | OK* |
| `WaveSize(64)` on a 32-lane host | Never declared; host pipeline would refuse it | `lower.rs:1844`, tests | OK |
| Pixel/vertex lane masks | Ballots over the host wave; only wave-size-independent uses allowed | `lower.rs:408-425` | OK* |
| Mesh cross-lane ops | Refused entirely | `lower.rs:5105-5110` | RISK (latent) |
| Mesh thread/lane index | `flattenedThreadIdInGroup` masked by console wave size | `lower.rs:5256-5275` | OK |
| DPP / `ds_swizzle` / `v_permlane16` | Confined to 32-lane halves, handled | `lower.rs:1831-1848` | OK |
| Helper lanes in pixel quads | Quad reads used; AMD zero-helper assumption documented | `lower.rs:5323` | OK* |

## 4. LDS / shared memory

- LDS is emitted as a DXIL `groupshared` array in address space 3
  (`emit/shader.rs:330-360`, `lds()`).
- When a console wave64 program runs as two host waves, the translator inserts
  a group barrier before every LDS access (`lower.rs:1069-1170`,
  `lds_meetings`).
- LDS accesses inside lane-divergent branches are refused when a barrier could
  deadlock (`lower.rs:1887`).
- `ds_swizzle` and `ds_permute` are treated as lane exchanges rather than
  ordinary LDS (`lower.rs:5489-5500`).
- Byte/16-bit LDS reads and writes are unsupported (`lower.rs` failure list:
  "an LDS read of bytes or halves", "an LDS write of bytes or halves").

On NVIDIA, LDS/barrier semantics are standard; the risk is performance
(barriers serialize the two host waves) and the refusal cases, not a vendor
difference.

## 5. Operations requiring special handling on Turing

### 5.1 Already handled

| Operation | Difference on NVIDIA | Handling |
|---|---|---|
| `v_cvt_f16_f32` / 16-bit float rounding | NVIDIA `f32tof16` rounds toward zero; console rounds to nearest | Opt-in exact path `VICTORY_F16_NEAREST=1` (`lower.rs:1488`, `4335`) |
| `fcmp uno` | NVIDIA folds/does not fold under fast-math differently | Explicit NaN-safe lowering (`lower.rs:4407`) |
| `Log` | DXIL `Log` is base-2, not natural log | Corrected in `bitcode.rs` (documented in `docs/findings.md`) |
| Cube-map face coordinates | AMD ISA major-axis order differs | Explicit cube coordinate mapping (`lower.rs:8643`) |
| Non-consecutive host lane numbering | NVIDIA 8×8 thread groups are not linear | Wave base taken from LDS counter (`lower.rs:4643`) |
| Structured buffer read as raw | NVIDIA returns zeros | Slot view made raw when possible (`descriptor/host.rs:3740-3812`) |
| Normalized buffer codes | One step off vs console | Nearest-code correction (`docs/findings.md`) |

### 5.2 Not handled / capability-dependent

| Operation | Issue | Evidence |
|---|---|---|
| 64-bit typed image atomics | Emitted unconditionally; OPTIONS9 capability not queried | `lower.rs:11508-11547` |
| 64-bit descriptor-heap atomics | Same; OPTIONS11 not queried | same |
| Mesh cross-lane reductions | Refused | `lower.rs:5106` |
| `WaveSize` in mesh | Not expressible in SM 6.6; mesh relies on thread-ID mapping | `lower.rs:5107-5110` |
| Compute derivatives / quad ops in mesh | SM 6.6 optional; no capability query | `OPTIONS9` absent |
| Byte/16-bit LDS | Refused | `lower.rs` failure strings |
| 64-bit compares / operands | Refused in several forms | `lower.rs` failure strings |
| Packed 16-bit operations outside a VGPR | Refused | `lower.rs` failure strings |

The failure strings are deliberate `Err` returns, not crashes. A refused shader
becomes a refused pipeline; the title then draws without that pipeline.

## 6. Why shaders can still fail on NVIDIA after translation

Translation success is not the same as host pipeline success. A translated
shader can fail at `CreatePipelineState` for reasons outside the translator:

1. **Root signature refusal** — SM 6.5 runtime on Windows 10 (F-01).
2. **64-bit atomic capability** — typed/heap atomics (F-06).
3. **Mesh limits** — output size/thread count beyond Turing's mesh limits
   (`lower.rs:5186-5215`).
4. **Descriptor heap indices** — a shader may be valid but reference a slot
   that the host heap did not mirror (F-04).
5. **Driver validation** — a DXIL construct the NVIDIA compiler rejects even
   though the validator accepted it.

The project has `victory translate --validate --pipelines` precisely for this;
it should be run on the RTX 2060 before any gameplay test. A successful batch
proves translation and host pipeline creation only, **not** gameplay.

## 7. Cache correctness risk

`lower.rs:1516-1519` builds the cache fingerprint from:

```text
[host_max_wave, view_heap_limit, raw_views, host_rdna]
```

It does **not** include:

- the GPU vendor / architecture;
- the 64-bit atomic capabilities;
- format support (the stand-in decisions);
- mesh tier;
- driver version.

Translations are largely vendor-independent, but the last four can change
emission or host binding. The shader cache key should be extended, or the cache
must be invalidated when moving a cache directory between an AMD and an NVIDIA
machine. This is a suspected problem (S-06), not a confirmed corruption.

## 8. Verdict

The shader recompiler is the most NVIDIA-ready part of the project. It decodes
real GFX10, handles 32-lane hosts, splits wave64 where legal, and documents the
NVIDIA math differences. The remaining risks are specific and testable:

- 64-bit atomic capability gating;
- mesh cross-lane programs;
- cache key coverage;
- pipeline creation failures caused by the runtime/descriptor issues in the
  main report.

No shader compatibility claim in this report was validated on an RTX 2060.
