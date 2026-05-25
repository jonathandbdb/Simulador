# autoloads/

Singletons globales registrados en `project.godot` bajo `[autoload]`. Cargan antes que cualquier escena.

| Autoload | Fase | Responsabilidad |
|----------|------|-----------------|
| `DataManager` | F1 | Catalogo de lentes + estado binocular actual |
| `LicenseManager` | F4 | Validacion contra /api/verify + periodo de gracia offline |
| `UpdateManager` | F5 | manifest.json, descarga PCK/APK, boot counter, rollback |

**Convencion:** los autoloads NO contienen logica de UI. Emiten senales que las escenas escuchan.
