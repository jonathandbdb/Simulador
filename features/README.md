# features/

Cada subcarpeta agrupa una feature completa: escenas, scripts y assets propios.

| Carpeta | Fase | Contenido |
|---------|------|-----------|
| `vr_core/` | F1 | XROrigin3D, XRCamera3D, controllers, escena base VR |
| `lenses/` | F1-F2 | Logica de aplicacion de lentes en runtime |
| `environment/` | F1 | Salas 3D, transicion dia/noche, EnvironmentManager |
| `vision_shaders/` | F2 | Shaders spatial de post-procesado, SubViewport setup |
| `tablet/` | F3 | UI de control de la tablet, WebSocket client |
| `license/` | F4 | LicenseManager, pantalla de bloqueo |
| `ota/` | F5 | UpdateManager, descarga PCK/APK, boot counter |

Cuando una feature crezca lo suficiente, internamente puede tener su propio `scenes/`, `scripts/`, `shaders/`.
