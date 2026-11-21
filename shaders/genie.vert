#version 440
// L'effet « génie » du panneau de droite (panels/SidePanel.qml) : l'image du
// panneau ouvert, posée sur une grille, s'engouffre dans son bouton de la
// barre, comme une fenêtre de macOS dans le Dock.
//
// `t` va de 0 (ouvert) à 1 (rentré). D'abord le bas se resserre vers le
// bouton et les flancs s'incurvent ; puis tout descend dans l'entonnoir,
// chaque rangée prenant la largeur de la hauteur où elle se trouve.

layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;
layout(location = 0) out vec2 qt_TexCoord0;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float t;
    float itemW;
    float itemH;
    // Le bouton, en x dans l'item : où l'entonnoir aboutit, au bas.
    float buttonL;
    float buttonR;
};

out gl_PerVertex { vec4 gl_Position; };

void main() {
    vec2 uv = qt_MultiTexCoord0;
    qt_TexCoord0 = uv;

    // Les deux temps, qui se recouvrent un peu.
    float bend = smoothstep(0.0, 0.55, t);
    float slide = smoothstep(0.3, 1.0, t);

    // La descente : tout se tasse vers le bas.
    float y = mix(uv.y, 1.0, slide) * itemH;

    // La largeur à cette hauteur : celle du bouton au bas, celle du panneau
    // en haut, le passage d'autant plus bas que le génie commence. Une fois
    // descendu, tout a la largeur du bouton.
    float f = 1.0 - y / itemH;              // 0 au bas, 1 en haut
    float neck = 1.0 - smoothstep(0.0, mix(0.15, 1.0, bend), f);
    float k = mix(bend * neck, 1.0, slide);
    float left = mix(0.0, buttonL, k);
    float right = mix(itemW, buttonR, k);
    float x = mix(left, right, uv.x);

    gl_Position = qt_Matrix * vec4(x, y, 0.0, 1.0);
}
