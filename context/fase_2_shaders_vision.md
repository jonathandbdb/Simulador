# FASE 2 Detallada: Shaders de Visión (Modo "Blend" / Independencia Ocular)

Esta fase implementa la lógica de renderizado asimétrico necesaria para simulaciones de monovisión y lentes intraoculares multifocales. El objetivo es que cada ojo procese su propia profundidad de campo y distorsiones basadas en distancias de enfoque específicas.

---

## 🏗️ 2.1 Shaders con Control por Ojo (VIEW_INDEX) y Distancia Focal

El reto aquí es que el shader sea inteligente respecto a la profundidad. Para simular lentes multifocales (como PanOptix), necesitamos que el shader aplique un grado de desenfoque diferente dependiendo de si el objeto está en el punto focal (foco), cerca del punto focal (desenfoque ligero) o lejos del mismo (desenfoque fuerte).

### Requisitos Técnicos
1.  **Detección de Profundidad:** El shader debe leer el `DEPTH_TEXTURE` de Godot para saber a qué distancia real está cada píxel.
2.  **Parámetros Independientes:** Definiremos un set de parámetros para `(Cerca, Media, Lejos)` por cada ojo.
3.  **Lógica del Shader:** `VIEW_INDEX` decidirá qué set de parámetros aplicar a cada píxel.

### 🤖 Prompt para alimentar al LLM (Cursor / Copilot / ChatGPT):
> "Actúa como experto en Shaders de Godot 4 (GLSL). Estoy desarrollando un simulador oftálmico. Necesito un 'Screen Reading Shader' de post-procesado que realice lo siguiente:
> 1. Utilice el `DEPTH_TEXTURE` para calcular la distancia de los objetos a la cámara.
> 2. Reciba uniforms para definir 3 planos de enfoque: `near_distance`, `medium_distance`, `far_distance`.
> 3. Implemente la lógica de 'Blend' (Independencia Ocular) usando `VIEW_INDEX`:
>    - Si `VIEW_INDEX == 0` (ojo izquierdo), aplique un set de parámetros: `params_l` (con structs para near, medium, far blur).
>    - Si `VIEW_INDEX == 1` (ojo derecho), aplique `params_r`.
> 4. El shader debe calcular un efecto de 'Desenfoque de Profundidad' (Depth of Field) basado en la distancia calculada respecto a los planos de enfoque definidos.
> 5. Incluye uniforms para `halo_intensity` por ojo, que se apliquen solo a las áreas de alta luminosidad."

---

## 👁️ 2.2 Post-Process y Profundidad de Campo (DoF) Asimétrica

Godot 4's `WorldEnvironment` aplica el desenfoque de forma global a la cámara. Para lograr el "Blend" de lentes (ej. ojo izquierdo enfocado a lejos, ojo derecho enfocado a cerca), necesitamos un shader de post-procesado de pantalla completa que tome el control total.

### El Trabajo de Campo:
Necesitamos un `SubViewportContainer` en la escena VR. Esto permite que el shader de post-procesado corra después de que la escena 3D haya sido renderizada, permitiéndonos manipular los píxeles antes de enviarlos a los lentes del visor.

### 🤖 Prompt para alimentar al LLM:
> "Necesito implementar un sistema de 'Custom DoF' (Profundidad de campo) en Godot 4 que permita desenfocar la imagen basándose en la profundidad, de manera independiente por ojo.
> 1. Explícame cómo configurar un `SubViewport` que contenga toda la escena 3D, y cómo usar un `SubViewportContainer` con un `ShaderMaterial` para aplicar post-procesado a la salida de ese viewport.
> 2. Proporcióname el código del shader de post-procesado (Screen Reading Shader) que:
>    - Tome la textura del viewport (`SCREEN_TEXTURE`).
>    - Utilice el buffer de profundidad (`DEPTH_TEXTURE`) para convertir el valor de profundidad a distancia real en metros.
>    - Aplique un desenfoque (puedes usar un kernel simple de 9 taps o un box blur) cuya fuerza dependa de qué tan lejos esté el píxel del plano de enfoque (cerca, media o lejos).
>    - Aplique este cálculo de forma distinta para ojo izquierdo y derecho usando `VIEW_INDEX`.
> 3. ¿Cómo aseguro que este shader no cause lag en un Meta Quest 3? dame consejos de optimización (ej. uso de 'mipmap' o 'low res blur')."

### 📋 Notas Técnicas (Verificadas contra Godot 4.6 Docs):

**Screen-Reading Shaders en Godot 4:**

| API | Detalle |
|-----|---------|
| `hint_screen_texture` | Declarar `uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest`. Accede al contenido ya renderizado de la pantalla. |
| `hint_depth_texture` | Declarar `uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest`. **El depth NO es lineal** — debe convertirse con `INV_PROJECTION_MATRIX`. |
| `SCREEN_UV` | Built-in varying. UV relativo a la pantalla para el fragmento actual. |
| `textureLod(screen_texture, SCREEN_UV, 0.0)` | Leer del mipmap base. LOD > 0.0 requiere filter con `mipmap`. |

**Conversión de profundidad a distancia real (metros):**
```glsl
// En fragment():
float depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
vec4 upos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
vec3 pixel_position = upos.xyz / upos.w;
float distance_to_camera = length(pixel_position);  // en unidades de mundo
```

**⚠️ CRÍTICO para VR — Post-procesado estéreo:**
La doc oficial advierte: *"Many post process effects have not yet been updated to support stereoscopic rendering."*

El `WorldEnvironment` (DoF global, SSAO, SSR, glow) **no está garantizado** que funcione correctamente en modo estéreo/multiview. Esto confirma que el enfoque de la Fase 2 usando `SubViewport` + `ShaderMaterial` propio es **la decisión correcta**: bypassea el `WorldEnvironment` y permite control total por ojo vía `VIEW_INDEX`.

**SubViewport + SubViewportContainer (Workaround para post-procesado):**
| API | Detalle |
|-----|---------|
| `SubViewport` | Renderiza la escena 3D a una textura interna. Configurar `render_target_update_mode = ALWAYS`. |
| `SubViewportContainer` | Muestra la textura del SubViewport en pantalla. Se le asigna un `ShaderMaterial` con el shader de post-procesado. |
| `SubViewportContainer.material` | El `ShaderMaterial` que contiene el screen-reading shader con `hint_screen_texture` apuntando a la textura del viewport. |

**⚠️ Limitación del screen-reading en 3D:**
- En 3D, los materiales con `hint_screen_texture` se consideran **transparentes** y NO aparecen en la screen texture de otros materiales.
- La screen texture se captura **una sola vez** después del pase opaco, antes del transparente.
- Si necesitas múltiples capas de post-procesado, debes usar múltiples `SubViewport` encadenados.

**Optimización para Meta Quest 3 (documentado):**
| Técnica | Detalle |
|---------|---------|
| Mipmaps en screen texture | Usar `filter_nearest_mipmap` + `textureLod(screen_tex, SCREEN_UV, lod)` para blur "gratis" vía GPU. |
| Kernel reducido | Box blur de 9 taps en lugar de Gaussian blur de 15+ taps. Suficiente para simular pérdida de agudeza visual. |
| `scaling_3d_mode` en Viewport | Usar `SCALING_3D_MODE_FSR` (FidelityFX Super Resolution) con `scaling_3d_scale < 1.0` para renderizar a menor resolución y reescalar. |
| `texture_mipmap_bias` | Ajustar en Viewport para forzar mipmaps más agresivos (reduce carga de memoria). |
| Limitar el blur al mínimo necesario | Si `distance_to_plane` > umbral, aplicar blur. Si no, pasar el píxel sin modificar. |

**VIEW_INDEX en shaders de post-procesado (screen-reading):**
**⚠️ HALLAZGO CRÍTICO:** `VIEW_INDEX` **NO existe en shaders `canvas_item`**. Solo está disponible en shaders `spatial`. Esto significa que el post-procesado asimétrico por ojo **debe hacerse con un shader `spatial`**, nunca con `canvas_item`.

**Enfoque correcto (verificado):**
```glsl
shader_type spatial;                // ← DEBE ser spatial, NO canvas_item
render_mode unshaded;               // Sin iluminación (es post-procesado)

uniform sampler2D screen_texture : hint_screen_texture, filter_nearest;
uniform float blur_near_l;
uniform float blur_near_r;

void fragment() {
    vec3 color = textureLod(screen_texture, SCREEN_UV, 0.0).rgb;
    float blur_amount;
    if (VIEW_INDEX == 0) {          // ← VIEW_INDEX funciona en spatial
        blur_amount = blur_near_l;
    } else {
        blur_amount = blur_near_r;
    }
    // Aplicar blur basado en blur_amount + distancia
    ALBEDO = apply_blur(color, blur_amount);
}
```

**Montaje en escena:**
1. `SubViewport` con la escena 3D (mundo, iluminación, objetos).
2. `SubViewportContainer` mostrando el viewport en pantalla.
3. `ShaderMaterial` con el shader `spatial` asignado al `material_override` del `SubViewportContainer`.
4. El `SubViewportContainer` se posiciona como un Quad frente a la cámara XR.

**⚠️ Advertencia adicional de los OpenXR Settings:**
La foveated rendering (optimización de rendimiento en Quest) se **desactiva automáticamente** si se usan efectos de post-procesado (glow, bloom, DOF). Esto aplica tanto a `WorldEnvironment` como a shaders de post-procesado custom. Impacto: pérdida de ~15-20% de rendimiento GPU. Mitigación: usar `scaling_3d_scale < 1.0` con FSR para compensar.

---

## 📱 2.3 Lógica en la Tablet (Interfaz de Blend)

La tablet debe reflejar este estado binocular. Si el modo Blend está activo, el médico debe ver dos bloques de controles.

### Estructura de UI de Control
* **Modo Normal (Vincular Ojos):** Un solo conjunto de Sliders (Cerca, Media, Lejos, Halo).
* **Modo Blend:** Pantalla dividida. Bloque Ojo Izquierdo (Sliders) | Bloque Ojo Derecho (Sliders).

### 🤖 Prompt para alimentar al LLM:
> "Estoy construyendo la interfaz de control en Godot para mi app de tablet. 
> 1. Tengo un nodo `VBoxContainer` principal.
> 2. Crea un script en GDScript para un nodo `UI_Controller` que gestione el modo 'Blend'.
> 3. Incluye una señal `params_changed(eye: String, params: Dictionary)`.
> 4. Si el 'Modo Blend' está activado, la UI debe instanciar dos paneles idénticos (usando un `PackedScene` llamado 'Eye_Control_Panel'). 
> 5. Si está desactivado, debe ocultar uno y mostrar solo el principal, el cual, al moverse, actualiza los datos tanto de `left_eye` como `right_eye` en mi diccionario global `current_vision_state` del `DataManager`."
