#!/usr/bin/env sh
# Compile les shaders de l'interface en .qsb, le format que Qt Quick charge
# (ShaderEffect). Les .qsb sont versionnés à côté de leurs sources : à
# relancer après chaque changement d'un .vert ou d'un .frag.
#
# Usage : shaders/build.sh   (qsb vient de qt6.qtshadertools)
set -eu
cd "$(dirname "$0")"
for f in *.vert *.frag; do
    qsb --glsl "100 es,120,150" --hlsl 50 --msl 12 -o "$f.qsb" "$f"
done
