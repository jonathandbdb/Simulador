# FASE 3 Detallada: Cliente Tablet, Conectividad y Streaming (Casting)

En esta fase, convertimos el Visor en un **Servidor de Streaming y Control**, y la Tablet en un **Cliente de Visualización Ligero**. La clave es la comunicación eficiente: transmitir los comandos de control (lentes) y el flujo de video (paciente) simultáneamente por WebSocket.

---

## 📡 3.1 Servidor WebSocket Robusto (Visor como Servidor)

El Visor debe manejar dos tipos de tráfico: **JSON** para control y **Bytes (binarios)** para el streaming de video.

### 🤖 Prompt para alimentar al LLM:
> "Actúa como desarrollador senior en Godot 4. Estoy creando un Servidor WebSocket (`WebSocketPeer`) en mi Visor VR.
> 1. Necesito una arquitectura donde el servidor pueda manejar clientes de forma eficiente. Al conectar una Tablet, el servidor debe permitirle suscribirse a dos canales: 'Control' (JSON) y 'Stream' (Binary/Video).
> 2. Implementa un método para recibir paquetes JSON (cambios de lentes/parámetros) que se integre con mi `DataManager` (Fase 1).
> 3. Implementa un método que permita enviar paquetes binarios (el buffer de la imagen de video) a los clientes.
> 4. Asegúrate de que el servidor valide el `handshake` inicial del Hardware Binding antes de habilitar el streaming."

---

## 📱 3.2 UI Dinámica en Tablet con Modo "Blend"

La interfaz debe ser lo suficientemente inteligente para detectar si el modo 'Blend' está activo y renderizar los controles en consecuencia.

### 🤖 Prompt para alimentar al LLM:
> "Estoy creando la interfaz de control en la Tablet (también en Godot 4).
> 1. Necesito un contenedor `HBoxContainer` que actúe como raíz de mi menú.
> 2. Escribe un script que genere dinámicamente sliders basados en el JSON recibido del visor.
> 3. Implementa un `CheckButton` de 'Activar Blend'. Al activarlo:
>    - Si está apagado: Muestra 1 panel de control que, al moverse, envía comandos al Visor para aplicar valores a AMBOS ojos.
>    - Si está encendido: Divide el contenedor en dos paneles ('Ojo Izquierdo' y 'Ojo Derecho'), cada uno con sus propios sliders, enviando comandos específicos para cada ojo al visor (ej. `{'action': 'set_lens', 'eye': 'left', 'params': {...}}`)."

---

## 🎥 3.3 El Pipeline de Streaming de Video (Real-time Casting)

Esta es la parte más exigente. Para evitar destruir el framerate del Visor VR, no podemos capturar el frame 60 veces por segundo a resolución completa. 

**Estrategia:** Captura asíncrona a baja resolución + compresión JPG + envío por WebSocket binario.

### 🤖 Prompt para alimentar al LLM:
> "Eres un experto en optimización de Godot 4 para VR. Quiero implementar un sistema de streaming para mi simulador.
> 1. Escribe un script para el Visor VR que capture el viewport de la cámara usando `get_viewport().get_texture().get_image()` en un hilo secundario (para no bloquear el renderizado principal).
> 2. Explícame cómo hacer un 'downscaling' de la imagen antes de guardarla (para reducir el peso) y luego usar `image.save_jpg_to_buffer()` para obtener los bytes.
> 3. ¿Cómo envío este buffer binario por mi `WebSocketPeer` para que la Tablet lo reciba?
> 4. En la Tablet, escribe el código necesario para recibir los bytes binarios del WebSocket, convertirlos de vuelta a una `Image`, crear una `ImageTexture` y actualizar un `TextureRect` en tiempo real (al menos a 20-30 FPS).
> 5. Dame consejos de performance: ¿Es mejor limitar el tamaño de la textura capturada a 512x512 o usar una calidad de JPG baja? ¿Cómo evitar el 'backpressure' en los WebSockets?"

### 📋 Notas Técnicas (Verificadas contra Godot 4.6 Docs):

**Arquitectura WebSocket Server en Godot 4:**

El servidor WebSocket **no se crea con un nodo `WebSocketServer`** (eso es Godot 3). En Godot 4 se usa:
```gdscript
var tcp_server = TCPServer.new()
tcp_server.listen(8080)

# En _process():
while tcp_server.is_connection_available():
    var peer = WebSocketPeer.new()
    peer.accept_stream(tcp_server.take_connection())
    peers[new_id] = peer
```

| API | Uso |
|-----|-----|
| `TCPServer.new()` + `listen(port)` | Crear servidor TCP. Retorna `OK` o `ERR_ALREADY_IN_USE`. |
| `TCPServer.take_connection()` | Aceptar conexión entrante. Retorna `StreamPeerTCP`. |
| `WebSocketPeer.accept_stream(stream)` | Realizar handshake HTTP → WebSocket sobre el stream TCP. |
| `WebSocketPeer.poll()` | **Debe llamarse cada frame** para procesar datos entrantes/salientes. |
| `WebSocketPeer.send_text(json_string)` | Enviar frame de texto (JSON). |
| `WebSocketPeer.send(packed_byte_array)` | Enviar frame binario (video, imágenes). |
| `WebSocketPeer.get_packet()` | Recibir datos. Retorna `PackedByteArray`. |
| `WebSocketPeer.was_string_packet()` | `true` si el último paquete era texto, `false` si binario. |
| `WebSocketPeer.STATE_OPEN` | Constante = 1. Conexión lista para enviar/recibir. |
| `WebSocketPeer.STATE_CLOSED` | Constante = 3. Peer desconectado — eliminar de la lista. |

**⚠️ Permiso de red en Android:**
La doc de WebSocket y HTTPRequest coinciden: hay que habilitar el permiso **`INTERNET`** en el Android Export Preset. Sin esto, toda comunicación de red es bloqueada.

**Streaming de video desde Viewport (realidad técnica):**

| API | Realidad |
|-----|----------|
| `get_viewport().get_texture()` | Retorna `ViewportTexture`, **no** `Image`. No se puede acceder a sus píxeles directamente. |
| `get_viewport().get_texture().get_image()` | **SÍ funciona** pero **bloquea el hilo principal** mientras captura. En VR a 90fps esto puede causar stuttering. |
| `SubViewport` + `render_target_update_mode` | Alternativa: crear un `SubViewport` adicional que renderice la vista, y capturar su textura de forma controlada. |

**⚠️ Godot NO tiene soporte nativo para captura asíncrona de viewport.** 
No existe un "hilo secundario" para `get_image()`. Las opciones reales son:
1. Capturar a baja resolución (ej. 512×512) y baja frecuencia (15-20 FPS) para minimizar el impacto.
2. Usar `SubViewport` dedicado para el stream, con `render_target_update_mode` controlado.
3. Comprimir agresivamente con `image.save_jpg_to_buffer(quality)` — calidad 50-60% reduce byte count ~10x.

**Recepción y display en la tablet:**

| API | Uso |
|-----|-----|
| `Image.load_jpg_from_buffer(bytes)` | Crear Image desde bytes JPG recibidos por WebSocket. |
| `ImageTexture.create_from_image(image)` | Crear textura GPU desde Image (primera vez). |
| `ImageTexture.update(image)` | **Actualizar** textura existente (más rápido que recrear). Usar si ya fue creada. |
| `TextureRect.texture = texture` | Asignar al nodo UI que muestra el stream. |

**Seguridad WebSocket:**
| API | Uso |
|-----|-----|
| `WebSocketPeer.get_connected_host()` | Obtener IP del peer conectado (para logging/whitelist). |
| `WebSocketPeer.close(code, reason)` | Cerrar conexión con código de estado (ej. 4003 = forbidden). |
| `handshake_headers` | Propiedad para enviar headers custom durante el handshake HTTP inicial. |

---

---

## 🔒 3.4 Hardware Binding y Seguridad

Aseguramos que solo las tablets autorizadas reciban el stream y puedan controlar el visor.

### 🤖 Prompt para alimentar al LLM:
> "Estoy integrando seguridad en mi sistema WebSocket.
> 1. En el Visor (Servidor), quiero mantener una lista blanca (Whitelist) de `device_id` autorizados (obtenidos de la API en la nube).
> 2. Antes de que la tablet pueda solicitar el stream de video o enviar comandos de control, debe enviar un paquete de 'auth' en la conexión WebSocket.
> 3. Si el `device_id` no está en la lista blanca, el Visor debe cerrar la conexión inmediatamente y enviar un código de error 403.
> 4. Escribe el script para el `Handshake` de autenticación que verifique este ID contra el almacenamiento local (donde se cacheó la whitelist)."
