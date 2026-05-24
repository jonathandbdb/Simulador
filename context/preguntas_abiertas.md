# Preguntas Abiertas — Simulador VR Oftalmológico

Este documento recoge preguntas de diseño, arquitectura y desarrollo que deben resolverse **antes o durante** la implementación de cada fase. Cada pregunta incluye opciones con pros y contras para decidir al momento de programar.

---

## 🔴 Fase 0 — Backend y Panel de Control

### Q0.1 — ¿Cloud o auto-hospedado (on-premise)?
El servidor puede vivir en la nube o en un servidor dentro de la clínica. La decisión impacta la seguridad, latencia, y requisitos de Fase 4 (offline grace period).

| Opción | Pros | Contras |
|--------|------|---------|
| **A) Cloud (Railway/Render/Fly.io)** | Sin mantenimiento de hardware, accesible desde cualquier clínica, escalable, backups automáticos. | Requiere internet siempre (crítico para F4), datos médicos en terceros, costo mensual. |
| **B) On-premise (Docker en servidor local)** | Datos 100% locales (privacidad médica), funciona en intranet sin internet, sin costo mensual. | El admin mantiene el servidor, backups manuales, difícil acceso remoto para soporte. |
| **C) Híbrido (API cloud + bucket local)** | API ligera en cloud para manifest/licencias, archivos grandes (APK/PCK) en servidor local o viceversa. | Complejidad operativa, dos cosas que mantener. |

### Q0.2 — ¿SQLite o PostgreSQL desde el inicio?
SQLite es más simple pero tiene límites de concurrencia. PostgreSQL requiere infraestructura extra.

| Opción | Pros | Contras |
|--------|------|---------|
| **A) SQLite + migrar a Postgres si escala** | Cero configuración, backup = copiar archivo, perfecto para <100 dispositivos y 1 admin. | Sin concurrencia real (solo un writer), no apto para alta carga. |
| **B) PostgreSQL desde el inicio** | Concurrencia, replicación, backups profesionales, tipos de datos ricos. | Requiere servidor Postgres corriendo, más complejidad de deploy. |

### Q0.3 — ¿El Panel de Control debe ser server-rendered (HTMX) o SPA (React/Vue)?
Impacta la complejidad de desarrollo y la experiencia de uso en tablet.

| Opción | Pros | Contras |
|--------|------|---------|
| **A) Server-rendered (Jinja2 + HTMX + Tailwind)** | Mismo repo que la API, sin build step, rápido de desarrollar, liviano en tablet. | Menos interactividad rica, recargas de página para navegación. |
| **B) SPA (React/Vue + Vite)** | Experiencia de app nativa, navegación instantánea, componentes reutilizables. | Build step separado, dos repos o monorepo, más complejidad de desarrollo. |
| **C) Godot (la misma tablet app de F3 como admin)** | Un solo codebase, interfaz nativa en Android/iOS, consistencia visual. | Godot no es ideal para formularios/CRUD, más lento de iterar que web. |

### Q0.4 — ¿Cómo se registra un dispositivo por primera vez?
Escenario: visor nuevo, sin licencia local, sin internet. ¿Cómo entra al sistema?

| Opción | Pros | Contras |
|--------|------|---------|
| **A) Pre-registro manual en panel** | Admin ingresa el Device ID manualmente (leído del visor o etiqueta física). | Requiere que el admin tenga el ID antes de que el visor se conecte. |
| **B) Modo "primer arranque" con código de emparejamiento** | El visor muestra un código de 6 dígitos, el admin lo ingresa en el panel. | Más friendly, pero requiere que el visor tenga UI de primer arranque. |
| **C) Auto-registro con aprobación pendiente** | El visor se auto-registra al conectarse y queda en estado "pending" hasta que el admin lo aprueba. | Simple, pero vulnerable a registros no deseados si la API es pública. |

---

## 🔴 Fase 1 — Core VR y Base de Datos

### Q1.1 — ¿Cuál es la fuente inicial de lentes en el visor?
El `DataManager` lee `user://lentes.json`. En un primer arranque sin internet, ese archivo no existe.

| Opción | Pros | Contras |
|--------|------|---------|
| **A) Embeber un `lentes.json` por defecto en el APK** | El visor siempre tiene lentes base, funciona 100% offline. | Si se actualiza el catálogo en servidor, hay que esperar a que el visor se conecte para ver nuevas lentes. |
| **B) Descargar del servidor al primer arranque** | Siempre tiene el catálogo más reciente. | Si no hay internet en primer arranque, el visor está vacío — no usable. |
| **C) A) + B) combinado** | Lentes base en APK, actualización desde API cuando haya internet. | Lógica más compleja (merge de catálogo local + remoto). |

### Q1.2 — ¿Cómo se maneja el fade to black en VR?
El `EnvironmentManager` propone un `ColorRect` frente a la cámara para el fundido. En VR, un `ColorRect` 2D no funciona igual.

| Opción | Pros | Contras |
|--------|------|---------|
| **A) Quad 3D negro frente a la cámara XR** | Cubre todo el FOV del visor, funciona nativamente en estéreo. | Hay que posicionarlo correctamente respecto al `XRCamera3D`. |
| **B) ColorRect en un `SubViewport` overlay** | Control total 2D, independiente de la escena 3D. | Añade un Viewport extra (costo de rendimiento). |
| **C) Post-process shader que oscurece la pantalla** | Sin geometría extra, fade suave. | El shader corre en ambos ojos igual; no es problema para un fade. |

### Q1.3 — ¿El catálogo de lentes se actualiza con el sistema OTA de F5 o es independiente?
El `lentes.json` podría ser parte del `.pck` de assets o descargarse por separado.

| Opción | Pros | Contras |
|--------|------|---------|
| **A) El catálogo va DENTRO del .pck de assets** | Versionado atómico junto con shaders. Una sola descarga. | Si solo cambian lentes, hay que re-empaquetar y descargar todo el .pck. |
| **B) El catálogo se descarga por separado (HTTP GET)** | Ligero, se actualiza sin tocar el .pck. | Dos sistemas de actualización (F1 + F5). Riesgo de desincronización: lentes nuevas que requieren shaders nuevos. |
| **C) Híbrido: catálogo en .pck, pero con endpoint `/api/lenses` para consulta rápida** | El visor puede saber si hay lentes nuevas sin descargar todo el .pck. | Complejidad extra en `DataManager`. |

---

## 🔴 Fase 2 — Shaders de Visión

### Q2.1 — ¿Shader `spatial` con screen_texture en Quad, o Spatial con SubViewport?
Verificado: `VIEW_INDEX` solo existe en shaders `spatial`. Pero hay dos formas de aplicarlo a post-procesado.

| Opción | Pros | Contras |
|--------|------|---------|
| **A) SubViewportContainer + ShaderMaterial spatial** | Aisla el post-procesado de la escena. Fácil de debugear. | Un Viewport extra. En VR ya hay presión de rendimiento. |
| **B) Quad espacial frente a XRCamera3D con ShaderMaterial** | Sin Viewport extra. Más ligero. | El Quad debe ser hijo de la cámara y moverse con ella. Posibles problemas de clipping. |
| **C) Compositor de post-procesado de Godot (Compositor API)** | Nativo, optimizado. Disponible en Godot 4.2+. | Compatibilidad con estéreo no verificada. API experimental. |

### Q2.2 — ¿Cuántos taps de blur son viables en Quest 3 a 90 FPS?
Simular pérdida de agudeza visual requiere blur. El rendimiento varía según el tamaño del kernel.

| Opción | Pros | Contras |
|--------|------|---------|
| **A) Box blur 9 taps (3x3)** | Muy rápido, ~0.3ms. | Efecto sutil, puede no ser suficiente para simular cataratas severas. |
| **B) Gaussian blur 15 taps (separable, 5+5)** | Buen balance calidad/rendimiento, ~0.8ms. | Sigue siendo un blur simple. |
| **C) Mipmap blur (`textureLod` con LOD alto)** | Gratis (GPU), sin samples extra. Muy rápido. | No es un blur real, es un downscale + upscale. Aspecto "pixelado". |
| **D) Combinar mipmap + pequeño kernel (híbrido)** | Buen rendimiento con calidad aceptable. Mejor de ambos mundos. | Más complejo de implementar. |

### Q2.3 — ¿El efecto halo debe ser un shader separado o combinado con el DoF?
Los halos (glare alrededor de luces) y el desenfoque son efectos distintos pero relacionados.

| Opción | Pros | Contras |
|--------|------|---------|
| **A) Shader unificado (halo + DoF juntos)** | Un solo pase de post-procesado, menos overhead. | Shader más complejo. Difícil ajustar halo sin afectar DoF y viceversa. |
| **B) Shaders separados en dos pases** | Cada efecto es simple. Se pueden activar/desactivar independientemente. | Dos pases de post-procesado = doble costo de GPU. Crítico en Quest. |
| **C) Halo solo en pixeles brillantes (threshold), DoF en todos** | El halo se aplica condicionalmente, ahorrando cómputo en zonas oscuras. | Requiere un paso de detección de brillo en el mismo shader. |

### Q2.4 — ¿La combinación de SubViewport propio + foveated rendering desactivado es aceptable?
OpenXR docs: foveated rendering se desactiva con post-procesado. Esto impacta rendimiento.

| Opción | Pros | Contras |
|--------|------|---------|
| **A) Aceptar la pérdida y compensar con FSR (scaling_3d_scale < 1.0)** | FSR puede recuperar ~20% de rendimiento. | La imagen se ve un poco más suave (lo cual en un simulador de visión podría ser aceptable). |
| **B) Renderizar la escena a resolución nativa sin foveated rendering** | Imagen nítida donde no hay blur. | ~15-20% más carga de GPU. Puede bajar de 90 FPS. |
| **C) Usar foveated rendering solo en la escena base (sin post-procesado) y post-procesado solo en el SubViewport** | La escena base se beneficia de foveated. | La complejidad de setup aumenta. Dos viewports encadenados. |

---

## 🔴 Fase 3 — Streaming y Tablet

### Q3.1 — ¿Opción A (streaming de video) u Opción B (replicación 2D)?
La Fase 3 ya plantea esta decisión, pero está pendiente de pruebas de rendimiento.

| Opción | Pros | Contras |
|--------|------|---------|
| **A) Streaming de video real** | El paciente ve exactamente lo que ve el médico (incluyendo UI y efectos). | Godot no tiene captura asíncrona de viewport → stuttering en VR. Latencia. Batería del Quest. |
| **B) Replicación 2D síncrona** | 60 FPS fluidos, sin overhead de compresión. | La tablet necesita los mismos assets 3D que el visor. Solo muestra geometría, no efectos de post-procesado. |
| **C) Híbrido: replicación 2D con captura de textura del SubViewport** | La tablet renderiza su propia escena 3D pero aplica la textura del viewport del Quest como referencia visual. | Complejidad de sincronización. |

### Q3.2 — ¿A qué resolución y FPS se streamea el video?
Impacta directamente el rendimiento del Quest y la calidad en la tablet.

| Opción | Pros | Contras |
|--------|------|---------|
| **A) 512×512 @ 15 FPS, JPG calidad 50** | Mínimo impacto en Quest (~2-3ms por frame). | Imagen pixelada, 15 FPS se ve entrecortado. |
| **B) 512×512 @ 30 FPS, JPG calidad 70** | Más fluido, calidad aceptable. | ~5-8ms por frame en Quest — riesgo de bajar de 90 FPS. |
| **C) 256×256 @ 30 FPS, JPG calidad 50** | Muy ligero, casi sin impacto. | Demasiado pequeña para ver detalles. |
| **D) Dinámico: ajustar según carga de GPU** | Se adapta a la escena (escenas simples = más calidad). | Complejidad de implementación. |

### Q3.3 — ¿Cuántas tablets pueden conectarse simultáneamente al visor?
El WebSocket server en el Quest puede aceptar múltiples conexiones.

| Opción | Pros | Contras |
|--------|------|---------|
| **A) Solo 1 tablet** | Simple, sin conflictos de control. | Solo el médico principal puede ver/controlar. |
| **B) Múltiples tablets (1 controla, N ven)** | Un médico controla, otros observan (formación). | Más ancho de banda. Lógica de "quién controla" compleja. |
| **C) Múltiples tablets con control compartido** | Varios médicos pueden ajustar parámetros. | Conflictos de control. Carreras de condiciones. |

---

## 🔴 Fase 4 — Licencias y Seguridad

### Q4.1 — ¿Qué pasa si el dispositivo se resetea de fábrica?
`OS.get_unique_id()` usa `ANDROID_ID` en Android, que cambia al resetear de fábrica.

| Opción | Pros | Contras |
|--------|------|---------|
| **A) El admin debe re-registrar el dispositivo manualmente** | Simple, sin lógica extra. | El visor queda inutilizado hasta que el admin lo registre de nuevo. Fricción para el médico. |
| **B) Fingerprint compuesto (MAC + ANDROID_ID + serial)** | Más robusto ante reseteos. | Algunos de estos valores requieren permisos extra o no son accesibles desde Godot sin plugin. |
| **C) Código de recuperación (mostrado en pantalla de error)** | Similar al "primer arranque" de Q0.4. El médico llama a soporte con un código. | Proceso manual. |

### Q4.2 — ¿Cómo se gestiona la renovación de licencia?
Las licencias pueden ser temporales (anuales) o permanentes.

| Opción | Pros | Contras |
|--------|------|---------|
| **A) Solo permanentes (sin expiración)** | Cero fricción post-venta. | Sin ingresos recurrentes. Si un cliente no paga, hay que revocar manualmente. |
| **B) Anuales con recordatorio en el panel** | Ingresos recurrentes. El panel avisa 30 días antes del vencimiento. | Si el admin no renueva, el visor se bloquea → médico sin herramienta. |
| **C) Anuales con periodo de gracia extendido (30 días)** | El visor sigue funcionando 30 días después del vencimiento. | Potencial abuso. |

### Q4.3 — ¿Dónde se almacena la contraseña de cifrado de `license.bin`?
`FileAccess.open_encrypted_with_pass()` requiere una contraseña. Si está hardcodeada en el binario, es extraíble.

| Opción | Pros | Contras |
|--------|------|---------|
| **A) Hardcodeada en GDScript** | Simple de implementar. | Inseguro. Cualquiera con el APK puede extraerla. |
| **B) Derivada de `OS.get_unique_id()` + salt** | Única por dispositivo. Si cambia el ID, se pierde la licencia. | Si se resetea el dispositivo, la licencia anterior es irrecuperable. |
| **C) Derivada de un secreto embebido + ofuscación** | Más seguro que hardcodeado. | La ofuscación en GDScript es limitada. Sigue siendo extraíble con ingeniería inversa. |
| **D) Aceptar que la seguridad 100% no existe en cliente, y depender del servidor** | El servidor es la fuente de verdad (Fase 4). El archivo local es solo un cache del estado. | Si el archivo local es manipulado, el servidor lo detecta en la próxima verificación online. |

---

## 🔴 Fase 5 — OTA y CI/CD

### Q5.1 — ¿El sistema de auto-actualización de APK aplica si se distribuye por Meta Store?
Si el simulador está en la Meta Horizon Store, las actualizaciones las gestiona la tienda.

| Opción | Pros | Contras |
|--------|------|---------|
| **A) Mantener ambos sistemas (APK propio + Meta Store)** | Flexibilidad total. | El sistema de APK propio genera complejidad (plugin Android, FileProvider) que quizás nunca se use. |
| **B) Solo sistema .pck, delegar APK a la Store** | Mucho más simple. La Store gestiona revisiones, rollout, rollback. | Dependencia de los tiempos de revisión de Meta (días/semanas). No sirve para sideload. |
| **C) Detectar en runtime si la app viene de la Store y desactivar auto-APK** | Código único, comportamiento adaptativo. | ¿Cómo detectar si estás en la Store o sideload? No hay API estándar. |

### Q5.2 — ¿Cómo se testea el boot counter sin causar crashes reales?
Probar el sistema de rollback requiere simular crashes.

| Opción | Pros | Contras |
|--------|------|---------|
| **A) Modo debug: botón secreto que simula crash** | Fácil de testear en desarrollo. | Hay que eliminar el botón en producción. |
| **B) Inyectar un .pck corrupto a propósito** | Test real del sistema. | Arriesgado si no hay backup. |
| **C) Variable de entorno o flag en archivo de config** | `user://debug_crash_on_boot.txt` → fuerza rollback. | Solo para desarrollo. Hay que documentarlo. |

### Q5.3 — ¿Qué hace el visor si el bucket S3 está caído pero la API funciona?
El `manifest.json` se sirve desde la API, pero los archivos APK/PCK están en S3.

| Opción | Pros | Contras |
|--------|------|---------|
| **A) Reintentar descarga cada 5 minutos hasta 3 veces** | Simple, ya está diseñado en F5. | El visor no puede actualizarse hasta que S3 vuelva. |
| **B) Usar el bucket como fuente primaria pero tener fallback a la API (servir archivos desde la API si S3 falla)** | Mayor disponibilidad. | La API no está diseñada para servir archivos grandes. |
| **C) CDN delante de S3 (CloudFront/Cloudflare)** | S3 rara vez se cae, un CDN añade caché y disponibilidad. | Costo extra, configuración adicional. |

### Q5.4 — ¿`.pck` o `.zip` para los paquetes de assets?
Godot soporta ambos formatos. PCK es sin comprimir, ZIP es comprimido.

| Opción | Pros | Contras |
|--------|------|---------|
| **A) PCK (sin comprimir)** | Carga más rápida en runtime. Sin overhead de descompresión. | Archivo más grande (~2-3x), más ancho de banda para descargar. |
| **B) ZIP (comprimido)** | Archivo más pequeño, descarga más rápida. | Descompresión en runtime (CPU). Documentado: requiere script launcher especial. |
| **C) PCK para parches pequeños, ZIP para paquetes grandes** | Lo mejor de ambos. | Más lógica condicional en UpdateManager. |

---

## 🔴 Preguntas Transversales

### QX.1 — ¿Idioma del código y comentarios?
| Opción | Recomendación |
|--------|---------------|
| **A) Inglés** | Estándar en desarrollo. Godot y sus APIs están en inglés. |
| **B) Español** | Consistente con el roadmap. Más natural para el equipo. |
| **C) Spanglish (código en inglés, comentarios en español)** | Balance entre estándar y accesibilidad. |

### QX.2 — ¿Versión de Godot a fijar?
El proyecto se creó con Godot 4.6.3. ¿Actualizar a 4.7 cuando salga o congelar?

| Opción | Pros | Contras |
|--------|------|---------|
| **A) Congelar en 4.6.3** | Estabilidad. Sin sorpresas de regresiones. | Sin nuevas features ni bug fixes. |
| **B) Actualizar a cada versión stable** | Bug fixes, mejor soporte XR (OpenXR mejora cada versión). | Riesgo de regresiones. Hay que testear todo de nuevo. |
| **C) Actualizar solo si hay una feature/bugfix crítico para el proyecto** | Balance entre estabilidad y mejoras. | Requiere estar al tanto del changelog de Godot. |

### QX.3 — ¿Estrategia de testing para VR?
Testear en VR es difícil de automatizar.

| Opción | Pros | Contras |
|--------|------|---------|
| **A) Tests unitarios para lógica (GUT addon)** | Automatizable en CI. Rápido. | No cubre rendering, shaders, VR. |
| **B) Tests manuales en Quest (checklist por release)** | Cubre todo. | Lento, propenso a error humano. |
| **C) Tests de integración con escenas de prueba en editor** | Se puede testear lógica de escenas sin VR. | No cubre la experiencia real en el visor. |
| **D) Combinación A + B + C** | Cobertura completa. | Más tiempo de desarrollo. |

### QX.4 — ¿Qué métricas de rendimiento son aceptables en Quest 3?
| Métrica | Objetivo | Crítico |
|---------|----------|---------|
| FPS | 90 FPS estables | < 72 FPS = inaceptable |
| Frame time GPU | < 8ms | > 11ms = pierde frames |
| Draw calls | < 200 | > 500 = problema |
| Triángulos | < 200k | > 500k = problema |
| Memoria | < 3GB | > 4GB = crash probable |

### QX.5 — ¿Estructura de carpetas del proyecto Godot?
| Opción | Estructura |
|--------|------------|
| **A) Por tipo (scenes/, scripts/, shaders/, assets/)** | Estándar Godot. Claro al principio. Se vuelve caótico con muchas features. |
| **B) Por feature (lenses/, environment/, tablet/, license/)** | Modular. Cada feature tiene sus scenes, scripts y assets juntos. |
| **C) Mixto (autoloads/, features/, shared/)** | Lo común separado, features agrupadas. Más flexible. |

---

## 🔬 Análisis de Viabilidad Técnica (Quest 2 + Quest 3)

Este análisis está basado en las verificaciones hechas contra la documentación de Godot 4.6 y las especificaciones del hardware objetivo.

### Veredicto general: **Viable, pero con 3 riesgos altos que requieren mitigación temprana**

No hay ningún bloqueante absoluto. Todo tiene solución o workaround. Pero hay cosas que **no van a funcionar como uno esperaría** y hay que atacarlas desde el día 1.

---

### 🔴 Riesgos Altos (pueden matar el proyecto si se ignoran)

#### Riesgo 1: Post-procesado asimétrico a 90 FPS en Quest 2
Tres factores se suman para hacer este el riesgo más crítico:

| Factor | Detalle |
|--------|---------|
| **Foveated rendering se desactiva** | Documentación de OpenXR Settings: *"This feature is disabled if post effects are used such as glow, bloom, or DOF."* El simulador depende enteramente de post-procesado. Foveated rendering ahorra ~20-30% de GPU. Sin él, el presupuesto de 11ms por frame se reduce drásticamente. |
| **Forward+ no es el renderer recomendado para Quest** | La doc oficial: *"Use the Compatibility renderer for any project running on a standalone headset like the Meta Quest 3."* Forward+ no está optimizado para XR. Si hay que migrar a Compatibility, algunos shaders pueden comportarse distinto. |
| **Quest 2 (XR2 Gen 1) es ~2.5× más lento que Quest 3** | Lo que corre a 90 FPS en Quest 3 puede ir a 45-60 FPS en Quest 2. Y el simulador debe funcionar en ambos. |

**Mitigación:** Hacer una **prueba de concepto temprana** (Fase 1 + mini Fase 2) midiendo el costo real de GPU de un blur 9-tap en un SubViewport spatial a 90 FPS en Quest 2. Si no da, opciones de fallback:
- Bajar a 72 FPS en Quest 2
- Reducir taps de blur (de 9 a 5)
- Migrar de Forward+ a Compatibility
- Aceptar que Quest 2 tenga menos features visuales que Quest 3

#### Riesgo 2: Streaming de video desde el Viewport
Godot 4 **no tiene captura asíncrona de GPU**. `get_viewport().get_texture().get_image()` bloquea el hilo principal mientras la GPU termina de renderizar y copia el framebuffer a RAM. En VR a 90 FPS (11ms por frame), esto puede causar stuttering visible.

No hay workaround nativo. Las opciones son:
- Capturar a 15 FPS en vez de 30 (reduce el problema, no lo elimina)
- Usar un SubViewport separado a baja resolución y capturarlo a intervalos
- Renderizar con `scaling_3d_scale` bajo para que la captura sea más rápida

**Mitigación:** Hacer prueba de concepto de streaming en Fase 3 **antes** de decidir entre Opción A (video) y Opción B (replicación 2D). Si el streaming causa stuttering, la Opción B es la correcta por descarte.

#### Riesgo 3: Brecha de rendimiento Quest 2 ↔ Quest 3

| Métrica | Quest 2 | Quest 3 |
|---------|---------|---------|
| GPU | Adreno 650 (~1.2 TFLOPS) | Adreno 740 (~2.5 TFLOPS) |
| RAM | 6 GB | 8 GB |
| Resolución por ojo | ~1832×1920 | ~2064×2208 |
| FPS objetivo | 72-90 Hz | 90-120 Hz |
| Lente | Fresnel (god rays) | Pancake (mejor claridad) |

La Quest 3 empuja más píxeles pero tiene más potencia. La Quest 2 tiene pantallas Fresnel con más artefactos visuales (god rays), pero el blur del simulador podría enmascararlos. El target de rendimiento **debe ser Quest 2**; Quest 3 se beneficia del margen extra.

---

### 🟡 Riesgos Medios (resolubles, requieren trabajo)

| Riesgo | Solución |
|--------|----------|
| `VIEW_INDEX` solo en shaders `spatial`, no `canvas_item` | Verificado y corregido en Fase 2. Approach: `SubViewport` + `ShaderMaterial spatial`. |
| Instalación de APK desde la app | Requiere plugin Android custom (FileProvider + Intents). Complejo pero factible. Si se distribuye por Meta Store, este riesgo desaparece. |
| `user://` no accesible desde otras apps en Android | El APK descargado debe copiarse a almacenamiento compartido vía plugin Android. |
| `DEPTH_TEXTURE` no lineal | Convertir con `INV_PROJECTION_MATRIX`. Fórmula documentada en Fase 2. Funciona, pero pierde precisión en distancias lejanas. |
| Primer arranque sin internet | Se mitiga con `lentes.json` embebido en el APK y periodo de gracia de 7 días (Fase 4). |

---

### 🟢 Riesgos Bajos (sin problema)

| Aspecto | Estado |
|---------|--------|
| OpenXR + `VIEW_INDEX` | ✅ Verificado. |
| `load_resource_pack()` para OTA | ✅ El overlay del .pck gana sobre el APK base. |
| WebSocket server en Quest | ✅ `TCPServer` + `WebSocketPeer`. |
| SHA256 / cifrado de archivos | ✅ `FileAccess.get_sha256()`, `open_encrypted_with_pass()`. |
| CI/CD con GitHub Actions | ✅ CLI de Godot documentado: `--headless --export-release`. |
| Backend FastAPI + Panel | ✅ Stack convencional, sin dependencia de Godot. |

---

### 📊 Viabilidad por fase

| Fase | Viabilidad | Riesgo principal |
|------|-----------|------------------|
| F0 (Backend) | ✅ **Alta** | Ninguno. |
| F1 (Core VR) | ✅ **Alta** | Solo elección de renderer. |
| F2 (Shaders) | ⚠️ **Media-Baja** | Rendimiento en Quest 2 con foveated desactivado. |
| F3 (Streaming) | ⚠️ **Media** | Captura de viewport bloqueante. |
| F4 (Licencias) | ✅ **Alta** | Ninguno técnico. |
| F5 (OTA) | ✅ **Alta** | APK auto-update requiere plugin Android. |

---

### ⚠️ Recomendación

La **Fase 2 debe prototiparse junto con Fase 1**, antes de construir el backend, el streaming o las licencias. Si el Quest 2 no puede correr un blur asimétrico a 90 FPS, el concepto mismo del simulador está en riesgo. Si la prueba sale bien, el resto es cuesta abajo.

---

## 🎨 Recursos de Renderizado para Alto Realismo (Godot 4)

El simulador debe tener un nivel de realismo **médico-profesional**. No puede verse como un videojuego casual. Estos recursos ayudan a lograr ese objetivo.

### 🏠 Entornos 3D de referencia

| Recurso | Link | Relevancia |
|---------|------|------------|
| **Godot TPS Demo** (high-quality 3D) | https://github.com/godotengine/tps-demo | Referencia #1 de renderizado 3D en Godot 4. PBR, iluminación, post-procesado, entornos detallados. Ideal como base para la sala de lectura. |
| **Truck Town Demo** (ambiente exterior) | https://github.com/godotengine/godot-demo-projects/tree/master/3d/truck_town | Escena 3D completa con iluminación día/noche, vehículos, edificios. Referencia de escala y ambientación. |
| **Material Testers Demo** | https://github.com/godotengine/godot-demo-projects/tree/master/3d/material_testers | Todos los materiales PBR de Godot en un solo proyecto. Referencia para elegir los materiales correctos (madera, metal, tela, vidrio). |

### 💡 Iluminación realista

| Recurso | Link | Relevancia |
|---------|------|------------|
| **Physical Light & Camera Units** | https://github.com/godotengine/godot-demo-projects/tree/master/3d/physical_light_camera_units | Cómo usar unidades físicas reales (lux, lúmenes, EV) en Godot 4. Esencial para simular condiciones de luz reales (consultorio, calle nocturna). |
| **Global Illumination Demo** | https://github.com/godotengine/godot-demo-projects/tree/master/3d/global_illumination | SDFGI y LightmapGI en Godot 4. Referencia para iluminación indirecta realista. |
| **Lights and Shadows Demo** | https://github.com/godotengine/godot-demo-projects/tree/master/3d/lights_and_shadows | Tipos de luces, sombras, configuración. Referencia técnica. |
| **Volumetric Fog Demo** | https://github.com/godotengine/godot-demo-projects/tree/master/3d/volumetric_fog | Niebla volumétrica para escenas nocturnas y atmósfera. |

### 🖌️ Shaders y Post-procesado

| Recurso | Link | Relevancia |
|---------|------|------------|
| **Screen Space Shaders Demo** (oficial Godot 4) | https://github.com/godotengine/godot-demo-projects/tree/master/2d/screen_space_shaders | **CRÍTICO para Fase 2.** Ejemplos de screen-reading shaders: blur, distorsión, ajustes de color. Base directa para el DoF y halos. |
| **Glow & Blur Shaders Tutorial** | https://godotengine.org/asset-library/asset/2366 | Shaders de glow y blur con video tutorial. Base para el efecto halo. |
| **Godot Shaders (comunidad)** | https://godotshaders.com | Repositorio comunitario de shaders. Buscar: "blur", "depth of field", "glow", "halo", "night vision". |
| **10 Simple Shader Examples** | https://godotengine.org/asset-library/asset/2098 | Ejemplos didácticos de shaders en Godot 4. |

### 🧱 Texturas y Materiales PBR

| Recurso | Link | Relevancia |
|---------|------|------------|
| **Poly Haven** (gratis, CC0) | https://polyhaven.com/textures | Texturas PBR 4K/8K gratis: madera, paredes, pisos, telas. Ideal para la sala de consultorio. Entornos HDR para iluminación. |
| **AmbientCG** (gratis, CC0) | https://ambientcg.com | Texturas PBR con mapas de roughness, normal, displacement. Catálogo enorme. |
| **Standard Material 3D (doc oficial)** | https://docs.godotengine.org/en/stable/tutorials/3d/standard_material_3d.html | Referencia completa del material PBR de Godot. Parámetros, modos, optimización. |
| **Material Maker** | https://godotengine.org/showcase/material-maker/ | Herramienta procedural para crear materiales PBR (como Substance Designer, pero gratis). |

### 🌃 Escenas nocturnas y condiciones de luz

| Recurso | Link | Relevancia |
|---------|------|------------|
| **Sky Shaders Demo** | https://github.com/godotengine/godot-demo-projects/tree/master/3d/sky_shaders | Shaders de cielo procedural. Útil para cielo nocturno con estrellas, luna. |
| **Tonemap & Color Correction Demo** | https://github.com/godotengine/godot-demo-projects/tree/master/3d/tonemap_color_correction | Ajustes de color y tonemapping. Para simular diferentes condiciones de luz (calle, faros, interior). |

### 🥽 VR específico

| Recurso | Link | Relevancia |
|---------|------|------------|
| **Godot XR Demo Projects** | https://github.com/godotengine/godot-demo-projects/tree/master/xr | Demos oficiales de XR/VR. Setup de OpenXR, interacción, UI en VR. |
| **Godot XR Tools (addon)** | https://github.com/godotvr/godot-xr-tools | Addon con herramientas VR: mano fantasma, pointer, teleport, snap zones. Ahorra meses de desarrollo. |
| **OpenXR Settings Reference** | https://docs.godotengine.org/en/stable/tutorials/xr/openxr_settings.html | Configuración de OpenXR: foveated rendering, frame synthesis, hand tracking. |

### 📐 Recomendación de setup para la sala de consultorio

Para lograr realismo médico con buen rendimiento en Quest 2/3:

1. **Geometría**: Modelos low-poly bien texturizados con mapas de normales (no hace falta high-poly).
2. **Iluminación**: Bakeada (LightmapGI) para la sala base. Una luz dinámica para simular la lámpara del consultorio.
3. **Materiales**: PBR con roughness/metallic maps de Poly Haven o AmbientCG.
4. **Post-procesado**: Solo el shader de visión (Fase 2). No usar WorldEnvironment para DoF/glow.
5. **Resolución de texturas**: 1K para objetos pequeños, 2K para paredes/pisos. Nada de 4K en Quest.
6. **Escena nocturna**: Sky shader procedural + luces puntuales (farolas) + volumetric fog ligero.
7. **Optimización**: LODs, occlusion culling, mesh instancing para objetos repetidos.
