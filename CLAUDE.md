# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project state

**Sprint 1 closed.** Sprint 2 (F2 PoC GO/NO-GO) is next. The repo has the Godot project skeleton (`project.godot` configured for OpenXR + XR shaders + Forward+/D3D12 + Jolt + 90 Hz physics + VSYNC off + Meta XR loader via `godot_openxr_vendors` + Gradle Build), the directory structure, the seed lens catalog (`defaults/lentes.json`), the `DataManager` autoload skeleton, and a stereoscopic test scene that renders red on the left eye and blue on the right (validated on Quest 2).

**Documentation hierarchy:**
- `PLAN.md` — full sprint roadmap, criteria de salida, locked decisions, risk register. **Source of truth for what comes next.**
- `progress.txt` — current sprint status + session notes. Updated at sprint close.
- `AGENTS.md` — agent-facing project briefing (stack, conventions, decisions already taken).
- `context/` — original design specs (Roadmap_Simulador_v2.md + fase_0..5.md + preguntas_abiertas.md). 📋 Notas Tecnicas in each phase file have already verified Godot 4.6 APIs — don't re-verify, use as written.

## What this will become

VR ophthalmology simulator for Meta Quest 3 (Quest 2 best-effort), built with **Godot 4.6.x + OpenXR**, that lets users experience vision through different intraocular lens types (monofocal, multifocal, PanOptix, Vivity), with independent per-eye effects (monovision/blend mode). The full system also has a FastAPI backend, an Android tablet control app (also Godot), licensing, and OTA updates.

## Locked decisions (from Sprint 0 planning)

| Topic | Decision |
|-------|----------|
| Distribution | **Sideload** (no Meta Store) — F5 OTA implements full APK auto-install via custom Android plugin |
| Hardware target | **Quest 3 primary, Quest 2 best-effort** — degrade quality on Quest 2 if F2 PoC demands it |
| Backend hosting | **Dedicated VPS + Docker Compose** (api, db, bucket, nginx) |
| Streaming (F3) | **Option A: real video** with blocking PoC at Sprint 6; documented fallback to Option B |
| Project layout | Mixed: `autoloads/` + `features/{vr_core,lenses,environment,vision_shaders,tablet,license,ota}/` + `shared/{ui,utils,constants}/` + `defaults/` + `backend/` |
| First-boot lens catalog | Embedded in APK at `res://defaults/lentes.json`; sync from `/api/lenses` when online |
| Device onboarding | Manual pre-registration of Device ID by admin |
| License model | Permanent (`license_expiry = NULL`) |
| Renderer | Start with Forward+ (current); migrate to Compatibility only if Sprint 2 PoC demands it |
| Code language | English identifiers, Spanish comments |

## Repository layout

- `project.godot` — Godot config: Forward+, D3D12, Jolt Physics, OpenXR enabled, XR shaders enabled, multiview auto, VSYNC off, physics 90 Hz, `DataManager` autoload registered.
- `autoloads/data_manager.gd` — singleton: loads `defaults/lentes.json`, exposes `get_lens(id)` / `apply_lens(id, eye)`, holds `current_vision_state` (`{left: {...}, right: {...}}`), emits `catalog_loaded` / `catalog_load_failed` / `vision_state_changed`. Skeleton only — sync with `/api/lenses` lands in Sprint 4.
- `defaults/lentes.json` — seed catalog (monofocal, panoptix, vivity) with `halo_intensity`, `contrast_loss`, `blur_near/medium/far`, `focal_distance_m`. This is the **only** lens source until F0 backend exists.
- `features/` — empty subdirs filled per sprint (see `features/README.md`).
- `shared/` — placeholder for cross-feature UI / utils / constants.
- `backend/` — FastAPI project, implemented in Sprint 3.
- `context/` — full design spec (Roadmap_Simulador_v2.md + fase_0..5.md + preguntas_abiertas.md). 📋 Notas Tecnicas in each phase file have already verified Godot 4.6 APIs — don't re-verify, use as written.

Phase dependencies: F0 independent. F1 independent. F2 and F3 depend on F1. F4 depends on F0. F5 depends on F0 and F1.

## Coding conventions

- **Language**: GDScript. English identifiers, Spanish comments.
- **Naming**: `snake_case` for variables / functions / signals; `UPPER_SNAKE_CASE` for constants.
- **Per-eye post-processing**: `SubViewportContainer` + `ShaderMaterial` with `shader_type spatial` (NOT `canvas_item`); branch on `VIEW_INDEX` inside the shader.
- **Autoloads**: no UI logic — emit signals, scenes listen.
- **License crypto**: `FileAccess.open_encrypted_with_pass()`; checksum includes `device_id` to prevent license-file copy between devices.
- **Asset packaging**: PCK uncompressed; single `manifest.json` covers APK + asset versions.

## Commands

### Godot — Android export

The CLI must use the exact preset name configured in `export_presets.cfg`. Convention here: preset name = `"Android"`.

```bash
# Debug APK (uses debug keystore — fast iteration)
godot --headless --path . --export-debug "Android" build/simulador-debug.apk

# Release APK (uses release keystore — set GODOT_ANDROID_KEYSTORE_RELEASE_* env vars)
godot --headless --path . --export-release "Android" build/simulador.apk

# Assets-only PCK (for OTA updates, F5)
godot --headless --path . --export-pack "Android" build/assets.pck

# Incremental patch PCK (only files changed vs base.pck)
godot --headless --path . --export-patch "Android" build/patch.pck --patches "build/base.pck"
```

Notes:
- `--headless` is required on environments without GPU (CI runners).
- Output paths are relative to `--path` (the project dir), not `pwd`.
- Editor must have **Android Build Template installed** (Editor → Project → Install Android Build Template) and **export templates downloaded** (Editor → Manage Export Templates).
- Quest is `arm64-v8a` only — disable `armeabi-v7a` in the preset.

### Quest 2/3 deploy

```bash
adb devices                              # confirm Quest is connected (USB + dev mode + trusted)
adb install -r build/simulador-debug.apk # install/replace
adb logcat -s godot                      # view Godot logs from the Quest
```

### Godot — open the project

The MCP config (`.mcp.json`) points to `Godot_v4.6.1-stable_win64.exe`. The project's stated version (in `AGENTS.md`) is 4.6.3. Either is fine for now; pin one once the dev environment is finalized.

### Backend (Sprint 3+ — not yet implemented)

```bash
cd backend
docker compose up -d                  # start api + db + bucket + nginx
docker compose logs -f api            # tail FastAPI logs
```

## Editor steps that aren't automatable from this repo

These belong to the human and are tracked in `progress.txt` until done:

1. Verify Project Settings → XR → OpenXR → Enabled and XR → Shaders → Enabled (the latter requires **Save & Restart**; without it `VIEW_INDEX` won't compile in shaders).
2. Confirm `DataManager` appears under Project Settings → Autoload.
3. Install Android Build Template + download Export Templates for 4.6.x.
4. Generate `debug.keystore` (see `progress.txt` for the keytool command).
5. Add the `"Android"` export preset with: package name `com.simulador.vr`, arm64-v8a only, permissions `INTERNET` + `REQUEST_INSTALL_PACKAGES`, XR Mode = OpenXR, debug keystore configured.
6. Connect Quest via USB, enable Developer Mode in the Meta app, trust the PC from inside the headset, verify `adb devices`.

## Risk register (from `context/preguntas_abiertas.md`)

- **#1 (Sprint 2, blocking)** — post-processing at 90 FPS on Quest 2 with foveated disabled. Must hit ≥72 FPS, frame time GPU < 11 ms.
- **#2 (Sprint 6, blocking)** — viewport capture for streaming is synchronous in Godot 4 → may stutter VR. PoC validates Option A; documented fallback to Option B.
- **#3** — Quest 2 vs Quest 3 perf gap. Mitigated by "primary Quest 3, best-effort Quest 2" decision.
