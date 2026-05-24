# FASE 0 Detallada: Infraestructura Cloud, API REST y Panel de Control

Esta fase establece el **lado servidor** del ecosistema del simulador. Sin esto, las fases 4 (licencias) y 5 (actualizaciones) no tienen contra quién comunicarse. El objetivo es construir una API REST robusta, una base de datos de dispositivos y licencias, almacenamiento en la nube para artefactos, y un **Panel de Control web** desde donde el administrador gestiona todo sin tocar código.

---

## 🏗️ 0.1 Arquitectura General del Ecosistema

```
┌──────────────────────────────────────────────────┐
│                  ADMINISTRADOR                     │
│  (Navegador web → Panel de Control)                │
└──────────────────────┬───────────────────────────┘
                       │ HTTPS
                       ▼
┌──────────────────────────────────────────────────┐
│              SERVIDOR (API REST)                   │
│  ┌─────────────┐  ┌──────────┐  ┌─────────────┐  │
│  │ Panel Web   │  │ API REST │  │ Base Datos  │  │
│  │ (HTML/JS)   │  │ /api/*   │  │ (SQLite)    │  │
│  └─────────────┘  └────┬─────┘  └─────────────┘  │
│                        │                           │
└────────────────────────┼───────────────────────────┘
                         │
          ┌──────────────┼──────────────┐
          ▼              ▼              ▼
   ┌───────────┐  ┌───────────┐  ┌───────────┐
   │ Visor VR  │  │ Visor VR  │  │ Tablet    │
   │ (Quest)   │  │ (Quest)   │  │ (Control) │
   └───────────┘  └───────────┘  └───────────┘
          │              │              │
          └──────────────┴──────────────┘
                         │
                         ▼
              ┌──────────────────┐
              │  Bucket S3       │
              │  (APK, PCK,      │
              │   manifest.json) │
              └──────────────────┘
```

**Flujo de datos:**
1. El **Administrador** usa el Panel Web para gestionar dispositivos, lentes y versiones.
2. La **API REST** sirve `manifest.json`, verifica licencias, y entrega catálogos de lentes a los visores.
3. Los **Visores VR** consultan la API al arrancar (licencia + actualizaciones).
4. El **CI/CD** (GitHub Actions) sube APK/PCK al bucket S3 y notifica a la API.
5. La **Tablet** del médico se comunica por WebSocket directamente con el visor (Fase 3), no con el servidor.

---

## 🛠️ 0.2 Stack Tecnológico Recomendado

| Componente | Tecnología | Justificación |
|------------|------------|---------------|
| Backend API | **Python 3.11+ + FastAPI** | Ligero, async, documentación automática (Swagger), fácil de deployar. |
| Base de Datos | **SQLite** (desarrollo) / **PostgreSQL** (producción) | SQLite para empezar sin infraestructura extra. Migrable a Postgres si se escala. |
| Panel de Control | **HTML + Jinja2 + HTMX** (server-rendered) o **React/Vue SPA** | HTMX es más simple y no requiere build step. React si se quiere una SPA completa. |
| Almacenamiento | **AWS S3** o **Cloudflare R2** (compatible S3, sin costos de egress) | Para APK, PCK, y archivos grandes. |
| Autenticación Admin | **JWT + bcrypt** | Sesiones stateless para el panel de control. |
| Deploy | **Railway / Render / Fly.io** (gratis para empezar) o **VPS propio** | Alternativas: Docker + servidor propio en la clínica. |
| Monitoreo | **Archivos de log** + endpoint de health check | Simplicidad. Si escala, Prometheus + Grafana. |

### Estructura del proyecto backend:
```
backend/
├── main.py              # Punto de entrada FastAPI
├── config.py            # Configuración (env vars, secrets)
├── database.py          # Conexión SQLite/Postgres + modelos
├── models/
│   ├── device.py        # Modelo de dispositivo
│   ├── lens.py          # Modelo de catálogo de lentes
│   ├── version.py       # Modelo de versiones (manifest)
│   └── admin.py         # Modelo de usuario administrador
├── routers/
│   ├── manifest.py      # GET /api/manifest.json
│   ├── license.py       # POST /api/verify
│   ├── lenses.py        # GET /api/lenses
│   ├── devices.py       # CRUD de dispositivos
│   ├── versions.py      # CRUD de versiones (upload APK/PCK)
│   └── admin.py         # Auth + panel admin
├── templates/           # Jinja2 templates (si HTMX)
├── static/              # CSS/JS estáticos
└── requirements.txt     # Dependencias
```

---

## 🗄️ 0.3 Esquema de Base de Datos

### Tabla: `devices`
Dispositivos (visores) registrados/ autorizados.

| Columna | Tipo | Descripción |
|---------|------|-------------|
| `id` | INTEGER PK | ID interno |
| `device_id` | TEXT UNIQUE | `OS.get_unique_id()` del visor |
| `name` | TEXT | Nombre descriptivo (ej. "Visor Consultorio 3") |
| `status` | TEXT | `active`, `suspended`, `pending` |
| `last_seen` | DATETIME | Último contacto con el servidor |
| `last_ip` | TEXT | Última IP desde la que se conectó |
| `license_expiry` | DATE | Fecha de vencimiento de licencia (NULL = permanente) |
| `notes` | TEXT | Notas del administrador |
| `created_at` | DATETIME | Fecha de registro |
| `updated_at` | DATETIME | Última modificación |

### Tabla: `versions`
Control de versiones de APK y assets.

| Columna | Tipo | Descripción |
|---------|------|-------------|
| `id` | INTEGER PK | ID interno |
| `apk_version` | TEXT | Versión del APK (ej. "1.0.5") |
| `min_apk_version` | TEXT | Versión mínima requerida |
| `asset_version` | TEXT | Versión de assets (ej. "2.1.0") |
| `apk_url` | TEXT | URL pública del APK en S3 |
| `pck_url` | TEXT | URL pública del PCK en S3 |
| `pck_sha256` | TEXT | Hash SHA256 del PCK |
| `changelog` | TEXT | Descripción de cambios |
| `is_active` | BOOLEAN | Si es la versión actualmente publicada |
| `created_at` | DATETIME | Fecha de creación |

### Tabla: `update_logs`
Registro de actividad de actualizaciones de cada visor (para diagnóstico remoto).

| Columna | Tipo | Descripción |
|---------|------|-------------|
| `id` | INTEGER PK | ID interno |
| `device_id` | TEXT FK | Visor que envió el log |
| `event` | TEXT | Tipo de evento: `manifest_check`, `download_start`, `download_complete`, `hash_ok`, `hash_fail`, `update_success`, `update_failed`, `rollback` |
| `detail` | TEXT | Detalle del evento (versiones, errores) |
| `created_at` | DATETIME | Fecha/hora del evento |

### Tabla: `lenses_catalog`
Catálogo de lentes disponibles para los visores (el `lentes.json` que consume la Fase 1).

| Columna | Tipo | Descripción |
|---------|------|-------------|
| `id` | INTEGER PK | ID interno |
| `version` | TEXT | Versión del catálogo (ej. "1.2.0") |
| `data` | TEXT (JSON) | Contenido completo del JSON de lentes |
| `is_active` | BOOLEAN | Catálogo actualmente activo |
| `created_at` | DATETIME | Fecha de creación |

### Tabla: `admin_users`
Usuarios del panel de control.

| Columna | Tipo | Descripción |
|---------|------|-------------|
| `id` | INTEGER PK | ID interno |
| `username` | TEXT UNIQUE | Nombre de usuario |
| `password_hash` | TEXT | bcrypt hash de la contraseña |
| `role` | TEXT | `superadmin` o `viewer` |
| `created_at` | DATETIME | Fecha de creación |

---

## 🌐 0.4 Endpoints de la API REST

### 0.4.1 Endpoints Públicos (consumidos por el visor)

#### `GET /api/manifest.json`
Retorna el manifiesto de versión actual. Lo consume el `UpdateManager` del visor (Fase 5).

**Response 200:**
```json
{
  "min_apk_version": "1.0.2",
  "current_apk_version": "1.0.5",
  "current_asset_version": "2.1.0",
  "apk_url": "https://bucket.s3.region.amazonaws.com/simulador_v1.0.5.apk",
  "pck_url": "https://bucket.s3.region.amazonaws.com/assets_v2.1.0.pck",
  "pck_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "changelog": "Añadidas nuevas lentes PanOptix Pro."
}
```

**Response 503:** (si no hay versión activa — servidor en mantenimiento)

#### `POST /api/verify`
Verifica si un dispositivo tiene licencia válida. Lo consume el `LicenseManager` del visor (Fase 4).

**Request:**
```json
{
  "device_id": "abc123def456",
  "current_apk_version": "1.0.3",
  "current_asset_version": "2.0.0"
}
```

**Response 200 (licencia válida):**
```json
{
  "status": "ok",
  "device_name": "Visor Consultorio 3",
  "license_expiry": "2026-12-31",
  "message": "Licencia verificada correctamente."
}
```

**Response 403 (dispositivo no autorizado):**
```json
{
  "status": "denied",
  "reason": "DEVICE_NOT_FOUND",
  "message": "Este dispositivo no está registrado. Contacte al administrador."
}
```

**Response 403 (licencia vencida):**
```json
{
  "status": "denied",
  "reason": "LICENSE_EXPIRED",
  "message": "La licencia de este dispositivo ha vencido."
}
```

#### `GET /api/lenses`
Retorna el catálogo de lentes activo. Lo consume el `DataManager` del visor (Fase 1) para actualizar su `lentes.json` local.

**Response 200:**
```json
{
  "version": "1.2.0",
  "catalogo": [
    {
      "id": "panoptix",
      "nombre": "PanOptix Pro",
      "params": {
        "halo_intensity": { "default": 0.6, "min": 0.0, "max": 1.0 },
        "contrast_loss": { "default": 0.2, "min": 0.0, "max": 0.5 }
      }
    }
  ]
}
```

#### `POST /api/log`
Recibe logs de actualización desde el visor para almacenamiento centralizado.

**Request:**
```json
{
  "device_id": "abc123def456",
  "events": [
    {"event": "manifest_check", "detail": "manifest v2.1.0 downloaded"},
    {"event": "download_complete", "detail": "PCK 14.2MB downloaded"},
    {"event": "hash_ok", "detail": "SHA256 verified"},
    {"event": "update_success", "detail": "PCK loaded successfully"}
  ]
}
```

**Response 200:** `{"status": "ok", "events_logged": 4}`

---

### 0.4.2 Endpoints del Panel de Control (requieren autenticación JWT)

#### `POST /api/admin/login`
Inicia sesión en el panel de control.

**Request:** `{"username": "admin", "password": "***"}`
**Response 200:** `{"token": "eyJ...", "role": "superadmin", "expires_in": 3600}`

#### `GET /api/admin/devices`
Lista todos los dispositivos registrados (con filtros: `?status=active&search=consultorio`).

#### `POST /api/admin/devices`
Registra un nuevo dispositivo.

**Request:** `{"device_id": "abc123", "name": "Visor Quirófano 2", "license_expiry": "2026-12-31"}`

#### `PUT /api/admin/devices/<device_id>`
Actualiza datos de un dispositivo (nombre, estado, expiración).

#### `DELETE /api/admin/devices/<device_id>`
Elimina o suspende un dispositivo.

#### `GET /api/admin/versions`
Lista historial de versiones.

#### `POST /api/admin/versions`
Crea una nueva entrada de versión. Opcionalmente recibe archivos APK/PCK para subir al bucket.

**Request (multipart/form-data):**
```
apk_version: "1.0.6"
min_apk_version: "1.0.2"
asset_version: "2.2.0"
changelog: "Nuevas lentes y mejoras de rendimiento."
apk_file: <binary>
pck_file: <binary>
```

El servidor calcula SHA256 del PCK, sube ambos al bucket S3, y guarda el registro en BD.

#### `PUT /api/admin/versions/<id>/activate`
Activa una versión específica (la marca como publicada y actualiza el `manifest.json`).

#### `GET /api/admin/lenses`
Obtiene el catálogo de lentes actual.

#### `POST /api/admin/lenses`
Sube un nuevo catálogo de lentes (reemplaza o versiona).

**Request:** `{"version": "1.3.0", "data": {...catálogo JSON completo...}}`

#### `GET /api/admin/logs`
Consulta logs de actualizaciones. Filtros: `?device_id=abc&event=update_failed&days=30`.

#### `GET /api/admin/stats`
Estadísticas del dashboard: total dispositivos, activos, últimas actualizaciones, versiones instaladas.

---

## 🖥️ 0.5 Panel de Control (Interfaz Web)

El Panel de Control es la interfaz donde el administrador gestiona todo sin tocar archivos ni servidores directamente. Debe ser funcional desde una tablet o laptop estándar.

### Secciones del Panel:

#### 🏠 Dashboard (Vista Principal)
- Tarjetas con estadísticas: dispositivos activos, versión actual, última actualización.
- Gráfico simple: dispositivos por versión instalada.
- Tabla de actividad reciente (últimos 10 eventos de update_logs).
- Indicador de salud del servidor (API online, bucket accesible).

#### 📱 Dispositivos
- Tabla paginada con todos los visores registrados.
- Columnas: Nombre, Device ID, Estado (activo/suspendido/pendiente), Última conexión, Licencia hasta.
- Filtros por estado y búsqueda por nombre.
- Botones: **Registrar nuevo**, **Editar**, **Suspender/Reactivar**, **Eliminar**.
- Al registrar: formulario con Device ID, nombre, y fecha de expiración opcional.

#### 📦 Versiones
- Lista de versiones publicadas (APK + Assets).
- Mostrar: versión APK, versión assets, changelog, fecha, estado (activa/histórica).
- Botón: **Nueva versión** → formulario de upload con:
  - Campos de texto para versiones (APK, assets, changelog).
  - Upload de archivo APK (.apk).
  - Upload de archivo PCK (.pck).
  - Checkbox "Publicar inmediatamente" (actualiza manifest.json).
- Al hacer upload, el servidor calcula SHA256 del PCK automáticamente.
- Botón **Activar** en versiones históricas para hacer rollback.

#### 👁️ Catálogo de Lentes
- Editor JSON con resaltado de sintaxis y validación.
- Vista previa del catálogo (tabla con lentes y parámetros).
- Botón **Importar** (subir JSON), **Exportar** (descargar JSON actual).
- Botón **Guardar y publicar** (actualiza el endpoint `/api/lenses`).

#### 📋 Logs
- Visor de logs con filtros: por dispositivo, por tipo de evento, por rango de fechas.
- Tabla: Fecha, Dispositivo, Evento, Detalle.
- Botón **Exportar CSV** para enviar a soporte.
- Indicador visual de errores (filas en rojo si evento es `update_failed` o `hash_fail`).

#### ⚙️ Configuración
- Configuración de conexión S3 (endpoint, bucket, región).
- URL base pública para descargas (CDN o bucket directo).
- Gestión de usuarios administradores (si hay más de uno).
- Cambio de contraseña.

### 🤖 Prompt para alimentar al LLM (Panel de Control):
> "Actúa como desarrollador full-stack senior. Necesito construir el Panel de Control para mi sistema de simulación VR oftalmológica.
>
> **Stack:** Python + FastAPI (backend), Jinja2 + HTMX + Tailwind CSS (frontend server-rendered). Base de datos SQLite.
>
> **Requisitos:**
> 1. Genera la estructura completa del proyecto FastAPI con routers separados para API pública y panel admin.
> 2. Implementa autenticación JWT para el panel de control (`/api/admin/login`, middleware de verificación).
> 3. Crea el Dashboard con tarjetas de estadísticas usando consultas SQL agregadas.
> 4. Implementa el CRUD completo de dispositivos con tabla paginada, búsqueda y filtros.
> 5. Crea el gestor de versiones con upload de archivos APK/PCK, cálculo automático de SHA256, y subida a S3 usando `boto3`.
> 6. Implementa el editor de catálogo de lentes con un textarea JSON + validación + vista previa en tabla.
> 7. Crea el visor de logs con filtros y exportación CSV.
> 8. Asegura que el panel sea responsive (funcione en tablet y laptop).
> 9. Incluye protección CSRF y rate limiting en endpoints sensibles."

---

## 🔒 0.6 Seguridad del Servidor

| Aspecto | Implementación |
|---------|---------------|
| **HTTPS** | Obligatorio en producción. Usar Let's Encrypt (gratis) o Cloudflare. |
| **Autenticación API pública** | Los endpoints `/api/verify` y `/api/log` no requieren auth, pero validan `device_id` contra BD. |
| **Autenticación Panel Admin** | JWT con expiración (1h). Refresh tokens opcionales. |
| **Protección de uploads** | Solo administradores autenticados pueden subir APK/PCK. Validar tipo de archivo y tamaño máximo. |
| **Rate Limiting** | `/api/verify`: máximo 1 petición por minuto por IP (evita brute-force). |
| **API Keys para CI/CD** | Un endpoint dedicado con API key (no JWT) para que GitHub Actions pueda notificar nuevas versiones. |
| **CORS** | Solo permitir orígenes del panel de control y del bucket S3. |

---

## 🚀 0.7 Despliegue

### Opción A: Cloud (recomendado para empezar)
1. **Railway / Render / Fly.io**: Deploy gratuito de FastAPI + SQLite.
2. **Cloudflare R2**: Bucket S3-compatible sin costos de egress (ideal para descargas de APK/PCK).
3. **Migración a Postgres**: Cuando el volumen de dispositivos lo justifique.

### Opción B: On-Premise (clínica con servidor propio)
1. **Docker Compose** con FastAPI + SQLite + Nginx reverse proxy.
2. **MinIO** como bucket S3-compatible auto-hospedado.
3. VPN o red local — no requiere exponer a internet público (más seguro).

### Variables de entorno necesarias:
```env
DATABASE_URL=sqlite:///simulador.db
S3_ENDPOINT=https://s3.us-east-1.amazonaws.com
S3_BUCKET=simulador-updates
S3_ACCESS_KEY=AKIA...
S3_SECRET_KEY=...
S3_REGION=us-east-1
PUBLIC_BASE_URL=https://updates.midominio.com
JWT_SECRET=clave-secreta-jwt
ADMIN_DEFAULT_USER=admin
ADMIN_DEFAULT_PASS=admin123  # Cambiar en primer inicio
API_KEY_CI=clave-para-github-actions
```

---

## 🔗 0.8 Integración con las Demás Fases

| Fase | Cómo se conecta con Fase 0 |
|------|---------------------------|
| **F1** (Core VR) | `DataManager` descarga `GET /api/lenses` para obtener el catálogo de lentes más reciente. |
| **F3** (Tablet) | La whitelist de `device_id` de la tablet se gestiona desde el Panel de Dispositivos. |
| **F4** (Licencias) | `LicenseManager` llama a `POST /api/verify` cada vez que arranca el visor. Las respuestas 200/403 definen el comportamiento. |
| **F5** (OTA) | `UpdateManager` descarga `GET /api/manifest.json` y las URLs de descarga apuntan al bucket S3 gestionado por esta fase. El CI/CD notifica nuevas versiones a la API vía API Key. |

---

## 📝 Flujo de Trabajo del Administrador con la Fase 0:

1. **Primera vez:** Desplegar el backend (Railway o Docker). Crear usuario admin.
2. **Registrar dispositivos:** Entrar al Panel → Dispositivos → Registrar nuevo → ingresar Device ID del visor y nombre.
3. **Cargar lentes:** Panel → Catálogo de Lentes → pegar/editar el JSON → Guardar.
4. **Publicar versión inicial:** Panel → Versiones → Nueva versión → subir APK y PCK → Publicar.
5. **Día a día:** Revisar Dashboard para ver estado de dispositivos. Si un visor falla, revisar Logs.
6. **Actualización:** El CI/CD (o el admin manualmente) sube nueva versión → los visores se actualizan solos al encenderse.

---

## ⚠️ Checklist de Verificación para la Fase 0:

- [ ] **API online:** `GET /api/manifest.json` retorna 200 con JSON válido.
- [ ] **Verificación de licencia:** `POST /api/verify` con device_id válido retorna 200; con ID inválido retorna 403.
- [ ] **Catálogo de lentes:** `GET /api/lenses` retorna el JSON activo.
- [ ] **Panel de Control accesible:** Login funciona, JWT se refresca.
- [ ] **CRUD Dispositivos:** Se puede registrar, editar, suspender y eliminar dispositivos.
- [ ] **Upload de versiones:** Subir APK y PCK los almacena en S3 y calcula SHA256.
- [ ] **Publicación de versión:** Activar una versión actualiza `GET /api/manifest.json` inmediatamente.
- [ ] **Logs centralizados:** `POST /api/log` recibe eventos y se visualizan en el panel.
- [ ] **HTTPS:** Todos los endpoints sirven sobre TLS en producción.
- [ ] **Backup:** La BD SQLite se respalda periódicamente (cron job o similar).
