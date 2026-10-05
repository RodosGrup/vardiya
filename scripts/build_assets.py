"""Kenney (CC0) paketlerinden Vardiya'nın 3D varlıklarını üretir.

- Mobilyalar: GLB → USDZ (macOS'un usdcat/usdzip araçlarıyla).
- Karakterler: RealityKit iskeletli GLB'yi içe aktaramıyor; karakterler zaten blok
  parçalardan oluştuğu için her üçgeni bağlı olduğu ekleme göre ayırıp eklem
  hiyerarşisinde katı parçalar olarak yazıyoruz. Uygulama parçaları doğrudan döndürüyor.
- Animasyonlar: GLB'deki klipler (idle, walk, sit…) JSON olarak çıkarılıyor.

Çalıştırma: python3 scripts/build_assets.py
"""
import json
import os
import shutil
import struct
import subprocess
import sys
import urllib.request
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CACHE = os.path.join(ROOT, "build", "kenney")
OUT = os.path.join(ROOT, "Vardiya", "Resources", "Models")

PACKS = {
    "mini": "https://kenney.nl/media/pages/assets/mini-characters/bfc7e272b4-1774770718/kenney_mini-characters.zip",
    "furniture": "https://kenney.nl/media/pages/assets/furniture-kit/440e0608a4-1677580847/kenney_furniture-kit.zip",
}

FURNITURE = [
    "desk", "chairDesk", "laptop", "computerScreen", "computerKeyboard", "computerMouse",
    "toilet", "bathroomSink", "kitchenCoffeeMachine", "kitchenBar", "kitchenFridgeSmall",
    "pottedPlant", "plantSmall1", "plantSmall2", "lampSquareTable", "lampRoundFloor",
    "trashcan", "books", "bookcaseOpen", "cardboardBoxClosed", "loungeSofa", "rugRectangle",
    "wall", "wallWindow", "wallDoorway", "doorwayOpen", "floorFull", "coatRackStanding", "speakerSmall",
    "lampSquareCeiling", "lampRoundTable", "tableRound", "chair", "kitchenCabinet",
]

CHARACTERS = [f"character-{g}-{v}" for g in ("male", "female") for v in "abcdef"]
CLIPS = ["idle", "walk", "sit", "interact-right", "interact-left", "emote-yes", "emote-no", "pick-up", "holding-both", "die"]


def fetch():
    os.makedirs(CACHE, exist_ok=True)
    for name, url in PACKS.items():
        target = os.path.join(CACHE, name)
        if os.path.isdir(target):
            continue
        zpath = target + ".zip"
        print("indiriliyor:", url)
        urllib.request.urlretrieve(url, zpath)
        with zipfile.ZipFile(zpath) as z:
            z.extractall(target)


# MARK: - GLB okuma

def load_glb(path):
    data = open(path, "rb").read()
    json_len = struct.unpack("<I", data[12:16])[0]
    gltf = json.loads(data[20:20 + json_len])
    bin_start = 20 + json_len + 8
    return gltf, data[bin_start:]


COMPONENTS = {5120: "b", 5121: "B", 5122: "h", 5123: "H", 5125: "I", 5126: "f"}
COUNTS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def accessor(gltf, binary, index):
    acc = gltf["accessors"][index]
    view = gltf["bufferViews"][acc["bufferView"]]
    fmt = COMPONENTS[acc["componentType"]]
    n = COUNTS[acc["type"]]
    size = struct.calcsize(fmt)
    stride = view.get("byteStride", size * n)
    start = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
    out = []
    for i in range(acc["count"]):
        off = start + i * stride
        vals = struct.unpack_from("<" + fmt * n, binary, off)
        if acc.get("normalized") and fmt != "f":
            maxv = float((1 << (8 * size)) - 1)
            vals = tuple(v / maxv for v in vals)
        out.append(vals if n > 1 else vals[0])
    return out


def mat_mul_point(m, p):
    # glTF matrisleri sütun öncelikli
    x, y, z = p
    return (
        m[0] * x + m[4] * y + m[8] * z + m[12],
        m[1] * x + m[5] * y + m[9] * z + m[13],
        m[2] * x + m[6] * y + m[10] * z + m[14],
    )


def mat_mul_dir(m, d):
    x, y, z = d
    v = (m[0] * x + m[4] * y + m[8] * z, m[1] * x + m[5] * y + m[9] * z, m[2] * x + m[6] * y + m[10] * z)
    l = max(1e-9, (v[0] ** 2 + v[1] ** 2 + v[2] ** 2) ** 0.5)
    return (v[0] / l, v[1] / l, v[2] / l)


def prim_name(name):
    return name.replace("-", "_")


# MARK: - Karakter → parçalı USDA

def convert_character(src, name, out_dir):
    gltf, binary = load_glb(src)
    nodes = gltf["nodes"]
    skin = gltf["skins"][0]
    joints = skin["joints"]
    ibm = accessor(gltf, binary, skin["inverseBindMatrices"])

    # eklem → (ebeveyn, durağan konum)
    parent = {}
    for i, node in enumerate(nodes):
        for c in node.get("children", []):
            parent[c] = i

    parts = {j: {"points": [], "normals": [], "uvs": [], "indices": []} for j in joints}
    for node in nodes:
        if "mesh" not in node:
            continue
        for prim in gltf["meshes"][node["mesh"]]["primitives"]:
            attrs = prim["attributes"]
            pos = accessor(gltf, binary, attrs["POSITION"])
            nor = accessor(gltf, binary, attrs["NORMAL"])
            uv = accessor(gltf, binary, attrs["TEXCOORD_0"])
            jnt = accessor(gltf, binary, attrs["JOINTS_0"])
            wgt = accessor(gltf, binary, attrs["WEIGHTS_0"])
            idx = accessor(gltf, binary, prim["indices"])
            for t in range(0, len(idx), 3):
                tri = idx[t:t + 3]
                # Blok karakter: her köşe tek bir ekleme tam ağırlıkla bağlı. Üçgeni ilk köşenin
                # en ağır ekleminin parçasına koyuyoruz.
                v0 = tri[0]
                k = max(range(4), key=lambda q: wgt[v0][q])
                ji = jnt[v0][k]
                joint_node = joints[ji]
                part = parts[joint_node]
                for v in tri:
                    # Bağlanma pozundaki köşeyi eklemin yerel uzayına taşı.
                    p = mat_mul_point(ibm[ji], pos[v])
                    n = mat_mul_dir(ibm[ji], nor[v])
                    part["indices"].append(len(part["points"]))
                    part["points"].append(p)
                    part["normals"].append(n)
                    part["uvs"].append((uv[v][0], 1.0 - uv[v][1]))

    def fmt3(v):
        return "(%.5f, %.5f, %.5f)" % v

    def fmt2(v):
        return "(%.5f, %.5f)" % v

    lines = [
        "#usda 1.0",
        "(",
        '    defaultPrim = "%s"' % prim_name(name),
        '    upAxis = "Y"',
        "    metersPerUnit = 1",
        ")",
        "",
        'def Xform "%s"' % prim_name(name),
        "{",
        '    def Scope "Materials"',
        "    {",
        '        def Material "colormap"',
        "        {",
        '            token outputs:surface.connect = </%s/Materials/colormap/Surface.outputs:surface>' % prim_name(name),
        '            def Shader "Surface"',
        "            {",
        '                uniform token info:id = "UsdPreviewSurface"',
        '                color3f inputs:diffuseColor.connect = </%s/Materials/colormap/Texture.outputs:rgb>' % prim_name(name),
        "                float inputs:roughness = 0.75",
        "                float inputs:metallic = 0",
        "                token outputs:surface",
        "            }",
        '            def Shader "Texture"',
        "            {",
        '                uniform token info:id = "UsdUVTexture"',
        "                asset inputs:file = @Textures/colormap.png@",
        '                float2 inputs:st.connect = </%s/Materials/colormap/UV.outputs:result>' % prim_name(name),
        '                token inputs:wrapS = "repeat"',
        '                token inputs:wrapT = "repeat"',
        "                float3 outputs:rgb",
        "            }",
        '            def Shader "UV"',
        "            {",
        '                uniform token info:id = "UsdPrimvarReader_float2"',
        '                string inputs:varname = "st"',
        "                float2 outputs:result",
        "            }",
        "        }",
        "    }",
    ]

    def emit(node_index, depth):
        node = nodes[node_index]
        pad = "    " * depth
        t = node.get("translation", [0, 0, 0])
        lines.append('%sdef Xform "%s"' % (pad, prim_name(node["name"])))
        lines.append(pad + "{")
        lines.append('%s    double3 xformOp:translate = (%.6f, %.6f, %.6f)' % (pad, t[0], t[1], t[2]))
        lines.append('%s    uniform token[] xformOpOrder = ["xformOp:translate"]' % pad)
        part = parts.get(node_index)
        if part and part["points"]:
            count = len(part["points"]) // 3
            lines.extend([
                '%s    def Mesh "mesh" (prepend apiSchemas = ["MaterialBindingAPI"])' % pad,
                pad + "    {",
                "%s        int[] faceVertexCounts = [%s]" % (pad, ", ".join(["3"] * count)),
                "%s        int[] faceVertexIndices = [%s]" % (pad, ", ".join(map(str, part["indices"]))),
                "%s        point3f[] points = [%s]" % (pad, ", ".join(map(fmt3, part["points"]))),
                '%s        normal3f[] normals = [%s] (interpolation = "vertex")' % (pad, ", ".join(map(fmt3, part["normals"]))),
                '%s        texCoord2f[] primvars:st = [%s] (interpolation = "vertex")' % (pad, ", ".join(map(fmt2, part["uvs"]))),
                '%s        uniform token subdivisionScheme = "none"' % pad,
                "%s        rel material:binding = </%s/Materials/colormap>" % (pad, prim_name(name)),
                pad + "    }",
            ])
        for c in node.get("children", []):
            if c in parts or "children" in nodes[c]:
                emit(c, depth + 1)
        lines.append(pad + "}")

    root_joint = joints[0]
    emit(root_joint, 1)
    lines.append("}")

    work = os.path.join(CACHE, "work", name)
    os.makedirs(os.path.join(work, "Textures"), exist_ok=True)
    usda = os.path.join(work, name + ".usda")
    open(usda, "w").write("\n".join(lines) + "\n")
    tex_src = os.path.join(os.path.dirname(src), "Textures", "colormap.png")
    shutil.copy(tex_src, os.path.join(work, "Textures", "colormap.png"))
    out = os.path.join(out_dir, name + ".usdz")
    if os.path.exists(out):
        os.remove(out)
    subprocess.run(["usdzip", out, name + ".usda", "Textures/colormap.png"], cwd=work, check=True, capture_output=True)
    return gltf, binary


def extract_clips(gltf, binary):
    nodes = gltf["nodes"]
    clips = {}
    for anim in gltf.get("animations", []):
        if anim["name"] not in CLIPS:
            continue
        channels = {}
        duration = 0.0
        for ch in anim["channels"]:
            sampler = anim["samplers"][ch["sampler"]]
            times = accessor(gltf, binary, sampler["input"])
            values = accessor(gltf, binary, sampler["output"])
            path = ch["target"]["path"]
            if path not in ("rotation", "translation"):
                continue
            joint = prim_name(nodes[ch["target"]["node"]]["name"])
            duration = max(duration, times[-1])
            channels.setdefault(joint, {})[path] = {
                "t": [round(x, 4) for x in times],
                "v": [[round(c, 5) for c in v] for v in values],
                "step": sampler.get("interpolation") == "STEP",
            }
        clips[anim["name"]] = {"duration": round(duration, 4), "channels": channels}
    rest = {prim_name(n["name"]): n.get("translation", [0, 0, 0]) for n in nodes}
    return {"clips": clips, "rest": rest}


def convert_furniture(src, name, out_dir):
    work = os.path.join(CACHE, "work", "furniture")
    os.makedirs(work, exist_ok=True)
    usdc = os.path.join(work, name + ".usdc")
    subprocess.run(["usdcat", src, "-o", usdc], check=True, capture_output=True)
    out = os.path.join(out_dir, name + ".usdz")
    if os.path.exists(out):
        os.remove(out)
    subprocess.run(["usdzip", out, name + ".usdc"], cwd=work, check=True, capture_output=True)


def main():
    fetch()
    os.makedirs(OUT, exist_ok=True)
    glb_chars = os.path.join(CACHE, "mini", "Models", "GLB format")
    glb_furn = os.path.join(CACHE, "furniture", "Models", "GLTF format")

    anims = None
    for c in CHARACTERS:
        gltf, binary = convert_character(os.path.join(glb_chars, c + ".glb"), c, OUT)
        if anims is None:
            anims = extract_clips(gltf, binary)
        print("karakter:", c)
    json.dump(anims, open(os.path.join(OUT, "animations.json"), "w"), separators=(",", ":"))

    for f in FURNITURE:
        convert_furniture(os.path.join(glb_furn, f + ".glb"), f, OUT)
    print("mobilya:", len(FURNITURE))

    shutil.copy(os.path.join(CACHE, "mini", "License.txt"), os.path.join(OUT, "LICENSE-kenney.txt"))


if __name__ == "__main__":
    sys.exit(main())
