# FASE 5 Detallada: App Inteligente — Auto-Actualización y Despliegue Continuo (Smart OTA)

Esta fase transforma el simulador en un sistema autónomo capaz de autogestionar su ciclo de vida completo. El objetivo es que la aplicación sea "Smart": determina automáticamente si necesita actualizar contenido (assets vía `.pck`), si requiere una actualización crítica de motor (binario `APK`), o si debe continuar con lo que tiene. Además, se implementa el pipeline de CI/CD para que nada se suba a mano.

---

## 🏗️ 5.1 La Torre de Control: `manifest.json`

El simulador no busca actualizaciones a ciegas. Consume un único archivo `manifest.json` alojado en tu servidor, que actúa como el "contrato de versión" tanto para assets como para el binario.

### Estructura del Manifest (Ejemplo)
```json
{
  "min_apk_version": "1.0.2",
  "current_apk_version": "1.0.5",
  "current_asset_version": "2.1.0",
  "apk_url": "https://server.com/simulador_v1.0.5.apk",
  "pck_url": "https://server.com/assets_v2.1.0.pck",
  "pck_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "changelog": "Añadidas nuevas lentes PanOptix Pro. Mejoras en shaders de contraste nocturno."
}
```

### Campos explicados:
| Campo | Propósito |
|-------|-----------|
| `min_apk_version` | Versión mínima del APK requerida. Si el visor tiene una versión inferior, **debe** actualizar el binario. |
| `current_apk_version` | Última versión del APK disponible. |
| `current_asset_version` | Última versión del paquete de assets (`.pck`). |
| `apk_url` | URL de descarga directa del APK. |
| `pck_url` | URL de descarga directa del `.pck`. |
| `pck_sha256` | Hash SHA256 del `.pck` para verificar integridad tras la descarga. |
| `changelog` | Texto legible para mostrar al administrador o médico qué cambió. |

### 🤖 Prompt para alimentar al LLM:
> "Actúa como arquitecto de sistemas en Godot 4. Necesito que diseñes la lógica de parseo del `manifest.json` descrito arriba. El script debe:
> 1. Descargar el manifest desde una URL configurable (ej. `https://api.mi-servidor.com/manifest.json`) usando `HTTPRequest`.
> 2. Parsear el JSON y exponer cada campo como propiedad del `UpdateManager` (ej. `UpdateManager.manifest.current_apk_version`).
> 3. Si la descarga del manifest falla (sin internet), entrar en modo offline sin crashear — devolver `null` o un estado `offline`."

### 📋 Notas Técnicas (Verificadas contra Godot 4.6 Docs):
| API | Detalle |
|-----|---------|
| `HTTPRequest` | `request(url, headers, method)` — método `HTTPClient.METHOD_GET` por defecto. La señal `request_completed` devuelve `(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray)`. |
| Detección offline | El enum `HTTPRequest.Result` tiene: `RESULT_CANT_CONNECT = 2`, `RESULT_CANT_RESOLVE = 3`, `RESULT_TIMEOUT = 13`. Si `result != RESULT_SUCCESS`, es offline o error de red. |
| `JSON.new().parse()` | Para parsear el body: `var json = JSON.new(); json.parse(body.get_string_from_utf8()); var data = json.get_data()` |
| Internet en Android | Requiere permiso `INTERNET` en el Android Export Preset. Sin esto, toda comunicación de red es bloqueada por Android. |
| Timeout | Para el manifest (archivo pequeño), `timeout = 5.0` segundos es suficiente. Para descargas grandes (APK/PCK), usar `timeout = 0.0` (sin timeout). |
| URL | La URL en `HTTPRequest.request()` debe ser absoluta y bien formada, o devuelve `ERR_INVALID_PARAMETER`. |

---

## 🤖 5.2 El Cerebro: Smart Update Manager (Autoload)

El `UpdateManager` es un **Autoload** (Singleton) que se ejecuta al arrancar, antes que cualquier escena del simulador. Su trabajo es decidir el camino a tomar.

### Lógica de Decisión (Flujo):

```
┌─────────────────────────────┐
│  Arranque: Descargar        │
│  manifest.json              │
└─────────────┬───────────────┘
              │
    ┌─────────▼─────────┐
    │ ¿Hay internet?     │
    └────┬──────────┬────┘
         │NO        │SÍ
         ▼          ▼
   ┌──────────┐  ┌─────────────────────────────────┐
   │ MODO     │  │ Comparar versiones:              │
   │ OFFLINE  │  │                                 │
   │ (usar    │  │ manifest.current_apk_version     │
   │  assets  │  │   > current_app_version ?        │
   │  locales)│  │                                 │
   └──────────┘  │ manifest.current_asset_version   │
                 │   > current_assets_version ?     │
                 └────────────┬────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
        ┌──────────┐   ┌───────────┐   ┌──────────────┐
        │ APK      │   │ PCK       │   │ Todo         │
        │ NUEVO    │   │ NUEVO     │   │ actualizado  │
        │ (crítico)│   │ (assets)  │   │ → Ir al menú │
        └────┬─────┘   └─────┬─────┘   └──────────────┘
             │               │
             ▼               ▼
      Bloquear app     Descargar .pck
      → Forzar inst.   → Verificar SHA256
      del APK          → load_resource_pack()
                       → Actualizar versión local
```

### 🤖 Prompt para alimentar al LLM:
> "Actúa como desarrollador senior de Godot 4 para Android/Meta Quest. Necesito crear un Autoload `UpdateManager` que gestione las actualizaciones de forma inteligente.
>
> **Requisitos:**
> 1. **Al arrancar**, en una escena `LoadingScreen` inicial, usa `HTTPRequest` para descargar el `manifest.json` desde una URL configurable.
> 2. **Lógica de decisión:**
>    - Si `manifest.current_apk_version > current_app_version`: Bloquea el acceso, muestra aviso 'Actualización Crítica Requerida', descarga el APK desde `apk_url` y lanza el proceso de instalación (ver sección 5.4).
>    - Si `manifest.current_asset_version > current_assets_version`: Descarga el `.pck` desde `pck_url`, verifica el hash SHA256 contra `pck_sha256`, guárdalo en `user://downloads/`, cárgalo con `ProjectSettings.load_resource_pack()`, y actualiza el archivo de versión local (`user://local_asset_version.txt`).
>    - Si ambas versiones son iguales o menores: continúa al menú principal.
> 3. **UI Feedback:** La `LoadingScreen` debe tener una `ProgressBar` vinculada a la señal `http_request_request_completed` de Godot, calculando el porcentaje de bytes descargados. Incluye un `Label` con el estado actual ("Verificando versión...", "Descargando assets...", "Actualización completada").
> 4. **Seguridad:** Antes de cargar el `.pck`, calcula su hash SHA256 con `HashingContext` y compáralo con el del manifest. Si no coincide, borra el archivo corrupto y notifica el error.
> 5. **Manejo de errores:** Si la descarga falla a mitad de camino, reintenta hasta 3 veces con un intervalo de 30 segundos. Si agota los reintentos, permite continuar con los assets actuales."

### 📋 Notas Técnicas (Verificadas contra Godot 4.6 Docs):

**Descarga de archivos grandes (.pck / .apk):**
| API | Detalle |
|-----|---------|
| `HTTPRequest.download_file` | **Propiedad clave.** Asignar `"user://downloads/update.pck"` ANTES de llamar a `request()`. Godot escribe el body directamente a disco, sin cargarlo en RAM. Ejemplo: `http.download_file = "user://downloads/update.pck"`. |
| `HTTPRequest.timeout` | Para descargas grandes, usar `0.0` (sin timeout). Con timeout, una descarga lenta puede cancelarse antes de completar. |
| `HTTPRequest.use_threads` | `true` para descargas en segundo plano sin bloquear el hilo principal. |
| `HTTPRequest.body_size_limit` | Por defecto `-1` (sin límite). Si se configura un límite, descargas que lo excedan devuelven `RESULT_BODY_SIZE_LIMIT_EXCEEDED = 7`. |

**Tracking de progreso REAL (importante):**
La señal `request_completed` solo se emite AL FINAL. Para una barra de progreso real durante la descarga, usar `_process()`:
```gdscript
func _process(_delta):
    if downloading:
        var downloaded = http_request.get_downloaded_bytes()
        var total = http_request.get_body_size()
        if total > 0:
            progress_bar.value = float(downloaded) / float(total) * 100.0
```
⚠️ `get_body_size()` puede devolver `-1` si el servidor no envía `Content-Length`. En ese caso, mostrar barra indeterminada.

**Carga del .pck (timing crítico):**
| API | Detalle |
|-----|---------|
| `ProjectSettings.load_resource_pack(path, replace_files)` | `replace_files = true` por defecto → los archivos del .pck SOBREESCRIBEN los del APK base. Retorna `true` si éxito, `false` si falla. |
| ⚠️ **TIMING** | Debe cargarse en `_init()` del Autoload, **NO en `_ready()`**. Si se carga en `_ready()`, escenas ya preloadadas no verán los nuevos assets. Fuente: [Godot Docs - Exporting PCKs](https://docs.godotengine.org/en/stable/tutorials/export/exporting_pcks.html#troubleshooting). |
| `DirAccess.make_dir_recursive()` | Usar para crear `user://downloads/` si no existe antes de descargar. |

**Verificación de hash:**
| API | Detalle |
|-----|---------|
| `FileAccess.get_sha256(path)` | **Método estático** — calcula SHA256 de un archivo completo en una línea. Más simple que `HashingContext` para archivos ya descargados. Retorna `String` hex. |
| `HashingContext` | Alternativa para streaming: `start(HASH_SHA256)` → `update(chunk)` en bucle → `finish()`. Útil si se quiere hashear mientras se descarga, pero innecesario si usamos `download_file`. |

**Versión de la app actual (APK version):**
No hay un API directo en Godot para leer la versión del APK en runtime. Estrategias:
- **Opción A (recomendada):** Hardcodear la versión en un archivo `res://version.txt` incluido en el APK, y leerlo con `FileAccess.get_file_as_string("res://version.txt")`.
- **Opción B:** Usar `ProjectSettings.get_setting("application/config/version")` si se configuró en Project Settings > Application > Config > Version.
- **Opción C:** Plugin Android nativo que lea `PackageInfo.versionName`.

---

## 📱 5.3 El "Tricky Part": Instalación de APKs en Android (Meta Quest)

Meta Quest es Android. No puedes simplemente "actualizar" la app desde dentro de la app sin permisos especiales y un **Intent** del sistema.

### Permisos necesarios en `AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />

<!-- Para Android 10+ (API 29+), se requiere FileProvider -->
<provider
    android:name="androidx.core.content.FileProvider"
    android:authorities="${applicationId}.fileprovider"
    android:exported="false"
    android:grantUriPermissions="true">
    <meta-data
        android:name="android.support.FILE_PROVIDER_PATHS"
        android:resource="@xml/file_paths" />
</provider>
```

### ⚠️ Nota importante:
En Android 10+ (que incluye todos los Meta Quest modernos), no se puede lanzar un APK directamente desde `user://`. Debe copiarse a almacenamiento externo compartido o usar un **FileProvider** para generar una URI de contenido segura. Godot 4 no tiene soporte nativo para FileProvider — se requiere un **plugin Android personalizado** o modificar el template de exportación.

### 🤖 Prompt para alimentar al LLM:
> "Estoy en Godot 4 para Android (Meta Quest). Una vez descargado un nuevo APK (`update.apk` en `user://downloads/`), necesito lanzarlo para que el sistema Android pregunte al usuario si quiere instalar la actualización.
>
> **Explícame:**
> 1. Cómo usar un Intent de Android (`ACTION_VIEW` + `application/vnd.android.package-archive`) para invocar al Package Installer del sistema.
> 2. Qué configuración necesito en `AndroidManifest.xml`: permisos `REQUEST_INSTALL_PACKAGES` y el uso de `FileProvider` para Android 10+ (cómo exponer el archivo con una URI de contenido en lugar de una URI de archivo directa).
> 3. Cómo crear un plugin Android mínimo en Godot 4 (extendiendo `GodotPlugin`) que exponga una función `install_apk(path: String)` invocable desde GDScript.
> 4. Cómo cerrar la aplicación actual (`get_tree().quit()`) inmediatamente después de lanzar el Intent para evitar conflictos.
>
> **Importante:** Asegúrate de que la solución funcione en Meta Quest OS (Android 10/12)."

### 📋 Notas Técnicas (Verificadas contra Godot 4.6 Docs):

**Realidad del soporte Android en Godot 4:**
| Realidad | Detalle |
|----------|---------|
| `DisplayServer.shell_open()` | En Godot 4, `shell_open()` está en `DisplayServer`, no en `OS`. Puede abrir URLs e intentar abrir archivos, pero **NO garantiza funcionar con APKs** en Android 10+ por las restricciones de `file://` URIs. |
| Sin soporte nativo para Intents | Godot 4 **no expone Intents de Android ni FileProvider** en GDScript. No hay `GodotPlugin` built-in que maneje esto — se requiere compilar un plugin Android custom (Java/Kotlin + `GodotPlugin`). |
| Camino viable | Modificar el Android Build Template de Godot: añadir una Activity Java/Kotlin que use `FileProvider` + `Intent.ACTION_INSTALL_PACKAGE`, y exponerla vía `GodotPlugin` para invocarla desde GDScript. |
| `user://` en Android | `user://` mapea a `getFilesDir()` (interno, privado). Otras apps NO pueden acceder a archivos en `user://`. El APK descargado debe copiarse a `getExternalFilesDir()` o usar FileProvider con `getUriForFile()`. |
| Permiso `REQUEST_INSTALL_PACKAGES` | Debe declararse en `AndroidManifest.xml`. En Android 10+, además el usuario debe concederlo manualmente en Settings > Apps > Special Access > Install Unknown Apps. |

**Estrategia práctica recomendada para la instalación de APK:**
1. Descargar APK vía `HTTPRequest.download_file` → `user://downloads/update.apk`.
2. Usar un plugin Android que copie el archivo a almacenamiento externo compartido (`getExternalFilesDir()`).
3. El plugin lanza `Intent.ACTION_VIEW` con Uri de `FileProvider` + tipo MIME `application/vnd.android.package-archive`.
4. El sistema muestra diálogo nativo de instalación. El usuario confirma manualmente.
5. Llamar `get_tree().quit()` inmediatamente después de lanzar el Intent.

**⚠️ NOTA SOBRE META QUEST:** Si la app se distribuye fuera de Meta Store (sideload), el usuario DEBE tener el modo desarrollador activado y permisos de instalación concedidos. Si se distribuye vía Meta Store, las actualizaciones las gestiona la propia Store y este sistema de auto-actualización de APK probablemente no sea necesario — solo necesitarías el sistema de `.pck` para assets.

---

## ⚙️ 5.4 Estrategia de Carga y "File System Overlay"

Cuando cargamos un `.pck` mediante `ProjectSettings.load_resource_pack()`, Godot lo monta **por encima** del sistema de archivos actual. Es vital entender qué pasa si hay conflictos de archivos.

### Regla de oro del File System Overlay:
> **El `.pck` cargado más recientemente SIEMPRE prevalece** sobre los archivos del APK base. Si `res://shaders/halo.gdshader` existe en el APK base y también en el `.pck` descargado, Godot usará la versión del `.pck`.

Esto significa que los parches de actualización "ganan" automáticamente. No necesitas lógica especial de sobreescritura.

### Buenas prácticas:
1. **Estructura idéntica:** Al exportar el `.pck` desde Godot, la estructura de carpetas dentro del pack debe coincidir exactamente con `res://`. Si tu shader está en `res://shaders/halo.gdshader`, el `.pck` debe contener `shaders/halo.gdshader` (relativo a la raíz del proyecto).
2. **No renombres archivos:** Si quieres actualizar un shader, manten el mismo nombre y ruta. El overlay se encarga del resto.
3. **Limpieza post-actualización de binario:** Cuando se instala un APK nuevo, la carpeta `user://` persiste. Es buena práctica limpiar `user://downloads/` al detectar una nueva versión de APK, para no acumular `.pck` obsoletos.

### 🤖 Prompt para alimentar al LLM:
> "Explícame en detalle cómo funciona el 'File System Overlay' en Godot 4 cuando uso `load_resource_pack()`.
>
> **Responde a estas preguntas:**
> 1. Si `res://shaders/halo.gdshader` existe en el APK base y también en el `.pck` que descargo, ¿cuál prevalece? Confírmame que el `.pck` gana.
> 2. Si quiero añadir un archivo NUEVO (que no existía en el APK base), ¿simplemente lo incluyo en el `.pck` y Godot lo encuentra automáticamente?
> 3. ¿Cómo debo organizar mis carpetas al exportar el `.pck` desde el editor para asegurarme de que las rutas `res://` sean correctas?
> 4. Dame un script de utilidad que limpie la carpeta `user://downloads/` cada vez que el `UpdateManager` detecte que se ha instalado una versión de binario nueva (para evitar acumulación de parches obsoletos)."

### 📋 Notas Técnicas (Verificadas contra Godot 4.6 Docs):

**API exacta de `load_resource_pack`:**
```gdscript
# Firma real del método (Godot 4.6):
var ok: bool = ProjectSettings.load_resource_pack("user://downloads/update.pck", true)
# 2do parámetro: replace_files (default true)
#   true  → archivos del .pck reemplazan los del juego base
#   false → archivos del juego base NO son reemplazados (útil para mods)
```

**Exportación de .pck por CLI (para CI/CD y admin):**
| Comando | Descripción |
|---------|-------------|
| `godot --headless --export-pack "Android" output.pck` | Exporta PCK con TODOS los assets del preset. `.pck` = sin comprimir (más rápido en runtime). |
| `godot --headless --export-pack "Android" output.zip` | Si la extensión es `.zip`, exporta comprimido (más lento en runtime, más pequeño). |
| `godot --headless --export-patch "Android" output.pck --patches "base.pck"` | Exporta SOLO archivos modificados respecto a `base.pck`. Ideal para parches incrementales. |

**Estructura interna del .pck:**
- Mantiene la misma jerarquía que `res://`. Si exportas desde la raíz del proyecto, las rutas dentro del .pck serán idénticas a `res://`.
- Para archivos NUEVOS (no existentes en el APK base), simplemente se incluyen en el .pck y Godot los encuentra en `res://` automáticamente tras `load_resource_pack()`.

**API de limpieza de directorios:**
```gdscript
# Godot 4: DirAccess (no Directory)
var dir = DirAccess.open("user://downloads/")
if dir:
    dir.list_dir_begin()
    var file_name = dir.get_next()
    while file_name != "":
        if not dir.current_is_dir():
            dir.remove(file_name)
        file_name = dir.get_next()
    dir.list_dir_end()
```
⚠️ `Directory` fue renombrado a `DirAccess` en Godot 4.

---

## 🛡️ 5.5 Rollback, Modo Offline y "Supervivencia" del Simulador

Un simulador médico no puede quedarse inutilizable. Debe sobrevivir a cortes de internet, crashes por `.pck` corruptos, y siempre ofrecer una ruta de recuperación.

### 5.5.1 Modo Offline
- **Regla:** Si al arrancar no hay internet, el `UpdateManager` debe permitir la entrada al simulador con los assets que ya tenga en disco.
- **UX:** Muestra un aviso sutil: *"Sin conexión. Usando contenido local. Última verificación: [fecha]"*.
- **Reintento silencioso:** Cada 30 minutos en segundo plano, reintenta la descarga del manifest.

### 5.5.2 Boot Counter (Anti-Crash Loop)
- **Mecanismo:** Antes de cargar un `.pck` nuevo, se incrementa un contador en `user://boot_counter.txt`.
- Al llegar al menú principal exitosamente, el contador se resetea a 0.
- Si la app crashea 3 veces consecutivas sin llegar al menú (contador >= 3):
  - Se elimina el `.pck` corrupto de `user://downloads/`.
  - Se resetea `user://local_asset_version.txt` a la versión de fábrica.
  - Se muestra un mensaje: *"Se detectó un problema con la última actualización. Se ha restaurado la versión estable."*

### 5.5.3 Factory Reset (Recuperación Total)
Si todo falla, debe existir un comando secreto o combinación (ej. mantener pulsado un botón del mando durante el arranque) que borre todo `user://` y vuelva al estado de fábrica.

### 5.5.4 Log de Errores
- El `UpdateManager` escribe en `user://log_update.txt` cada evento relevante:
  - Fecha/hora de cada intento de actualización.
  - Versiones detectadas.
  - Errores de descarga (código HTTP, excepción).
  - Resultado de verificación de hash.
  - Eventos de rollback.
- Esto permite que el médico envíe ese archivo a soporte técnico para diagnóstico remoto.

### 🤖 Prompt para alimentar al LLM:
> "Necesito implementar el sistema de 'supervivencia' completo para mi simulador VR en Godot 4.
>
> **Implementa:**
> 1. **Modo Offline:** Si `HTTPRequest` falla al descargar el manifest (timeout, DNS), el `UpdateManager` debe emitir señal `offline_mode` y permitir continuar. La UI muestra un aviso no intrusivo.
> 2. **Boot Counter:** Un archivo `user://boot_counter.txt` que se incrementa antes de cargar un `.pck` nuevo y se resetea al llegar al menú principal. Si el contador >= 3 al arrancar, ejecuta el rollback (borrar `.pck`, restaurar versión local).
> 3. **Factory Reset:** Un método `factory_reset()` que borre todo `user://` y reinicie la app. Debe ser invocable desde un botón oculto en la UI de configuración (accesible solo con combinación de teclas).
> 4. **Log de actualizaciones:** Un helper `log_update(message: String)` que escriba con timestamp en `user://log_update.txt`. Todos los eventos del `UpdateManager` deben pasar por este log.
>
> Asegúrate de que el sistema sea robusto: si el archivo de contador o de versión está corrupto, asume valores por defecto seguros (no bloquear la app)."

### 📋 Notas Técnicas (Verificadas contra Godot 4.6 Docs):

**APIs Clave para Supervivencia:**
| API | Uso |
|-----|-----|
| `FileAccess.file_exists(path)` | Verificar si `user://boot_counter.txt` existe antes de leerlo. |
| `FileAccess.open(path, FileAccess.READ)` | Abrir archivo para lectura. Retorna `null` si no existe. |
| `FileAccess.open(path, FileAccess.WRITE)` | Abrir para escritura. Crea el archivo si no existe, trunca si existe. |
| `FileAccess.get_file_as_string(path)` | **Método estático** — lee archivo completo como String en una línea. Ideal para archivos pequeños (boot counter, versión local). |
| `DirAccess.remove_absolute(path)` | Eliminar un archivo específico. Usar ruta absoluta: `DirAccess.remove_absolute(ProjectSettings.globalize_path("user://downloads/update.pck"))`. |
| `Time.get_unix_time_from_system()` | Obtener timestamp actual para log y comparaciones de fecha. |
| `OS.get_unique_id()` | ID único del dispositivo. Útil para identificar el visor en los logs. |

**Estructura recomendada de archivos locales:**
```
user://
├── downloads/           # .pck y .apk descargados (limpiar periódicamente)
├── local_asset_version.txt   # "2.1.0" — última versión de assets cargada
├── local_apk_version.txt     # "1.0.5" — versión del APK instalado (para comparar)
├── boot_counter.txt          # "0", "1", "2", "3" → trigger de rollback
├── log_update.txt            # Log de eventos del UpdateManager
└── license.bin               # (Fase 4) — archivo de licencia cifrado
```

**Boot Counter — Lógica de implementación:**
```gdscript
# Al arrancar, ANTES de cargar .pck:
var boot_count = 0
if FileAccess.file_exists("user://boot_counter.txt"):
    boot_count = FileAccess.get_file_as_string("user://boot_counter.txt").to_int()
    if boot_count >= 3:
        # ROLLBACK: borrar .pck, resetear versión, seguir con assets base
        _rollback()
        return

# Incrementar contador antes de intentar cargar nuevo .pck
boot_count += 1
var f = FileAccess.open("user://boot_counter.txt", FileAccess.WRITE)
f.store_string(str(boot_count))

# ... cargar .pck ...

# Al llegar al menú principal exitosamente:
var f = FileAccess.open("user://boot_counter.txt", FileAccess.WRITE)
f.store_string("0")  # Resetear contador
```

**Factory Reset:**
Para borrar todo `user://`, usar `DirAccess` recursivamente o `OS.move_to_trash()` (Godot 4.2+):
```gdscript
func factory_reset():
    var user_path = OS.get_user_data_dir()  # o ProjectSettings.globalize_path("user://")
    var dir = DirAccess.open(user_path)
    if dir:
        # Borrar recursivamente
        _remove_recursive(dir, user_path)
    get_tree().quit()

func _remove_recursive(dir: DirAccess, base_path: String):
    dir.list_dir_begin()
    var item = dir.get_next()
    while item != "":
        var full_path = base_path.path_join(item)
        if dir.current_is_dir():
            var sub_dir = DirAccess.open(full_path)
            if sub_dir:
                _remove_recursive(sub_dir, full_path)
            DirAccess.remove_absolute(full_path)  # borrar directorio vacío
        else:
            DirAccess.remove_absolute(full_path)
        item = dir.get_next()
    dir.list_dir_end()
```

---

## 🚀 5.6 Automatización del Despliegue (CI/CD con GitHub Actions)

El administrador no debe subir archivos manualmente a servidores. Cada release se dispara con un tag de Git.

### Flujo del Pipeline:

```
Git Tag "v1.0.6"
       │
       ▼
┌──────────────────────────────┐
│ GitHub Actions               │
│ (.github/workflows/deploy.yml)│
└────────────┬─────────────────┘
             │
    ┌────────┼────────┐
    ▼        ▼        ▼
  Export   Export   Generar
  APK      PCK      manifest.json
    │        │        │
    └────────┼────────┘
             ▼
    ┌────────────────┐
    │  Subir a S3    │
    │  (o servidor)  │
    └───────┬────────┘
            ▼
    ┌────────────────┐
    │  Actualizar     │
    │  manifest.json  │
    │  en el servidor │
    └────────────────┘
```

### 🤖 Prompt para alimentar al LLM:
> "Diseña un pipeline de GitHub Actions (`.github/workflows/deploy.yml`) para mi proyecto Godot 4.
>
> **Requisitos:**
> 1. **Trigger:** Se ejecuta al hacer un `git tag` que empiece por `v` (ej. `v1.0.6`).
> 2. **Exportación:**
>    - Exporta el proyecto para Android (APK) usando el CLI de Godot: `godot --headless --export-release "Android"`.
>    - Exporta los assets por separado como `.pck`: `godot --headless --export-pack "assets.pck"`.
> 3. **Artefactos:** Adjunta el APK y el PCK como artefactos del workflow para descarga manual si es necesario.
> 4. **Upload a bucket:** Sube ambos archivos a AWS S3 (o alternativa: DigitalOcean Spaces, Google Cloud Storage) usando `aws s3 cp` o la acción `aws-actions/configure-aws-credentials`.
> 5. **Generar y actualizar manifest.json:**
>    - Extrae la versión del tag (`v1.0.6` → `1.0.6`).
>    - Genera el `manifest.json` con las URLs reales del bucket.
>    - Calcula el SHA256 del `.pck` y lo incluye en el campo `pck_sha256`.
>    - Sube el `manifest.json` al servidor/bucket.
> 6. **Secrets:** Explica cómo configurar en GitHub Settings > Secrets:
>    - `AWS_ACCESS_KEY_ID`
>    - `AWS_SECRET_ACCESS_KEY`
>    - `S3_BUCKET_NAME`
>    - `GODOT_EXPORT_PASSWORD` (si aplica)
>
> Dame el YAML completo del workflow y las instrucciones de configuración."

### 📋 Notas Técnicas (Verificadas contra Godot 4.6 Docs):

**Comandos CLI exactos para CI/CD:**
| Comando | Descripción |
|---------|-------------|
| `godot --headless --path ./ --export-release "Android" simulador.apk` | Exporta APK completo. `"Android"` debe coincidir exactamente con el nombre del preset en `export_presets.cfg`. |
| `godot --headless --path ./ --export-pack "Android" assets.pck` | Exporta solo el paquete de assets (PCK). |
| `godot --headless --path ./ --export-patch "Android" assets.pck --patches "base.pck"` | Exporta solo archivos cambiados respecto a `base.pck` (parche incremental). |

**⚠️ Reglas importantes del CLI de Godot:**
- `--headless` es **obligatorio** en entornos sin GPU (GitHub Actions runners).
- El **path de salida** es relativo al directorio del proyecto (donde está `project.godot`), **NO** al directorio de trabajo actual.
- El nombre del preset debe ir entre comillas si contiene espacios.
- El editor de Godot debe tener los **export templates instalados**.
- Para Android se requiere JDK 17 + Android SDK configurados en el editor.

**Variables de entorno para CI/CD Android (sin exponer keystore en archivos):**
| Variable | Propósito |
|----------|-----------|
| `GODOT_ANDROID_KEYSTORE_RELEASE_PATH` | Ruta al archivo `.keystore` |
| `GODOT_ANDROID_KEYSTORE_RELEASE_USER` | Alias de la clave |
| `GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD` | Contraseña del keystore |
| `GODOT_SCRIPT_ENCRYPTION_KEY` | Clave de cifrado de scripts (si se usa) |

**Secrets de GitHub necesarios:**
| Secret | Propósito |
|--------|-----------|
| `AWS_ACCESS_KEY_ID` | Acceso al bucket S3 |
| `AWS_SECRET_ACCESS_KEY` | Secreto del bucket S3 |
| `S3_BUCKET_NAME` | Nombre del bucket (ej. `simulador-updates`) |
| `S3_ENDPOINT` | Endpoint S3 (ej. `s3.us-east-1.amazonaws.com`) |
| `KEYSTORE_BASE64` | Keystore Android codificado en Base64 (se decodifica en el workflow) |
| `KEYSTORE_PASSWORD` | Contraseña del keystore |
| `KEYSTORE_ALIAS` | Alias de la clave |
| `MANIFEST_UPLOAD_URL` | URL del endpoint que recibe el manifest.json (o usar S3) |

**Ejemplo de configuración de Keystore en CI (sin exponer archivo binario en git):**
```yaml
- name: Decode Keystore
  run: echo "${{ secrets.KEYSTORE_BASE64 }}" | base64 -d > release.keystore
- name: Export APK
  env:
    GODOT_ANDROID_KEYSTORE_RELEASE_PATH: release.keystore
    GODOT_ANDROID_KEYSTORE_RELEASE_USER: ${{ secrets.KEYSTORE_ALIAS }}
    GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD: ${{ secrets.KEYSTORE_PASSWORD }}
  run: godot --headless --path ./ --export-release "Android" simulador.apk
```

**Export presets necesarios en el proyecto:**
El archivo `export_presets.cfg` debe tener al menos un preset llamado `"Android"` configurado con:
- Package/Unique Name
- Arquitecturas: `armeabi-v7a` y/o `arm64-v8a` (Meta Quest es arm64)
- Keystore configurado (Release)
- Permiso `INTERNET` habilitado

---

## 📝 Resumen del Flujo de Trabajo para el Administrador:

1. **Desarrollo:** Creas nuevos shaders, lentes o funcionalidades en tu PC.
2. **Commit y Tag:**
   ```bash
   git add .
   git commit -m "Añade lentes PanOptix Pro v2"
   git tag v1.0.7
   git push origin main --tags
   ```
3. **Automático:** GitHub Actions:
   - Exporta el APK y el PCK.
   - Calcula el SHA256 del PCK.
   - Sube todo al bucket S3.
   - Actualiza `manifest.json` en el servidor con las nuevas URLs y hash.
4. **Despliegue:** Los visores, al encenderse, descargan el `manifest.json`, detectan la nueva versión y se actualizan solos. Sin intervención manual.

---

## ⚠️ Checklist de Verificación Final para la Fase 5:

- [ ] **Modo Offline:** Si no hay internet al arrancar, el gestor permite entrar al simulador con los assets en disco.
- [ ] **Manejo de Crash:** Si un `.pck` corrupto causa 3 crashes, el boot counter elimina el parche y restaura la versión estable.
- [ ] **Factory Reset:** Existe un método para borrar `user://` y volver a estado de fábrica.
- [ ] **Logs:** El `UpdateManager` escribe `user://log_update.txt` con todos los eventos (éxitos y errores) para diagnóstico remoto.
- [ ] **Verificación de integridad:** Todo `.pck` descargado se verifica contra el SHA256 del manifest antes de cargarse.
- [ ] **CI/CD funcional:** Un `git tag v*` dispara el pipeline y el `manifest.json` se actualiza solo.
- [ ] **Permisos Android:** `AndroidManifest.xml` incluye `REQUEST_INSTALL_PACKAGES` y `FileProvider` para APK en Android 10+.
- [ ] **Barra de progreso real:** `_process()` usa `get_downloaded_bytes()` / `get_body_size()`, no solo la señal `request_completed`.
- [ ] **Timing de `load_resource_pack()`:** Se ejecuta en `_init()` del Autoload, no en `_ready()`.
- [ ] **Versión del APK embebida:** Hay un `res://version.txt` o `ProjectSettings` configurado con la versión para comparar en runtime.

---

## 🔗 Referencias (Godot 4.6 Docs — Verificadas):

| Tema | URL |
|------|-----|
| HTTPRequest (descarga, señales, progreso) | https://docs.godotengine.org/en/stable/classes/class_httprequest.html |
| Exporting PCKs (load_resource_pack, overlay, timing) | https://docs.godotengine.org/en/stable/tutorials/export/exporting_pcks.html |
| HashingContext (SHA256, MD5) | https://docs.godotengine.org/en/stable/classes/class_hashingcontext.html |
| FileAccess (get_sha256, cifrado, lectura/escritura) | https://docs.godotengine.org/en/stable/classes/class_fileaccess.html |
| DirAccess (operaciones de directorio) | https://docs.godotengine.org/en/stable/classes/class_diraccess.html |
| OS (get_unique_id, execute) | https://docs.godotengine.org/en/stable/classes/class_os.html |
| DisplayServer (shell_open) | https://docs.godotengine.org/en/stable/classes/class_displayserver.html |
| ProjectSettings (load_resource_pack) | https://docs.godotengine.org/en/stable/classes/class_projectsettings.html |
| CLI Export (--headless, --export-pack, --export-release) | https://docs.godotengine.org/en/stable/tutorials/editor/command_line_tutorial.html |
| Export Android (keystore, env vars, permisos) | https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_android.html |
| Exporting Projects (PCK vs ZIP, modos de export) | https://docs.godotengine.org/en/stable/tutorials/export/exporting_projects.html |

---

### ⚠️ Nota sobre Meta Quest y la Store:

Si el simulador se distribuye a través de **Meta Horizon Store**, las actualizaciones de APK las gestiona la propia Store. En ese caso, el sistema de auto-actualización de APK descrito en 5.3 y 5.4 **no es necesario** — solo se necesita el sistema de `.pck` para actualizar assets/lentes/shaders sin pasar por revisión de tienda.

Si la distribución es por **sideload** (fuera de la Store, típico en entornos médicos/clínicos), el sistema completo (APK + PCK) aplica, pero requiere que cada visor tenga el **modo desarrollador activado** y el permiso **"Install Unknown Apps"** concedido para la app.
