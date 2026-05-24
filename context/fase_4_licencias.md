# FASE 4 Detallada: Hardware Binding y Seguridad (Offline + Cloud)

El objetivo de esta fase es implementar un sistema de licenciamiento robusto. El visor debe ser capaz de verificar su autorización contra una API en la nube, pero ser lo suficientemente inteligente para no bloquear al médico si la clínica sufre un corte de internet temporal.

---

## 🔒 4.1 El Mecanismo de Seguridad: "Offline-First" con Periodo de Gracia

La lógica se basa en tres pilares:
1. **Identificación Única:** Usamos `OS.get_unique_id()` como el identificador de hardware (impreso en el visor).
2. **Cifrado Local:** El archivo de licencia no puede ser un simple .json legible. Debe ser un archivo binario cifrado para que no sea fácil de manipular manualmente.
3. **Validación de Delta:** Al fallar la conexión, calculamos la diferencia entre el timestamp actual y el último timestamp de validación exitosa guardado en el archivo cifrado.

### Flujo Lógico:
1. Al arrancar, el Visor intenta hacer un `HTTPRequest` a `api/verify`.
2. **Si el Servidor responde OK:** Se actualiza el archivo cifrado (`user://license.bin`) con el `timestamp` actual + un "hash" de seguridad (para evitar que alguien edite la fecha del archivo).
3. **Si falla la conexión:** El visor lee `user://license.bin`. Calcula `(fecha_actual - fecha_guardada)`. Si es <= 7 días, permite el acceso. Si es mayor, bloquea.
4. **Si el servidor devuelve 403 (Prohibido):** Bloqueo inmediato, sin importar el periodo de gracia.

---

## 🤖 Prompt para alimentar al LLM (Implementación del Autoload de Seguridad)

> "Actúa como un Desarrollador Senior en Godot 4 especializado en seguridad. Necesito crear un Autoload llamado `LicenseManager` que gestione el 'Hardware Binding'.
> 
> 1. **Setup:** Al entrar en `_ready()`, el script debe ejecutar una función `validate_license()`.
> 2. **Comunicación:** Debe usar `HTTPRequest` para enviar un POST a mi API con un JSON `{'device_id': OS.get_unique_id()}`.
> 3. **Cifrado:** Implementa una función para guardar y leer archivos cifrados usando `FileAccess.open_encrypted_with_pass()`. El archivo debe contener: `{'last_valid_date': <timestamp>, 'checksum': <hash>}`.
> 4. **Lógica de Gracia:**
>    - Si la respuesta de la API es 200 (OK), guarda el timestamp actual en `user://license.bin` y permite el inicio de la app.
>    - Si hay un error de red (Timeout/DNS), intenta leer `user://license.bin`. Si el archivo existe, verifica que `(actual_date - last_valid_date) < 7 días`. Si es válido, emite una señal `license_warning` (para mostrar un aviso al médico) y permite el inicio.
>    - Si el archivo no existe o el delta > 7 días, emite `license_denied` y detén la carga del juego.
>    - Si la respuesta de la API es 403, emite `license_denied` permanentemente.
> 5. **Seguridad:** Asegúrate de que el checksum valide que el archivo no fue alterado manualmente."

### 📋 Notas Técnicas (Verificadas contra Godot 4.6 Docs):

**Cifrado de archivos locales:**

| API | Uso |
|-----|-----|
| `FileAccess.open_encrypted_with_pass(path, mode_flags, pass)` | Abrir archivo con cifrado AES-256-CBC usando contraseña. `mode_flags` = `FileAccess.WRITE` o `FileAccess.READ`. |
| `FileAccess.store_var(data)` / `FileAccess.get_var()` | Escribir/leer datos tipados (Dictionary, Array, etc.) de forma serializada. Ideal para guardar estructura de licencia. |

⚠️ **La contraseña hardcodeada en el binario NO es segura.** Un atacante con acceso al APK puede extraerla. Para seguridad real en producción, usar ofuscación de código o derivación de clave basada en `OS.get_unique_id()`.

**Lógica de timestamp y periodo de gracia:**

| API | Uso |
|-----|-----|
| `Time.get_unix_time_from_system()` | Timestamp UTC actual en segundos (int64). |
| `Time.get_datetime_string_from_system()` | Fecha/hora legible para logging. |

**Diferencia de días:**
```gdscript
var now = Time.get_unix_time_from_system()
var last_valid = saved_data["last_valid_date"]
var days_passed = (now - last_valid) / 86400.0  # 86400 segundos = 1 día
if days_passed <= 7.0:
    # Periodo de gracia válido
```

**HTTPRequest para validación cloud:**

| API | Uso |
|-----|-----|
| `HTTPRequest.request(url, headers, HTTPClient.METHOD_POST, json_body)` | POST a `api/verify` con `{"device_id": OS.get_unique_id()}`. |
| `request_completed(result, response_code, headers, body)` | `response_code == 200` → licencia válida. `response_code == 403` → bloqueo permanente. |
| `HTTPRequest.timeout = 5.0` | Timeout corto (5s) para API. Si falla, pasar a modo offline. |

**Identificación única del dispositivo:**
| API | Retorna |
|-----|--------|
| `OS.get_unique_id()` | String único por dispositivo. En Android usa `ANDROID_ID` (puede cambiar al resetear de fábrica). |

**⚠️ Limitación en Android:** Si el dispositivo se resetea de fábrica, el ID cambia y la licencia se pierde. Solución: considerar un identificador secundario (ej. número de serie del visor, ingresado por el admin).

**Checksum anti-tamper:**
```gdscript
# Al guardar:
var data = {"last_valid_date": timestamp, "device_id": OS.get_unique_id()}
var checksum = (str(timestamp) + OS.get_unique_id()).sha256_text()
var saved = {"data": data, "checksum": checksum}
file.store_var(saved)

# Al leer:
var saved = file.get_var()
var expected = (str(saved["data"]["last_valid_date"]) + saved["data"]["device_id"]).sha256_text()
if saved["checksum"] != expected:
    # Archivo manipulado → licencia denegada
```
⚠️ `sha256_text()` requiere Godot 4.0+. Alternativa: `HashingContext` con `HASH_SHA256`.

**UI de bloqueo — CanvasLayer:**
- `CanvasLayer` con layer alta (ej. 128) para cubrir cualquier otra UI.
- `ColorRect` negro con `anchors_preset = FULL_RECT` como fondo.
- `Label` con `autowrap_mode` para texto largo (ID del dispositivo).

---

---

## 🛑 4.2 Bloqueo y UI de Estado

No basta con que el código se detenga; el profesional necesita saber por qué no puede usar el equipo.

### Consideraciones de UX:
- Si estamos en "periodo de gracia", muestra un pequeño aviso en la esquina superior de la UI de la tablet: *"Aviso: Licencia sin verificar. El equipo funcionará offline por X días más"*.
- Si la licencia es denegada, el Visor debe mostrar una pantalla negra con un código de error único (ej. `ERR_AUTH_01`) y la dirección MAC/HardwareID del visor, para que el médico pueda contactar al soporte técnico fácilmente.

### 🤖 Prompt para alimentar al LLM ( UI de Error):
> "Genera una escena de Godot 4 llamada `LicenseErrorScreen` que se muestre si `LicenseManager` emite la señal `license_denied`.
> 1. La pantalla debe ser un `CanvasLayer` con fondo negro.
> 2. Muestra un `Label` grande con el mensaje: 'Dispositivo no autorizado o licencia vencida'.
> 3. Muestra otro `Label` más pequeño con el Hardware ID del dispositivo (`OS.get_unique_id()`) y un código de error generado por el `LicenseManager`.
> 4. Asegúrate de que esta escena sea lo único visible, deteniendo cualquier proceso de juego en segundo plano."

---

## 💡 Notas para la escalabilidad:
* **Checksum:** Cuando el LLM genere el código de cifrado, asegúrate de que el `checksum` incluya también el `device_id`. Esto evita que alguien copie el archivo `license.bin` de un visor autorizado y lo pegue en uno no autorizado.
* **API del servidor:** Asegúrate de que tu backend no solo verifique el ID, sino que también tenga un endpoint para 'activar' visores nuevos.