#include "ReShade.fxh"

texture2D BareFrontBezelTexture <
    source = "c64.png";
>
{
    Width = 1920;
    Height = 1080;
    Format = RGBA8;
};

sampler2D BareFrontBezelSampler
{
    Texture = BareFrontBezelTexture;
    MinFilter = POINT;
    MagFilter = POINT;
    AddressU = CLAMP;
    AddressV = CLAMP;
};

sampler2D BareFrontSceneSampler
{
    Texture = ReShade::BackBufferTex;
    MinFilter = POINT;
    MagFilter = POINT;
};

float4 BareFrontBezel(
    float4 position : SV_Position,
    float2 uv : TEXCOORD
) : SV_Target
{
    float4 scene =
        tex2D(
            BareFrontSceneSampler,
            uv
        );

    float4 bezel =
        tex2D(
            BareFrontBezelSampler,
            uv
        );

    float3 colour =
        lerp(
            scene.rgb,
            bezel.rgb,
            bezel.a
        );

    return float4(
        colour,
        1.0
    );
}

technique BareFrontBezel
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = BareFrontBezel;
    }
}
