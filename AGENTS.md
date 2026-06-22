# AGENTS.md — Brief del Simulador VR Oftalmológico

> **Este archivo es el brief canónico para agentes.** Si sos un subagente del enjambre (`blender-modeler`, `godot-builder`, `scene-verifier`, `project-explorer`) **leelo primero**: te da el mapa del proyecto, el estado real y las convenciones. Es la fuente de verdad agent-facing y se mantiene actualizado. Identificadores en **inglés**, comentarios en **español**.

## Qué es

Simulador de visión oftalmológica en **VR** para **Meta Quest 3** (Quest 2 best-effort), construido con **Godot 4.6.x + OpenXR** (renderer Forward+, multiview). Permite experimentar cómo se ve el mundo a través de distintas lentes intraoculares (monofocal, multifocal, PanOptix, Vivity), con efectos **independientes por ojo** (modo blend / monovisión). Incluye backend FastAPI, app de tablet de control (también en Godot), licencias y actualizaciones OTA.

## Estado actual (lo más importante)

- **Sprints 0–8 CERRADOS.** Corre end-to-end: OpenXR estéreo con shaders de visión asimétricos por-ojo (halo + DoF), catálogo de lentes sincronizado desde backend, transición día/noche, streaming a tablet, descubrimiento LAN. Backend completo (FastAPI + Postgres + MinIO + Caddy) con panel admin. App de tablet operativa.
- **Sprint 9 (F4 licencias) es el próximo.** Sprint 10 (escenario consultorio inmersivo) está en progreso parcial.
- **El proyecto YA tiene código** — no estás en fase de diseño. No re-debatas decisiones bloqueadas.

## Jerarquía de documentación (qué leer y cuándo)

| Doc | Para qué |
|-----|----------|
| `PLAN.md` | **Fuente de verdad de lo que viene**: sprints, criterios de salida, decisiones bloqueadas, riesgos. |
| `progress.txt` | Estado por sprint + **bugs descubiertos y workarounds** (leer antes de tocar algo frágil). |
| `CLAUDE.md` | Comandos (build/export/adb/backend), convenciones, known issues/TODOs, tabla completa de decisiones bloqueadas. |
| `MEMORY.md` + `memory/` | Aprendizajes durables entre sesiones (glare, perf, optimizaciones, estructura de assets). Consultá antes de re-investigar. |
| `context/fase_0..5.md` + `Roadmap_Simulador_v2.md` | Specs originales. Sus **📋 Notas Técnicas** tienen APIs de Godot 4.6 **ya verificadas — usalas como están, no re-verifiques**. |

## Arquitectura (dónde está cada cosa)

Raíz: `C:\Users\jvare\OneDrive\Documents\simulador`.

- **`autoloads/`** — `data_manager.gd` (catálogo de lentes: `user://` → `res://defaults/lentes.json` → backend; `current_vision_state`, señal `vision_state_changed`), `streaming_server.gd` (WebSocket :9090, desactivado en builds tablet), `discovery_beacon.gd` (UDP :9091). Los autoloads **no llevan lógica de UI**: emiten señales, las escenas escuchan.
- **`features/vr_core/`** — `main.tscn` + `main.gd`: escena raíz. Bootstrap OpenXR; `SubViewport` + `SubViewportContainer` + `ShaderMaterial` para post-proceso por-ojo; `ScenarioContainer` donde se cargan escenarios; diccionario `SCENARIOS` define por-escena `halos/astigmatism/env(day|night)/show_book/halo_threshold/foveation/glow`.
- **`features/vision_shaders/`** — `sprint2_blur_test.gdshader` (shader principal `spatial`, ramifica en `VIEW_INDEX`: blur box 9-tap, halo 2-anillos, contraste, DoF), `fade.gdshader`, `glare_billboard.gdshader` + `glare_source.gd`, `eye_test.gdshader`.
- **`features/scenarios/`** — `consultorio/` (oficina inmersiva + libro en mano, `book_holder.gd`; cerrada con `room_shell.glb` + `tree.glb`), `ruta_noche/` (escena **100% code-gen** en `_ready()` — referencia canónica del patrón generativo: `ruta_noche.gd` + `ruta_traffic.gd`).
- **`features/tablet/`** — captura de streaming (`SubViewport` 320×320 @10Hz, JPG en `WorkerThreadPool`), `streaming_client.*` (UI control), `eye_preview.gdshader` (canvas_item, simula por-ojo en la tablet).
- **`backend/`** — FastAPI + Postgres 16 + MinIO + Caddy vía Docker Compose. `api/app/` (config, models, seed, routers públicos + `admin/` con auth JWT, CRUD devices, editor de lentes, version manager, logs, i18n es/en, Jinja2 + HTMX + Tailwind).
- **`defaults/lentes.json`** — catálogo seed (única fuente si el backend no responde). `export_presets.cfg` — presets `Android` (visor, `com.simulador.vr`, OpenXR) y `AndroidTablet` (`com.simulador.tablet`, sin XR, feature `tablet`).
- **`assets/scenarios/<escena>/<asset>/`** — modelos (glb/fbx/gltf/obj) + texturas, todo commiteado con sus `.import`.

## Convenciones técnicas (respetalas)

- **Post-proceso por-ojo**: `SubViewportContainer` + shader `shader_type spatial` (NUNCA `canvas_item`) ramificando en `VIEW_INDEX`. (Setup de OpenXR: XR + Shaders habilitados en Project Settings, requiere Save & Restart, si no `VIEW_INDEX` no compila.)
- **Halos/glare = arquitectura GlareSource**: billboards con `render_priority 10` + material emissive con energy alto. En Quest/multiview el backbuffer **no genera mips**, por eso el halo es procedural por billboard, NO screen-space. Ver `memory/glare-billboard-architecture.md`.
- **Iluminación por escena** según `SCENARIOS` en `main.gd`. Ej.: consultorio = `env="day"`, `halos=false`, **glow apagado** (lectura de cerca). No agregues glow/GlareSource ahí salvo pedido explícito.
- **Escenarios nuevos**: seguí el patrón code-gen de `ruta_noche.gd` (cargar assets con `load()`, construir materiales/meshes por código, repetir módulos). Filtrado anisotrópico en texturas de lectura cercana (patrón en `book_holder.gd`).
- **Naming**: `snake_case` (vars/funcs/señales), `UPPER_SNAKE_CASE` (constantes). GDScript, identificadores en inglés, comentarios en español.

## Decisiones bloqueadas (resumen — tabla completa en `CLAUDE.md` y `PLAN.md`)

Sideload (sin Meta Store) · Quest 3 primario/Quest 2 best-effort · backend VPS + Docker Compose (api+Postgres+MinIO+Caddy) · streaming = video real (validado) · catálogo embebido + sync `/api/lenses` · alta de visor manual por admin · **licencias permanentes** (`license_expiry = NULL`) · Forward+ (migrar a Compatibility solo si perf lo exige) · cifrado licencia con checksum atado a `device_id`. **No re-debatir sin justificación fuerte.**

## MCP + el enjambre

El proyecto usa **`godot-mcp-pro`** (editor Godot) y **`blender-mcp`** (Blender) — definidos en `.mcp.json`. **No usar Engram en este proyecto.**

- **Regla EDITOR vs RUNTIME (Godot MCP)**: tools de *editor* (escena/nodos/scripts/recursos/screenshots de editor) están siempre disponibles; tools de *runtime* (`get_game_*`, `execute_game_script`, `simulate_*`) **fallan sin el juego corriendo**. Para medir AABB/propiedades usá `execute_editor_script`. El runtime XR puede dar screenshots negros sin sesión OpenXR.
- **Instancia única / serializar mutaciones**: hay UN editor Godot y UN Blender. **Nunca mutar el mismo editor en paralelo** entre agentes; las mutaciones se serializan. El paralelismo seguro es solo-lectura + cruce Blender‖Godot.
- **Enjambre** (`.claude/agents/` + workflow `.claude/workflows/blender-to-godot.js`):
  - **`blender-modeler`** — modela/exporta glb vía Blender MCP. Entrega assets a `godot-builder`.
  - **`godot-builder`** — escenas/nodos/materiales/shaders vía Godot MCP. Siempre `save_scene` + chequear `get_editor_errors`.
  - **`scene-verifier`** — solo-lectura: medidas, screenshots, perf, errores. Nunca muta.
  - **`project-explorer`** — solo-lectura: investigación general del repo (código, backend, docs).
  - **Gotcha**: los subagentes custom de `.claude/agents/` se registran al **iniciar sesión**; recién creados/editados no son invocables con la tool Agent en la misma sesión (usar la tool Workflow, que los resuelve por `agentType`, o manejar los MCP directamente). PolyHaven en Blender viene **deshabilitado** por defecto.

## Pasos de editor no automatizables (estado en `progress.txt`)
Verificar XR/OpenXR + Shaders habilitados (Save & Restart); autoloads bajo Autoload; Android Build Template + export templates 4.6.x; `debug.keystore`; presets `Android`/`AndroidTablet`. `BACKEND_URL` está hardcodeado en `autoloads/data_manager.gd` (IP LAN dev) — actualizar antes de exportar a otra red.
