// One analytic ray evaluation per pixel. GPU quad derivatives provide the
// optical footprint without evaluating four more Snell/normal calculations.
vec3 glassPoint(vec2 position) {
    vec2 p = position - uRect.xy - uRect.zw * 0.5;
    float touchX = (clamp(uTouch, 0.0, 1.0) - 0.5) * uRect.z;
    float spread = max(1.0, uRect.z * 0.28);
    float delta = (p.x - touchX) / spread;
    float contact = uActivation > 0.0 ? exp(-delta * delta) : 0.0;
    float halfHeight = uRect.w * 0.5
        * (1.0 - 0.05 * uActivation * (1.0 - contact));
    float radius = min(uRadius, min(uRect.z * 0.5, halfHeight));
    vec2 q = abs(p) - vec2(uRect.z * 0.5, halfHeight) + radius;
    vec2 outside = max(q, vec2(0.0));
    float outsideLength = length(outside);
    float sd = outsideLength + min(max(q.x, q.y), 0.0) - radius;
    vec2 gradient;
    if (outsideLength > 0.0001) gradient = outside / outsideLength * sign(p);
    else gradient = q.x > q.y ? vec2(sign(p.x), 0.0) : vec2(0.0, sign(p.y));
    float heightSlope = uRect.w * 0.025 * uActivation
        * contact * (-2.0 * delta / spread);
    gradient = normalize(vec2(gradient.x - abs(gradient.y) * heightSlope, gradient.y));
    float thickness = max(uThickness, 0.01);
    float nxy = clamp((thickness + sd) / thickness, 0.0, 1.0);
    float nz = sqrt(max(0.0, 1.0 - nxy * nxy));
    vec3 normal = vec3(gradient * nxy, nz);
    vec3 transmitted = refract(vec3(0.0, 0.0, -1.0), normal, 1.0 / max(uIndex, 1.0));
    float height = sqrt(max(0.0, thickness * thickness - pow(max(thickness + sd, 0.0), 2.0)));
    vec2 displacement = transmitted.xy * ((height + thickness * 3.0) / max(0.2, abs(transmitted.z)));
    return vec3(position + displacement, sd);
}

void main() {
    // Impeller re-rasterizes composed-filter input transforms. Do not infer a
    // symmetric border from input size minus view size: clipping/rounding makes
    // that difference unsuitable as either a position or a sampling offset.
    vec2 position = floor(FlutterFragCoord().xy) + vec2(0.5);
    vec2 distance = abs(position - uRect.xy - uRect.zw * 0.5);
    // Complete the 2x2 derivative quad before discarding boundary pixels.
    // The small guard keeps unrelated full-scene pixels out of this calculation.
    if (any(greaterThanEqual(distance, uRect.zw * 0.5 + vec2(2.0)))) {
        fragColor = vec4(0.0);
        return;
    }
    // The flat core has exactly zero displacement. Its source/tint/emission
    // need no normal, refract, square roots or quad resampling. The 4px guard
    // keeps every derivative quad used by the curved rim on the reference path.
    // Contact deformation deliberately keeps the full analytic evaluation.
    if (uOptimize > 0.5 && uActivation <= 0.0) {
        float radius = min(uRadius, min(uRect.z, uRect.w) * 0.5);
        vec2 q = distance - uRect.zw * 0.5 + radius;
        float sd = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
        if (sd < -uThickness - 4.0) {
            vec4 color = sampleInput(position);
            color.rgb = mix(color.rgb, uTint.rgb * color.a, uTint.a);
            color.rgb = min(vec3(color.a), color.rgb + vec3(uEmission * color.a));
            fragColor = color;
            return;
        }
    }
    vec3 center = glassPoint(position);
    float aa = max(fwidth(center.z), 1.0);
    vec2 dx = dFdx(center.xy) * 0.25;
    vec2 dy = dFdy(center.xy) * 0.25;
    if (any(greaterThanEqual(distance, uRect.zw * 0.5))) {
        fragColor = vec4(0.0);
        return;
    }
    vec4 color;
    float coverage = 1.0;
    if (center.z < -uThickness - 2.0) {
        color = sampleInput(position);
    } else {
        coverage = 1.0 - smoothstep(-aa, 0.0, center.z);
        if (coverage <= 0.0) {
            fragColor = vec4(0.0);
            return;
        }
        color = (sampleInput(center.xy - dx - dy)
            + sampleInput(center.xy + dx - dy)
            + sampleInput(center.xy - dx + dy)
            + sampleInput(center.xy + dx + dy)) * 0.25;
    }
    color.rgb = mix(color.rgb, uTint.rgb * color.a, uTint.a);
    color.rgb = min(vec3(color.a), color.rgb + vec3(uEmission * color.a));
    fragColor = color * coverage;
}
