export const meta = {
  name: 'blender-to-godot',
  description: 'Pipeline Blender->Godot: medir un modelo objetivo, modelar geometria complementaria en Blender, exportar glb, importarla y ubicarla en una escena Godot, y verificar visual+performance. Serializa toda mutacion del editor.',
  whenToUse: 'Cuando hay que crear un asset en Blender e integrarlo a una escena Godot del simulador VR (p. ej. cerrar el consultorio con paredes/techo/ventana).',
  phases: [
    { title: 'Measure', detail: 'scene-verifier mide extents del modelo objetivo en Godot (read-only)' },
    { title: 'Model', detail: 'blender-modeler construye y exporta glb' },
    { title: 'Place', detail: 'godot-builder importa, ubica y guarda la escena (serializado)' },
    { title: 'Verify', detail: 'scene-verifier saca screenshots y mide perf' },
    { title: 'Fix', detail: 'correccion acotada si Verify falla' },
  ],
}

// --- Parametros (args) con defaults para la tarea del consultorio ---
const cfg = Object.assign({
  sceneResPath: 'res://features/scenarios/consultorio/consultorio.tscn',
  encloseModelResPath: 'res://assets/scenarios/consultorio/modern_office/modern_office.fbx',
  glbOutDir: 'C:/Users/jvare/OneDrive/Documents/simulador/assets/scenarios/consultorio/room_shell',
  glbResDir: 'res://assets/scenarios/consultorio/room_shell',
  styleBrief: 'Clinica simple: paredes lisas claras + zocalo + techo plano con luz cenital. Una ventana en la pared orientada al sol, con marco simple, por la que se vean el disco solar y 3-5 arboles low-poly afuera. Sin glow ni glare (escena de lectura, env=day).',
  maxFixRounds: 2,
}, (typeof args === 'object' && args) ? args : {})

const MEASURE_SCHEMA = {
  type: 'object',
  required: ['floor_y', 'room_size_m', 'sun_facing_wall', 'notes'],
  properties: {
    floor_y: { type: 'number', description: 'Cota Y del piso real en metros' },
    seat_world: { type: 'array', items: { type: 'number' }, description: 'Posicion mundo del SeatSpawn [x,y,z]' },
    room_size_m: { type: 'array', items: { type: 'number' }, description: 'Ancho(X) x Alto(Y) x Fondo(Z) sugeridos para el shell, en metros' },
    model_aabb: { type: 'object', description: 'pos y size del AABB combinado y por-surface relevante' },
    sun_facing_wall: { type: 'string', description: 'En que pared (+X/-X/+Z/-Z) conviene la ventana segun la direccion del SunLight' },
    notes: { type: 'string' },
  },
}

const MODEL_SCHEMA = {
  type: 'object',
  required: ['glb_paths', 'bbox_m', 'objects', 'notes'],
  properties: {
    glb_paths: { type: 'array', items: { type: 'string' }, description: 'Rutas glb exportadas (absolutas y res://)' },
    bbox_m: { type: 'array', items: { type: 'number' }, description: 'Bounding box del shell en metros [x,y,z]' },
    objects: { type: 'array', items: { type: 'string' }, description: 'Nombres de objetos exportados' },
    emissive_objects: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string', description: 'Orientacion, donde quedo la ventana, escala' },
  },
}

const PLACE_SCHEMA = {
  type: 'object',
  required: ['saved', 'editor_errors', 'notes'],
  properties: {
    saved: { type: 'boolean' },
    editor_errors: { type: 'string' },
    transforms: { type: 'string', description: 'Como se ubico/escalo/oriento el shell y el sol' },
    notes: { type: 'string' },
  },
}

const VERIFY_SCHEMA = {
  type: 'object',
  required: ['verdict', 'issues'],
  properties: {
    verdict: { type: 'string', enum: ['PASS', 'FAIL'] },
    issues: { type: 'array', items: { type: 'string' }, description: 'Problemas con ubicacion (huecos, costuras, escala, sol/arboles no visibles)' },
    perf: { type: 'string', description: 'draw-calls / FPS observados' },
  },
}

log('Pipeline Blender->Godot para: ' + cfg.sceneResPath)

// Recordatorio de contexto que se inyecta en cada fase (los agentes ya leen AGENTS.md por su system prompt; esto refuerza).
const CONV = '\n\nContexto: seguí las convenciones de AGENTS.md (brief canónico del proyecto en la raíz del repo).'

// --- Fase 1: Measure (read-only en Godot) ---
phase('Measure')
const measure = await agent(
  `Abri/lee la escena ${cfg.sceneResPath} y medi (SOLO LECTURA) lo necesario para dimensionar una sala que ENCIERRE el modelo ${cfg.encloseModelResPath}.\n` +
  `Con execute_editor_script: carga el modelo, recorre MeshInstance3D y calcula el AABB combinado y, si es una sola malla combinada, su footprint real en metros. Identifica la cota Y del piso (usa SeatSpawn y FloorCollider como referencia) y la posicion mundo de SeatSpawn.\n` +
  `Determina hacia que pared (+X/-X/+Z/-Z) apunta la luz direccional SunLight, para colocar la ventana de ese lado.\n` +
  `Devolve dimensiones (ancho x alto x fondo) razonables para una sala de consulta acogedora alrededor del paciente (no toda la huella del diorama si es enorme).` + CONV,
  { agentType: 'scene-verifier', phase: 'Measure', schema: MEASURE_SCHEMA }
)
log('Medidas: piso Y=' + (measure?.floor_y) + ' sala=' + JSON.stringify(measure?.room_size_m) + ' ventana en ' + (measure?.sun_facing_wall))

// --- Fase 2: Model (Blender) ---
phase('Model')
const model = await agent(
  `Modela en Blender un SHELL DE SALA para el simulador VR y exportalo a glb.\n` +
  `Estilo: ${cfg.styleBrief}\n` +
  `Dimensiones objetivo (m): ${JSON.stringify(measure?.room_size_m)}; piso a Y=0 en el glb (el builder lo reubica). La ventana va en la pared ${measure?.sun_facing_wall}.\n` +
  `Notas de medida: ${measure?.notes}\n` +
  `Construi: 4 paredes lisas + zocalo + techo plano (interior hueco), un hueco de ventana con marco en la pared indicada, y 3-5 arboles low-poly como objetos separados ubicados AFUERA frente a la ventana. Materiales Principled simples (pared clara, zocalo, techo, tronco, follaje).\n` +
  `Aplica transforms y exporta glb a ${cfg.glbOutDir}/room_shell.glb (podes exportar los arboles en el mismo glb o en ${cfg.glbOutDir}/trees.glb). Verifica con un viewport screenshot antes de exportar.\n` +
  `Devolve rutas glb (absolutas y ${cfg.glbResDir}/...), bounding box real y orientacion.` + CONV,
  { agentType: 'blender-modeler', phase: 'Model', schema: MODEL_SCHEMA }
)
log('Modelado: ' + JSON.stringify(model?.glb_paths))

// --- Fase 3: Place (Godot, serializado) ---
phase('Place')
let place = await agent(
  `Integra el/los glb modelados en la escena ${cfg.sceneResPath} (editor Godot).\n` +
  `glb a importar: ${JSON.stringify(model?.glb_paths)} (${cfg.glbResDir}). Forza un re-scan del filesystem si hace falta para que Godot los importe.\n` +
  `Instancia el shell y los arboles, ubicalos/escalalos para ENCERRAR el OfficeModel sin chocar el mobiliario; piso del shell alineado a Y=${measure?.floor_y}. La pared de la ventana debe mirar hacia ${measure?.sun_facing_wall} para alinearse con SunLight.\n` +
  `Configura el ProceduralSkyMaterial del WorldEnvironment para que dibuje el DISCO SOLAR ligado al DirectionalLight3D (SunLight) y orienta el sol para que entre por la ventana, con los arboles entre la ventana y el cielo. Manten glow apagado (env=day, lectura). NO agregues GlareSource.\n` +
  `Guarda la escena (save_scene) y reporta get_editor_errors.\n` +
  `Bbox del shell (m): ${JSON.stringify(model?.bbox_m)}. Notas del modelador: ${model?.notes}` + CONV,
  { agentType: 'godot-builder', phase: 'Place', schema: PLACE_SCHEMA }
)

// --- Fase 4: Verify ---
phase('Verify')
let verify = await agent(
  `Verifica (SOLO LECTURA) la escena ${cfg.sceneResPath} ya integrada. Encuadra la camara del editor en la pose de SeatSpawn y saca screenshots mirando alrededor (incluida la ventana).\n` +
  `Confirma: sala cerrada por 4 lados + techo, sin huecos al vacio, sin costuras/z-fighting, sol visible por la ventana y arboles afuera, escala creible. Mide draw-calls/FPS.\n` +
  `Veredicto PASS solo si no hay huecos al vacio y la ventana muestra sol+arboles.`,
  { agentType: 'scene-verifier', phase: 'Verify', schema: VERIFY_SCHEMA }
)

// --- Fase 5: Fix (bucle acotado) ---
let round = 0
while (verify?.verdict === 'FAIL' && round < cfg.maxFixRounds) {
  round++
  phase('Fix')
  log('Correccion ronda ' + round + ': ' + JSON.stringify(verify?.issues))
  place = await agent(
    `Corregi estos problemas en ${cfg.sceneResPath} (editor Godot, serializado): ${JSON.stringify(verify?.issues)}.\n` +
    `Contexto: shell bbox ${JSON.stringify(model?.bbox_m)}, piso Y=${measure?.floor_y}, ventana en ${measure?.sun_facing_wall}. Si el problema es de geometria (no de ubicacion) anotalo claramente en notes para re-modelar. Guarda la escena.`,
    { agentType: 'godot-builder', phase: 'Fix', schema: PLACE_SCHEMA }
  )
  verify = await agent(
    `Re-verifica (solo lectura) ${cfg.sceneResPath} tras la correccion. Mismos criterios que antes. Devolve PASS/FAIL + issues restantes + perf.`,
    { agentType: 'scene-verifier', phase: 'Fix', schema: VERIFY_SCHEMA }
  )
}

return {
  measure,
  model,
  place,
  verify,
  fix_rounds: round,
  done: verify?.verdict === 'PASS',
}
