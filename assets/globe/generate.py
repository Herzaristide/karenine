#!/usr/bin/env python3
# Refait les cartes du globe (panels/Globe.qml) depuis Natural Earth
# (domaine public), ne_50m_admin_0_countries.geojson :
#   countries.png  : 4096×2048 équirectangulaire, le numéro du pays par
#                    pixel (0 : la mer), sans antialiasing ;
#   countries.json : les noms (fr, en), les codes ISO, et la même carte en
#                    2048×1024, ligne par ligne en plages, pour le survol.
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
json.dump({"w": 2048, "h": 1024, "fr": names_fr, "en": names_en, "codes": codes, "rows": rows},
          open(js, "w"), ensure_ascii=False, separators=(",", ":"))
print(len(feats), "pays")
