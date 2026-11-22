#version 440
// Le géoïde du bureau vide : les pays seuls, chacun d'une nuance de
// l'accent, bordés de leur frontière, sur une sphère dont on a élargi les
// pôles, qui tourne autour de son axe. Rien d'autre : ni océan, ni
// méridiens. La sphère est transparente : les pays de la face cachée se
// voient à travers les mers, dans l'ombre, à l'envers.
//
// La forme : sur chaque ligne de l'écran, la demi-largeur vaut
// √(1 − polar·y²) — 1 donnerait une sphère, moins garde les calottes
// larges au lieu de les refermer en pointe. Sur la ligne, la longitude
// s'enroule comme sur une sphère (le bord fuit) ; en hauteur, Mercator
// agrandit les hautes latitudes.
//
// La carte (assets/globe/countries.png, équirectangulaire, Natural Earth)
// porte dans chaque pixel le numéro de son pays, 0 pour la mer. Le numéro
// choisit la nuance ; un trait suit chaque frontière, là où deux pixels
// voisins changent de pays. Le pays survolé et le pays choisi s'éclairent.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float itemW;      // taille de l'élément, en pixels
    float itemH;
    float halfW;      // demi-largeur à l'équateur de la forme, en pixels
    float halfH;      // demi-hauteur
    float polar;      // 1 : sphère ; moins : pôles élargis
    float vMin;       // bornes de la carte, en unités de Mercator
    float vMax;
    float yaw;        // rotation autour de l'axe, radians
    float shadow;     // éclat de la face cachée (0 : invisible)
    float hoverId;    // pays survolé (0 : aucun)
    float selectId;   // pays choisi (0 : aucun)
    vec4 accent;
};

layout(binding = 1) uniform sampler2D countries;

const float PI = 3.14159265359;

float countryAt(vec2 uv) {
    uv.x = fract(uv.x);
    uv.y = clamp(uv.y, 0.0, 1.0);
    return floor(textureLod(countries, uv, 0.0).r * 255.0 + 0.5);
}

bool isLit(float id) {
    return id > 0.5 && (abs(id - hoverId) < 0.5 || abs(id - selectId) < 0.5);
}

// La nuance d'un pays : l'accent, assombri ou éclairci selon son numéro.
vec3 shadeOf(float id) {
    float h = fract(sin(id * 12.9898) * 43758.5453);
    vec3 dark = accent.rgb * 0.38;
    vec3 light = mix(accent.rgb, vec3(1.0), 0.22);
    return mix(dark, light, h);
}

// Un pays vu en ce point de la carte : sa nuance en aplat, sa frontière en
// trait. Rend une couleur prémultipliée ; dans .a, la couverture.
vec4 paint(vec2 uv, vec2 duvX, vec2 duvY, float fillA, float lineA) {
    float here = countryAt(uv);
    float rx = countryAt(uv + duvX);
    float ry = countryAt(uv + duvY);
    bool edgeX = abs(here - rx) > 0.5;
    bool edgeY = abs(here - ry) > 0.5;
    bool hot = isLit(here) || (edgeX && isLit(rx)) || (edgeY && isLit(ry));

    vec4 c = vec4(0.0);
    if (here > 0.5) {
        float a = fillA;
        if (abs(here - selectId) < 0.5)
            a = min(1.0, fillA * 2.4);
        else if (abs(here - hoverId) < 0.5)
            a = min(1.0, fillA * 1.8);
        c = vec4(shadeOf(here) * a, a);
    }
    if (edgeX || edgeY) {
        float l = lineA * (hot ? 1.0 : 0.7);
        c = vec4(accent.rgb * l, l) + c * (1.0 - l);
    }
    return c;
}

void main() {
    vec2 px = qt_TexCoord0 * vec2(itemW, itemH) - 0.5 * vec2(itemW, itemH);
    float ny = -px.y / halfH;
    float row = sqrt(max(1.0 - polar * ny * ny, 1e-4));   // demi-largeur de la ligne
    float nx = px.x / (halfW * row);
    float inside = step(abs(nx), 1.0) * step(abs(ny), 1.0);

    // Sur la ligne, la sphère : l'angle autour de l'axe et sa profondeur.
    float ang = asin(clamp(nx, -1.0, 1.0));
    float z = cos(ang);
    float v = mix(vMin, vMax, 0.5 + 0.5 * ny);
    float lat = atan(sinh(v));
    float ty = 0.5 - lat / PI;

    // Devant, puis derrière (l'angle opposé, vu à travers). x non replié :
    // les longitudes sont continues à l'écran, leurs dérivées aussi, et
    // toutes sont prises avant tout branchement.
    vec2 uvF = vec2((ang - yaw) / (2.0 * PI) + 0.5, ty);
    vec2 uvB = vec2((PI - ang - yaw) / (2.0 * PI) + 0.5, ty);
    vec2 dFx = dFdx(uvF), dFy = dFdy(uvF);
    vec2 dBx = dFdx(uvB), dBy = dFdy(uvB);

    // Vers le limbe, la carte se tasse : chaque pixel y chevauche plusieurs
    // pays, et les frontières, partout, feraient un halo. Elles s'éteignent
    // donc tôt ; les aplats tiennent plus loin. Devant, l'éclat baisse aussi
    // avec la profondeur.
    float rim = smoothstep(0.05, 0.3, z);
    float lineFade = smoothstep(0.25, 0.6, z);
    float depth = mix(0.45, 1.0, smoothstep(0.0, 0.8, z));

    vec4 front = paint(uvF, dFx, dFy, 0.34, 0.9 * lineFade) * depth * rim;
    vec4 back = paint(uvB, dBx, dBy, 0.34, 0.9 * lineFade) * shadow * rim;

    // Les terres de devant cachent celles de derrière.
    float frontLand = step(0.5, countryAt(uvF));
    back *= 1.0 - frontLand;

    vec4 c = front + back * (1.0 - front.a);
    fragColor = c * inside * qt_Opacity;
}
