extends SceneTree
## Diff numerico de dos PNG (borrar al cierre). Uso:
## godot --headless --script res://tmp_img_diff.gd -- a.png b.png

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		print("DIFF_ERR faltan argumentos")
		quit(1)
		return
	var a := Image.load_from_file(args[0])
	var b := Image.load_from_file(args[1])
	if a == null or b == null or a.get_size() != b.get_size():
		print("DIFF_ERR carga o tamanos distintos")
		quit(1)
		return
	var w := a.get_width()
	var h := a.get_height()
	var max_d := 0.0
	var sum_d := 0.0
	var count := 0
	# Muestreo cada 3px (suficiente para detectar cambios visibles).
	for y in range(0, h, 3):
		for x in range(0, w, 3):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var d: float = abs(ca.r - cb.r) + abs(ca.g - cb.g) + abs(ca.b - cb.b)
			max_d = max(max_d, d)
			sum_d += d
			count += 1
	print("DIFF max=%.4f mean=%.6f px=%d" % [max_d, sum_d / count, count])
	quit()
