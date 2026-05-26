# PLAN.md — Plan de sprints del Simulador VR Oftalmologico

Plan de ejecucion por sprints. Es la fuente de verdad operativa: orden, hitos y criterios de salida.
Para el detalle tecnico de cada fase ver `context/fase_N_*.md`.
Para el estado actual del avance ver `progress.txt`.

---

## Decisiones bloqueadas (no re-discutir sin justificacion fuerte)

| # | Tema | Decision |
|---|------|----------|
| 1 | Distribucion | Sideload (sin Meta Store) |
| 2 | Hardware | Quest 3 primario, Quest 2 best-effort |
| 3 | Backend | VPS dedicado + Docker Compose (api + db Postgres + bucket MinIO + nginx con TLS) |
| 4 | Streaming F3 | Opcion A (video real) — PoC bloqueante en Sprint 6, fallback documentado a B |
| 5 | Estructura repo | `autoloads/` + `features/{vr_core,lenses,environment,vision_shaders,tablet,license,ota}/` + `shared/{ui,utils,constants}/` + `defaults/` + `backend/` |
| 6 | Catalogo en primer arranque | Embebido en APK (`res://defaults/lentes.json`); sync con `/api/lenses` cuando hay internet |
| 7 | Alta de visor | Pre-registro manual del Device ID por el admin |
| 8 | Modelo de licencias | Permanentes (`license_expiry = NULL`) |
| 9 | Renderer | Forward+ por defecto; migrar a Compatibility solo si Sprint 2 lo exige |
| 10 | Idioma codigo | Identificadores ingles, comentarios espanol |
| 11 | Cifrado licencia | Server es fuente de verdad; `license.bin` local es cache con checksum atado al `device_id` |
| 12 | Equipo | 1 dev (secuencial, 1 frente activo a la vez) |

---

## Riesgos criticos identificados

| # | Riesgo | Sprint que lo valida | Mitigacion si falla |
|---|--------|---------------------|---------------------|
| R1 | Post-procesado asimetrico a 90 FPS en Quest 2 con foveated desactivado | Sprint 2 (GO/NO-GO) | Bajar a 72 Hz, reducir taps de blur, migrar a Compatibility, o Quest 3 obligatorio |
| R2 | Captura sincrona de viewport en Godot 4 puede stutterar VR | Sprint 6 (GO/NO-GO) | Pivotar a Opcion B (replicacion 2D sincrona) |
| R3 | Brecha rendimiento Quest 2 vs Quest 3 | Continuo | Best-effort en Quest 2, target real Quest 3 |

---

## Sprints

### Sprint 0 — Setup del proyecto
**Estado:** CERRADO ✅
**Objetivo:** proyecto deployable a Quest con un comando.
**Entregables:**
- `project.godot` con OpenXR + XR shaders + multiview + VSYNC off + physics 90Hz + autoload `DataManager`.
- Estructura de carpetas (`autoloads/`, `features/`, `shared/`, `defaults/`, `backend/`).
- `defaults/lentes.json` con 3 lentes seed (monofocal, panoptix, vivity).
- `autoloads/data_manager.gd` esqueleto.
- `.gitignore`, `CLAUDE.md`, `progress.txt`, `AGENTS.md`.
- Plugin `godot_openxr_vendors` instalado, Meta plugin habilitado, Gradle Build activado.
- Debug keystore generado, export preset Android configurado, Quest conectado por adb.
**Criterio de salida:** APK instalado en Quest, app arranca sin error de OpenXR.

### Sprint 1 — F1 minima (OpenXR + VIEW_INDEX)
**Estado:** CERRADO ✅
**Objetivo:** validar visualmente que el Blend tecnico funciona.
**Entregables:**
- `features/vr_core/main.tscn`: XROrigin3D + XRCamera3D + EyeTestQuad + 2 XRController3D.
- `features/vr_core/main.gd`: bootstrap OpenXR.
- `features/vision_shaders/eye_test.gdshader`: shader spatial con `VIEW_INDEX` ramificado.
- `run/main_scene` apuntando a la escena.
**Criterio de salida:** ojo izquierdo rojo, ojo derecho azul en Quest 2.

### Sprint 2 — F2 PoC GO/NO-GO ⚠️ BLOQUEANTE
**Estado:** CERRADO ✅ (con GO en Quest 2: 70 FPS avg, 13 ms frame time, sin stuttering)
**Objetivo:** medir si el simulador es viable a >=72 FPS en Quest 2 con post-procesado asimetrico.
**Entregables:**
- `SubViewport` + `SubViewportContainer` + `ShaderMaterial spatial`.
- Shader screen-reading con `hint_screen_texture` + `hint_depth_texture`.
- Box blur 9-tap asimetrico por ojo + halo simple en zonas brillantes.
- Conversion depth a metros con `INV_PROJECTION_MATRIX`.
- `scaling_3d_scale = 0.85` con FSR para compensar foveated desactivado.
- HUD debug en VR mostrando FPS y frame time.
- Mediciones registradas en `progress.txt`.
**Criterio GO:** >=72 FPS estables, frame time GPU < 11ms en Quest 2.
**Si NO-GO:** documentar en `progress.txt` cual de las mitigaciones (R1) se aplica antes de Sprint 5.
**Hito:** video grabado del Quest mostrando blur diferente por ojo + tabla de mediciones.

### Sprint 3 — F0 backend minimo
**Estado:** EN CURSO (fase local CERRADA ✅, fase VPS pendiente)
**Objetivo:** API REST publica desplegada en el VPS.
**Entregables:**
- `backend/docker-compose.yml`: api (FastAPI) + db (Postgres 16) + bucket (MinIO) + nginx con  TLS.
- Schema DB: `devices`, `versions`, `update_logs`, `lenses_catalog`, `admin_users`.
- Endpoints publicos: `GET /api/manifest.json`, `POST /api/verify`, `GET /api/lenses`, `POST /api/log`.
- Seed: 1 admin, 1 version dummy activa, 1 catalogo activo.
- Rate limiting en `/api/verify` (1/min/IP).
- HTTPS via Let's Encrypt.
**Criterio de salida:** `curl https://api.tu-dominio.com/api/manifest.json` retorna 200 desde el VPS.

### Sprint 4 — F1 completa
**Estado:** CERRADO ✅
**Objetivo:** simulador con catalogo dinamico y entorno 3D.
**Entregables:**
- `DataManager` con sync remoto (`/api/lenses`), fallback a defaults, cache en `user://lentes.json`.
- `features/environment/`: sala 3D placeholder + transicion dia/noche con `Tween`.
- Fade to black via Quad 3D negro frente a la camara (Q1.2 opcion A).
- Estado binocular completo: `current_vision_state = {left:{}, right:{}}`.
**Criterio de salida:** el visor arranca, lee catalogo, muestra sala con luz que transiciona dia/noche.
**Nota:** `BACKEND_URL` quedo hardcodeada a la IP de LAN de desarrollo (`http://192.168.2.12:8080`). TODO post-Sprint 5: investigar por que el resolver runtime no funciono en Quest (probable scoped storage Android 11+) y volver a una solucion configurable.

### Sprint 5 — F2 completa
**Estado:** CERRADO ✅
**Objetivo:** shaders de lentes reales conectados al catalogo.
**Entregables:**
- Shader unificado halo + DoF con threshold de brillo (Q2.3 opcion C).
- Parametros `near/medium/far` por ojo conectados al `DataManager`.
- 3-4 lentes reales del catalogo aplicables en runtime.
- UI debug temporal en VR para cambiar de lente con el control derecho.
**Criterio de salida:** cambiar de lente en VR muestra diferencia visual notable; modo Blend con lentes distintas por ojo funciona.
**Nota:** durante Sprint 5 se descubrio y corrigio un bug en `DataManager.apply_lens()` que ignoraba el parametro `eye` cuando `blend_mode_enabled=false`, sobrescribiendo siempre ambos ojos. Ahora `blend_mode_enabled` es solo un flag informativo, calculado a partir del estado de los dos ojos.

### Sprint 6 — F3 PoC streaming GO/NO-GO ⚠️ BLOQUEANTE
**Estado:** CERRADO ✅ (GO)
**Objetivo:** validar la opcion A (video real) del streaming.
**Entregables:**
- `SubViewport` 256x256 con `render_target_update_mode = UPDATE_ONCE` disparado por Timer a 10 Hz. ✅ `features/tablet/streaming_capture.gd`
- `WebSocketPeer` server en el visor (`TCPServer` + `accept_stream`). ✅ `autoloads/streaming_server.gd` puerto 9090.
- Cliente Godot minimo en PC que recibe bytes, `Image.load_jpg_from_buffer`, `ImageTexture.update`, `TextureRect`. ✅ `features/tablet/streaming_client.tscn`.
- HUD `StreamHud` en el visor (clients/frames/KB). ✅
**Resultado:** primera prueba (512x512 @ 15 Hz, encoding en main thread) bajaba FPS a 30-40. Tras optimizar (256x256, 10 Hz, JPG q=0.4 y mover `save_jpg_to_buffer` a `WorkerThreadPool`), el visor mantiene FPS estable en Quest 2 con streaming activo, cumpliendo el criterio GO. En Quest 3 deberia ser holgado.
**Pendiente para Sprint 7:** medicion fina con perfviewer + decisiones sobre canal de control bidireccional.

### Sprint 7 — F3 completa
**Estado:** EN CURSO
**Objetivo:** tablet de control funcional.
**Entregables:**
- WebSocket protocol con dos canales (control JSON / stream binario).
- Cliente tablet completo: UI dinamica desde el JSON del catalogo, modo Blend con paneles divididos.
- Hardware binding del WebSocket: handshake con `device_id`, whitelist cacheada de `/api/admin/devices`. **[Pospuesto a Sprint 9 — depende de licencias]**
- Build separado para Android (tablet) ademas del Quest.
**Criterio de salida:** desde la tablet se cambia de lente y el visor responde; modo Blend funciona desde la tablet.

### Sprint 8 — F0 panel admin
**Estado:** PENDIENTE
**Objetivo:** admin gestiona el sistema sin tocar codigo.
**Entregables:**
- Auth JWT + bcrypt.
- CRUD dispositivos.
- Editor de catalogo de lentes (textarea JSON + validacion + preview).
- Gestor de versiones (upload APK/PCK con SHA256 server-side, subida a MinIO, marcar activa).
- Visor de logs con filtros y export CSV.
- Dashboard con estadisticas.
- Stack: Jinja2 + HTMX + Tailwind.
**Criterio de salida:** el admin registra un visor, sube una version y la activa, todo desde el navegador.

### Sprint 9 — F4 licencias
**Estado:** PENDIENTE
**Objetivo:** sistema offline-first con periodo de gracia.
**Entregables:**
- `LicenseManager` autoload corre en `_init()`, antes que cualquier escena.
- POST `/api/verify` con timeout 5s.
- `license.bin` cifrado con `open_encrypted_with_pass` (password = `OS.get_unique_id()` + salt).
- Checksum incluyendo `device_id` (anti-copia entre visores).
- Periodo de gracia: 7 dias.
- `LicenseErrorScreen` (CanvasLayer) con `OS.get_unique_id()` + codigo de error.
**Criterio de salida:** visor sin internet 5 dias sigue funcionando; al dia 8 muestra bloqueo. Server 403 bloquea inmediato.

### Sprint 10 — F5 OTA core
**Estado:** PENDIENTE
**Objetivo:** auto-actualizacion de assets (PCK) funcionando.
**Entregables:**
- `UpdateManager` autoload con logica APK vs PCK.
- Descarga con `download_file` + barra de progreso real.
- Verificacion SHA256 con `FileAccess.get_sha256` antes de cargar PCK.
- `load_resource_pack` en `_init()` (CRITICO: no en `_ready`).
- Boot counter en `user://boot_counter.txt` con rollback automatico a 3 crashes.
- Factory reset oculto (combinacion de botones del controller).
- Log en `user://log_update.txt` enviado a `/api/log`.
**Criterio de salida:** subir un PCK al panel -> el visor lo detecta al arrancar, descarga, verifica, aplica. Inducir corrupcion provoca rollback.

### Sprint 11 — F5 plugin Android + CI/CD
**Estado:** PENDIENTE
**Objetivo:** auto-actualizacion de APK + pipeline automatizado.
**Entregables:**
- Plugin Android Java/Kotlin: `install_apk(path)` con FileProvider + `Intent.ACTION_VIEW` + `application/vnd.android.package-archive`.
- Permisos `REQUEST_INSTALL_PACKAGES` + FileProvider en `AndroidManifest.xml`.
- GitHub Actions: trigger `git tag v*` -> export APK + PCK -> SHA256 -> upload a MinIO -> POST a `/api/admin/versions` con API key.
**Criterio de salida:** `git tag v0.1.0 && git push --tags` -> el visor se autoactualiza al siguiente arranque.

### Sprint 12 — Hardening
**Estado:** PENDIENTE
**Objetivo:** estabilidad y operabilidad.
**Entregables:**
- GUT tests para logica pura (DataManager, LicenseManager, UpdateManager parsers).
- Checklist manual de release documentado.
- Documentacion operativa: como registrar visor nuevo, como publicar version, como diagnosticar visor caido.
- Metricas baseline registradas en cada Quest.
**Criterio de salida:** documento "Operations Manual" + suite de tests verde en CI.

---

## Estimacion (1 dev part-time, 10-15 h/semana)

- Sprints 0-2 (setup + GO/NO-GO critico): 4-5 semanas. **Zona de mayor riesgo.**
- Sprints 3-7 (backend minimo + F1/F2/F3 completas): 8-10 semanas.
- Sprints 8-12 (panel + licencias + OTA + CI/CD + hardening): 10-12 semanas.

**Total: ~25-30 semanas (~6-7 meses) part-time** hasta producto operable end-to-end.
Full-time: ~3-4 meses.

---

## Como mantener este documento

- **No editar a mitad de un sprint.** Si surge una decision durante un sprint que cambia el plan, anotarla en `progress.txt` y formalizarla aca al cerrar el sprint.
- Marcar sprints como CERRADO cuando se cumple el criterio de salida.
- Si un sprint cambia de alcance, actualizar el bloque del sprint y dejar nota en `progress.txt`.
- Las decisiones bloqueadas no se cambian salvo que un sprint demuestre que son inviables. En ese caso: documentar en `progress.txt` el por que del cambio.
