extends SceneTree
# Cuenta triángulos de las escenas y de los modelos clave (headless).

func _initialize() -> void:
	print("\n========== CONTEO DE TRIÁNGULOS ==========")

	# --- Modelos individuales del consultorio ---
	_model("res://assets/scenarios/consultorio/modern_office/modern_office.fbx", "OFICINA (modern_office.fbx)")
	_model("res://assets/scenarios/consultorio/room_shell/room_shell.glb", "RoomShell (paredes/ventana)")
	_model("res://assets/scenarios/consultorio/tree/tree.glb", "Árbol (x1)")

	# --- Modelos de la ruta ---
	_model("res://assets/scenarios/ruta_noche/road2/source/road.obj", "Ruta: 1 tile de asfalto")
	_model("res://assets/scenarios/ruta_noche/street-light/source/Untitled_3/Untitled_3.obj", "Farola (1 poste)")
	_model("res://assets/scenarios/ruta_noche/auto-nuevo/interior.fbx", "Auto del conductor (cabina)")
	_model("res://assets/scenarios/ruta_noche/autos/source/fab.fbx", "Autos tráfico (fab.fbx = 10 autos)")

	# --- Escenas completas (instanciadas; corre la generación procedural) ---
	_scene("res://features/scenarios/consultorio/consultorio.tscn", "ESCENA CONSULTORIO (completa)")
	_scene("res://features/scenarios/ruta_noche/ruta_noche.tscn", "ESCENA RUTA_NOCHE (completa, sin tráfico runtime)")

	print("==========================================\n")
	quit()

func _model(path: String, label: String) -> void:
	var res = load(path)
	if res == null:
		print("  [%s] NO CARGÓ: %s" % [label, path])
		return
	var node: Node = null
	if res is PackedScene:
		node = res.instantiate()
	elif res is Mesh:
		var mi := MeshInstance3D.new()
		mi.mesh = res
		node = mi
	if node == null:
		print("  [%s] tipo no soportado: %s" % [label, res.get_class()])
		return
	print("  %-44s %s tris" % [label, _commas(_count(node))])
	node.free()

func _scene(path: String, label: String) -> void:
	var ps = load(path)
	if ps == null:
		print("  [%s] NO CARGÓ" % label)
		return
	var inst = ps.instantiate()
	get_root().add_child(inst)  # dispara _ready (generación procedural)
	print("  >>> %-40s %s tris" % [label, _commas(_count(inst))])
	inst.queue_free()

func _count(node: Node) -> int:
	var total := 0
	var mi := node as MeshInstance3D
	if mi != null and mi.mesh != null:
		for s in range(mi.mesh.get_surface_count()):
			var arr = mi.mesh.surface_get_arrays(s)
			if arr.is_empty():
				continue
			var idx = arr[Mesh.ARRAY_INDEX]
			if idx != null and idx.size() > 0:
				total += idx.size() / 3
			else:
				var v = arr[Mesh.ARRAY_VERTEX]
				if v != null:
					total += v.size() / 3
	for c in node.get_children():
		total += _count(c)
	return total

func _commas(n: int) -> String:
	var s := str(n)
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "." + out
	return out
