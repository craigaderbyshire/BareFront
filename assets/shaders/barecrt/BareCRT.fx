#include "ReShade.fxh"

uniform float BareFrontDummy = 0.0;

sampler2D BareFrontSource
{
    Texture = ReShade::BackBufferTex;
    MinFilter = POINT;
    MagFilter = POINT;
};

float4 BareFrontCrtCrisp(
    float4 position : SV_Position,
    float2 uv : TEXCOORD
) : SV_Target
{
    //
    // Absolutely no rescaling or fractional neighbour sampling.
    //
    float3 colour =
        tex2D(BareFrontSource, uv).rgb;

    float x = floor(position.x);
    float y = floor(position.y);

    //
    // Source-pixel-aligned CRT halation.
    //
    // PC Engine is already integer-scaled 4x by Gamescope.
    // Sample whole source-pixel steps only: never fractional pixels.
    //
    float2 sourceStep =
        ReShade::PixelSize * 4.0;

    float3 glow =
        tex2D(BareFrontSource, uv + float2( sourceStep.x, 0.0)).rgb +
        tex2D(BareFrontSource, uv + float2(-sourceStep.x, 0.0)).rgb +
        tex2D(BareFrontSource, uv + float2(0.0,  sourceStep.y)).rgb +
        tex2D(BareFrontSource, uv + float2(0.0, -sourceStep.y)).rgb;

    glow *= 0.25;

    //
    // Only strong highlights should bleed.
    //
    glow =
        saturate(
            (glow - 0.60) / 0.40
        );

    glow *= 0.14;

    //
    // PC Engine is exactly 4x vertically:
    // 232 -> 928.
    //
    // Shape each four-output-pixel source row like a CRT beam:
    //
    //   dim
    //   bright
    //   bright
    //   dim
    //
    float row =
        y - 4.0 * floor(y / 4.0);

    //
    // BareCRT motion-safe beam profile.
    //
    // Keep the modulation deliberately shallow and independent
    // of pixel brightness. Strong brightness-dependent beams
    // caused visible shimmer during vertical scrolling.
    //
    float edgeGain =
        0.92;

    float beamGain =
        1.04;

    if (row < 1.0 || row >= 3.0)
        colour *= edgeGain;
    else
        colour *= beamGain;

    //
    // Motion-safe phosphor structure.
    //
    // PC Engine is scaled exactly 4x, so repeat the mask once
    // per scaled source pixel. This prevents the RGB phase from
    // walking across source pixels during horizontal scrolling.
    //
    float maskPhase =
        x - 4.0 * floor(x / 4.0);

    float3 mask;

    if (maskPhase < 1.0)
        mask = float3(1.00, 0.86, 0.86);
    else if (maskPhase < 2.0)
        mask = float3(0.86, 1.00, 0.86);
    else if (maskPhase < 3.0)
        mask = float3(0.86, 0.86, 1.00);
    else
        mask = float3(0.91, 0.91, 0.91);

    colour *= mask;

    //
    // Small compensation for light lost through beam/mask structure.
    //
    colour *= 1.10;

    //
    // Add a very small amount of CRT light spread.
    // Base pixels remain untouched and POINT sampled.
    //
    colour += glow;

    colour += BareFrontDummy * 0.0;

    return float4(
        saturate(colour),
        1.0
    );
}

technique BareFrontCrtCrisp
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = BareFrontCrtCrisp;
    }
}
