"""Platine's room for Cycles: the light the app can't compute in real time.

Run with Blender 4.2+ (tested on 5.2):
    blender -b -P render/room.py -- --out Sources/Platine/Resources/Plates [--only medium:noon] [--size 2560x1600]
                                     [--samples 256] [--reference] [--probes-only]

Every dimension mirrors the SceneKit scene (RoomScene.swift, TurntableNode.swift),
written in SceneKit coordinates (y up, z towards the viewer) and converted here,
so the app can draw what moves (record, arm, sleeve art, steam, rain) over these
plates with a camera that lines up to the pixel.
"""
import math
import os
import random
import sys

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector

# --------------------------------------------------------------------------- args

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def arg(flag, default=None):
    return argv[argv.index(flag) + 1] if flag in argv else default


OUT = os.path.abspath(arg("--out", "render/out"))
ONLY = arg("--only")                      # e.g. "medium:noon,close:night"
W, H = (int(v) for v in arg("--size", "2560x1600").split("x"))
SAMPLES = int(arg("--samples", "256"))
REFERENCE = "--reference" in argv         # keep record + arm, for matching the app's look
PROBES_ONLY = "--probes-only" in argv
NO_PROBES = "--no-probes" in argv
os.makedirs(OUT, exist_ok=True)

# ------------------------------------------------------------ SceneKit -> Blender

C = Matrix(((1, 0, 0, 0), (0, 0, -1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))
C_INV = C.inverted()


def V(x, y, z):
    """A SceneKit point in Blender space."""
    return Vector((x, -z, y))


def T(x, y, z):
    return Matrix.Translation((x, y, z))


def R(axis, angle):
    return Matrix.Rotation(angle, 4, axis)


def place(obj, sk_matrix):
    obj.matrix_world = C @ sk_matrix @ C_INV


# Constants shared with the app.
DECK_Y = 0.093
SPINDLE = (-0.045, 0.0)
PIVOT = (0.165, -0.105)
RECORD_TOP = DECK_Y + 0.0306
ARM_DROP = 0.022
ARM_Y = RECORD_TOP + ARM_DROP
WINDOW = (-0.78, 0.14, 1.16, 1.12)        # x, y, width, height
WALL_Z = -0.55
FLOOR_Y = -0.75
CEIL_Y = 2.05

# ---------------------------------------------------------------------- scene

scene = bpy.context.scene
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)

collections = {}


def coll(name):
    if name not in collections:
        c = bpy.data.collections.new(name)
        scene.collection.children.link(c)
        collections[name] = c
    return collections[name]


def new_object(name, bm, material, collection="room", smooth_sides=False):
    mesh = bpy.data.meshes.new(name)
    if smooth_sides:
        for f in bm.faces:
            f.smooth = abs(f.normal.z) < 0.5
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    coll(collection).objects.link(obj)
    if material is not None:
        obj.data.materials.append(material)
    return obj


def bevel(obj, width, segments=3):
    if width <= 0:
        return obj
    m = obj.modifiers.new("Bevel", "BEVEL")
    m.width = width
    m.segments = segments
    m.limit_method = "ANGLE"
    m.harden_normals = True
    return obj


def box(name, w, h, d, sk_matrix, material, round_=0.0015, collection="room"):
    """SCNBox(width: w, height: h, length: d)."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co = Vector((v.co.x * w, v.co.y * d, v.co.z * h))
    obj = new_object(name, bm, material, collection)
    place(obj, sk_matrix)
    return bevel(obj, min(round_, w / 3, h / 3, d / 3))


def cylinder(name, r, h, sk_matrix, material, segments=96, round_=0.0008, collection="room", r2=None):
    """SCNCylinder(radius: r, height: h) along SceneKit's y."""
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments,
                          radius1=r, radius2=r if r2 is None else r2, depth=h)
    obj = new_object(name, bm, material, collection, smooth_sides=True)
    place(obj, sk_matrix)
    return bevel(obj, min(round_, h / 3), 2)


def tube_between(name, a, b, r, material, collection="room", segments=24):
    """A rod from SceneKit point a to b."""
    pa, pb = V(*a), V(*b)
    d = pb - pa
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=segments, radius1=r, radius2=r, depth=d.length)
    obj = new_object(name, bm, material, collection, smooth_sides=True)
    obj.matrix_world = Matrix.Translation((pa + pb) / 2) @ d.to_track_quat("Z", "Y").to_matrix().to_4x4()
    return obj


def lathe(name, profile, sk_matrix, material, segments=96, collection="room"):
    """Spin a (radius, y) profile around SceneKit's y axis."""
    bm = bmesh.new()
    verts = [bm.verts.new((r, 0, y)) for r, y in profile]
    edges = [bm.edges.new((verts[i], verts[i + 1])) for i in range(len(verts) - 1)]
    bmesh.ops.spin(bm, geom=verts + edges, cent=(0, 0, 0), axis=(0, 0, 1), angle=2 * math.pi,
                   steps=segments, use_merge=True)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-6)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    for f in bm.faces:
        f.smooth = True
    obj = new_object(name, bm, material, collection)
    place(obj, sk_matrix)
    return obj


def plane(name, w, h, sk_matrix, material, collection="room"):
    """SCNPlane(width: w, height: h): faces +z in SceneKit."""
    bm = bmesh.new()
    for x, y in ((-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)):
        bm.verts.new((x, 0, y))
    bm.faces.new(bm.verts)
    bm.faces.ensure_lookup_table()
    uv = bm.loops.layers.uv.new()
    for loop, co in zip(bm.faces[0].loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
        loop[uv].uv = co
    obj = new_object(name, bm, material, collection)
    place(obj, sk_matrix)
    return obj


# ----------------------------------------------------------------- materials

def material(name, color=(0.8, 0.8, 0.8), metal=0.0, rough=0.5, **inputs):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    p = m.node_tree.nodes["Principled BSDF"]
    p.inputs["Base Color"].default_value = (*color, 1)
    p.inputs["Metallic"].default_value = metal
    p.inputs["Roughness"].default_value = rough
    for k, v in inputs.items():
        p.inputs[k.replace("_", " ")].default_value = v
    return m


def nodes(m):
    return m.node_tree.nodes, m.node_tree.links, m.node_tree.nodes["Principled BSDF"]


def bump(m, strength=0.2, scale=400.0, detail=6.0, distance=0.0005, coords="Object", stretch=None):
    """Fine noise in the normal: plaster, brushed metal, cardboard."""
    n, l, p = nodes(m)
    tc = n.new("ShaderNodeTexCoord")
    src = tc.outputs[coords]
    if stretch:
        mp = n.new("ShaderNodeMapping")
        mp.inputs["Scale"].default_value = stretch
        l.new(src, mp.inputs["Vector"])
        src = mp.outputs["Vector"]
    nz = n.new("ShaderNodeTexNoise")
    nz.inputs["Scale"].default_value = scale
    nz.inputs["Detail"].default_value = detail
    l.new(src, nz.inputs["Vector"])
    b = n.new("ShaderNodeBump")
    b.inputs["Strength"].default_value = strength
    b.inputs["Distance"].default_value = distance
    l.new(nz.outputs["Fac"], b.inputs["Height"])
    l.new(b.outputs["Normal"], p.inputs["Normal"])
    return nz


def color_noise(m, a, b, scale=8.0, detail=4.0):
    """Base colour wandering between a and b: wear, stains, uneven paint."""
    n, l, p = nodes(m)
    nz = n.new("ShaderNodeTexNoise")
    nz.inputs["Scale"].default_value = scale
    nz.inputs["Detail"].default_value = detail
    ramp = n.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (*a, 1)
    ramp.color_ramp.elements[1].color = (*b, 1)
    l.new(nz.outputs["Fac"], ramp.inputs["Fac"])
    l.new(ramp.outputs["Color"], p.inputs["Base Color"])


def image_from(name, array):
    """A float RGBA numpy array (h, w, 4) as a packed Blender image."""
    h, w = array.shape[:2]
    img = bpy.data.images.new(name, w, h, alpha=True, float_buffer=False)
    img.pixels.foreach_set(np.ascontiguousarray(array[::-1]).ravel().astype(np.float32))
    img.pack()
    return img


def image_texture(m, img, to="Base Color", coords="UV", non_color=False):
    n, l, p = nodes(m)
    t = n.new("ShaderNodeTexImage")
    t.image = img
    if non_color:
        img.colorspace_settings.name = "Non-Color"
    tc = n.new("ShaderNodeTexCoord")
    l.new(tc.outputs[coords], t.inputs["Vector"])
    l.new(t.outputs["Color"], p.inputs[to])
    return t


SATIN_BLACK = material("satin black", (0.012, 0.012, 0.012), 0.0, 0.42, Coat_Weight=0.25, Coat_Roughness=0.25)
bump(SATIN_BLACK, 0.05, 900)
CHROME = material("chrome", (0.92, 0.92, 0.9), 1.0, 0.08)
ALU = material("brushed aluminium", (0.91, 0.91, 0.9), 1.0, 0.24, Anisotropic=0.7)
bump(ALU, 0.06, 6, 8, 0.0002, stretch=(1, 900, 1))          # long hairlines across the deck
WORN_ALU = material("worn button", (0.7, 0.7, 0.68), 1.0, 0.45)
RUBBER = material("rubber", (0.025, 0.025, 0.025), 0.0, 0.85)
CERAMIC = material("ceramic", (0.86, 0.83, 0.76), 0.0, 0.18, Coat_Weight=0.6, Coat_Roughness=0.05)
color_noise(CERAMIC, (0.84, 0.8, 0.72), (0.9, 0.87, 0.8), 3)
COFFEE = material("coffee", (0.03, 0.012, 0.004), 0.0, 0.03)
BRASS = material("brass", (0.86, 0.66, 0.36), 1.0, 0.3)
bump(BRASS, 0.08, 300)
SHADE = material("lamp shade", (0.06, 0.13, 0.09), 0.2, 0.38, Coat_Weight=0.5)
STEEL = material("window steel", (0.03, 0.03, 0.03), 0.4, 0.5)
bump(STEEL, 0.15, 120)
SILL = material("stone sill", (0.62, 0.6, 0.56), 0.0, 0.62)
color_noise(SILL, (0.55, 0.53, 0.5), (0.68, 0.66, 0.62), 40)
bump(SILL, 0.2, 200)
PAPER_WHITE = material("sleeve face", (0.82, 0.82, 0.82), 0.0, 0.6)   # the app draws the cover over this
CARDBOARD = material("cardboard", (0.75, 0.72, 0.66), 0.0, 0.85)
bump(CARDBOARD, 0.1, 500)

# Plaster: warm off-white with a trowelled surface.
PLASTER = material("plaster", (0.78, 0.74, 0.67), 0.0, 0.92)
color_noise(PLASTER, (0.74, 0.7, 0.63), (0.8, 0.76, 0.69), 2.5, 3)
bump(PLASTER, 0.35, 60, 8, 0.001)
CEILING = material("ceiling", (0.82, 0.8, 0.76), 0.0, 0.95)

# Desk: oiled wood, grain along x.
WOOD = material("wood", (0.4, 0.22, 0.11), 0.0, 0.42, Coat_Weight=0.35, Coat_Roughness=0.18)
n, l, p = nodes(WOOD)
tc = n.new("ShaderNodeTexCoord")
mp = n.new("ShaderNodeMapping")
mp.inputs["Scale"].default_value = (0.6, 9.0, 0.6)
l.new(tc.outputs["Object"], mp.inputs["Vector"])
nz = n.new("ShaderNodeTexNoise")
nz.inputs["Scale"].default_value = 2.0
nz.inputs["Detail"].default_value = 3.0
l.new(mp.outputs["Vector"], nz.inputs["Vector"])
wave = n.new("ShaderNodeTexWave")
wave.wave_type = "BANDS"
wave.bands_direction = "Y"
wave.inputs["Scale"].default_value = 3.0
wave.inputs["Distortion"].default_value = 9.0
wave.inputs["Detail"].default_value = 3.0
l.new(mp.outputs["Vector"], wave.inputs["Vector"])
mix = n.new("ShaderNodeMix")
mix.data_type = "FLOAT"
mix.inputs[0].default_value = 0.6
l.new(wave.outputs["Fac"], mix.inputs[2])
l.new(nz.outputs["Fac"], mix.inputs[3])
ramp = n.new("ShaderNodeValToRGB")
ramp.color_ramp.elements[0].color = (0.24, 0.11, 0.045, 1)
ramp.color_ramp.elements[1].color = (0.40, 0.21, 0.1, 1)
l.new(mix.outputs[0], ramp.inputs["Fac"])
l.new(ramp.outputs["Color"], p.inputs["Base Color"])
wb = n.new("ShaderNodeBump")
wb.inputs["Strength"].default_value = 0.08
wb.inputs["Distance"].default_value = 0.0004
l.new(mix.outputs[0], wb.inputs["Height"])
l.new(wb.outputs["Normal"], p.inputs["Normal"])

FLOOR = material("floor", (0.3, 0.17, 0.09), 0.0, 0.5)
n, l, p = nodes(FLOOR)
br = n.new("ShaderNodeTexBrick")
br.inputs["Scale"].default_value = 1.2
br.inputs["Color1"].default_value = (0.32, 0.17, 0.08, 1)
br.inputs["Color2"].default_value = (0.22, 0.11, 0.05, 1)
br.inputs["Mortar"].default_value = (0.1, 0.05, 0.02, 1)
br.inputs["Mortar Size"].default_value = 0.004
br.inputs["Brick Width"].default_value = 1.2
br.inputs["Row Height"].default_value = 0.14
tc = n.new("ShaderNodeTexCoord")
l.new(tc.outputs["Object"], br.inputs["Vector"])
l.new(br.outputs["Color"], p.inputs["Base Color"])

def see_through(name, tint, transparency, gloss=0.03):
    """Transparent + glossy instead of refraction, so light passes without caustics."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    n, l = m.node_tree.nodes, m.node_tree.links
    n.remove(n["Principled BSDF"])
    tr = n.new("ShaderNodeBsdfTransparent")
    tr.inputs["Color"].default_value = (*tint, 1)
    gl = n.new("ShaderNodeBsdfGlossy")
    gl.inputs["Roughness"].default_value = gloss
    fr = n.new("ShaderNodeFresnel")
    fr.inputs["IOR"].default_value = 1.5
    mx = n.new("ShaderNodeMixShader")
    l.new(fr.outputs[0], mx.inputs[0])
    l.new(tr.outputs[0], mx.inputs[1])
    l.new(gl.outputs[0], mx.inputs[2])
    if transparency < 1:
        dk = n.new("ShaderNodeBsdfDiffuse")
        dk.inputs["Color"].default_value = (0.01, 0.01, 0.01, 1)
        mx2 = n.new("ShaderNodeMixShader")
        mx2.inputs[0].default_value = 1 - transparency
        l.new(mx.outputs[0], mx2.inputs[1])
        l.new(dk.outputs[0], mx2.inputs[2])
        mx = mx2
    l.new(mx.outputs[0], n["Material Output"].inputs["Surface"])
    return m


SMOKED = see_through("smoked acrylic", (0.6, 0.52, 0.44), 0.93)
GLASS = see_through("glass", (0.96, 0.97, 0.96), 1.0, 0.0)

# Platter strobe rim: four rows of dots (180, 183, 133, 135 per turn).
rim_w, rim_h = 4096, 128
rim = np.full((rim_h, rim_w, 4), (0.86, 0.86, 0.85, 1.0), dtype=np.float32)
for row, count in enumerate((180, 183, 133, 135)):
    y0 = int(rim_h * (0.14 + row * 0.19))
    cell = rim_w / count
    for i in range(count):
        x0 = int(i * cell)
        rim[y0:y0 + int(rim_h * 0.1), x0:x0 + max(2, int(cell * 0.45))] = (0.03, 0.03, 0.03, 1)
STROBE = material("platter rim", (1, 1, 1), 1.0, 0.25)
STROBE_IMG = image_from("strobe rim", rim)

# Mat: concentric ribs.
mat_n = 1024
yy, xx = np.mgrid[0:mat_n, 0:mat_n]
rr = np.hypot(xx - mat_n / 2, yy - mat_n / 2) / (mat_n / 2)
ribs = 0.5 + 0.5 * np.sign(np.sin(rr * 2 * np.pi * 34))
mat_rgba = np.zeros((mat_n, mat_n, 4), dtype=np.float32)
mat_rgba[..., 0] = mat_rgba[..., 1] = mat_rgba[..., 2] = ribs
mat_rgba[..., 3] = 1
MAT = material("rubber mat", (0.03, 0.03, 0.03), 0.0, 0.8)
MAT_IMG = image_from("mat ribs", mat_rgba)
n, l, p = nodes(MAT)
t = n.new("ShaderNodeTexImage")
t.image = MAT_IMG
MAT_IMG.colorspace_settings.name = "Non-Color"
tc = n.new("ShaderNodeTexCoord")
l.new(tc.outputs["UV"], t.inputs["Vector"])
mb = n.new("ShaderNodeBump")
mb.inputs["Strength"].default_value = 0.4
mb.inputs["Distance"].default_value = 0.0004
l.new(t.outputs["Color"], mb.inputs["Height"])
l.new(mb.outputs["Normal"], p.inputs["Normal"])

# ---------------------------------------------------------------- the room

w_x, w_y, w_w, w_h = WINDOW
wall_c = WALL_Z - 0.07


def wall_block(x0, x1, y0, y1):
    box("wall", x1 - x0, y1 - y0, 0.14, T((x0 + x1) / 2, (y0 + y1) / 2, wall_c), PLASTER, 0.0)


wall_block(-2.2, w_x, FLOOR_Y, CEIL_Y)
wall_block(w_x + w_w, 2.2, FLOOR_Y, CEIL_Y)
wall_block(w_x, w_x + w_w, FLOOR_Y, w_y)
wall_block(w_x, w_x + w_w, w_y + w_h, CEIL_Y)
# Reveal: the wall's thickness inside the opening catches the sun.
box("floor", 4.4, 0.04, 4.4, T(0, FLOOR_Y - 0.02, 1.6), FLOOR, 0)
box("ceiling", 4.4, 0.04, 4.4, T(0, CEIL_Y + 0.02, 1.6), CEILING, 0)
box("left wall", 0.1, CEIL_Y - FLOOR_Y, 4.4, T(-2.2, (CEIL_Y + FLOOR_Y) / 2, 1.6), PLASTER, 0)
box("right wall", 0.1, CEIL_Y - FLOOR_Y, 4.4, T(2.2, (CEIL_Y + FLOOR_Y) / 2, 1.6), PLASTER, 0)
box("back wall", 4.4, CEIL_Y - FLOOR_Y, 0.1, T(0, (CEIL_Y + FLOOR_Y) / 2, 3.8), PLASTER, 0)

# Steel frame with a mullion and a transom.
fz = WALL_Z - 0.09
t_ = 0.028
mx, my = w_x + w_w / 2, w_y + w_h / 2
for x, y, bw, bh in ((mx, w_y + t_ / 2, w_w, t_), (mx, w_y + w_h - t_ / 2, w_w, t_),
                     (w_x + t_ / 2, my, t_, w_h), (w_x + w_w - t_ / 2, my, t_, w_h),
                     (mx, my, t_ * 0.7, w_h), (mx, w_y + w_h * 0.7, w_w, t_ * 0.7)):
    box("frame", bw, bh, 0.035, T(x, y, fz), STEEL, 0.002)
box("sill", w_w + 0.08, 0.025, 0.1, T(mx, w_y - 0.012, WALL_Z - 0.02), SILL, 0.003)
glass = plane("glass", w_w, w_h, T(mx, my, fz - 0.005), GLASS)

# Desk.
box("desk", 2.4, 0.04, 1.0, T(-0.1, -0.02, -0.05), WOOD, 0.004)
for x in (-1.24, 1.04):
    for z in (-0.5, 0.4):
        box("desk leg", 0.05, -FLOOR_Y - 0.04, 0.05, T(x, (FLOOR_Y - 0.04) / 2, z), WOOD, 0.003)

# ------------------------------------------------------------- turntable

TT = "turntable"
for x, z in ((-0.19, 0.15), (0.19, 0.15), (-0.19, -0.15), (0.19, -0.15)):
    cylinder("foot", 0.028, 0.012, T(x, 0.006, z), RUBBER, 48, 0.003, TT)
box("plinth", 0.453, 0.075, 0.367, T(0, 0.012 + 0.0375, 0), SATIN_BLACK, 0.005, TT)
deck = box("deck", 0.447, 0.006, 0.361, T(0, DECK_Y - 0.003, 0), ALU, 0.0015, TT)
box("start stop", 0.052, 0.006, 0.022, T(-0.17, DECK_Y + 0.002, 0.162), WORN_ALU, 0.002, TT)
for x in (0.10, 0.135):
    box("speed button", 0.026, 0.005, 0.016, T(x, DECK_Y + 0.0015, 0.162), CHROME, 0.002, TT)
box("strobe housing", 0.02, 0.016, 0.02, T(-0.2, DECK_Y + 0.008, 0.155), SATIN_BLACK, 0.003, TT)

sx, sz = SPINDLE
platter = cylinder("platter", 0.156, 0.024, T(sx, DECK_Y + 0.014, sz), STROBE, 256, 0.0015, TT)
# Cylindrical UVs on the rim for the strobe dots.
n, l, p = nodes(STROBE)
tex = n.new("ShaderNodeTexImage")
tex.image = STROBE_IMG
tc = n.new("ShaderNodeTexCoord")
sep = n.new("ShaderNodeSeparateXYZ")
l.new(tc.outputs["Object"], sep.inputs["Vector"])
atan = n.new("ShaderNodeMath")
atan.operation = "ARCTAN2"
l.new(sep.outputs["Y"], atan.inputs[0])
l.new(sep.outputs["X"], atan.inputs[1])
u = n.new("ShaderNodeMath")
u.operation = "MULTIPLY_ADD"
u.inputs[1].default_value = 1 / (2 * math.pi)
u.inputs[2].default_value = 0.5
l.new(atan.outputs[0], u.inputs[0])
v = n.new("ShaderNodeMath")
v.operation = "MULTIPLY_ADD"
v.inputs[1].default_value = 1 / 0.024
v.inputs[2].default_value = 0.5
l.new(sep.outputs["Z"], v.inputs[0])
comb = n.new("ShaderNodeCombineXYZ")
l.new(u.outputs[0], comb.inputs["X"])
l.new(v.outputs[0], comb.inputs["Y"])
l.new(comb.outputs["Vector"], tex.inputs["Vector"])
l.new(tex.outputs["Color"], p.inputs["Base Color"])

cylinder("mat", 0.150, 0.003, T(sx, DECK_Y + 0.0275, sz), MAT, 256, 0.0008, TT)

# Arm base, pillar, rest, cue lever: what doesn't move.
px, pz = PIVOT
cylinder("arm base", 0.032, 0.008, T(px, DECK_Y + 0.004, pz), ALU, 96, 0.002, TT)
cylinder("arm base ring", 0.026, 0.003, T(px, DECK_Y + 0.0095, pz), SATIN_BLACK, 96, 0.001, TT)
cylinder("arm pillar", 0.011, ARM_Y - DECK_Y, T(px, (ARM_Y + DECK_Y) / 2, pz), CHROME, 64, 0.001, TT)
L_EFF = 0.230
rest_yaw = -math.pi / 2 + 0.035
rest = (px + 0.6 * L_EFF * math.cos(rest_yaw), pz - 0.6 * L_EFF * math.sin(rest_yaw))
cylinder("arm rest post", 0.004, ARM_Y - DECK_Y - 0.004, T(rest[0], (ARM_Y - 0.004 + DECK_Y) / 2, rest[1]),
         SATIN_BLACK, 32, 0.0005, TT)
box("arm rest", 0.014, 0.004, 0.008, T(rest[0], ARM_Y - 0.006, rest[1]), SATIN_BLACK, 0.001, TT)
box("cue lever", 0.006, 0.012, 0.03, T(px + 0.045, DECK_Y + 0.008, pz + 0.11) @ R("X", -0.3), CHROME, 0.002, TT)
for x in (-0.15, 0.15):
    box("hinge", 0.03, 0.012, 0.014, T(x, DECK_Y + 0.004, -0.178), SATIN_BLACK, 0.002, TT)

# Lid, open.
hinge = T(0, DECK_Y, -0.18) @ R("X", -1.62)
lw, lh, ld = 0.448, 0.095, 0.362
for g, pos, rot in (((lw, ld), (0, lh, ld / 2), R("X", -math.pi / 2)),
                    ((lw, lh), (0, lh / 2, ld), Matrix.Identity(4)),
                    ((lw, lh), (0, lh / 2, 0), Matrix.Identity(4)),
                    ((ld, lh), (-lw / 2, lh / 2, ld / 2), R("Y", math.pi / 2)),
                    ((ld, lh), (lw / 2, lh / 2, ld / 2), R("Y", math.pi / 2))):
    o = plane("lid", g[0], g[1], hinge @ T(*pos) @ rot, SMOKED, TT)
    s = o.modifiers.new("Solidify", "SOLIDIFY")
    s.thickness = 0.003

# Live parts, built here only for --reference renders (the app draws them).
LIVE = "live"
VINYL = material("vinyl", (0.006, 0.006, 0.006), 0.0, 0.18, Coat_Weight=0.5, Coat_Roughness=0.08, Anisotropic=0.8)
cylinder("record", 0.1515, 0.0016, T(sx, RECORD_TOP - 0.0008, sz), VINYL, 256, 0.0005, LIVE)
cylinder("label", 0.05, 0.0004, T(sx, RECORD_TOP + 0.0001, sz), material("label", (0.7, 0.2, 0.1), 0, 0.6), 128, 0, LIVE)
cylinder("spindle", 0.0036, 0.02, T(sx, RECORD_TOP + 0.002, sz), CHROME, 32, 0.001, LIVE)
yaw = rest_yaw
arm = T(px, ARM_Y, pz) @ R("Y", yaw)


def arm_point(x, y, z):
    p4 = arm @ Vector((x, y, z, 1))
    return (p4.x, p4.y, p4.z)


tube_end = L_EFF - 0.048
pts = [arm_point(x, 0, -0.016 * math.sin(2 * math.pi * x / tube_end))
       for x in (tube_end * i / 18 for i in range(19))]
for a, b in zip(pts, pts[1:]):
    tube_between("arm tube", a, b, 0.0042, CHROME, LIVE)
tube_between("arm stub", arm_point(0, 0, 0), arm_point(-0.06, 0, 0), 0.005, CHROME, LIVE)
cylinder("counterweight", 0.017, 0.032, arm @ T(-0.068, 0, 0) @ R("Z", math.pi / 2), material("weight", (0.6, 0.6, 0.6), 1, 0.35), 64, 0.002, LIVE)
box("headshell", 0.052, 0.004, 0.019, arm @ T(L_EFF - 0.024, -0.002, 0) @ R("Y", -0.08), SATIN_BLACK, 0.0015, LIVE)
box("cartridge", 0.018, 0.014, 0.015, arm @ T(L_EFF - 0.006, -0.011, 0), SATIN_BLACK, 0.0015, LIVE)

# ------------------------------------------------------------------ props

# Coffee: a lathed mug on its saucer.
mug_x, mug_z = 0.40, 0.17
mug = lathe("mug", [(0.0, 0.006), (0.036, 0.006), (0.041, 0.009), (0.042, 0.03), (0.042, 0.094),
                    (0.0405, 0.0955), (0.0375, 0.0945), (0.037, 0.03), (0.034, 0.012), (0.0, 0.012)],
            T(mug_x, 0, mug_z), CERAMIC)
# The handle: a bevelled curve.
curve = bpy.data.curves.new("handle", "CURVE")
curve.dimensions = "3D"
curve.bevel_depth = 0.0062
curve.bevel_resolution = 6
sp = curve.splines.new("BEZIER")
sp.bezier_points.add(2)
for bp, (x, y) in zip(sp.bezier_points, ((0.040, 0.078), (0.066, 0.052), (0.040, 0.024))):
    bp.co = V(mug_x + x, y, mug_z)
    bp.handle_left_type = bp.handle_right_type = "AUTO"
handle_curve = bpy.data.objects.new("mug handle", curve)
coll("room").objects.link(handle_curve)
handle_curve.data.materials.append(CERAMIC)
lathe("coffee", [(0.0, 0.082), (0.0368, 0.082)], T(mug_x, 0, mug_z), COFFEE)
lathe("saucer", [(0.0, 0.0), (0.05, 0.0), (0.074, 0.004), (0.077, 0.007), (0.074, 0.008), (0.05, 0.004), (0.0, 0.004)],
      T(mug_x, 0, mug_z), CERAMIC)

# The pile of records.
rnd = random.Random(77)
tones = [(0.78, 0.7, 0.56), (0.2, 0.25, 0.3), (0.65, 0.25, 0.18), (0.9, 0.88, 0.82), (0.15, 0.15, 0.14), (0.45, 0.55, 0.4)]
pile = T(-0.66, 0, -0.16) @ R("Y", 0.12)
for i in range(9):
    jx, jz, jr = rnd.uniform(-0.008, 0.008), rnd.uniform(-0.008, 0.008), rnd.uniform(-0.05, 0.05)
    tone = tones[i % len(tones)]
    m = material(f"sleeve {i}", tone, 0.0, 0.8)
    bump(m, 0.08, 500)
    box("pile sleeve", 0.315, 0.0055, 0.315, pile @ T(jx, 0.003 + 0.0056 * i, jz) @ R("Y", jr), m, 0.0008)
    if i == 8:
        plane("pile top face", 0.313, 0.313, pile @ T(jx, 0.003 + 0.0056 * i + 0.00276, jz) @ R("Y", jr) @ R("X", -math.pi / 2),
              PAPER_WHITE)

# The sleeve on its stand.
stand = T(0.62, 0, -0.43) @ R("Y", -0.35)
box("stand", 0.2, 0.012, 0.06, stand @ T(0, 0.006, 0), material("stand wood", (0.3, 0.18, 0.1), 0, 0.5), 0.003)
lean = stand @ T(0, 0.012, -0.01) @ R("X", -0.16)
box("sleeve backing", 0.315, 0.315, 0.003, lean @ T(0, 0.1575, -0.002), CARDBOARD, 0.0006)
plane("stand face", 0.313, 0.313, lean @ T(0, 0.1575, 0.0002), PAPER_WHITE)

# Desk lamp.
lamp = T(0.86, 0, -0.3)
cylinder("lamp base", 0.07, 0.015, lamp @ T(0, 0.0075, 0), BRASS, 96, 0.003)


def lamp_point(x, y, z):
    p4 = lamp @ Vector((x, y, z, 1))
    return (p4.x, p4.y, p4.z)


tube_between("lamp arm", lamp_point(0, 0.01, 0), lamp_point(-0.05, 0.42, 0.05), 0.006, BRASS)
tube_between("lamp arm", lamp_point(-0.05, 0.42, 0.05), lamp_point(-0.21, 0.455, 0.125), 0.006, BRASS)
shade_m = lamp @ T(-0.24, 0.42, 0.13) @ R("Z", -0.45)
shade = cylinder("lamp shade", 0.075, 0.11, shade_m, SHADE, 96, 0.0, r2=0.025)
shade.data.polygons.foreach_set("use_smooth", [True] * len(shade.data.polygons))
# Open the bottom of the cone: remove its cap.
bm = bmesh.new()
bm.from_mesh(shade.data)
bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.normal.z < -0.9 and len(f.verts) > 4], context="FACES")
bm.to_mesh(shade.data)
bm.free()
shade.modifiers.new("Solidify", "SOLIDIFY").thickness = 0.0015
BULB = material("bulb", (1, 0.9, 0.8), 0, 0.3, Emission_Color=(1.0, 0.62, 0.32, 1), Emission_Strength=0.0)
bulb_bm = bmesh.new()
bmesh.ops.create_uvsphere(bulb_bm, u_segments=32, v_segments=16, radius=0.022)
bulb = new_object("bulb", bulb_bm, BULB)
place(bulb, shade_m @ T(0, -0.045, 0))
bulb.data.polygons.foreach_set("use_smooth", [True] * len(bulb.data.polygons))
lamp_light = bpy.data.lights.new("lamp light", "SPOT")
lamp_light.spot_size = math.radians(110)
lamp_light.spot_blend = 0.6
lamp_light.shadow_soft_size = 0.02
lamp_light.color = (1.0, 0.68, 0.4)
lamp_obj = bpy.data.objects.new("lamp light", lamp_light)
coll("room").objects.link(lamp_obj)
place(lamp_obj, shade_m @ T(0, -0.05, 0) @ R("X", -math.pi / 2))

# Scanned props from Poly Haven (CC0): render/fetch_assets.py downloads them.
ASSET_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets")


def append(asset, keep=lambda name: True):
    path = os.path.join(ASSET_DIR, asset, f"{asset}_1k.blend")
    if not os.path.exists(path):
        sys.exit(f"missing {path}: run python3 render/fetch_assets.py")
    with bpy.data.libraries.load(path, link=False) as (src, dst):
        dst.objects = [n for n in src.objects if keep(n)]
    objs = [o for o in dst.objects if o is not None and o.type == "MESH"]
    for o in objs:
        coll("room").objects.link(o)
    return objs


# A few books against the wall, spines to the room.
books = sorted(append("decorative_book_set_01", lambda n: n.startswith("book_")), key=lambda o: o.location.x)
keep, x0 = books[:8], books[0].location.x
for o in books[8:]:
    bpy.data.objects.remove(o, do_unlink=True)
for i, o in enumerate(keep):
    o.parent = None
    o.location = V(-1.06, 0, -0.43) + Vector((o.location.x - x0, o.location.y, 0))
    o.rotation_euler = (0, 0, 0)
# The last one leans on the others: it pivots on its bottom edge nearest them until its
# side rests on the top of its neighbour.
keep[-1].location += Vector((0.035, 0, 0))
bpy.context.view_layer.update()
def corners(o):
    return [o.matrix_world @ Vector(c) for c in o.bound_box]
prev, last = corners(keep[-2]), corners(keep[-1])
pivot = Vector((min(c.x for c in last), sum(c.y for c in last) / 8, min(c.z for c in last)))
gap = pivot.x - max(c.x for c in prev)
top = max(c.z for c in prev) - pivot.z
tilt = math.atan2(gap, 0.97 * top)
keep[-1].matrix_world = (Matrix.Translation(pivot) @ Matrix.Rotation(-tilt, 4, "Y")
                         @ Matrix.Translation(-pivot) @ keep[-1].matrix_world)

# A plant: a syngonium in terracotta, the way they grow in every São Paulo flat.
plant = append("potted_plant_02")
for o in plant:
    o.parent = None
    o.location = V(-0.95, 0, -0.1) + o.location * 0.42
    o.scale = Vector(o.scale) * 0.42
    o.rotation_euler = (0, 0, math.radians(35))
    o.location = V(-0.95, 0, -0.1) + (Matrix.Rotation(math.radians(35), 3, "Z") @ ((o.location - V(-0.95, 0, -0.1))))

# ---------------------------------------------------------------- outside
# The view itself is a photograph the app puts behind the window (the plates leave it
# transparent); here only the ground below, for the light it bounces into the room.
GROUND_Y = FLOOR_Y - 34.0                # a twelfth floor
GROUND = material("ground", (0.12, 0.12, 0.11), 0, 0.9)
plane("ground", 1200, 1200, T(0, GROUND_Y, -500) @ R("X", -math.pi / 2), GROUND, "outside").visible_camera = False
# Where the app hangs the photo: a 3:2 card far out, wide enough to frame like a normal lens.
VIEW_DIST = 120.0
VIEW_W = 2 * (VIEW_DIST + 2.1) * math.tan(math.radians(32.5))
VIEW_H = VIEW_W / 1.5
VIEW_CENTRE = (WINDOW[0] + WINDOW[2] / 2, 14.0, WALL_Z - VIEW_DIST)   # horizon low in the window, as from a high floor

# ---------------------------------------------------------------- lighting

world = bpy.data.worlds.new("sky")
scene.world = world
world.use_nodes = True
wn_, wl_ = world.node_tree.nodes, world.node_tree.links
bg = wn_["Background"]
sky = wn_.new("ShaderNodeTexSky")
sky.sky_type = "MULTIPLE_SCATTERING"
sky.sun_disc = False
sky.altitude = 760.0                      # São Paulo sits at 760 m
sky.air_density = 1.0
sky.aerosol_density = 2.2                 # a hazy megacity
night = wn_.new("ShaderNodeRGB")
night.outputs[0].default_value = (0.0025, 0.003, 0.007, 1)
glow_grad = wn_.new("ShaderNodeTexGradient")
glow_grad.gradient_type = "LINEAR"
tcw = wn_.new("ShaderNodeTexCoord")
sepw = wn_.new("ShaderNodeSeparateXYZ")
wl_.new(tcw.outputs["Generated"], sepw.inputs["Vector"])
# Sodium sky glow near the horizon at night.
glow = wn_.new("ShaderNodeMath")
glow.operation = "POWER"
horizon = wn_.new("ShaderNodeMath")
horizon.operation = "SUBTRACT"
horizon.inputs[0].default_value = 1.0
nz_abs = wn_.new("ShaderNodeMath")
nz_abs.operation = "ABSOLUTE"
wl_.new(sepw.outputs["Z"], nz_abs.inputs[0])
wl_.new(nz_abs.outputs[0], horizon.inputs[1])
wl_.new(horizon.outputs[0], glow.inputs[0])
glow.inputs[1].default_value = 6.0
glow_col = wn_.new("ShaderNodeMix")
glow_col.data_type = "RGBA"
wl_.new(glow.outputs[0], glow_col.inputs[0])
wl_.new(night.outputs[0], glow_col.inputs[6])
glow_col.inputs[7].default_value = (0.03, 0.014, 0.007, 1)
blend = wn_.new("ShaderNodeMix")
blend.data_type = "RGBA"
blend.name = "day night"
wl_.new(glow_col.outputs[2], blend.inputs[6])
sky_scale = wn_.new("ShaderNodeMix")
sky_scale.data_type = "RGBA"
sky_scale.blend_type = "MULTIPLY"
sky_scale.inputs[0].default_value = 1.0
sky_scale.name = "sky scale"
wl_.new(sky.outputs["Color"], sky_scale.inputs[6])
wl_.new(sky_scale.outputs[2], blend.inputs[7])
wl_.new(blend.outputs[2], bg.inputs["Color"])

sun_data = bpy.data.lights.new("sun", "SUN")
sun_data.angle = math.radians(0.6)
sun = bpy.data.objects.new("sun", sun_data)
scene.collection.objects.link(sun)

# The camera.
cam_data = bpy.data.cameras.new("camera")
cam_data.sensor_fit = "VERTICAL"
cam_data.clip_start = 0.01
cam_data.clip_end = 3000
camera = bpy.data.objects.new("camera", cam_data)
scene.collection.objects.link(camera)
scene.camera = camera

SHOTS = {  # position, target, vertical fov, f-stop: RoomScene.shot(_:)
    "wide": ((0.02, 0.62, 1.55), (-0.12, 0.36, -0.3), 42, 4.0),   # the plate alone gets a little depth
    "medium": ((0.06, 0.42, 0.74), (-0.02, 0.1, -0.06), 40, 5.6),
    "close": ((0.27, 0.215, 0.29), (0.02, 0.11, 0.0), 36, 2.8),
    "above": ((0.0, 0.98, 0.16), (0.0, 0.09, -0.01), 40, 0),
}

# Hours: DayCycle.swift's keyframes, one plate each. Sun direction as in updateEnvironment.
# The sky is physical (multiple scattering); the sun lamp is set from it, and each plate is
# metered like a photograph, to a key that follows the time of day.
HOURS = {  # hour, sun elevation, sun colour, lamp, key (median grey the eye adapts to)
    "night": (0.0, -0.3, (0.5, 0.6, 1.0), 1.0, 0.05),
    "dawn": (6.3, 0.05, (1.0, 0.6, 0.36), 0.4, 0.11),
    "morning": (7.5, 0.25, (1.0, 0.85, 0.68), 0.0, 0.16),
    "noon": (12.0, 1.05, (1.0, 0.97, 0.93), 0.0, 0.2),
    "afternoon": (16.0, 0.55, (1.0, 0.9, 0.76), 0.0, 0.19),
    "golden": (17.6, 0.2, (1.0, 0.62, 0.32), 0.1, 0.16),
    "dusk": (19.0, -0.02, (1.0, 0.45, 0.25), 0.6, 0.1),
}


def sun_direction(hour, elevation):
    sweep = min(1, max(-1, (hour - 12.8) / 6.5))
    e = max(0.08, elevation)
    d = Vector((sweep * 0.7, -math.sin(e), math.cos(e)))     # SceneKit, the way the light travels
    return d.normalized()


def render_exr(path, w, h, samples):
    """A quick linear, denoised render, for metering (a noisy one's median reads far too dark)."""
    fmt = scene.render.image_settings.file_format
    old = scene.cycles.samples, scene.cycles.use_denoising
    scene.render.image_settings.file_format = "OPEN_EXR"
    scene.cycles.samples, scene.cycles.use_denoising = samples, True
    scene.render.resolution_x, scene.render.resolution_y = w, h
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    scene.render.image_settings.file_format = fmt
    scene.cycles.samples, scene.cycles.use_denoising = old
    img = bpy.data.images.load(path)
    px = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)[::-1, :, :3]
    bpy.data.images.remove(img)
    os.remove(path)
    return px


def luminance(px):
    return px[..., 0] * 0.2126 + px[..., 1] * 0.7152 + px[..., 2] * 0.0722


def sky_irradiance():
    """Horizontal irradiance from the sky alone, from a tiny equirect of the world."""
    hidden = [(c, c.hide_render) for c in collections.values()]
    for c, _ in hidden:
        c.hide_render = True
    sun_hidden = sun.hide_render
    sun.hide_render = True
    cam_data.type, cam_data.panorama_type = "PANO", "EQUIRECTANGULAR"
    camera.location, camera.rotation_euler = (0, 0, 0), (math.pi / 2, 0, 0)
    px = luminance(render_exr(os.path.join(OUT, "_sky.exr"), 128, 64, 16))
    cam_data.type = "PERSP"
    for c, h in hidden:
        c.hide_render = h
    sun.hide_render = sun_hidden
    rows = px.shape[0]
    elev = (0.5 - (np.arange(rows) + 0.5) / rows) * math.pi   # top row looks up
    weight = np.clip(np.sin(elev), 0, None) * np.cos(elev)    # cos(zenith) * solid angle
    d_theta, d_phi = math.pi / rows, 2 * math.pi / px.shape[1]
    return float((px.mean(axis=1) * px.shape[1] * weight).sum() * d_theta * d_phi)


def set_hour(tag):
    hour, elev, sun_col, lamp_v, _ = HOURS[tag]
    d_b = V(*sun_direction(hour, elev))
    sun.rotation_euler = d_b.to_track_quat("-Z", "Y").to_euler()
    sun_data.color = sun_col
    to_sun = -d_b
    sky.sun_elevation = math.asin(max(-1, min(1, to_sun.z))) if elev > 0 else elev
    sky.sun_rotation = math.atan2(to_sun.x, to_sun.y)
    day = max(0.0, min(1.0, (elev + 0.12) / 0.15))
    world.node_tree.nodes["day night"].inputs[0].default_value = day
    BULB.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"].default_value = 40.0 * lamp_v
    lamp_light.energy = 30.0 * lamp_v
    lamp_obj.hide_render = lamp_v <= 0
    sun.hide_render = True
    e_sky = sky_irradiance()
    # Clear-but-hazy sky: direct sun is a few times the diffuse sky, less near the horizon.
    ratio = 1.0 + 5.0 * min(1.0, max(0.0, elev) / 0.3)
    sun_data.energy = ratio * e_sky if elev > 0 else 0.0
    sun.hide_render = elev <= 0
    print(f"HOUR {tag}: sky irradiance {e_sky:.3f}, sun {sun_data.energy:.3f}", flush=True)
    if "--debug-light" in argv:
        for link in list(bg.inputs["Color"].links):
            world.node_tree.links.remove(link)
        bg.inputs["Color"].default_value = (1, 1, 1, 1)
        sun.hide_render = True



def meter(key):
    """Expose like the eye: the frame's median brightness lands on the hour's key."""
    scene.view_settings.exposure = 0
    px = luminance(render_exr(os.path.join(OUT, "_meter.exr"), 192, 120, 48))
    blocks = px.reshape(15, 8, 24, 8).mean(axis=(1, 3))
    median = float(np.median(blocks))
    ev = math.log2(key / max(median, 1e-6))
    scene.view_settings.exposure = ev
    return ev


def set_shot(name):
    pos, target, fov, fstop = SHOTS[name]
    p, t = V(*pos), V(*target)
    camera.location = p
    camera.rotation_euler = (t - p).to_track_quat("-Z", "Y").to_euler()
    cam_data.angle_y = math.radians(fov)
    cam_data.dof.use_dof = fstop > 0
    if fstop > 0:
        stylus = V(SPINDLE[0], RECORD_TOP, SPINDLE[1] + 0.05)
        cam_data.dof.focus_distance = (stylus - p).length
        cam_data.dof.aperture_fstop = fstop


# ----------------------------------------------------------------- render

scene.render.engine = "CYCLES"
prefs = bpy.context.preferences.addons["cycles"].preferences
try:
    prefs.compute_device_type = "METAL"
    prefs.get_devices()
    for dev in prefs.devices:
        dev.use = dev.type == "METAL"
    scene.cycles.device = "GPU"
except Exception as exc:  # no GPU: still renders, slowly
    print("GPU unavailable:", exc)
scene.cycles.samples = SAMPLES
scene.cycles.adaptive_threshold = 0.015
scene.cycles.use_denoising = True
scene.cycles.denoiser = "OPENIMAGEDENOISE"
scene.cycles.max_bounces = 10
scene.cycles.diffuse_bounces = 6
scene.cycles.glossy_bounces = 6
scene.cycles.transmission_bounces = 8
scene.cycles.caustics_reflective = False
scene.cycles.caustics_refractive = False
scene.cycles.sample_clamp_indirect = 8.0
scene.cycles.blur_glossy = 1.0
scene.view_settings.view_transform = "AgX"
try:
    scene.view_settings.look = "AgX - Medium High Contrast"
except TypeError:
    pass
scene.render.film_transparent = False
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_depth = "8"
scene.render.image_settings.color_mode = "RGBA"

live = coll(LIVE)
live.hide_render = not REFERENCE


def render(path, w, h, transparent=False):
    scene.render.resolution_x, scene.render.resolution_y = w, h
    scene.render.resolution_percentage = 100
    scene.render.filepath = path
    scene.render.film_transparent = transparent
    bpy.ops.render.render(write_still=True)
    scene.render.film_transparent = False
    print("WROTE", path, flush=True)


def view_card():
    """Where the photo card lands in this shot's frame (0-1, top-left origin), and how much
    the lens blurs it: the circle of confusion at infinity, as a fraction of the frame height."""
    from bpy_extras.object_utils import world_to_camera_view
    scene.render.resolution_x, scene.render.resolution_y = W, H
    cx, cy, cz = VIEW_CENTRE
    pts = [world_to_camera_view(scene, camera, V(cx + sx * VIEW_W / 2, cy + sy * VIEW_H / 2, cz))
           for sx in (-1, 1) for sy in (-1, 1)]
    xs, ys = [p.x for p in pts], [p.y for p in pts]
    coc = 0.0
    if cam_data.dof.use_dof:
        f, n = cam_data.lens, cam_data.dof.aperture_fstop
        coc = f * f / (n * (cam_data.dof.focus_distance * 1000 - f)) / cam_data.sensor_height
    return {"rect": [round(min(xs), 4), round(1 - max(ys), 4), round(max(xs), 4), round(1 - min(ys), 4)],
            "blur": round(coc, 5)}


wanted = None if not ONLY else {tuple(s.split(":")) for s in ONLY.split(",")}
manifest = {}
views = {}
for tag in HOURS:
    if wanted and not any(t == tag for _, t in wanted):
        continue
    set_hour(tag)
    for shot in SHOTS:
        if wanted and (shot, tag) not in wanted:
            continue
        set_shot(shot)
        views[shot] = view_card()
        ev = meter(HOURS[tag][4])
        manifest[f"{shot}-{tag}"] = round(ev, 3)
        print(f"EXPOSURE {shot}-{tag}: {ev:+.2f} EV", flush=True)
        if not PROBES_ONLY:
            render(os.path.join(OUT, f"{shot}-{tag}{'-ref' if REFERENCE else ''}.png"), W, H, transparent=True)
        if NO_PROBES:
            continue
        # Light probe at the record, exposed like this plate: what the app's record and arm reflect.
        cam_data.type, cam_data.panorama_type = "PANO", "EQUIRECTANGULAR"
        dof = cam_data.dof.use_dof
        cam_data.dof.use_dof = False
        camera.location = V(SPINDLE[0], RECORD_TOP + 0.12, SPINDLE[1] + 0.05)
        camera.rotation_euler = (math.pi / 2, 0, 0)    # image centre looks at the window
        live.hide_render = True
        samples = scene.cycles.samples
        scene.cycles.samples = 96
        render(os.path.join(OUT, f"probe-{shot}-{tag}.png"), 1024, 512)
        scene.cycles.samples = samples
        live.hide_render = not REFERENCE
        cam_data.type = "PERSP"
        cam_data.dof.use_dof = dof

import json
path = os.path.join(OUT, "exposures.json")
old = json.load(open(path)) if os.path.exists(path) else {}
json.dump({**old, **manifest}, open(path, "w"), indent=1, sort_keys=True)
vpath = os.path.join(OUT, "views.json")
oldv = json.load(open(vpath)) if os.path.exists(vpath) else {}
json.dump({**oldv, **views}, open(vpath, "w"), indent=1, sort_keys=True)

# ---------------------------------------------------------------- plant masks
# Where the plant is in each framing (alpha = coverage, through the same lens), so the
# app can let its leaves sway in a breeze.
if not PROBES_ONLY and not REFERENCE and (not ONLY or "--masks" in argv):
    def flat(name, kind):
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        nt = m.node_tree
        nt.nodes.clear()
        out = nt.nodes.new("ShaderNodeOutputMaterial")
        nt.links.new(nt.nodes.new(kind).outputs[0], out.inputs[0])
        return m
    white, hold = flat("mask_plant", "ShaderNodeEmission"), flat("mask_hold", "ShaderNodeHoldout")
    leaves = set(plant)
    for ob in scene.objects:
        if ob.type not in {"MESH", "CURVE"}:
            continue
        m = white if ob in leaves else hold
        if not ob.material_slots:
            ob.data.materials.append(m)
        for slot in ob.material_slots:
            slot.link = "OBJECT"
            slot.material = m
    scene.cycles.samples = 16
    set_hour("noon")
    for shot in SHOTS:
        set_shot(shot)
        render(os.path.join(OUT, f"plant-{shot}.png"), W // 2, H // 2, transparent=True)
