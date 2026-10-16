#version 460 core
precision highp float;
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform vec4 uRect;
uniform float uRadius;
uniform float uThickness;
uniform float uIndex;
uniform vec4 uTint;
uniform float uActivation;
uniform float uTouch;
uniform float uEmission;
uniform float uOptimize;
uniform sampler2D uInput;
out vec4 fragColor;

vec4 sampleInput(vec2 position) {
    vec2 uv = position / uSize;
    #ifdef IMPELLER_TARGET_OPENGLES
        uv.y = 1.0 - uv.y;
    #endif
    return texture(uInput, clamp(uv, vec2(0.0), vec2(1.0)));
}

#include "glass_shape.glsl"
