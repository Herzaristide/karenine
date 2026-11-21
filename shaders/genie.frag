#version 440
// L'image du panneau, déformée par genie.vert ; elle s'efface tout à la fin,
// dans le bouton.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float t;
    float itemW;
    float itemH;
    float buttonL;
    float buttonR;
};

layout(binding = 1) uniform sampler2D source;

void main() {
    float fade = 1.0 - smoothstep(0.82, 1.0, t);
    fragColor = texture(source, qt_TexCoord0) * qt_Opacity * fade;
}
