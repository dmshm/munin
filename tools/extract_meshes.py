#!/usr/bin/env python3
"""Extract real meshes from a local Valheim install: every build piece, and with
--world also the trees, rocks and other props that world contains.

The game's assets are not ours to commit, so the app ships without meshes and this
script builds a catalog from whatever copy of Valheim is on the machine:

    catalog.json   prefab name -> kind and parts (byte ranges into catalog.bin,
                   colour, texture, normal map, alpha cutoff)
    catalog.bin    float32 positions/normals/uvs and uint32 indices, back to back
    textures/      main textures (JPEG, or PNG when alpha cuts holes) and normal maps

Geometry stays in Valheim's own frame (Unity: left-handed, y up, z forward), baked
relative to the prefab's pivot. Only what the game shows for an intact object is
kept: active objects, no worn/broken/snow variants, LOD0 for pieces and a lighter
LOD for props (a forest of LOD0 trees is millions of triangles).

Needs UnityPy and numpy (pip install UnityPy numpy). Loading every bundle at once
is what lets cross-bundle references resolve, and costs ~6 GB of RAM and a few minutes.
"""
import argparse
import json
import math
import os
import struct
import sys
import time
from pathlib import Path

import texture2ddecoder
import UnityPy
from UnityPy.helpers.MeshHelper import MeshHandler
from UnityPy.helpers.ResourceReader import get_resource_data
import numpy as np
from PIL import Image

DEFAULT_GAME = Path.home() / 'Library/Application Support/Steam/steamapps/common/Valheim/valheim.app/Contents/Resources/Data'
DEFAULT_OUT = Path.home() / 'Library/Application Support/Munin/catalog'


# --- small linear algebra (row-major 4x4, column vectors, like Unity) --------

def trs(t, q, s):
    x, y, z, w = q.x, q.y, q.z, q.w
    r = [
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ]
    sc = (s.x, s.y, s.z)
    return [[r[i][0] * sc[0], r[i][1] * sc[1], r[i][2] * sc[2], (t.x, t.y, t.z)[i]] for i in range(3)] + [[0, 0, 0, 1]]


def mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


IDENTITY = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]


def det3(m):
    return (m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]))


# --- unity object helpers -----------------------------------------------------

def component_ptrs(go):
    for c in go.m_Component:
        yield c.component if hasattr(c, 'component') else c


def components(go):
    """(type name, reader) for each component that resolves."""
    for ptr in component_ptrs(go):
        try:
            reader = ptr.deref()
        except Exception:
            continue
        yield reader.type.name, reader


def script_name(reader):
    try:
        return reader.read().m_Script.read().m_Name
    except Exception:
        return None


def props(entries):
    """m_SavedProperties lists come back as [(name, value)] or dicts depending on version."""
    if entries is None:
        return {}
    if isinstance(entries, dict):
        return entries
    out = {}
    for e in entries:
        if isinstance(e, tuple):
            out[e[0]] = e[1]
        else:
            out[getattr(e, 'first', None)] = getattr(e, 'second', None)
    return out


# --- per-piece extraction -----------------------------------------------------

class Extractor:
    def __init__(self, out, texture_size):
        self.out = out
        self.size = texture_size
        self.blob = bytearray()
        self.textures = {}  # (file, path_id, normal) -> texture() result
        (out / 'textures').mkdir(parents=True, exist_ok=True)

    def texture(self, tex_ptr, normal=False, cutoff=None):
        """Save one texture; returns {name, avg (sRGB 0..1), cutout, point} or None."""
        if not tex_ptr or not tex_ptr.path_id:
            return None
        key = (getattr(tex_ptr.assetsfile, 'name', ''), tex_ptr.path_id, normal)
        if key in self.textures:
            return self.textures[key]
        result = None
        try:
            tex = tex_ptr.read()
            img = tex.image.convert('RGBA')
            img.thumbnail((self.size, self.size), Image.LANCZOS)
            px = np.asarray(img).astype(np.float32) / 255
            stem = f'{tex.m_Name}_{abs(tex_ptr.path_id) % 10**8}'.replace('/', '_')
            # Valheim's textures are small (64–512 px) by design; small ones stay lossless.
            lossless = max(img.size) <= 256
            settings = getattr(tex, 'm_TextureSettings', None)
            point = getattr(settings, 'm_FilterMode', 1) == 0
            if normal:
                rgb = Image.fromarray(decode_normal(px))
                name = stem + ('_n.png' if lossless else '_n.jpg')
                rgb.save(self.out / 'textures' / name, **({'optimize': True} if lossless else {'quality': 92}))
                result = {'name': name, 'avg': None, 'cutout': False, 'point': point}
            else:
                alpha = px[..., 3]
                holes = float((alpha < (cutoff or 0.5)).mean())
                # Valheim alpha-tests nearly every material, but only some textures use
                # alpha for shape (thatch edges, leaves); fully opaque ones never cut.
                cutout = cutoff is not None and cutoff > 0 and 0.002 < holes < 0.97
                solid = px[alpha >= (cutoff or 0.5)] if cutout else px.reshape(-1, 4)
                avg = solid[:, :3].mean(axis=0) if len(solid) else px[..., :3].mean(axis=(0, 1))
                if cutout:
                    name = stem + '.png'
                    img.save(self.out / 'textures' / name, optimize=True)
                elif lossless:
                    name = stem + '.png'
                    img.convert('RGB').save(self.out / 'textures' / name, optimize=True)
                else:
                    name = stem + '.jpg'
                    img.convert('RGB').save(self.out / 'textures' / name, quality=92)
                result = {'name': name, 'avg': [float(c) for c in avg], 'cutout': cutout, 'point': point}
        except Exception:
            pass
        self.textures[key] = result
        return result

    def material(self, mat_ptr):
        """Colour (sRGB 0..1), textures, UV tiling and alpha cutoff of a material."""
        try:
            mat = mat_ptr.read()
        except Exception:
            return {'color': [0.6, 0.6, 0.6], 'tint': [1, 1, 1], 'texture': None, 'normalMap': None, 'cutoff': None, 'st': (1, 1, 0, 0), 'point': False}
        saved = mat.m_SavedProperties
        tex_envs = props(saved.m_TexEnvs)
        colors = props(saved.m_Colors)
        floats = props(saved.m_Floats)
        tint = colors.get('_Color')
        tint = [tint.r, tint.g, tint.b] if tint is not None else [1, 1, 1]
        cutoff = floats.get('_Cutoff')
        main = tex_envs.get('_MainTex')
        diffuse = self.texture(main.m_Texture, cutoff=cutoff) if main is not None else None
        st = (main.m_Scale.x, main.m_Scale.y, main.m_Offset.x, main.m_Offset.y) if main is not None else (1, 1, 0, 0)
        bump = tex_envs.get('_BumpMap')
        normal = self.texture(bump.m_Texture, normal=True) if bump is not None else None
        # Grass is white in its own texture and coloured from a world-space map.
        tc = tex_envs.get('_TerrainColorTex')
        terrain_color = self.texture(tc.m_Texture) if tc is not None else None
        base = (diffuse or {}).get('avg') or [0.6, 0.6, 0.6]
        return {
            'color': [min(1, b * t) for b, t in zip(base, tint)],
            'tint': [round(min(1, t), 4) for t in tint],
            'texture': diffuse and diffuse['name'],
            'normalMap': normal and normal['name'],
            'cutoff': round(float(cutoff), 3) if diffuse and diffuse['cutout'] else None,
            'point': bool(diffuse and diffuse['point']),
            'st': st,
            'terrainColor': terrain_color and terrain_color['name'],
            'terrainColorScale': float(floats.get('_TerrainColorScale', 0.01)) if terrain_color else None,
        }

    def lod_excluded(self, go, level):
        """Renderers of every LOD under go except `level` (or the last one, if fewer)."""
        excluded = set()
        stack = [go]
        while stack:
            g = stack.pop()
            for name, reader in components(g):
                if name == 'LODGroup':
                    lods = reader.read().m_LODs
                    keep = min(level, len(lods) - 1)
                    for i, lod in enumerate(lods):
                        if i != keep:
                            for r in lod.renderers:
                                ptr = r.renderer if hasattr(r, 'renderer') else r
                                excluded.add(ptr.path_id)
                    for r in lods[keep].renderers if lods else []:
                        ptr = r.renderer if hasattr(r, 'renderer') else r
                        excluded.discard(ptr.path_id)
            tr = next((rd for n, rd in components(g) if n == 'Transform'), None)
            if tr:
                for ch in tr.read().m_Children:
                    try:
                        stack.append(ch.read().m_GameObject.read())
                    except Exception:
                        pass
        return excluded

    def instanced(self, mesh_ptr, material_ptr, scale):
        """A clutter prefab drawn by the game's InstanceRenderer: one mesh, one material."""
        by_material = {}
        m = [[scale[0], 0, 0, 0], [0, scale[1], 0, 0], [0, 0, scale[2], 0], [0, 0, 0, 1]]
        self.add_mesh(by_material, mesh_ptr, [material_ptr], m)
        return self.flush(by_material)

    def piece(self, go, lod=0):
        excluded = self.lod_excluded(go, lod)
        by_material = {}  # material key -> part accumulator
        lights = []
        fire = None

        def walk(transform, matrix, is_root, lights_only=False):
            nonlocal fire
            g = transform.m_GameObject.read()
            # Fires keep a low-quality copy of their light and flames for low settings.
            if g.m_Name == '_enabled_low':
                return
            if not g.m_IsActive:
                # A fire's light and flames sit in a subtree the game switches on while
                # it burns: take its lights, but not its meshes.
                if g.m_Name not in ('_enabled', '_enabled_high'):
                    return
                lights_only = True
            if not is_root:
                matrix = mul(matrix, trs(transform.m_LocalPosition, transform.m_LocalRotation, transform.m_LocalScale))
            mesh_ptr = None
            renderer = None
            flicker = None
            light = None
            for name, reader in components(g):
                if name == 'MeshFilter':
                    mesh_ptr = reader.read().m_Mesh
                elif name in ('MeshRenderer', 'SkinnedMeshRenderer'):
                    renderer = (name, reader)
                elif name == 'Light':
                    light = reader.read()
                elif name == 'MonoBehaviour' and script_name(reader) in ('LightFlicker', 'Fireplace'):
                    tree = reader.read_typetree()
                    if 'm_flickerIntensity' in tree:
                        flicker = {'intensity': float(tree['m_flickerIntensity']), 'speed': float(tree['m_flickerSpeed']),
                                   'movement': float(tree.get('m_movement', 0))}
                    elif 'm_startFuel' in tree:
                        fire = {'startFuel': float(tree['m_startFuel']), 'maxFuel': float(tree['m_maxFuel']),
                                'infiniteFuel': bool(tree['m_infiniteFuel'])}
            if light is not None and light.m_Enabled and light.m_Type in (0, 2):  # spot, point
                c = light.m_Color
                lights.append({
                    'position': [round(matrix[i][3], 3) for i in range(3)],
                    'color': [round(c.r, 3), round(c.g, 3), round(c.b, 3)],
                    'intensity': round(float(light.m_Intensity), 3),
                    'range': round(float(light.m_Range), 3),
                    'shadows': int(light.m_Shadows.m_Type) > 0,
                    'flicker': flicker,
                    # On only while the thing burns or works (fires, smelters, kilns).
                    'switched': lights_only,
                })
            if renderer and not lights_only and renderer[1].path_id not in excluded:
                r = renderer[1].read()
                if getattr(r, 'm_Enabled', True):
                    if renderer[0] == 'SkinnedMeshRenderer':
                        mesh_ptr = r.m_Mesh
                    if mesh_ptr is not None and mesh_ptr.path_id:
                        self.add_mesh(by_material, mesh_ptr, r.m_Materials, matrix)
            for ch in transform.m_Children:
                try:
                    walk(ch.read(), matrix, False, lights_only)
                except Exception:
                    pass

        root_tr = next(rd for n, rd in components(go) if n == 'Transform').read()
        walk(root_tr, IDENTITY, True)
        entry = self.flush(by_material)
        if entry is not None:
            if lights:
                entry['lights'] = lights
            if fire is not None:
                entry['fire'] = fire
        return entry

    def add_mesh(self, by_material, mesh_ptr, materials, matrix):
        mesh = mesh_ptr.read()
        h = MeshHandler(mesh)
        h.process()
        verts = flat(h.m_Vertices, 3)
        if not verts:
            return
        normals = flat(h.m_Normals, 3)
        uvs = flat(h.m_UV0, 2)
        n = len(verts) // 3
        flip = det3(matrix) < 0
        m = matrix
        pos = []
        nrm = []
        for i in range(n):
            x, y, z = verts[3 * i:3 * i + 3]
            pos += [m[0][0] * x + m[0][1] * y + m[0][2] * z + m[0][3],
                    m[1][0] * x + m[1][1] * y + m[1][2] * z + m[1][3],
                    m[2][0] * x + m[2][1] * y + m[2][2] * z + m[2][3]]
            if len(normals) == len(verts):
                a, b, c = normals[3 * i:3 * i + 3]
                tx, ty, tz = (m[0][0] * a + m[0][1] * b + m[0][2] * c,
                              m[1][0] * a + m[1][1] * b + m[1][2] * c,
                              m[2][0] * a + m[2][1] * b + m[2][2] * c)
                ln = math.sqrt(tx * tx + ty * ty + tz * tz) or 1
                nrm += [tx / ln, ty / ln, tz / ln]
        if len(nrm) != len(pos):
            nrm = []
        if len(uvs) != 2 * n:
            uvs = [0.0] * (2 * n)
        for sub, tris in enumerate(h.get_triangles()):
            if not tris or sub >= len(materials):
                continue
            mat_ptr = materials[sub]
            key = mat_ptr.path_id
            part = by_material.get(key)
            if part is None:
                part = by_material[key] = {'pos': [], 'nrm': [], 'uv': [], 'idx': [], 'mat': self.material(mat_ptr), 'has_nrm': True}
            # Copy only the vertices this submesh uses, renumbered into the part.
            remap = {}
            for t in tris:
                for v in t:
                    if v not in remap:
                        remap[v] = len(part['pos']) // 3
                        part['pos'] += pos[3 * v:3 * v + 3]
                        sx, sy, ox, oy = part['mat']['st']
                        part['uv'] += [uvs[2 * v] * sx + ox, uvs[2 * v + 1] * sy + oy]
                        if nrm:
                            part['nrm'] += nrm[3 * v:3 * v + 3]
                a, b, c = (remap[v] for v in t)
                part['idx'] += [a, c, b] if flip else [a, b, c]
            if not nrm:
                part['has_nrm'] = False

    def flush(self, by_material):
        parts = []
        lo = [math.inf] * 3
        hi = [-math.inf] * 3
        for part in by_material.values():
            if not part['idx']:
                continue
            n = len(part['pos']) // 3
            mat = part['mat']
            entry = {'count': n, 'indices': len(part['idx']), 'color': [round(c, 4) for c in mat['color']],
                     'tint': mat['tint'], 'texture': mat['texture'], 'normalMap': mat['normalMap'], 'cutoff': mat['cutoff'],
                     'point': mat['point']}
            if mat.get('terrainColor'):
                entry['terrainColor'] = mat['terrainColor']
                entry['terrainColorScale'] = mat['terrainColorScale']
            entry['positions'] = self.write('f', part['pos'])
            if part['has_nrm'] and len(part['nrm']) == len(part['pos']):
                entry['normals'] = self.write('f', part['nrm'])
            entry['uvs'] = self.write('f', part['uv'])
            entry['indexOffset'] = self.write('I', part['idx'])
            for i in range(n):
                for a in range(3):
                    v = part['pos'][3 * i + a]
                    lo[a] = min(lo[a], v)
                    hi[a] = max(hi[a], v)
            parts.append(entry)
        if not parts:
            return None
        return {'parts': parts, 'bounds': [[round(v, 3) for v in lo], [round(v, 3) for v in hi]]}

    def write(self, fmt, values):
        offset = len(self.blob)
        self.blob += struct.pack(f'<{len(values)}{fmt}', *values)
        return offset


def flat(data, width):
    if data is None:
        return []
    data = list(data)
    if data and isinstance(data[0], (tuple, list)):
        return [float(c) for v in data for c in v[:width]]
    return [float(v) for v in data]


def decode_normal(px):
    """Unity normal maps arrive as DXT5nm (x in alpha, y in green) or BC5 (x red,
    y green); rebuild an ordinary RGB tangent-space normal map from either."""
    r, g, b, a = (px[..., i] for i in range(4))
    if r.std() < 0.02 and a.std() > 0.02:
        x, y = a, g        # DXT5nm
    elif b.std() < 0.02 and b.mean() < 0.1:
        x, y = r, g        # BC5
    else:
        return (px[..., :3] * 255).astype(np.uint8)  # already RGB
    nx, ny = x * 2 - 1, y * 2 - 1
    nz = np.sqrt(np.clip(1 - nx * nx - ny * ny, 0, 1))
    return ((np.stack([nx, ny, nz], axis=-1) * 0.5 + 0.5).clip(0, 1) * 255).astype(np.uint8)


def stable_hash(s):
    """Valheim's Utils.GetStableHashCode."""
    a = b = 5381
    for i in range(0, len(s), 2):
        a = ((a << 5) + a ^ ord(s[i])) & 0xffffffff
        if i == len(s) - 1:
            break
        b = ((b << 5) + b ^ ord(s[i + 1])) & 0xffffffff
    r = (a + b * 1566083941) & 0xffffffff
    return r - 2**32 if r >= 2**31 else r


def world_prefabs(path):
    """Prefab hashes used in a world: a chunked world directory, or a single-file .db.
    Same layout as app/Sources/MuninCore/WorldReader.swift, minus everything but the prefab."""
    path = Path(path)
    directory = path if path.is_dir() else path.parent
    chunks = sorted(directory.glob('*.chunk'))
    found = set()

    def walk(d, p, count, compact):
        for _ in range(count):
            flags, = struct.unpack_from('<H', d, p); p += 2
            if not compact:
                p += 4
            p += 4 if compact and flags & 0x2000 else 12
            prefab, = struct.unpack_from('<i', d, p); p += 4
            found.add(prefab)
            if flags & 0x1000:
                if compact:
                    first, = struct.unpack_from('<H', d, p)
                    p += 2 if first & 0x8000 else 4
                else:
                    p += 12

            def num():
                nonlocal p
                n = d[p]; p += 1
                if n & 0x80:
                    n = ((n & 0x7f) << 8) | d[p]; p += 1
                return n
            if flags & 0xff:
                if flags & 1: p += 5
                for bit, size in ((2, 8), (4, 16), (8, 20), (16, 8), (32, 12)):
                    if flags & bit:
                        n = num(); p += n * size
                if flags & 64:
                    for _ in range(num()):
                        p += 4; length = shift = 0
                        while True:
                            c = d[p]; p += 1; length |= (c & 0x7f) << shift; shift += 7
                            if not c & 0x80:
                                break
                        p += length
                if flags & 128:
                    for _ in range(num()):
                        p += 4; length, = struct.unpack_from('<i', d, p); p += 4 + length
        return p

    if chunks:
        for c in chunks:
            d = c.read_bytes()
            _, count = struct.unpack_from('<Hi', d, 0)
            walk(d, 6, count, True)
    else:
        d = path.read_bytes()
        count, = struct.unpack_from('<i', d, 24)
        walk(d, 28, count, False)
    return found


# --- discovery ----------------------------------------------------------------

# Mod pieces built in code around a model from the mod's bundle, so no object carries
# the piece's own name: piece name -> model root in the bundle. Pieces named
# "<mod>_<id>" whose model root is just "<id>" are found without an entry here.
MODEL_ALIASES = {
    'sac_feed_trough': 'SM_FeedTrough',  # StoreAndCraft
}


def find_roots(env, wanted, only, extra_names=()):
    """Parentless GameObjects that are build pieces (carry a `Piece` script) or whose
    name hashes to a prefab in `wanted`. Returns name -> (GameObject, kind), kind being
    piece, item (something dropped), creature, or prop (trees, rocks, everything else).

    Several roots can share a name (a bare model and the prefab built around it);
    every saved object comes from a networked prefab, so roots with a ZNetView win.
    `extra_names` are names a mod gives pieces it builds in code, looked up through
    MODEL_ALIASES or by dropping the mod's prefix."""
    found = {}
    scores = {}
    roots_by_name = {}
    for obj in env.objects:
        if obj.type.name != 'GameObject':
            continue
        try:
            name = obj.peek_name()
        except Exception:
            continue
        try:
            go = obj.read()
            comps = list(components(go))
            tr = next(rd for n, rd in comps if n == 'Transform').read()
            if tr.m_Father.path_id:
                continue  # an instance nested inside some other prefab
        except Exception:
            continue
        roots_by_name.setdefault(name, go)
        if (only and name not in only):
            continue
        scripts = {script_name(rd) for n, rd in comps if n == 'MonoBehaviour'}
        if 'Piece' in scripts:
            kind = 'piece'
        elif wanted is not None and stable_hash(name) in wanted:
            kind = 'item' if 'ItemDrop' in scripts else 'creature' if scripts & {'Character', 'Humanoid', 'MonsterAI', 'AnimalAI'} else 'prop'
        else:
            continue
        score = 2 * ('ZNetView' in scripts) + ('Piece' in scripts)
        if name not in found or score > scores[name]:
            found[name] = (go, kind)
            scores[name] = score

    if wanted is not None:
        have = {stable_hash(n) for n in found}
        for name in extra_names:
            h = stable_hash(name)
            if h not in wanted or h in have or (only and name not in only):
                continue
            for model in (MODEL_ALIASES.get(name), name.split('_', 1)[1] if '_' in name else None):
                if model and model in roots_by_name:
                    found[name] = (roots_by_name[model], 'piece')
                    have.add(h)
                    print(f'  {name}: built by its mod around "{model}"', flush=True)
                    break
    return found


def mod_names(paths):
    """Identifiers in mod files — .NET keeps string literals as UTF-16."""
    import re
    names = set()
    for p in paths:
        try:
            d = Path(p).read_bytes()
        except OSError:
            continue
        names.update(m.decode('utf-16-le') for m in re.findall(rb'(?:[A-Za-z0-9_]\x00){4,64}', d))
        names.update(m.decode('ascii') for m in re.findall(rb'[A-Za-z0-9_]{4,64}', d))
    return names


def extract_terrain(env, out):
    """The terrain material's texture arrays, one image per layer, and its UV scale.
    Texture2DArray is beyond UnityPy, so the BC7 layers are decoded here."""
    layers = {'terrain_d_array': [], 'terrain_n_array': []}
    uv_scale = 0.5
    for obj in env.objects:
        if obj.type.name == 'Material' and obj.peek_name() == 'Heightmap_basematerial':
            floats = props(obj.read().m_SavedProperties.m_Floats)
            uv_scale = float(floats.get('_UVScale', uv_scale))
        if obj.type.name != 'Texture2DArray' or obj.peek_name() not in layers or layers[obj.peek_name()]:
            continue
        a = obj.read()
        name = obj.peek_name()
        sd = a.m_StreamData
        data = bytes(a.image_data) if a.image_data else get_resource_data(sd.path, obj.assets_file, sd.offset, sd.size)
        per = len(data) // a.m_Depth
        mip0 = (a.m_Width // 4) * (a.m_Height // 4) * 16  # BC7: 16 bytes per 4×4 block
        for i in range(a.m_Depth):
            rgba = texture2ddecoder.decode_bc7(data[i * per:i * per + mip0], a.m_Width, a.m_Height)
            img = Image.frombytes('RGBA', (a.m_Width, a.m_Height), rgba, 'raw', 'BGRA')
            file = f'terrain_{"n" if name.endswith("n_array") else "d"}_{i:02d}.png'
            if name.endswith('n_array'):
                img = Image.fromarray(decode_normal(np.asarray(img).astype(np.float32) / 255))
            img.save(out / 'textures' / file, optimize=True)
            layers[name].append(file)
    return {'uvScale': uv_scale, 'diffuse': layers['terrain_d_array'], 'normal': layers['terrain_n_array']}


CLUTTER_FIELDS = ['m_biome', 'm_amount', 'm_scaleMin', 'm_scaleMax', 'm_minTilt', 'm_maxTilt', 'm_minAlt', 'm_maxAlt',
                  'm_onUncleared', 'm_onCleared', 'm_inForest', 'm_forestTresholdMin', 'm_forestTresholdMax',
                  'm_fractalScale', 'm_fractalOffset', 'm_fractalTresholdMin', 'm_fractalTresholdMax',
                  'm_snapToWater', 'm_randomOffset', 'm_terrainTilt', 'm_minOceanDepth', 'm_maxOceanDepth']


def extract_clutter(env, ex, catalog):
    """The game's grass and ground-cover rules (ClutterSystem) and their meshes. Several
    scenes carry one; the main menu's is flagged m_menuHack, so the in-game one wins."""
    systems = []
    for obj in env.objects:
        if obj.type.name != 'MonoBehaviour':
            continue
        try:
            system = obj.read()
            if system.m_Script.read().m_Name == 'ClutterSystem':
                systems.append(system)
        except Exception:
            continue
    print('  clutter systems (menuHack, enabled rules):',
          [(int(getattr(x, 'm_menuHack', 0)), sum(1 for c in x.m_clutter if c.m_enabled)) for x in systems], flush=True)
    for system in sorted(systems, key=lambda x: int(getattr(x, 'm_menuHack', 0)))[:1]:
        rules = []
        for c in system.m_clutter:
            if not c.m_enabled:
                continue
            try:
                go = c.m_prefab.read()
                renderer = next((rd for n, rd in components(go) if n == 'MonoBehaviour' and script_name(rd) == 'InstanceRenderer'), None)
                if renderer is not None:
                    r = renderer.read()
                    entry = ex.instanced(r.m_mesh, r.m_material, (r.m_scale.x, r.m_scale.y, r.m_scale.z))
                else:
                    entry = ex.piece(go)
            except Exception as e:
                print(f'  clutter {c.m_name}: {type(e).__name__}: {e}')
                continue
            if not entry:
                continue
            key = f'clutter:{c.m_name}'
            entry['kind'] = 'clutter'
            catalog['pieces'][key] = entry
            rule = {'name': c.m_name, 'prefab': key}
            for f in CLUTTER_FIELDS:
                v = getattr(c, f, None)
                rule[f[2].lower() + f[3:]] = float(v) if isinstance(v, float) else int(v) if v is not None else None
            rules.append(rule)
        return {'patchSize': float(system.m_grassPatchSize), 'distance': float(system.m_distance),
                'waterLevel': float(system.m_waterLevel), 'rules': rules}
    return None


def carve_bundles(path, into):
    """Mods usually embed their asset bundles in the DLL; cut each `UnityFS` blob out to a file."""
    data = path.read_bytes()
    out = []
    start = data.find(b'UnityFS\x00')
    while start != -1:
        try:
            p = start + 8 + 4  # signature, format version
            for _ in range(2):  # unity version, revision: null-terminated
                p = data.index(b'\x00', p) + 1
            size = struct.unpack_from('>q', data, p)[0]
            if 0 < size <= len(data) - start:
                target = into / f'{path.stem}_{start}.bundle'
                target.write_bytes(data[start:start + size])
                out.append(str(target))
                start = data.find(b'UnityFS\x00', start + size)
                continue
        except (ValueError, struct.error):
            pass
        start = data.find(b'UnityFS\x00', start + 1)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--game', type=Path, default=DEFAULT_GAME, help='Valheim Data directory')
    ap.add_argument('--extra', type=Path, action='append', default=[], help='more asset bundles to scan, e.g. a mod folder')
    ap.add_argument('--out', type=Path, default=DEFAULT_OUT)
    ap.add_argument('--world', type=Path, help='also extract the props this world uses (chunked world directory or .db)')
    ap.add_argument('--only', help='comma-separated prefab names, for a quick test run')
    ap.add_argument('--texture-size', type=int, default=1024, help='largest texture edge kept (default 1024)')
    ap.add_argument('--prop-lod', type=int, default=1, help='LOD level for props (default 1; pieces always use 0)')
    args = ap.parse_args()

    bundles = args.game / 'StreamingAssets/SoftRef/Bundles'
    if not bundles.is_dir():
        sys.exit(f'No asset bundles at {bundles}; pass --game')
    t = time.time()
    paths = [str(bundles)]
    carved = args.out / '_mod_bundles'
    carved.mkdir(parents=True, exist_ok=True)
    mod_files = []
    for extra in args.extra:
        for p in extra.rglob('*'):
            if not p.is_file() or p.suffix.lower() in ('.pdb', '.md', '.txt', '.cfg', '.png', '.wav', '.xml', '.mdb', '.yml', '.yaml'):
                continue
            mod_files.append(p)
            if p.suffix.lower() != '.json':
                paths += carve_bundles(p, carved)
    env = UnityPy.load(*paths)
    print(f'loaded {len(env.files)} files in {time.time() - t:.0f}s', flush=True)

    only = set(args.only.split(',')) if args.only else None
    wanted = world_prefabs(args.world) if args.world else None
    if wanted is not None:
        print(f'{len(wanted)} distinct prefabs in {args.world.name}', flush=True)
    roots = find_roots(env, wanted, only, extra_names=mod_names(mod_files) if wanted is not None else ())
    kinds = {}
    for _, kind in roots.values():
        kinds[kind] = kinds.get(kind, 0) + 1
    print(f'found {kinds} in {time.time() - t:.0f}s', flush=True)

    args.out.mkdir(parents=True, exist_ok=True)
    for old in (args.out / 'textures').glob('*'):
        old.unlink()
    ex = Extractor(args.out, args.texture_size)
    catalog = {'version': 3, 'pieces': {}}
    failed = []
    for i, (name, (go, kind)) in enumerate(sorted(roots.items())):
        try:
            entry = ex.piece(go, lod=0 if kind == 'piece' else args.prop_lod)
            if entry:
                entry['kind'] = kind
                catalog['pieces'][name] = entry
        except Exception as e:
            failed.append(f'{name}: {type(e).__name__}: {e}')
        if i % 50 == 0:
            print(f'  {i}/{len(roots)} {name}', flush=True)

    if not only:
        catalog['terrain'] = extract_terrain(env, args.out)
        catalog['clutter'] = extract_clutter(env, ex, catalog)
        print(f'terrain: {len(catalog["terrain"]["diffuse"])} layers; clutter: '
              f'{len((catalog["clutter"] or {}).get("rules", []))} rules', flush=True)

    (args.out / 'catalog.bin').write_bytes(ex.blob)
    (args.out / 'catalog.json').write_text(json.dumps(catalog, separators=(',', ':')))
    print(f'wrote {len(catalog["pieces"])} prefabs, {len(ex.blob) / 2**20:.1f} MB geometry, '
          f'{sum(1 for v in ex.textures.values() if v)} textures to {args.out} in {time.time() - t:.0f}s')
    for f in failed:
        print('  failed', f)


if __name__ == '__main__':
    main()
