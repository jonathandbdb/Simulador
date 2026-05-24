# FASE 1 Detallada: Core del Visor VR, Datos y Estereoscopía

Esta guía profundiza en la Fase 1 del desarrollo del Simulador VR Oftalmológico en Godot 4. El objetivo de esta etapa es dejar los cimientos perfectamente estructurados para soportar visión independiente por ojo (Blend / Monovisión), lectura dinámica de parámetros y un entorno de pruebas transicionable.

---

## 🏗️ 1.1 Configuración Base OpenXR y el Secreto del "Blend" (VIEW_INDEX)

Para lograr el "Blend" de lentes (por ejemplo, PanOptix en el ojo izquierdo y Vivity en el derecho), no necesitamos renderizar dos cámaras distintas ni duplicar la geometría. Godot 4 con OpenXR utiliza una técnica llamada **Multiview**.

### ¿Cómo funciona el Blend a nivel técnico?
Godot renderiza la escena una sola vez pero envía dos "vistas" al visor. En los *Shaders* de Godot 4, existe una variable integrada llamada `VIEW_INDEX`.
* Si `VIEW_INDEX == 0`, se está dibujando el píxel para el **Ojo Izquierdo**.
* Si `VIEW_INDEX == 1`, se está dibujando el píxel para el **Ojo Derecho**.

Esto significa que nuestro material de post-procesado (el que genera los halos o el desenfoque) evaluará esta variable y decidirá qué parámetros aplicar en tiempo real, sin penalizar el rendimiento del visor.

### 🤖 Prompt para alimentar al LLM (Cursor / Copilot / ChatGPT):
> "Actúa como Arquitecto Senior en Godot 4 y OpenXR. Estoy configurando la escena principal de mi visor VR (Meta Quest).
> 1. Dame el paso a paso exacto para configurar los nodos `XROrigin3D` y `XRCamera3D`.
> 2. Explícame cómo crear un plano (Quad) emparentado a la cámara (como un HUD a pantalla completa) con un `ShaderMaterial`.
> 3. Escribe el código de ese Custom Shader (Spatial) que utilice la directiva `VIEW_INDEX`. El shader debe recibir uniforms independientes para cada ojo (ej. `halo_size_l` y `halo_size_r`, `blur_amount_l` y `blur_amount_r`) y usar un `if (VIEW_INDEX == 0)` para aplicar los valores izquierdos y un `else` para los derechos.
> 4. Asegúrate de incluir la configuración de renderizado en `Project Settings` necesaria para Multiview en Android."

### 📋 Notas Técnicas (Verificadas contra Godot 4.6 Docs):

**Configuración de OpenXR:**
| Paso | API / Setting | Detalle |
|------|--------------|---------|
| Habilitar OpenXR | Project Settings > XR > OpenXR > **Enabled** | Sin esto, `find_interface("OpenXR")` falla. |
| Habilitar XR Shaders | Project Settings > XR > Shaders > **Enabled** | Requiere **Save & Restart** del editor. Crítico para usar `VIEW_INDEX` en shaders. |
| Inicializar interfaz | `XRServer.find_interface("OpenXR")` → `is_initialized()` | Retorna `false` si el visor no está conectado o el runtime no está activo. |
| Activar XR en viewport | `get_viewport().use_xr = true` | Redirige el renderizado al HMD. |
| Desactivar vsync | `DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)` | Obligatorio. El HMD maneja su propia sincronización (90/120Hz). Si no, se limita a la tasa del monitor. |
| Physics ticks | `Engine.physics_ticks_per_second = 90` (o 120) | Por defecto 60Hz. En VR debe igualar la tasa del visor para física fluida. |

**Renderer para Meta Quest:**
La doc oficial recomienda **Compatibility** para dispositivos standalone (Quest). Forward+ no está optimizado para XR aún.

**⚠️ ADVERTENCIA DE LA DOC OFICIAL:**
> "Many post process effects have not yet been updated to support stereoscopic rendering. Using these will have adverse effects."

Esto impacta directamente la Fase 2 (shaders de post-procesado). El `WorldEnvironment` y efectos como DoF, SSAO, SSR pueden no funcionar correctamente en estéreo. El enfoque con `SubViewport` + `ShaderMaterial` descrito en la Fase 2 es la alternativa correcta.

**VIEW_INDEX — Confirmado en Spatial Shader Built-ins:**
| Built-in | Valor | Significado |
|----------|-------|-------------|
| `VIEW_INDEX` | `0` | Mono u ojo izquierdo |
| `VIEW_MONO_LEFT` | `0` | Constante para izquierda |
| `VIEW_RIGHT` | `1` | Constante para derecha |
| `EYE_OFFSET` | `vec3` | Offset del ojo actual en view space (solo multiview) |
| `CAMERA_POSITION_WORLD` | `vec3` | **Punto medio** entre ambos ojos (no la posición de un ojo individual) |

**Jerarquía de nodos XR correcta:**
```
XROrigin3D (raíz, centro del espacio de juego)
├── XRCamera3D (cámara estéreo, controlada por tracking)
├── XRController3D (mano izquierda, tracker = left_hand)
└── XRController3D (mano derecha, tracker = right_hand)
```

**DataManager (Autoload):**
| API | Uso |
|-----|-----|
| `FileAccess.open("user://lentes.json", FileAccess.READ)` | Leer archivo JSON local. Retorna `null` si no existe. |
| `FileAccess.get_file_as_string("user://lentes.json")` | Alternativa más simple para leer el archivo completo. |
| `JSON.new().parse(string)` + `get_data()` | Parsear el contenido. Verificar `json.get_error_line() == -1`. |
| `ProjectSettings.globalize_path("user://")` | Obtener ruta absoluta de `user://` para depuración. |

**Fade to black para transición día/noche:**
- `ColorRect` con `color.a` animado vía `Tween` (Godot 4: `create_tween()`).
- No usar `AnimationPlayer` para esto si solo es un fade simple; `Tween` es más ligero.

---

## 💾 1.2 El Gestor de Datos (DataManager) y el JSON Estereoscópico

El `DataManager` será un **Autoload** (Singleton) en Godot. Su trabajo es arrancar antes que cualquier otra escena, leer un archivo `user://lentes.json` y mantener el "Estado Actual" de la visión del paciente.

Para soportar el "Blend", el estado global de la aplicación siempre debe pensar en dos ojos. Si el médico no activa el Blend, simplemente copiamos los datos del ojo izquierdo al derecho.

### Estructura de Datos Recomendada (JSON)
```json
{
  "catalogo": [
    {
      "id": "panoptix",
      "nombre": "PanOptix Pro",
      "params": {
        "halo_intensity": { "default": 0.6, "min": 0.0, "max": 1.0 },
        "contrast_loss": { "default": 0.2, "min": 0.0, "max": 0.5 }
      }
    },
    {
      "id": "monofocal",
      "nombre": "Monofocal Estándar",
      "params": {
        "halo_intensity": { "default": 0.1, "min": 0.0, "max": 0.3 },
        "contrast_loss": { "default": 0.05, "min": 0.0, "max": 0.2 }
      }
    }
  ]
}