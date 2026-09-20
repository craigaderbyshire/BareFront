#include "ReShade.fxh"

uniform float BareFrontDummy = 0.0;
uniform float BareFrontScale = 4.0;
uniform float BareFrontPhaseX = 0.0;
uniform float BareFrontPhaseY = 0.0;
uniform float BareFrontBeamAxis = 0.0;
uniform float BareFrontSourceScaleX = 0.0;
uniform float BareFrontSourceScaleY = 0.0;

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
    float sourceScaleX =
        BareFrontScale;

    float sourceScaleY =
        BareFrontScale;

    if (BareFrontSourceScaleX > 0.5)
        sourceScaleX = BareFrontSourceScaleX;

    if (BareFrontSourceScaleY > 0.5)
        sourceScaleY = BareFrontSourceScaleY;


    float2 sourceStep =
        ReShade::PixelSize *
        float2(
            sourceScaleX,
            sourceScaleY
        );

    //
    // BareCRT v2 restrained CRT halation.
    //
    // Real CRT light spread is generally more noticeable
    // horizontally than vertically, so weight the neighbouring
    // source pixels accordingly.
    //
    float3 glowHorizontal =
        tex2D(BareFrontSource, uv + float2( sourceStep.x, 0.0)).rgb +
        tex2D(BareFrontSource, uv + float2(-sourceStep.x, 0.0)).rgb;

    glowHorizontal *= 0.5;

    float3 glowVertical =
        tex2D(BareFrontSource, uv + float2(0.0,  sourceStep.y)).rgb +
        tex2D(BareFrontSource, uv + float2(0.0, -sourceStep.y)).rgb;

    glowVertical *= 0.5;

    float3 glow =
        glowHorizontal * 0.70 +
        glowVertical   * 0.30;

    //
    // Only genuinely bright areas should spread light.
    //
    glow =
        saturate(
            (glow - 0.68) / 0.32
        );

    glow *= 0.10;

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
    //
    // Beam orientation.
    //
    // 0 = conventional horizontal CRT scanlines.
    // 1 = vertically mounted / TATE CRT scanlines after the
    //     emulated picture has been rotated upright.
    //
    float beamCoordinate =
        y;

    float beamPhase =
        BareFrontPhaseY;

    if (BareFrontBeamAxis > 0.5)
    {
        beamCoordinate =
            x;

        beamPhase =
            BareFrontPhaseX;
    }


    float phasedBeam =
        beamCoordinate - beamPhase;

    float row =
        phasedBeam -
        BareFrontScale *
        floor(phasedBeam / BareFrontScale);

    //
    // BareCRT v2 smooth motion-safe beam profile.
    //
    // Keep the beam locked to the four output rows belonging
    // to each source pixel, but replace the old hard
    // dim/bright/bright/dim steps with a smooth CRT-like curve.
    //
    // This remains independent of pixel brightness so vertical
    // scrolling cannot alter the beam shape.
    //
    float beamCentre =
        BareFrontScale * 0.5;

    float beamDistance;

    //
    // Avoid division by the vkBasalt-controlled scale uniform.
    // This particular ReShade/vkBasalt path renders black when
    // the scale uniform is used as a divisor.
    //
    // BareFront currently has two fixed integer-scale classes:
    //   2x -> half-height = 1.0
    //   4x -> half-height = 2.0
    //
    if (BareFrontScale < 3.0)
    {
        // 2x
        beamDistance =
            abs((row + 0.5) - beamCentre);
    }
    else if (BareFrontScale < 4.0)
    {
        // 3x
        beamDistance =
            abs((row + 0.5) - beamCentre);
    }
    else
    {
        // 4x
        beamDistance =
            abs((row + 0.5) - beamCentre) / 2.0;
    }

    float beamGain;

    //
    // BareCRT v2 beam profiles.
    //
    // 2x only has two output rows per source row, so a smooth
    // cosine curve collapses to almost identical brightness on
    // both rows. Give 2x its own restrained bright/dim pair.
    //
    if (BareFrontScale < 3.0)
    {
        if (row < 1.0)
            beamGain = 1.00;
        else
            beamGain = 0.76;
    }
    else
    {
        float beamShape =
            0.5 +
            0.5 * cos(
                beamDistance * 3.14159265
            );

        beamGain =
            lerp(
                0.84,
                1.00,
                beamShape
            );
    }

    colour *= beamGain;

    //
    // BareCRT v2 output-pixel aperture grille.
    //
    // The phosphor structure belongs to the displayed CRT surface,
    // not to the emulated source pixel. Keep a fixed RGB stripe
    // pattern across output pixels so game pixels move naturally
    // beneath the virtual phosphors.
    //
    float maskPhase =
        x - 3.0 * floor(x / 3.0);

    float3 mask;

    if (maskPhase < 1.0)
        mask = float3(1.00, 0.90, 0.90);
    else if (maskPhase < 2.0)
        mask = float3(0.90, 1.00, 0.90);
    else
        mask = float3(0.90, 0.90, 1.00);

    colour *= mask;

    //
    // Compensate for the average light lost through the grille.
    // Average channel transmission is 0.9333, so 1.0714 keeps
    // overall brightness close to neutral.
    //
    colour *= 1.0714286;

    //
    // Add a very small amount of CRT light spread.
    // Base pixels remain untouched and POINT sampled.
    //
    colour += glow;

    //
    // BareCRT analogue light response.
    //
    // Give dark and mid tones a slightly deeper CRT-like response
    // while allowing bright colours to retain a little more punch.
    // This is entirely per-pixel, so it cannot introduce motion shimmer.
    //
    colour *=
        0.96 + (0.06 * colour);

    //
    // BareCRT subtle chroma response.
    //
    // CRT phosphors give saturated colours a little more separation.
    // Keep this deliberately restrained and entirely per-pixel.
    //
    float luminance =
        dot(colour, float3(0.299, 0.587, 0.114));

    colour =
        lerp(
            float3(luminance, luminance, luminance),
            colour,
            1.03
        );

    //
    // BareCRT soft black toe.
    //
    // Deepen the darkest tones very slightly while preserving
    // mid-tone and highlight detail.
    //
    colour =
        pow(
            max(colour, 0.0),
            float3(1.015, 1.015, 1.015)
        );

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
