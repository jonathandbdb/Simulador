extends SceneTree
# Vuelca la estructura geométrica de room_shell y office para detectar
# paredes coplanares (Z-fighting). Headless.

func _initialize() -> void:
	print("\n========== ESTRUCTURA GEOMETRICA ==========")
	_dump("res://assets/scenarios/consultorio/room_shell/room_shell.glb", "ROOM_SHELL (paredes agregadas)")
	_dump("res://assets/scenarios/consultorio/modern_office/modern_office.fbx", "OFFICE (asset original)")
	print("===========================================\n")
	quit()

func _dump(path: String, label: String) -> void:
	var ps = load(path)
	if ps == null:
		print("[%s] NO CARGÓ: %s" % [label, path])
		return
	var inst = ps.instantiate()
	get_root().add_child(inst)
	print("\n=== %s ===" % label)
	_rec(inst, "")
	inst.queue_free()

func _rec(node: Node, indent: String) -> void:
	var mi := node as MeshInstance3D
	var info := ""
	if mi != null and mi.mesh != null:
		var ab: AABB = mi.get_aabb()  # local del mesh
		var c: Vector3 = ab.get_center()
		var np: Vector3 = mi.position
		info = "  | node_pos=(%.2f,%.2f,%.2f) aabb_centro=(%.2f,%.2f,%.2f) size=(%.2f,%.2f,%.2f)" % [
			np.x, np.y, np.z, c.x, c.y, c.z, ab.size.x, ab.size.y, ab.size.z]
	print("%s%s [%s]%s" % [indent, node.name, node.get_class(), info])
	for c in node.get_children():
		_rec(c, indent + "  ")
