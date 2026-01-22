#include <metal_stdlib>
using namespace metal;

struct Vertex
{
    float4 position [[ position ]];
    float2 texCoords;
};

struct CscParams
{
    float3x3 matrix;
    float3 offsets;
    float2 chromaOffset;
    float bitnessScaleFactor;
};

constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

vertex Vertex vs_draw(constant Vertex *vertices [[ buffer(0) ]], uint id [[ vertex_id ]])
{
    return vertices[id];
}

fragment half4 ps_draw_biplanar(Vertex v [[ stage_in ]],
                                constant CscParams &cscParams [[ buffer(0) ]],
                                texture2d<half> luminancePlane [[ texture(0) ]],
                                texture2d<half> chrominancePlane [[ texture(1) ]])
{
    float2 chromaOffset = cscParams.chromaOffset / float2(luminancePlane.get_width(),
                                                          luminancePlane.get_height());
    float2 chromaSample = float2(chrominancePlane.sample(s, v.texCoords + chromaOffset).rg);
    float3 yuv = float3(luminancePlane.sample(s, v.texCoords).r, chromaSample);
    yuv *= cscParams.bitnessScaleFactor;
    yuv -= cscParams.offsets;

    float4 rgba = float4(yuv * cscParams.matrix, 1.0);
    return half4(rgba);
}

fragment half4 ps_draw_triplanar(Vertex v [[ stage_in ]],
                                 constant CscParams &cscParams [[ buffer(0) ]],
                                 texture2d<half> luminancePlane [[ texture(0) ]],
                                 texture2d<half> chrominancePlaneU [[ texture(1) ]],
                                 texture2d<half> chrominancePlaneV [[ texture(2) ]])
{
    float2 chromaOffset = cscParams.chromaOffset / float2(luminancePlane.get_width(),
                                                          luminancePlane.get_height());
    float3 yuv = float3(luminancePlane.sample(s, v.texCoords).r,
                        chrominancePlaneU.sample(s, v.texCoords + chromaOffset).r,
                        chrominancePlaneV.sample(s, v.texCoords + chromaOffset).r);
    yuv *= cscParams.bitnessScaleFactor;
    yuv -= cscParams.offsets;

    float4 rgba = float4(yuv * cscParams.matrix, 1.0);
    return half4(rgba);
}

fragment half4 ps_draw_rgb(Vertex v [[ stage_in ]],
                           texture2d<half> rgbTexture [[ texture(0) ]])
{
    return rgbTexture.sample(s, v.texCoords);
}
