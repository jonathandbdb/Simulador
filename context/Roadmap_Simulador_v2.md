# Roadmap de Desarrollo V2: Simulador VR Oftalmológico (Godot 4 + OpenXR)

Índice general del proyecto. Cada fase tiene su propio archivo detallado con objetivos, prompts para LLM, y notas técnicas verificadas contra la documentación de Godot 4.6.

---

## 🌐 FASE 0: Infraestructura Cloud, API REST y Panel de Control
> 📄 **[fase_0_backend.md](fase_0_backend.md)**

La base que sostiene todo el ecosistema. Backend (FastAPI + SQLite), API REST con endpoints para manifest, verificación de licencias y catálogo de lentes. Panel de Control web (Jinja2 + HTMX + Tailwind) para gestionar dispositivos, versiones y logs.

| Step | Tema |
|------|------|
| 0.1 | API REST y Base de Datos |
| 0.2 | Panel de Control Web |
| 0.3 | Almacenamiento Cloud (S3 / R2) |
| 0.4 | Seguridad y Autenticación |
| 0.5 | Despliegue (Cloud u On-Premise) |

---

## 🚀 FASE 1: Core del Visor VR y Base de Datos
> 📄 **[fase_1_core_vr.md](fase_1_core_vr.md)**

Cimientos del proyecto en Godot: configuración OpenXR para Meta Quest, `VIEW_INDEX` para renderizado independiente por ojo, `DataManager` (Autoload) para leer catálogo de lentes, y entorno 3D de prueba con transición día/noche.

| Step | Tema |
|------|------|
| 1.1 | Configuración OpenXR + `VIEW_INDEX` |
| 1.2 | `DataManager` y `lentes.json` |
| 1.3 | Entorno 3D (día/noche + fade) |

---

## 👁️ FASE 2: Shaders de Visión (Modo "Blend" / Independencia Ocular)
> 📄 **[fase_2_shaders_vision.md](fase_2_shaders_vision.md)**

Shaders asimétricos por ojo usando `VIEW_INDEX`: halos nocturnos, pérdida de contraste, y Depth of Field personalizado. Post-procesado vía `SubViewport` + `ShaderMaterial` con shader `spatial` (NO `canvas_item`). Optimización para Meta Quest 3.

| Step | Tema |
|------|------|
| 2.1 | Shaders con control por ojo (`VIEW_INDEX`) |
| 2.2 | Post-procesado y DoF asimétrica |
| 2.3 | UI de Blend en la Tablet |

---

## 📱 FASE 3: Cliente Tablet, Conectividad y Streaming
> 📄 **[fase_3_streaming_tablet.md](fase_3_streaming_tablet.md)**

Servidor WebSocket en el Visor (`TCPServer` + `WebSocketPeer`), cliente tablet con UI dinámica y modo Blend, y dos opciones de visualización: streaming de video real vs replicación 2D síncrona.

| Step | Tema |
|------|------|
| 3.1 | Servidor WebSocket en el Visor |
| 3.2 | UI Dinámica en Tablet con Modo Blend |
| 3.3 | Pipeline de Streaming de Video |
| 3.4 | Hardware Binding y Seguridad WebSocket |

---

## 🔒 FASE 4: Hardware Binding Inteligente (Offline + Cloud)
> 📄 **[fase_4_licencias.md](fase_4_licencias.md)**

Sistema de licenciamiento con periodo de gracia offline de 7 días. Validación contra API cloud (`POST /api/verify`), archivo de licencia local cifrado (`open_encrypted_with_pass`), checksum anti-tamper, y pantalla de bloqueo con información de diagnóstico.

| Step | Tema |
|------|------|
| 4.1 | Mecanismo Offline-First + Periodo de Gracia |
| 4.2 | Bloqueo y UI de Estado |

---

## 🤖 FASE 5: App Inteligente — Auto-Actualización y Despliegue Continuo (Smart OTA)
> 📄 **[fase_5_ota.md](fase_5_ota.md)**

Sistema autónomo de actualizaciones: `manifest.json` unificado, `UpdateManager` (Autoload) con lógica de decisión APK vs PCK, descarga con barra de progreso real, verificación SHA256, instalación de APK vía plugin Android, rollback con boot counter, y CI/CD con GitHub Actions.

| Step | Tema |
|------|------|
| 5.1 | `manifest.json` unificado |
| 5.2 | Smart Update Manager (Autoload) |
| 5.3 | File System Overlay y carga de assets |
| 5.4 | Instalación de APK en Android |
| 5.5 | Rollback, Modo Offline y Supervivencia |
| 5.6 | CI/CD con GitHub Actions |

---

## 🔗 Documentos complementarios

| Archivo | Contenido |
|---------|-----------|
| **[preguntas_abiertas.md](preguntas_abiertas.md)** | Preguntas de diseño sin resolver, con opciones de respuesta para decidir al programar. |
| **[AGENTS.md](../AGENTS.md)** | Guía del proyecto (stack, convenciones, cómo usar el roadmap). |

---

## 🗺️ Orden de desarrollo recomendado

```
FASE 0 (backend) ─────────────────────────────┐
                                               │
FASE 1 (core VR) ──┬── FASE 2 (shaders)       │
                   │                           │
                   ├── FASE 3 (streaming)      │
                   │                           │
                   └───────────────────────────┤
                                               │
FASE 4 (licencias) ─── depende de F0 ──────────┤
                                               │
FASE 5 (OTA/CI/CD) ─── depende de F0 y F1 ────┘
```

- **F0** puede desarrollarse en paralelo con F1, F2 y F3.
- **F4** y **F5** necesitan que la API (F0) esté operativa.
- **F5** también necesita la estructura base de Godot (F1).

---

## ⚡ Referencias rápidas

| Tema | Recurso |
|------|---------|
| Godot 4.6 API Reference | https://docs.godotengine.org/en/stable/classes/index.html |
| OpenXR Setup Guide | https://docs.godotengine.org/en/stable/tutorials/xr/setting_up_xr.html |
| Spatial Shaders Reference | https://docs.godotengine.org/en/stable/tutorials/shaders/shader_reference/spatial_shader.html |
| Screen-Reading Shaders | https://docs.godotengine.org/en/stable/tutorials/shaders/screen-reading_shaders.html |
| WebSocket Tutorial | https://docs.godotengine.org/en/stable/tutorials/networking/websocket.html |
| Exporting Projects / PCKs | https://docs.godotengine.org/en/stable/tutorials/export/exporting_pcks.html |
| Command Line Tutorial | https://docs.godotengine.org/en/stable/tutorials/editor/command_line_tutorial.html |
| HTTPRequest Class | https://docs.godotengine.org/en/stable/classes/class_httprequest.html |
| FileAccess Class | https://docs.godotengine.org/en/stable/classes/class_fileaccess.html |
