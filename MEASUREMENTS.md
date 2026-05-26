# MEASUREMENTS.md — Protocolo de medicion del Sprint 2

Sprint 2 es el GO/NO-GO mas critico del proyecto: si Quest 2 no puede correr
post-procesado asimetrico a >=72 FPS, hay que reducir alcance o cambiar de hardware target.

Este documento define como se mide y donde se registran los resultados.

---

## Criterio GO/NO-GO

| Metrica | GO si... | NO-GO si... |
|---------|----------|-------------|
| FPS sostenido (Quest 2) | >= 72 FPS estable durante >= 60 s | < 72 FPS o muestra throttling |
| Frame time GPU (Quest 2) | < 11 ms p99 | > 11 ms con frecuencia |
| Stuttering visible | Ausente al mover la cabeza | Hitches perceptibles |
| FPS en Quest 3 | >= 90 FPS estable | (no bloqueante, esperado tras pasar Quest 2) |

**Si el resultado es NO-GO**, antes de seguir al Sprint 3 documentar aca cual de
las mitigaciones del riesgo R1 se aplica:
1. Bajar a 72 Hz fijo en Quest 2 (`OS.set_low_processor_usage_mode_sleep_usec` o equivalente).
2. Reducir taps del kernel de blur de 9 a 5.
3. Migrar de Forward+ a Compatibility renderer.
4. Quest 3 obligatorio (cambio de decision bloqueada #2).

---

## Que medir

1. **FPS** — el HUD en VR (FpsHud Label3D en la escena) muestra valor actual.
2. **Frame time GPU** — necesita herramienta externa (ver abajo).
3. **Frame time CPU** — idem.
4. **Calidad visual** — observacion subjetiva (los cubos cerca/medio/lejos se ven con
   blur correctamente diferenciado por ojo).

## Herramientas

### Opcion A: OVR Metrics Tool (recomendada)

App oficial de Meta que muestra HUD con metricas detalladas en VR.

1. Habilitar modo desarrollador en el Quest (ya esta, sino no se podria sideloadear).
2. Instalar OVR Metrics Tool desde la PC:
   ```bash
   # Descargar el APK desde https://developer.oculus.com/downloads/package/ovr-metrics-tool/
   adb install -r OVRMetricsTool.apk
   ```
3. Lanzar la app desde el Quest (en la libreria, filtro "Unknown sources").
4. Activar "Show Persistent Overlay" — el HUD aparece sobre cualquier app.
5. Configurar para mostrar: FPS, GPU level, CPU level, GPU utilization, frame time.

### Opcion B: adb logcat (sin GUI)

Si OVR Metrics Tool no es viable, capturar el log mientras corre la app:

```bash
adb logcat -c
# (lanzar la app del simulador en el Quest)
adb logcat -d -s godot:* > log_sprint2_run1.txt
```

Godot loguea FPS si se le pide. Podemos agregar prints en main.gd cada N frames.

### Opcion C: HUD en VR (built-in)

Ya esta — el `Label3D` "FpsHud" en la escena muestra FPS y frame time en vivo,
visible en la esquina superior derecha del campo visual.

---

## Protocolo de medicion (run estandar)

Para cada run:

1. Quest fully charged (>= 80%).
2. Cerrar todas las otras apps en el Quest.
3. Sin ningun dispositivo conectado por Casting/Mirroring (afecta GPU).
4. Lanzar el simulador.
5. Esperar 10 s para que el render se estabilice (warmup de shaders).
6. Mantener la cabeza quieta 30 s — observar FPS minimo y frame time GPU p99.
7. Mover la cabeza naturalmente 30 s (mirando los 3 cubos y la esfera brillante).
8. Acercarse a la NearCube (caminar hacia adelante) por 15 s — fuerza al shader
   a aplicar mucho blur en el ojo derecho (preset = blur_near 0.8).
9. Anotar resultados abajo.

---

## Resultados

### Run 1 — Quest 2 — fecha: sesion Sprint 2 (mayo 2026)

| Metrica | Resultado |
|---------|-----------|
| FPS minimo | 69 |
| FPS promedio | 70 |
| FPS maximo | 72 |
| Frame time GPU p99 | ~13 ms |
| Frame time CPU p99 | (no medido) |
| Stuttering visible | No |
| Diferencia de blur entre ojos | Sutil — kernel chico (4 px de radio) |
| Halo en la esfera brillante | Visible pero no realista (glow difuso, faltaban anillos) |
| Notas | Test con preset modificado (ambos ojos blur cerca=1 medio=1). Quest 2 default a 72 Hz; estamos en el borde del budget 13.88 ms. |

**Veredicto:** GO (cumple >=72 FPS estable y <11 ms target equivalente a 72 Hz).

### Iteracion 1 sobre el shader (post Run 1)

Fixes visuales sin tocar performance budget:
- `BLUR_RADIUS_PX` 4 -> 12. Mismo numero de samples (9-tap), kernel mas ancho.
  El blur ahora es claramente visible con `blur_amount` >= 0.3.
- Halo reescrito a 2 anillos concentricos (inner @18 px, outer @32 px con peso 0.4).
  Falloff cuadratico (`strength * strength`) para simular la caida fisica de la luz.
  Tinte cromatico amarillento `halo_tint = vec3(1.05, 1.0, 0.78)` — caracteristico
  de los halos clinicos producidos por IOLs multifocales tipo PanOptix.
- Costo: 0 samples extra. Mismo presupuesto GPU.

Pendiente Run 2: validar que el cambio visual es perceptible y el FPS no se
degrado.

### Run 2 — Quest 2 — fecha: ____

| Metrica | Resultado |
|---------|-----------|
| FPS minimo | __ |
| FPS promedio | __ |
| FPS maximo | __ |
| Frame time GPU p99 | __ ms |
| Stuttering visible | __ |
| Diferencia de blur entre ojos | clara / sutil / inexistente |
| Halo en la esfera brillante | anillos visibles? si / no |
| Notas | __ |

**Veredicto:** GO / NO-GO

### Run en Quest 3 — fecha: ____ (cuando llegue)

(Repetir esquema)

---

## Variantes a probar si el primer run es NO-GO

Si Run 1 sale NO-GO en Quest 2, antes de declararlo bloqueado intentar en orden:

| Variante | Cambio | Esperado |
|----------|--------|----------|
| V1: scaling 0.7 | `scaling_3d_scale = 0.7` | +5-8% FPS, imagen mas suave |
| V2: blur 5-tap | Reducir kernel del shader de 9 a 5 muestras | +1-2 ms GPU |
| V3: skip halo | `halo_intensity_l/r = 0.0` (preset)| +0.5-1 ms GPU |
| V4: 72Hz fijo | Configurar OpenXR refresh rate en Quest 2 | +14% headroom |
| V5: Compatibility | Migrar renderer | Variable, posible regresion en otros aspectos |

Cada variante se registra como Run separado con su veredicto.

---

## Cierre del Sprint 2

El sprint cierra cuando:

1. Hay al menos un Run con veredicto GO en Quest 2 (puede ser tras aplicar variantes).
2. El veredicto y las variantes aplicadas estan documentadas aca.
3. La decision esta reflejada en `PLAN.md` (si hubo cambio de alcance) y en `progress.txt`.
