# FASE 6 (FUTURA): Escena Nocturna — Disfotopsias (Halos, Destellos y Astigmatismo)

> **Estado:** Diseño aprobado, **NO implementado**. Reservado para cuando se disponga
> de **Meta Quest 3** (más potente) y se pueda probar sobre el dispositivo final.
> Este documento es el vuelco del análisis de viabilidad para retomarlo más adelante.
>
> **Regla de oro:** todo lo de esta escena debe quedar **aislado** y **no afectar en
> absoluto** a la escena del consultorio (libro). Se logra con parámetros nuevos en
> default 0 + gating por escena (`halos_enabled`) + canal de datos independiente para
> el astigmatismo.

---

## 6.0 Objetivo de la escena

Paciente sentado en un **auto de noche**, sosteniendo un **celular con un mapa**
(mismo efecto de cercanía que el libro del consultorio). Frente al auto hay un
**semáforo**; por los costados **pasan autos** con faros encendidos.

Fin clínico: mostrar **halos, destellos (starburst) y rayos** alrededor de las luces,
dependiendo de la **lente** y de si el **astigmatismo** está activado. Da feedback al
oftalmólogo de las disfotopsias nocturnas que percibe el paciente.

---

## 6.1 Viabilidad — alta

- El post-process [features/vision_shaders/sprint2_blur_test.gdshader](../features/vision_shaders/sprint2_blur_test.gdshader)
  **ya detecta fuentes brillantes por umbral** (`halo_threshold`) y genera anillos
  concéntricos con tinte cromático. La escena nocturna es el caso ideal: fondo oscuro
  + fuentes puntuales (semáforo, faros, pantalla del celular) que superan el umbral.
- El **celular con mapa reusa el mecanismo del libro**: un nodo "phone_holder" calcado
  de [features/scenarios/consultorio/book_holder.gd](../features/scenarios/consultorio/book_holder.gd)
  calcula la distancia y alimenta el uniform `book_distance_m`; el shader aplica ahí la
  misma curva de focos/dioptrías. Como son escenas distintas no hay conflicto por
  compartir el uniform.

---

## 6.2 Aislamiento respecto a la escena del libro

Tres capas, todas ya soportadas por la arquitectura:

1. **Parámetros nuevos con default 0** → invisibles salvo que la escena los active.
2. **Gating por escena:** `halos_enabled` es un flag por escenario en
   [features/vr_core/main.gd](../features/vr_core/main.gd) (el consultorio lo deja en
   `false`). La escena nocturna lo pone en `true` y activa destellos.
3. **Astigmatismo = estado independiente** (no del catálogo de lente), default off.

Mientras el libro mantenga sus parámetros (halo bajo, sin destellos, astigmatismo off),
su render no cambia.

---

## 6.3 Modelo clínico de las disfotopsias

Son **tres fenómenos distintos** que conviene modelar por separado:

### Halos (anillos circulares)
- **Causa:** óptica **difractiva** (multifocales/trifocales). Cada orden de difracción /
  foco adicional genera un anillo. Por eso **hasta 3 anillos** es correcto: un trifocal
  reparte luz en lejos/intermedio/cerca → varios anillos concéntricos; un EDOF difractivo
  (tipo Symfony) da menos; un monofocal casi ninguno.
- **Comportamiento:** el **radio** del halo crece con el **diámetro pupilar** (de noche la
  pupila se dilata → halos más grandes) y con el desenfoque de la fuente. Cada anillo a un
  radio distinto.
- **Mapeo:** número de anillos ligado a los focos activos de la lente; radio escalado por
  una "pupila nocturna".

### Destellos / starburst (rayos céntricos)
- **Causa:** bordes difractivos y diseños EDOF, también aberraciones corneales. Son
  **radiales** (rayos desde el centro de la fuente hacia afuera), distintos de los anillos.
- Es **específico de ciertas lentes** → debe ser **otro parámetro** (`destello_intensity` /
  número de rayos), independiente de `halo_intensity`.

### Astigmatismo (rayas direccionales en las luces)
- **Causa:** cilindro no corregido → un punto de luz se transforma en una **línea/raya**
  orientada según el **eje** del astigmatismo (conoide de Sturm: la fuente puntual se
  estira en una línea focal).
- Cuanto mayor el cilindro (dioptrías), **más larga** la raya. El **ángulo** de la raya =
  eje del astigmatismo.
- Es **independiente de la lente** y puede diferir por ojo → debe ser un **toggle global**
  del oftalmólogo, no un parámetro del catálogo.

---

## 6.4 Parámetros nuevos propuestos

### En el catálogo de lente (per-ojo, ya hay infra `_l`/`_r`)
| Parámetro | Rango | Significado |
|---|---|---|
| `halo_intensity` (ya existe) | 0–1 | Intensidad de anillos |
| `halo_rings` (nuevo) | 0–3 | Cantidad de anillos (difractivo) |
| `destello_intensity` (nuevo) | 0–1 | Intensidad del starburst radial |
| `destello_rayos` (nuevo) | 0–12 | Número de rayos del destello |

### Estado independiente (NO en catálogo, control directo del oftalmólogo, per-ojo)
| Parámetro | Rango | Significado |
|---|---|---|
| `astig_enabled` | bool | Toggle on/off |
| `astig_axis_deg` | 0–180 | Eje (orientación de la raya) |
| `astig_strength` | 0–1 (≈ dioptrías de cilindro) | Largo/intensidad de la raya |

Requiere un canal nuevo en [autoloads/data_manager.gd](../autoloads/data_manager.gd) para
el astigmatismo (paralelo a `current_vision_state`, pero fuera de la lente) y un comando
WebSocket nuevo (tipo `set_astigmatism`).

---

## 6.5 Implementación técnica (plan a futuro)

### Shader — [features/vision_shaders/sprint2_blur_test.gdshader](../features/vision_shaders/sprint2_blur_test.gdshader)
- Extender `halo_rings()` para soportar **hasta 3 anillos** (hoy hace 2) con radio
  escalado por una "pupila nocturna".
- Función nueva `starburst()`: muestrea N direcciones radiales (los `destello_rayos`) a
  radios crecientes desde píxeles brillantes, acumulando → patrón de estrella.
- Función nueva `astigmatism_streak()`: **desenfoque 1D direccional** de los píxeles
  brillantes a lo largo del eje `astig_axis_deg`, longitud = `astig_strength`. Es un blur
  lineal solo sobre lo que supera el umbral.
- Todas con **early-out** si el píxel y su vecindad son oscuros → de noche la pantalla es
  mayormente negra, el costo se concentra solo alrededor de las luces.

### Escena — `features/scenarios/auto_noche/` (a crear)
- Environment oscuro; tonemap que **conserve el punto brillante** de las fuentes (clave
  para que superen el umbral).
- **Semáforo:** mesh emisivo al frente.
- **Autos pasando:** meshes con faros emisivos animados por el costado.
- **Celular con mapa:** nodo "phone_holder" calcado de `book_holder.gd`, alimenta
  `book_distance_m`.

### Datos / Tablet
- Nuevos params de lente en [defaults/lentes.json](../defaults/lentes.json) + editor web
  (i18n, `lenses.html`, `seed.py`) + editor de la tablet.
- Sección nueva en la tablet "Astigmatismo" con toggle + sliders eje/magnitud por ojo,
  enviando el comando independiente.

---

## 6.6 Rendimiento (objetivo: Quest 3)

- Los tres efectos solo cuestan donde hay brillo; con early-out en zonas oscuras, de noche
  el costo extra es bajo (la mayoría de la pantalla es negra).
- El starburst con muchos rayos × muchos radios es lo más caro → limitar a ~6–8 rayos y
  2–3 radios.
- El astigmatismo (blur 1D) es barato si se restringe a píxeles sobre umbral.
- Estimado: similar al halo actual, **+0.3–0.8 ms** solo en la escena nocturna. No afecta
  al consultorio (efectos en 0). En Quest 3 hay margen de sobra.

---

## 6.7 Riesgos a cuidar

- **Tonemapping:** el consultorio usa AGX para no quemar el libro; la escena nocturna
  necesita que las fuentes **sí** superen el umbral. Conviene umbral/tonemap **por escena**,
  o fuentes con emisión alta y bloom controlado.
- **Coherencia binocular:** halos/destellos por ojo (difractivo) + astigmatismo por ojo
  (eje distinto OD/OI) → ya hay infra `_l`/`_r`, pero el astigmatismo necesita su propio
  canal de datos.
- **Streaming a la tablet:** el preview 2D [features/tablet/eye_preview.gdshader](../features/tablet/eye_preview.gdshader)
  tendría que replicar estos efectos para que el oftalmólogo los vea en la tablet (hoy ese
  shader ni siquiera está actualizado al modelo de focos/dioptrías — **pendiente previo**).

---

## 6.8 Resumen ejecutivo

Totalmente viable. Reusa el motor de halos y el mecanismo del libro, y se aísla limpio de
la escena del consultorio con parámetros default 0 + gating por escena. El trabajo real
está en: **3 funciones nuevas de shader** (3er anillo de halo, starburst, raya de
astigmatismo), el **canal independiente de astigmatismo** en DataManager/tablet, y armar la
**escena nocturna** con fuentes emisivas. Reservado para Quest 3.
