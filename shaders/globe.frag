#version 440
// Le géoïde du bureau vide : les pays en trames de points, dans l'accent,
// sur une sphère dont on a élargi les pôles, qui tourne autour de son axe.
// Rien d'autre : ni frontières tracées, ni océan, ni méridiens. La sphère
// est transparente : la face cachée se voit à travers les mers, dans
// l'ombre, à l'envers.
//
// La forme : sur chaque ligne de l'écran, la demi-largeur vaut
// √(1 − polar·y²) — 1 donnerait une sphère, moins garde les calottes
// larges au lieu de les refermer en pointe. Sur la ligne, la longitude
// s'enroule comme sur une sphère (le bord fuit, plus ou moins selon
// curve) ; en hauteur, Mercator agrandit les hautes latitudes. Le haut et
// le bas s'effacent en fondu.
//
// La carte (assets/globe/countries.png, équirectangulaire, Natural Earth)
// porte dans chaque pixel le numéro de son pays, 0 pour la mer. Les pays ne
// sont pas dessinés, mais chaque point sait à quel pays il appartient : ceux
// du pays survolé s'avivent, ceux du pays choisi se remplissent.

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
    float curve;      // 1 : bords écrasés comme sur une sphère ; moins : moins
    float vMin;       // bornes de la carte, en unités de Mercator
    float vMax;
    float yaw;        // rotation autour de l'axe, radians
    float unitX;      // pixels par radian de longitude, au centre
    float unitY;      // pixels par unité de Mercator
    float dotPx;      // écart entre deux points, en pixels (au centre)
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

// Le point de la trame le plus proche : la grille est régulière sur la
// carte (dotPx au centre de l'écran), le point s'allume si son centre tombe
// dans un pays. comp dit combien un pixel de carte se tasse à l'écran en
// largeur (1 au centre, moins vers les bords et les pôles) : les points
// s'y amincissent avec leurs colonnes, puis s'éteignent avant de se
// toucher. Le pays survolé a des points plus vifs ; le choisi, des points
// pleins et un peu plus gros. Rend une couleur prémultipliée.
vec4 dots(float lon, float v, float comp) {
    float count = max(8.0, floor(2.0 * PI * unitX / dotPx + 0.5));
    float lonStep = 2.0 * PI / count;
    float vStep = dotPx / unitY;
    float colLon = floor(lon / lonStep + 0.5) * lonStep;
    float rowV = floor(v / vStep + 0.5) * vStep;

    float lat = atan(sinh(rowV));
    float id = countryAt(vec2(colLon / (2.0 * PI) + 0.5, 0.5 - lat / PI));
    bool chosen = id > 0.5 && abs(id - selectId) < 0.5;
    bool hovered = id > 0.5 && abs(id - hoverId) < 0.5;

    // La distance au centre du point, en pixels de carte. Un pixel d'écran
    // y vaut 1/comp en largeur et 1 en hauteur : le bord adouci fait 0,7 px
    // d'écran dans la direction du centre, et le point reste net partout.
    vec2 d = vec2((lon - colLon) * unitX, (v - rowV) * unitY);
    float len = max(length(d), 1e-4);
    float r = dotPx * (chosen ? 0.36 : 0.3);
    float aa = 0.7 * length(vec2(d.x / max(comp, 0.05), d.y)) / len;
    float disc = 1.0 - smoothstep(r - aa, r + aa, len);
    // Les colonnes trop serrées (tout près des pôles) s'éteignent avant
    // que leurs points se touchent.
    disc *= smoothstep(1.5, 2.5, dotPx * comp);

    float level = chosen ? 1.0 : (hovered ? 0.85 : 0.5);
    float a = disc * step(0.5, id) * level;
    return vec4(accent.rgb * a, a);
}

void main() {
    vec2 px = qt_TexCoord0 * vec2(itemW, itemH) - 0.5 * vec2(itemW, itemH);
    float ny = -px.y / halfH;
    float row = sqrt(max(1.0 - polar * ny * ny, 1e-4));   // demi-largeur de la ligne
    float nx = px.x / (halfW * row);
    float inside = step(abs(nx), 1.0) * step(abs(ny), 1.0);

    // Sur la ligne, la sphère : l'angle autour de l'axe et sa profondeur.
    // L'écran suit sin(curve·angle)/curve : au centre la pente ne dépend pas
    // de curve (les pays gardent leurs proportions), vers les bords la carte
    // se tasse d'autant moins que curve est bas, et la forme s'élargit.
    float k = max(curve, 1e-3);
    float ang = asin(clamp(nx, -1.0, 1.0) * sin(k * 1.57079632679)) / k;
    float v = mix(vMin, vMax, 0.5 + 0.5 * ny);
    float lat = atan(sinh(v));
    float ty = 0.5 - lat / PI;

    // Devant, puis derrière (l'angle opposé, vu à travers).
    vec2 uvF = vec2((ang - yaw) / (2.0 * PI) + 0.5, ty);

    // Le tassement à l'écran, en largeur : la pente de sin(k·a)/k, et la
    // ligne qui raccourcit vers les pôles.
    float comp = cos(k * ang) * row;

    // Net jusqu'aux bords : seuls le haut et le bas s'effacent (plus bas).
    vec4 front = dots(ang - yaw, v, comp);
    vec4 back = dots(PI - ang - yaw, v, comp) * shadow;

    // Les terres de devant, même sans trait, cachent celles de derrière.
    float frontLand = step(0.5, countryAt(uvF));
    back *= 1.0 - frontLand;

    vec4 c = front + back * (1.0 - front.a);
    // En haut et en bas, la carte ne s'arrête pas sur une ligne : elle
    // s'efface sur le dernier huitième de la hauteur.
    float caps = smoothstep(1.0, 0.88, abs(ny));
    fragColor = c * inside * caps * qt_Opacity;
}
