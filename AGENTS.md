# AGENTS.md — Simulador VR Oftalmológico

## Sobre el proyecto

Simulador de visión oftalmológica en VR para Meta Quest, construido con **Godot 4.6.3 + OpenXR**. Permite a médicos y pacientes experimentar cómo se ve el mundo a través de diferentes lentes intraoculares (monofocales, multifocales, PanOptix, Vivity), con capacidad de aplicar efectos distintos a cada ojo (modo "Blend" / monovisión).

El proyecto está en **fase de diseño**. No se ha escrito código todavía. Toda la planificación y especificación vive en la carpeta `context/`.

---

## Estructura del proyecto

```
simulador/
├── project.godot              # Config del proyecto Godot (Forward+, D3D12, Jolt Physics)
├── icon.svg                   # Icono del proyecto
├── .editorconfig
├── .gitattributes
├── .gitignore
├── AGENTS.md                  # ← Este archivo
│
├── context/                   # 📋 Toda la planificación y roadmap
│   ├── Roadmap_Simulador_v2.md    # Índice general con links a cada fase
│   ├── preguntas_abiertas.md      # Preguntas de diseño por resolver
│   ├── fase_0_backend.md          # Infraestructura cloud, API REST, Panel de Control
│   ├── fase_1_core_vr.md          # OpenXR, VIEW_INDEX, DataManager, entorno 3D
│   ├── fase_2_shaders_vision.md   # Shaders asimétricos, DoF, halos, post-procesado
│   ├── fase_3_streaming_tablet.md # WebSocket, streaming video, tablet control
│   ├── fase_4_licencias.md        # Hardware binding, licencias offline, cifrado
│   └── fase_5_ota.md              # Actualizaciones OTA, CI/CD, Smart Update Manager
│
└── .godot/                    # Cache del editor Godot (ignorado por Git)
```

---

## Stack tecnológico

| Capa | Tecnología |
|------|------------|
| Motor | Godot 4.6.3 (Forward+ renderer, Vulkan/D3D12, Jolt Physics) |
| XR | OpenXR (Khronos standard) |
| Lenguaje | GDScript (nativo de Godot) |
| Shaders | GLSL-like (Godot Shading Language), `shader_type spatial` |
| Backend API | Python 3.11+ + FastAPI |
| Base de datos | SQLite (desarrollo) → PostgreSQL (producción si escala) |
| Panel Admin | HTML + Jinja2 + HTMX + Tailwind CSS |
| Almacenamiento | AWS S3 o Cloudflare R2 (APK, PCK, manifest) |
| CI/CD | GitHub Actions |
| Dispositivo objetivo | Meta Quest 3 (Android 12+, ARM64) |
| Dispositivo secundario | Tablet Android (app de control, también en Godot) |

---

## Cómo usar este proyecto

### Si sos un desarrollador nuevo:
1. Leé `Roadmap_Simulador_v2.md` para entender la visión general.
2. Leé cada fase en orden (0 → 5). Cada una tiene:
   - **Objetivo**: qué se construye.
   - **Prompts para LLM**: instrucciones detalladas para generar el código.
   - **📋 Notas Técnicas**: APIs verificadas contra la documentación de Godot 4.6.
3. Leé `preguntas_abiertas.md` para conocer decisiones pendientes.
4. La Fase 0 (backend) puede desarrollarse en paralelo con las otras fases.

### Si sos un LLM / AI agent:
1. Empezá leyendo `Roadmap_Simulador_v2.md` como índice.
2. Cuando trabajes en una fase específica, leé el archivo de fase correspondiente.
3. Respetá las APIs y patrones documentados en las **📋 Notas Técnicas** de cada fase.
4. Las verificaciones contra la doc de Godot YA ESTÁN HECHAS. No las repitas — usá las APIs documentadas.
5. Si encontrás una pregunta de diseño sin resolver, chequiá `preguntas_abiertas.md` primero.
6. Usá GDScript. Los nombres de variables y funciones en **inglés**, comentarios en español.
7. **NO escribas código** a menos que se te pida explícitamente. Este proyecto está en fase de diseño.
8. Si se te pide modificar el roadmap o las fases, mantené el formato consistente.

---

## Fases (orden de desarrollo recomendado)

| # | Fase | Archivo | Dependencias | Estado |
|---|------|---------|--------------|--------|
| 0 | Infraestructura y Panel | `fase_0_backend.md` | — | Diseño completo + verificado |
| 1 | Core VR y Datos | `fase_1_core_vr.md` | — | Diseño completo + verificado |
| 2 | Shaders de Visión | `fase_2_shaders_vision.md` | F1 | Diseño completo + verificado |
| 3 | Streaming y Tablet | `fase_3_streaming_tablet.md` | F1 | Diseño completo + verificado |
| 4 | Licencias y Seguridad | `fase_4_licencias.md` | F0 | Diseño completo + verificado |
| 5 | OTA y CI/CD | `fase_5_ota.md` | F0, F1 | Diseño completo + verificado |

**Nota:** F0 puede desarrollarse en paralelo con F1-F3. F4 y F5 dependen de F0 (necesitan la API).

---

## Decisiones de diseño YA TOMADAS

Estas cosas no deberían re-debatirse:

1. **Renderer:** Forward+ (ya configurado en `project.godot`). Para Quest standalone, la doc recomienda Compatibility, pero el proyecto usa Forward+. Si hay problemas de rendimiento en Quest, migrar a Compatibility.
2. **Motor de físicas:** Jolt Physics (ya configurado).
3. **Multiview:** Activado. `VIEW_INDEX` en shaders spatial para diferenciar ojos.
4. **Post-procesado por ojo:** Vía `SubViewportContainer` + `ShaderMaterial` con shader `spatial`. NO con `canvas_item`.
5. **Formato de assets:** PCK (sin comprimir) para máxima velocidad de carga.
6. **Manifiesto:** Un solo `manifest.json` con versiones de APK y assets.
7. **Periodo de gracia offline:** 7 días para licencias (Fase 4).
8. **WebSocket server:** `TCPServer` + `WebSocketPeer` (no hay `WebSocketServer` en Godot 4).
9. **Cifrado de licencia local:** `FileAccess.open_encrypted_with_pass()`.
10. **Hash de integridad:** SHA256 vía `FileAccess.get_sha256()`.
11. **Idioma de código:** Variables/funciones en inglés, comentarios en español.
12. **API Backend:** FastAPI. Panel admin: server-rendered (Jinja2 + HTMX).

---

## Convenciones

### Archivos de fase
Cada archivo de fase sigue esta estructura:
```
# FASE X Detallada: [título]

[descripción general de la fase]

## 🏗️ X.1 [sección]
[contenido]

### 🤖 Prompt para alimentar al LLM:
> "[prompt detallado para generar código]"

### 📋 Notas Técnicas (Verificadas contra Godot X.Y Docs):
[tablas con APIs verificadas, código de ejemplo, advertencias]
```

### GDScript (cuando se escriba)
```gdscript
# Variables: snake_case
var device_id: String
var update_manager: Node

# Funciones: snake_case
func check_for_updates() -> bool:
	pass

# Señales: snake_case
signal license_verified(device_id: String)
signal license_denied(reason: String)

# Constantes: UPPER_SNAKE_CASE
const MAX_RETRY_COUNT := 3
const DOWNLOAD_TIMEOUT := 30.0
```

### Shaders
```glsl
shader_type spatial;
// Uniforms: snake_case
uniform float blur_amount_l : hint_range(0.0, 1.0);
uniform float blur_amount_r : hint_range(0.0, 1.0);
```

---

## Verificaciones contra documentación

Todas las fases (0-5) han sido verificadas contra la documentación oficial de Godot 4.6. Las **📋 Notas Técnicas** en cada archivo contienen las APIs confirmadas, código de ejemplo validado, y advertencias de la doc oficial.

Fuentes verificadas:
- Godot 4.6 Classes API Reference
- XR Setup Guide (OpenXR)
- Spatial Shader Reference
- CanvasItem Shader Reference
- Screen-Reading Shaders Guide
- WebSocket Tutorial
- Exporting Projects / PCKs Guide
- Command Line Tutorial
- HTTPRequest Class Reference
- FileAccess / HashingContext / ProjectSettings Class References
- OpenXR Settings Reference

---

## Workflow típico de desarrollo

1. **Diseño:** Se refina el archivo de fase en `context/`.
2. **Decisión:** Se responden las preguntas de `preguntas_abiertas.md`.
3. **Implementación:** Se usa el prompt del LLM para generar el código GDScript/shaders.
4. **Verificación:** Se testea en Quest 3. Se itera.
5. **Commit:** Se actualiza el archivo de fase si hubo cambios de diseño.
6. **Release:** `git tag vX.Y.Z` → CI/CD → deploy automático (Fase 5).
