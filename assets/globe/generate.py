#!/usr/bin/env python3
# Refait les cartes du globe (panels/Globe.qml) depuis Natural Earth
# (domaine public), ne_50m_admin_0_countries.geojson :
#   countries.png  : 4096×2048 équirectangulaire, le numéro du pays par
#                    pixel (0 : la mer), sans antialiasing ;
#   countries.json : les noms (fr, en), les codes ISO, le centre de chaque
#                    pays, et la même carte en 2048×1024, ligne par ligne en
#                    plages, pour le survol.
#
# Usage : python3 generate.py ne_50m_admin_0_countries.geojson countries.png countries.json
# (Pillow requis.)
import json, sys, math
from PIL import Image, ImageDraw
src, png, js = sys.argv[1:4]
W, H = 4096, 2048
ids = Image.new("L", (W, H), 0)
def pt(lon, lat):
    return ((lon + 180) / 360 * W, (90 - lat) / 180 * H)
feats = json.load(open(src))["features"]
names_fr, names_en, codes = [], [], []
for i, f in enumerate(feats, start=1):
    p = f["properties"]
    names_fr.append(p.get("NAME_FR") or p["NAME"])
    names_en.append(p.get("NAME_EN") or p["NAME"])
    c = p.get("ISO_A2_EH") or p.get("ISO_A2")
    codes.append(c if c and c != "-99" else p["ADM0_A3"])
    g = f["geometry"]
    polys = g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]
    rings = [[pt(*c[:2]) for c in ring] for poly in polys for ring in poly]
    xs = [x for r in rings for x, _ in r]; ys = [y for r in rings for _, y in r]
    x0, y0 = max(0, int(min(xs)) - 1), max(0, int(min(ys)) - 1)
    x1, y1 = min(W, int(math.ceil(max(xs))) + 2), min(H, int(math.ceil(max(ys))) + 2)
    mask = Image.new("1", (x1 - x0, y1 - y0), 0)
    d = ImageDraw.Draw(mask)
    for poly in polys:
        for k, ring in enumerate(poly):
            d.polygon([(x - x0, y - y0) for x, y in (pt(*c[:2]) for c in ring)], fill=0 if k else 1)
    ids.paste(i, (x0, y0, x1, y1), mask)
ids.save(png, optimize=True)
# La table du survol : la même carte à 2048×1024, ligne par ligne en
# plages [id, longueur, id, longueur, …].
small = ids.resize((2048, 1024), Image.NEAREST)
px = small.load()
rows = []
for y in range(1024):
    row, cur, n = [], px[0, y], 0
    for x in range(2048):
        v = px[x, y]
        if v == cur: n += 1
        else: row += [cur, n]; cur, n = v, 1
    row += [cur, n]; rows.append(row)
# Le centre de chaque pays, en degrés : le centroïde de son plus grand
# morceau (la France se centre sur la métropole, pas entre elle et la Guyane).
def centroid(ring):
    a = cx = cy = 0.0
    for (x0, y0), (x1, y1) in zip(ring, ring[1:] + ring[:1]):
        k = x0 * y1 - x1 * y0
        a += k; cx += (x0 + x1) * k; cy += (y0 + y1) * k
    if abs(a) < 1e-12:
        return abs(a), ring[0][0], ring[0][1]
    return abs(a) / 2, cx / (3 * a), cy / (3 * a)
centers = []
for f in feats:
    g = f["geometry"]
    polys = g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]
    best = max((centroid([tuple(c[:2]) for c in poly[0]]) for poly in polys), key=lambda t: t[0])
    centers.append([round(best[1], 2), round(best[2], 2)])
json.dump({"w": 2048, "h": 1024, "fr": names_fr, "en": names_en, "codes": codes,
           "centers": centers, "rows": rows},
          open(js, "w"), ensure_ascii=False, separators=(",", ":"))
print(len(feats), "pays")
