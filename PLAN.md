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
**Estado:** CERRADO ✅
**Objetivo:** tablet de control funcional.
**Entregables:**
- WebSocket protocol con dos canales (control JSON / stream binario). ✅
- Cliente tablet completo: UI dinamica desde el JSON del catalogo, modo Blend con selector de ojo + lista de lentes desde catalogo. ✅
- Hardware binding del WebSocket: handshake con `device_id`, whitelist cacheada de `/api/admin/devices`. **[Pospuesto a Sprint 9 — depende de licencias]**
- Build separado para Android (tablet) ademas del Quest. ✅ (preset `AndroidTablet`)
- Discovery LAN automatico (extra): autoload `DiscoveryBeacon` con UDP broadcast en :9091 — la tablet detecta el visor sin tener que tipear IP. ✅
**Resultado:** desde la tablet se cambia de lente y el visor responde; modo Blend funciona; descubrimiento automatico en LAN. Calidad del stream subida a 320x320 q=0.55 sin penalidad de FPS perceptible. HUDs del visor reducidos para no estorbar.
**Pendientes para sprints futuros (no bloqueantes):** `MulticastLock` en Android si el discovery falla en campo, subir mas la resolucion del stream cuando se mida margen en Quest 3, indicador visual de reconexion en la tablet.

### Sprint 8 — F0 panel admin
**Estado:** CERRADO ✅
**Objetivo:** admin gestiona el sistema sin tocar codigo.
**Entregables:**
- Auth JWT + bcrypt en cookie httpOnly. ✅
- i18n configurable (es/en) con cookie + selector en navbar. ✅
- CRUD dispositivos (alta, edicion inline en tabla, baja con confirmacion). ✅
- Editor de catalogo de lentes (textarea JSON + validacion + activacion). ✅
- Gestor de versiones (upload multipart APK + PCK, SHA256 server-side, MinIO, activacion). ✅
- Visor de logs con filtros (device_id, evento, rango de fechas) + paginacion + export CSV. ✅
- Dashboard con estadisticas (totales devices, version y catalogo activos, ultimos eventos). ✅
- Stack: FastAPI + Jinja2 + HTMX + Tailwind (CDN). ✅
- Endpoint `/files/<key>` que proxea desde MinIO al cliente (Quest descarga APK/PCK sin tocar el bucket directo). ✅
- `ensure_bucket()` en startup (crea bucket si falta, idempotente). ✅
**Criterio de salida:** smoke test verde — login con `admin/admin123`, dashboard renderiza, CRUD device + ver listado funciona, lenses/versions/logs cargan, idioma EN/ES se intercambia, redirect a login cuando no hay sesion.

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

### Sprint 10 — Escenario inmersivo A: Consultorio + libro en mano
**Estado:** PENDIENTE
**Objetivo:** primer escenario 3D inmersivo. El paciente se sienta en un consultorio virtual y sostiene un libro 3D anclado al joystick derecho. Al acercarlo o alejarlo, el blur cambia segun la `focal_distance_m` de la lente activa. Valida el patron "distancia controller -> camara -> blur por ojo".

**Decisiones tecnicas:**
- Assets: Polyhaven (CC0) para escena base — habitacion, escritorio, silla, lampara, libro 3D. Formato `.glb` importado a `res://assets/scenarios/consultorio/`.
- Iluminacion: una `DirectionalLight3D` (luz exterior atenuada) + `OmniLight3D` (lampara de escritorio). `WorldEnvironment` con `glow_enabled = false` (no se necesitan halos aca).
- Libro: `Node3D` hijo de `XRController3D` (mano derecha). Se mueve con la mano fisicamente.
- Calculo de blur dinamico: cada frame, `distancia = (controller.global_position - xr_camera.global_position).length()`. Diferencia con `lens.focal_distance_m` se mapea a un nuevo uniform del shader del Sprint 2: `runtime_focus_error` (float 0..1). El shader existente sumara este factor al `blur_near` base.
- Aplicacion por ojo independiente: cada `SubViewportContainer` ya tiene su `lens_id`. El `runtime_focus_error` se calcula UNA vez pero el blur final usa el `focal_distance_m` propio de cada ojo.
- Boton del joystick A: "resetear posicion del libro al regazo" (Vector3 fijo offset de la camara).
- Selector de escenario: nuevo menu radial in-VR + comando WS desde tablet `{ "cmd": "load_scenario", "id": "consultorio" }`.

**Estructura:**
- `features/scenarios/consultorio/consultorio.tscn` — escena raiz cargable.
- `features/scenarios/consultorio/book_holder.gd` — script del libro: distance tracking + signal `focus_distance_changed`.
- `features/scenarios/scenario_manager.gd` (autoload) — carga/descarga escenarios bajo demanda.
- `features/vision_shaders/eye_shader.gdshader` — ampliado con uniform `runtime_focus_error`.

**Entregables:**
- Escena consultorio cargable y navegable a 90 FPS (Quest 3) / >=72 FPS (Quest 2).
- Libro anclado al controller derecho, visible y manipulable.
- Blur se actualiza en tiempo real al mover el libro: cerca del rostro -> blur si la lente no enfoca cerca.
- Tablet puede cambiar escenario via WS.
- `ScenarioManager` autoload registrado y verificado.
- Test manual: monofocal (focal=6m) -> libro a 30cm = muy borroso; PanOptix (focal=0.4m) -> libro a 30cm = nitido. Resultado coherente con la lente.

**Criterio de salida:** smoke test in-VR — usuario entra al consultorio, le aplican PanOptix en ambos ojos, ve el libro nitido a 30cm. Aplican monofocal en ojo izquierdo: ojo izquierdo borroso, derecho nitido (blend funcionando con interaccion).

### Sprint 11 — Escenario inmersivo B: Auto de noche + halos
**Estado:** PENDIENTE
**Objetivo:** segundo escenario, foco en `halo_intensity`. El paciente esta sentado en el asiento del conductor de un auto detenido al costado de una ruta nocturna. Pasan autos en sentido contrario con faros encendidos. Un celular con pantalla emisiva esta apoyado en el tablero. Valida halos nocturnos diferenciados por lente.

**Decisiones tecnicas:**
- Assets: interior de auto + ruta + autos enemigos: combinacion Polyhaven (interior) + Kenney Car Kit (low-poly autos enemigos, rapido de prototipar). HDRI nocturno de Polyhaven para skybox.
- Iluminacion: `WorldEnvironment` con `glow_enabled = true`, `glow_intensity = 1.5`, `glow_bloom = 0.3`. Faros: `SpotLight3D` con `light_energy` alto + cono estrecho. Pantalla celular: `StandardMaterial3D` con `emission_enabled = true`.
- Trafico: 4-6 autos enemigos en un `Path3D` paralelo a la ruta, animados con `PathFollow3D` a velocidad ~60 km/h. Loop infinito.
- El shader de halos del Sprint 2 (uniform `halo_intensity`) se activa naturalmente al detectar pixels brillantes (>= threshold de luminancia). PanOptix con `halo_intensity = 0.6` -> halos visibles intensos. Monofocal con `0.05` -> apenas un brillo.
- Celular en tablero: `Node3D` anclado al tablero. El controller izquierdo puede "agarrarlo" (boton grip) y acercarlo/alejarlo de la cara. Mismo patron de `runtime_focus_error` del Sprint 10.
- Audio ambiental: opcional, motor + viento. Si entra en presupuesto.

**Estructura:**
- `features/scenarios/auto_noche/auto_noche.tscn`.
- `features/scenarios/auto_noche/traffic_spawner.gd` — instancia y anima autos enemigos.
- `features/scenarios/auto_noche/phone_grabber.gd` — manipulacion del celular por el controller izquierdo.
- Reutiliza `ScenarioManager` y el uniform `runtime_focus_error` del Sprint 10.

**Entregables:**
- Escena auto-noche cargable y estable a 90/72 FPS.
- Trafico continuo con faros que producen halos diferenciados por lente.
- Celular manipulable con el grip izquierdo, blur dinamico segun lente.
- Tablet cambia entre `consultorio` y `auto_noche` via WS sin reiniciar.
- Comparativa visual documentada: screenshots del mismo momento con 3 lentes distintas (monofocal / Vivity / PanOptix).

**Criterio de salida:** demo grabada (screen capture del Quest) mostrando el mismo escenario nocturno con las 3 lentes del seed. Halos claramente distintos. FPS estable. Cambio entre lentes desde tablet sin glitch.

### Sprint 12 — F5 OTA core
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

### Sprint 13 — F5 plugin Android + CI/CD
**Estado:** PENDIENTE
**Objetivo:** auto-actualizacion de APK + pipeline automatizado.
**Entregables:**
- Plugin Android Java/Kotlin: `install_apk(path)` con FileProvider + `Intent.ACTION_VIEW` + `application/vnd.android.package-archive`.
- Permisos `REQUEST_INSTALL_PACKAGES` + FileProvider en `AndroidManifest.xml`.
- GitHub Actions: trigger `git tag v*` -> export APK + PCK -> SHA256 -> upload a MinIO -> POST a `/api/admin/versions` con API key.
**Criterio de salida:** `git tag v0.1.0 && git push --tags` -> el visor se autoactualiza al siguiente arranque.

### Sprint 14 — Hardening
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
