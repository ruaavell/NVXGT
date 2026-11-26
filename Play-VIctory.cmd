@echo off
setlocal EnableExtensions DisableDelayedExpansion
rem ---------------------------------------------------------------------------
rem VIctory launcher (ported from cool_fox f4b48ad, M7) -- tuned for a 6 GB
rem NVIDIA RTX 2060 target (Series S profile).
rem
rem Usage:
rem   Play-VIctory.cmd pareto-residency
rem
rem The profile below is cool_fox's RTX "pareto-residency" setting set, kept
rem as-is where it is vendor-neutral. Values that were tuned on a 16 GB VRAM
rem card are the ones to revisit first on a 6 GB card:
rem   VICTORY_CARD_BUFFERS_MIN_KB=64   -- card-resident constant buffer floor
rem   VICTORY_CARD_BUFFERS_MB=1024     -- card-resident buffer room (face fix)
rem   VICTORY_UPLOAD_AHEAD=1           -- speculative texture prefetch
rem   VICTORY_JOIN_PARTS=8            -- join-copy batching
rem Re-tune these down for the 6 GB target (T-020 M7 note in shared memory).
rem ---------------------------------------------------------------------------
if not "%~1"=="" if /i not "%~1"=="pareto-residency" (
  echo Usage: Play-VIctory.cmd pareto-residency 1>&2
  exit /b 2
)
if not defined VICTORY_GAME_DIR set "VICTORY_GAME_DIR=%~dp0..\GTA6.Xbox.v1.0.2.1"
if not exist "%VICTORY_GAME_DIR%\game_scarlett_master.exe" (
  echo Set VICTORY_GAME_DIR to your own dump folder containing game_scarlett_master.exe. 1>&2
  exit /b 2
)
set "runner=%~dp0victory-3d-rtx-pareto-residency.exe"
if not exist "%runner%" set "runner=%~dp0target\release\victory.exe"
if not exist "%runner%" (
  echo Extract the Windows release or run cargo build --release --locked -p victory. 1>&2
  exit /b 2
)
if not defined VICTORY_AMBIENT_AIR set "VICTORY_AMBIENT_AIR=1.5"
if not defined VICTORY_CACHE_DIR set "VICTORY_CACHE_DIR=%LOCALAPPDATA%\VIctory\cache-pareto"
if not defined VICTORY_TEXTURE_NO_WAIT set "VICTORY_TEXTURE_NO_WAIT=1"
if not defined VICTORY_RELAY set "VICTORY_RELAY=2"
if not defined VICTORY_WIDE_BACK set "VICTORY_WIDE_BACK=1"
if not defined VICTORY_CARD_REHASH_RUNS set "VICTORY_CARD_REHASH_RUNS=1"
if not defined VICTORY_JOIN_COPIES set "VICTORY_JOIN_COPIES=1"
if not defined VICTORY_INDIRECT_WINDOW set "VICTORY_INDIRECT_WINDOW=1"
if not defined VICTORY_RELAY_COPY set "VICTORY_RELAY_COPY=1"
if not defined VICTORY_CARD_STEPS set "VICTORY_CARD_STEPS=2"
if not defined VICTORY_INDIRECT_BATCH set "VICTORY_INDIRECT_BATCH=2"
if not defined VICTORY_MAP_THREADS set "VICTORY_MAP_THREADS=1"
if not defined VICTORY_CARD_AWAKE set "VICTORY_CARD_AWAKE=1"
if not defined VICTORY_SHOW_AFTER set "VICTORY_SHOW_AFTER=1"
if not defined VICTORY_AMBIENT set "VICTORY_AMBIENT=0.8"
if not defined VICTORY_THIN set "VICTORY_THIN=1"
if not defined VICTORY_JOIN_PARTS set "VICTORY_JOIN_PARTS=8"
if not defined VICTORY_UPLOAD_AHEAD set "VICTORY_UPLOAD_AHEAD=1"
if not defined VICTORY_LEVELS_ON_DEMAND set "VICTORY_LEVELS_ON_DEMAND=1"
if not defined VICTORY_CARD_BUFFERS_MIN_KB set "VICTORY_CARD_BUFFERS_MIN_KB=64"
rem Face fix profile (face fix.txt): keep the textures the title bakes onto
rem characters' faces on the card, hide levels it has not placed yet, and take
rem only the strict wave and barrier forms (no raw twins, no wide waves).
if not defined VICTORY_CARD_BUFFERS_MB set "VICTORY_CARD_BUFFERS_MB=1024"
if not defined VICTORY_RAW_VIEWS set "VICTORY_RAW_VIEWS=0"
if not defined VICTORY_GROUP_SYNC set "VICTORY_GROUP_SYNC=2"
if not defined VICTORY_WAVE_LOCAL set "VICTORY_WAVE_LOCAL=idiom"
rem VICTORY_WAVE_WIDE is left unset: wide wave forms stay off in this profile.
if not defined VICTORY_PIPELINE_BOOK set "VICTORY_PIPELINE_BOOK=1"
if not defined VICTORY_LOG if not defined RUST_LOG set "VICTORY_LOG=warn"
"%runner%" run "%VICTORY_GAME_DIR%\game_scarlett_master.exe" --console series-s --execute
exit /b %errorlevel%
