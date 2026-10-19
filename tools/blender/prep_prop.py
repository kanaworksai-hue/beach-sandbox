"""Clean a Meshy GLB for this project: one mesh, base colour only (1024 px), origin at the
bottom centre, longest side scaled to 1 m (real size is set per prop in props.gd).

blender --background --factory-startup --python tools/blender/prep_prop.py -- IN.glb OUT.glb [tex_px]
"""
import sys
import bpy
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
src, dst = argv[0], argv[1]
tex_px = int(argv[2]) if len(argv) > 2 else 1024

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
bpy.ops.object.select_all(action="DESELECT")
for o in meshes:
    o.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
if len(meshes) > 1:
    bpy.ops.object.join()
ob = bpy.context.view_layer.objects.active
# Bake parent transforms into the mesh, drop empties.
bpy.ops.object.parent_clear(type="CLEAR_KEEP_TRANSFORM")
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
for o in list(bpy.context.scene.objects):
    if o != ob:
        bpy.data.objects.remove(o, do_unlink=True)

# Bounds -> origin at bottom centre, longest side 1 m.
vs = [v.co for v in ob.data.vertices]
lo = Vector((min(v.x for v in vs), min(v.y for v in vs), min(v.z for v in vs)))
hi = Vector((max(v.x for v in vs), max(v.y for v in vs), max(v.z for v in vs)))
c = (lo + hi) * 0.5
s = 1.0 / max(hi - lo)
for v in ob.data.vertices:
    v.co = Vector(((v.co.x - c.x) * s, (v.co.y - c.y) * s, (v.co.z - lo.z) * s))  # Blender Z up

# Keep only the base colour texture, resized.
for mat in ob.data.materials:
    if not mat or not mat.use_nodes:
        continue
    nt = mat.node_tree
    bsdf = next((n for n in nt.nodes if n.type == "BSDF_PRINCIPLED"), None)
    base_img = None
    if bsdf and bsdf.inputs["Base Color"].is_linked:
        node = bsdf.inputs["Base Color"].links[0].from_node
        if node.type == "TEX_IMAGE":
            base_img = node.image
    for inp in ("Metallic", "Roughness", "Normal", "Emission Color"):
        if bsdf and inp in bsdf.inputs:
            for l in list(bsdf.inputs[inp].links):
                nt.links.remove(l)
    for n in list(nt.nodes):
        if n.type == "TEX_IMAGE" and n.image != base_img:
            nt.nodes.remove(n)
        elif n.type in ("NORMAL_MAP", "SEPRGB", "SEPARATE_COLOR"):
            nt.nodes.remove(n)
    if bsdf:
        bsdf.inputs["Metallic"].default_value = 0.0
        bsdf.inputs["Roughness"].default_value = 0.8
    if base_img and max(base_img.size) > tex_px:
        base_img.scale(tex_px, tex_px)
        base_img.pack()

bpy.ops.export_scene.gltf(filepath=dst, export_format="GLB", export_image_format="JPEG",
                          export_jpeg_quality=90, export_yup=True, use_selection=False)
print("PREP %s verts=%d tris=%d size=%s" % (dst, len(ob.data.vertices),
      sum(len(p.vertices) - 2 for p in ob.data.polygons), tuple(round(x, 3) for x in (hi - lo) * s)))
