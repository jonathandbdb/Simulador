# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project state

**Sprints 0–8 closed. Sprint 9 (F4 licencias) is next.**

What's running end-to-end today:
- Quest 2/3: OpenXR stereo with asymmetric per-eye vision shaders (halo + DoF), lens catalog synced from backend, day/night environment transition, streaming capture to tablet, LAN discovery.
- Tablet (Android): UI driven by live catalog, blend-mode per-eye lens selection, per-eye shader preview, LAN auto-discovery of the headset.
- Backend: FastAPI + Postgres + MinIO + Caddy with full admin panel (auth, CRUD devices, lens catalog editor, version manager with APK/PCK upload, log viewer, i18n es/en).

**Documentation hierarchy:**
- `PLAN.md` — full sprint roadmap, exit criteria, locked decisions, risk register. **Source of truth for what comes next.**
- `progress.txt` — current sprint status + session notes. Updated at sprint close. Contains important bug discoveries and workarounds.
- `AGENTS.md` — original agent-facing briefing (written at project start; some sections now outdated but the API/convention notes remain valid).
- `context/` — original design specs (Roadmap_Simulador_v2.md + fase_0..5.md + preguntas_abiertas.md). 📋 Notas Técnicas in each phase file have already verified Godot 4.6 APIs — don't re-verify, use as written.

## MCP de Godot

Este proyecto tiene configurado `godot-mcp-pro` (`.mcp.json`). Usar los tools del MCP de Godot para interactuar con el editor — **no usar Engram** en este proyecto. Los tools del MCP están disponibles cuando el editor Godot está abierto con el plugin `addons/godot_mcp` habilitado.

## What this is

VR ophthalmology simulator for Meta Quest 3 (Quest 2 best-effort), built with **Godot 4.6.x + OpenXR**. Lets users experience vision through different intraocular lens types (monofocal, multifocal, PanOptix, Vivity), with independent per-eye effects (monovision/blend mode). The system also has a FastAPI backend, an Android tablet control app (also Godot), licensing (Sprint 9), and OTA updates (Sprint 12).

## Locked decisions

| Topic | Decision |
|-------|----------|
| Distribution | **Sideload** (no Meta Store) — F5 OTA implements full APK auto-install via custom Android plugin |
| Hardware target | **Quest 3 primary, Quest 2 best-effort** |
| Backend hosting | **Dedicated VPS + Docker Compose** (api, db, bucket, caddy) |
| Streaming (F3) | **Option A: real video** — validated in Sprint 6 (GO) |
| Project layout | `autoloads/` + `features/{vr_core,lenses,environment,vision_shaders,tablet,license,ota,scenarios}/` + `shared/{ui,utils,constants}/` + `defaults/` + `backend/` |
| First-boot lens catalog | Embedded in APK at `res://defaults/lentes.json`; sync from `/api/lenses` when online |
| Device onboarding | Manual pre-registration of Device ID by admin |
| License model | Permanent (`license_expiry = NULL`) |
| Renderer | Forward+ (current); migrate to Compatibility only if required |
| Code language | English identifiers, Spanish comments |
| License crypto | `FileAccess.open_encrypted_with_pass()`; checksum includes `device_id` |
| WebSocket server | `TCPServer` + `WebSocketPeer` (Godot 4 has no `WebSocketServer`) |

## Repository layout

### Godot project root
- `project.godot` — Forward+, D3D12, Jolt Physics (90 Hz), OpenXR + XR shaders + multiview auto, VSYNC off. Registered autoloads: `DataManager`, `StreamingServer`, `DiscoveryBeacon`, plus MCP addon services.
- `defaults/lentes.json` — seed lens catalog (monofocal, panoptix, vivity) with `halo_intensity`, `contrast_loss`, `blur_near/medium/far`, `focal_distance_m`. Only lens source if backend is unreachable.
- `export_presets.cfg` — two presets: `"Android"` (headset, package `com.simulador.vr`, OpenXR, Meta plugin) and `"AndroidTablet"` (tablet, package `com.simulador.tablet`, no XR, custom feature `"tablet"`).

### `autoloads/`
- `data_manager.gd` — loads lens catalog (priority: `user://lentes.json` → `res://defaults/lentes.json` → backend sync). Exposes `get_lens(id)`, `get_lens_ids()`, `apply_lens(id, eye)`, `override_params(params, eye)`, `refresh_from_backend()`. Holds `current_vision_state = {left:{}, right:{}}`. Emits `catalog_loaded` / `catalog_synced_with_backend` / `catalog_sync_failed` / `vision_state_changed`. **`BACKEND_URL` is hardcoded to LAN dev IP** — update before exporting for Quest on a different network.
- `streaming_server.gd` — WebSocket server (port 9090) running on the headset. Accepts tablet clients, broadcasts JPG frames, handles bidirectional JSON commands (`command_received` signal). Disabled on tablet builds (`OS.has_feature("tablet")`).
- `discovery_beacon.gd` — UDP broadcast (port 9091). Headset: sends beacon every 2s. Tablet: listens and emits `visor_discovered(host, payload)`.

### `features/`
- `vr_core/main.tscn` + `main.gd` — root scene. Bootstraps OpenXR, sets up `SubViewport` + `SubViewportContainer` + `ShaderMaterial` for per-eye post-processing. Connects to `DataManager` signals, applies lens uniforms to `sprint2_blur_test.gdshader` on `vision_state_changed`. Handles XRController3D input (A/B buttons for lens cycling per eye, trigger to reset blend). FpsHud + SyncHud + StreamHud Label3D overlays.
- `vision_shaders/sprint2_blur_test.gdshader` — the main vision shader. `shader_type spatial`. Branches on `VIEW_INDEX` for asymmetric per-eye effects. Box blur 9-tap, halo 2-ring with quadratic falloff + yellow tint, depth conversion via `INV_PROJECTION_MATRIX`. Uniforms: `blur_radius_px_l/r`, `halo_intensity_l/r`, `contrast_loss_l/r`, `focal_distance_m_l/r`, `halo_threshold`.
- `vision_shaders/fade.gdshader` — spatial unshaded blend_mix shader for fade-to-black (uniform `alpha`).
- `vision_shaders/eye_test.gdshader` — left=red, right=blue; used in Sprint 1 validation only.
- `tablet/streaming_capture.gd` — `SubViewport` 320×320 rendered at 10 Hz; `save_jpg_to_buffer` (q=0.55) dispatched to `WorkerThreadPool` to avoid main-thread stall.
- `tablet/streaming_client.tscn` + `.gd` — tablet control UI. Receives lens catalog via WebSocket "hello", shows per-eye preview using `eye_preview.gdshader` (canvas_item shader that simulates blur/halo client-side from catalog params), split-panel UI in blend mode.
- `tablet/eye_preview.gdshader` — `shader_type canvas_item`. Box blur 9-tap (radius 8 px), 2-ring halo, contrast loss. Applied to each TextureRect panel to simulate per-eye appearance without extra SubViewports.
- `features/scenarios/consultorio/` — immersive office scene (Sprint 10, PENDING). Book holder anchored to right XRController, `runtime_focus_error` uniform driven by hand–camera distance vs `focal_distance_m`.
- `features/scenarios/auto_noche/` — night driving scene (Sprint 11, PENDING). Traffic spawner on Path3D, phone grabber for left controller.

### `backend/`
Full FastAPI + Postgres 16 + MinIO + Caddy stack.
- `docker-compose.yml` — four services: `api`, `db`, `bucket`, `caddy`. `../defaults/lentes.json` mounted as seed.
- `api/app/` — `config.py`, `database.py`, `models.py`, `seed.py`, `routers/` (public: `manifest`, `verify`, `lenses`, `log`), `admin/` (auth JWT, CRUD devices, lens catalog, version upload, logs, i18n es/en, MinIO storage wrapper, Jinja2 templates).
- Templates: `base.html` (Tailwind CDN + HTMX CDN, navbar, flash messages), `login`, `dashboard`, `devices`, `lenses` (visual table editor + raw JSON tab), `versions`, `logs`.
- Default credentials (seed): `admin` / `admin123` — rotate before production.

## Coding conventions

- **Language**: GDScript. English identifiers, Spanish comments.
- **Naming**: `snake_case` for variables / functions / signals; `UPPER_SNAKE_CASE` for constants.
- **Per-eye post-processing**: `SubViewportContainer` + `ShaderMaterial` with `shader_type spatial` (NOT `canvas_item`); branch on `VIEW_INDEX` inside the shader.
- **Autoloads**: no UI logic — emit signals, scenes listen.
- **`blend_mode_enabled`**: informational flag only — `apply_lens()` always respects the `eye` parameter regardless. Blend is active when `left.lens_id != right.lens_id`.
- **Tablet feature detection**: `OS.has_feature("tablet")` — set by the `AndroidTablet` export preset's custom features field.

## Commands

### Godot — Android export

```bash
# Debug APK (uses debug keystore)
godot --headless --path . --export-debug "Android" build/simulador-debug.apk

# Release APK
godot --headless --path . --export-release "Android" build/simulador.apk

# Tablet APK
godot --headless --path . --export-debug "AndroidTablet" build/SimuladorTablet.apk

# Assets-only PCK (for OTA updates, Sprint 12)
godot --headless --path . --export-pack "Android" build/assets.pck
```

Notes:
- `--headless` is required on environments without GPU (CI runners).
- Output paths are relative to `--path` (the project dir), not `pwd`.
- Editor must have **Android Build Template installed** and **export templates downloaded**.
- Quest is `arm64-v8a` only — disable `armeabi-v7a` in the preset.

### Quest 2/3 deploy

```bash
adb devices                              # confirm Quest is connected (USB + dev mode + trusted)
adb install -r build/simulador-debug.apk
adb logcat -s godot                      # view Godot logs from the Quest
```

### Backend

```bash
cd backend
docker compose up -d                  # start api + db + bucket + caddy
docker compose logs -f api            # tail FastAPI logs
docker compose up -d --force-recreate caddy  # reload Caddy config after .env change
```

Local URL: `http://localhost:8080`. Admin panel: `http://localhost:8080/admin`.

**Important `.env` gotcha**: use `${DOMAIN-localhost}` (no colon) in `docker-compose.yml` when you need to allow an empty string. `${DOMAIN:-localhost}` falls back to `localhost` even when `DOMAIN=` (empty), causing Caddy to only accept `Host: localhost` and block LAN requests from the Quest. See `progress.txt` Sprint 4 for full diagnosis.

## Known open issues / TODOs

- **`BACKEND_URL` hardcoded** in `autoloads/data_manager.gd` to `http://192.168.88.198:8080` (LAN dev IP). Update this before building for Quest on any other network. A runtime-configurable resolver was attempted and reverted (Android 11+ scoped storage blocked `user://backend_url.txt` reads) — see `progress.txt` for details.
- **MulticastLock**: UDP discovery broadcasts may be filtered on some Android Wi-Fi chips when in standby. If discovery fails in the field, add `CHANGE_WIFI_MULTICAST_STATE` permission + plugin. Tracked as post-Sprint 7 pending.
- **Stream split**: in blend mode the tablet shows the same raw frame in both eye panels (no per-eye shader applied at source). The client-side `eye_preview.gdshader` simulates the difference visually, but it is not pixel-accurate. Two full SubViewports with shaders would require double bandwidth — deferred to a future sprint.
- **Handshake with `device_id`** in StreamingServer: deferred to Sprint 9 (depends on LicenseManager).

## Risk register

- **R1 (Sprint 2, closed GO)** — post-processing at 90 FPS on Quest 2. Result: 70 FPS avg, 13 ms frame time, no stuttering on Quest 2. Mitigations applied: `filter_linear` (no mipmaps) on `hint_screen_texture`, FSR disabled for Quest Link compatibility.
- **R2 (Sprint 6, closed GO)** — synchronous viewport capture stuttering VR. Mitigated by `WorkerThreadPool` for JPG encoding + 320×320 @ 10 Hz.
- **R3** — Quest 2 vs Quest 3 perf gap. Ongoing: best-effort on Quest 2, primary target Quest 3.

## Editor steps that aren't automatable from this repo

Tracked in `progress.txt` until done:

1. Verify Project Settings → XR → OpenXR → Enabled and XR → Shaders → Enabled (requires Save & Restart; without it `VIEW_INDEX` won't compile).
2. Confirm `DataManager`, `StreamingServer`, `DiscoveryBeacon` appear under Autoload.
3. Install Android Build Template + download Export Templates for 4.6.x.
4. Ensure `debug.keystore` is generated and configured in the `"Android"` preset.
5. Add/verify the `"Android"` export preset: package `com.simulador.vr`, arm64-v8a only, `INTERNET` + `REQUEST_INSTALL_PACKAGES`, XR Mode = OpenXR, Meta plugin enabled, Gradle Build enabled.
6. Add/verify the `"AndroidTablet"` preset: package `com.simulador.tablet`, XR Mode = Regular, Meta plugin off, custom features = `tablet`.
