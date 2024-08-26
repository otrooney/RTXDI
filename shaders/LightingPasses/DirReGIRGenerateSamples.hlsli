#pragma pack_matrix(row_major)

#include "RtxdiApplicationBridge.hlsli"
#include "../DirReGIRParameters.h"

#include <rtxdi/InitialSamplingFunctions.hlsli>
#include <rtxdi/RtxdiParameters.h>

#define INVALID_LIGHT_INDEX 0x40000000u


uint2 GetUniformSample(inout RAB_RandomSamplerState rng)
{
    uint2 bufferLoc;
    bufferLoc.x = RAB_GetNextRandom(rng) * 16;
    bufferLoc.y = RAB_GetNextRandom(rng) * 16;
    return bufferLoc;
}

uint2 SampleDirToBufferLoc(float3 sampleDir)
{
    float2 sampleDirOct = ndirToOctSigned(sampleDir);
    sampleDirOct = (sampleDirOct + 1) / 2;
        
    uint2 bufferLoc = sampleDirOct * 16;
    return bufferLoc;
}

uint2 GetUniformHemisphereSample(RAB_Surface surface, inout RAB_RandomSamplerState rng)
{
    float2 randxy = { RAB_GetNextRandom(rng), RAB_GetNextRandom(rng) };
    float solidAnglePdf;
    float3 tangentDir = sampleSphere(randxy, solidAnglePdf);
    tangentDir.z = abs(tangentDir.z);
    
    float3 sampleDir = tangentToWorld(surface, tangentDir);
    return SampleDirToBufferLoc(sampleDir);
}

uint2 GetDiffuseSample(RAB_Surface surface, inout RAB_RandomSamplerState rng)
{
    float2 randxy = { RAB_GetNextRandom(rng), RAB_GetNextRandom(rng) };
    float pdf;
    float3 h = SampleCosHemisphere(randxy, pdf);
    
    float3 sampleDir = tangentToWorld(surface, h);
    return SampleDirToBufferLoc(sampleDir);
}

uint2 GetSpecularSample(RAB_Surface surface, inout RAB_RandomSamplerState rng)
{
    float2 randxy = { RAB_GetNextRandom(rng), RAB_GetNextRandom(rng) };
    float3 Ve = normalize(worldToTangent(surface, surface.viewDir));
    float3 h = ImportanceSampleGGX_VNDF(randxy, max(surface.roughness, kMinRoughness), Ve, 1.0);
    h = normalize(h);
    float3 sampleDir = reflect(-surface.viewDir, tangentToWorld(surface, h));
    
    return SampleDirToBufferLoc(sampleDir);
}

uint2 GetBrdfSample(RAB_Surface surface, float uniformProbability, inout RAB_RandomSamplerState rng)
{
    float rand = RAB_GetNextRandom(rng);
    if (rand < uniformProbability)
        return GetUniformHemisphereSample(surface, rng);
    else if (rand < uniformProbability + surface.diffuseProbability * (1 - uniformProbability))
        return GetDiffuseSample(surface, rng);
    return GetSpecularSample(surface, rng);
}

// Sample a local light from the Directional ReGIR buffer
void SelectNextLocalLightWithDirectionalReGIR(
    RAB_Surface surface,
    int cellIndex,
    inout RAB_RandomSamplerState rng,
    out RAB_LightInfo lightInfo,
    out uint lightIndex,
    out float invSourcePdf)
{
    uint2 bufferLoc;
    
    switch (g_Const.dirReGIRSampling)
    {
        case DirReGIRSampling::Uniform:
            bufferLoc = GetUniformSample(rng);
            break;
        case DirReGIRSampling::UniformHemisphere:
            bufferLoc = GetUniformHemisphereSample(surface, rng);
            break;
        case DirReGIRSampling::Diffuse:
            bufferLoc = GetDiffuseSample(surface, rng);
            break;
        case DirReGIRSampling::BRDF:
            bufferLoc = GetBrdfSample(surface, g_Const.dirReGIRBrdfUniformProbability, rng);
    }
    
    uint bufferIndex = (cellIndex * 16 * 16) + (bufferLoc.y * 16) + bufferLoc.x;
    
    uint2 tileData = u_DirReGIRBuffer[bufferIndex];
    lightIndex = tileData.x & RTXDI_LIGHT_INDEX_MASK;
    invSourcePdf = asfloat(tileData.y);
    
    if (lightIndex == INVALID_LIGHT_INDEX)
    {
        lightInfo = RAB_EmptyLightInfo();
        lightIndex = 0;
    }
    else if ((tileData.x & RTXDI_LIGHT_COMPACT_BIT) != 0)
    {
        uint4 packedData1, packedData2;
        packedData1 = u_DirReGIRLightDataBuffer[bufferIndex * 2 + 0];
        packedData2 = u_DirReGIRLightDataBuffer[bufferIndex * 2 + 1];
        lightInfo = unpackCompactLightInfo(packedData1, packedData2);
    }
    else
    {
        lightInfo = RAB_LoadLightInfo(lightIndex, false);
    }
    
}

RTXDI_DIReservoir SampleLocalLightsWithDirectionalReGIRInternal(
    inout RAB_RandomSamplerState rng,
    inout RAB_RandomSamplerState coherentRng,
    RAB_Surface surface,
    RTXDI_SampleParameters sampleParams,
    ReSTIRDI_LocalLightSamplingMode localLightSamplingMode,
    RTXDI_LightBufferRegion localLightBufferRegion,
    RTXDI_RISBufferSegmentParameters localLightRISBufferSegmentParams,
    ReGIR_Parameters regirParams,
    out RAB_LightSample o_selectedSample)
{
    RTXDI_DIReservoir state = RTXDI_EmptyDIReservoir();
    
    RTXDI_LocalLightSelectionContext fallbackCtx;
    int cellIndex = RTXDI_CalculateReGIRCellIndex(rng, regirParams, surface);
    
    if (regirParams.commonParams.localLightSamplingFallbackMode == ReSTIRDI_LocalLightSamplingMode_POWER_RIS)
        fallbackCtx = RTXDI_InitializeLocalLightSelectionContextRIS(coherentRng, localLightRISBufferSegmentParams);
    else
        fallbackCtx = RTXDI_InitializeLocalLightSelectionContextUniform(localLightBufferRegion);

    for (uint i = 0; i < sampleParams.numLocalLightSamples; i++)
    {
        uint lightIndex;
        RAB_LightInfo lightInfo;
        float invSourcePdf;

        if (cellIndex >= 0)
            SelectNextLocalLightWithDirectionalReGIR(surface, cellIndex, rng, lightInfo, lightIndex, invSourcePdf);
        else
            RTXDI_SelectNextLocalLight(fallbackCtx, rng, lightInfo, lightIndex, invSourcePdf);
        float2 uv = RTXDI_RandomlySelectLocalLightUV(rng);
        bool zeroPdf = RTXDI_StreamLocalLightAtUVIntoReservoir(rng, sampleParams, surface, lightIndex, uv, invSourcePdf, lightInfo, state, o_selectedSample);

        if (zeroPdf)
            continue;
    }

    RTXDI_FinalizeResampling(state, 1.0, sampleParams.numMisSamples);
    state.M = 1;

    return state;
}

RTXDI_DIReservoir SampleLocalLightsWithDirectionalReGIR(
    inout RAB_RandomSamplerState rng,
    inout RAB_RandomSamplerState coherentRng,
    RAB_Surface surface,
    RTXDI_SampleParameters sampleParams,
    ReSTIRDI_LocalLightSamplingMode localLightSamplingMode,
    RTXDI_LightBufferRegion localLightBufferRegion,
    RTXDI_RISBufferSegmentParameters localLightRISBufferSegmentParams,
    ReGIR_Parameters regirParams,
    out RAB_LightSample o_selectedSample)
{
    o_selectedSample = RAB_EmptyLightSample();

    if (localLightBufferRegion.numLights == 0)
        return RTXDI_EmptyDIReservoir();

    if (sampleParams.numLocalLightSamples == 0)
        return RTXDI_EmptyDIReservoir();
    
    return SampleLocalLightsWithDirectionalReGIRInternal(rng, coherentRng, surface, sampleParams, localLightSamplingMode, localLightBufferRegion,
        localLightRISBufferSegmentParams, regirParams, o_selectedSample);
}

// Samples the lights for a given surface using Directional ReGIR
// Identical to RTXDI_SampleLightsForSurface except for local light sampling
RTXDI_DIReservoir SampleLightsForSurfaceWithDirectionalReGIR(
    inout RAB_RandomSamplerState rng,
    inout RAB_RandomSamplerState coherentRng,
    RAB_Surface surface,
    RTXDI_SampleParameters sampleParams,
    RTXDI_LightBufferParameters lightBufferParams,
    ReSTIRDI_LocalLightSamplingMode localLightSamplingMode,
    RTXDI_RISBufferSegmentParameters localLightRISBufferSegmentParams,
    RTXDI_RISBufferSegmentParameters environmentLightRISBufferSegmentParams,
    ReGIR_Parameters regirParams,
    out RAB_LightSample o_lightSample)
{
    o_lightSample = RAB_EmptyLightSample();

    RTXDI_DIReservoir localReservoir;
    RAB_LightSample localSample = RAB_EmptyLightSample();

    localReservoir = SampleLocalLightsWithDirectionalReGIR(rng, coherentRng, surface,
        sampleParams, localLightSamplingMode, lightBufferParams.localLightBufferRegion,
        localLightRISBufferSegmentParams, regirParams, localSample);

    RAB_LightSample infiniteSample = RAB_EmptyLightSample();
    RTXDI_DIReservoir infiniteReservoir = RTXDI_SampleInfiniteLights(rng, surface,
        sampleParams.numInfiniteLightSamples, lightBufferParams.infiniteLightBufferRegion, infiniteSample);

    RAB_LightSample environmentSample = RAB_EmptyLightSample();
    RTXDI_DIReservoir environmentReservoir = RTXDI_SampleEnvironmentMap(rng, coherentRng, surface,
        sampleParams, lightBufferParams.environmentLightParams, environmentLightRISBufferSegmentParams, environmentSample);


    RAB_LightSample brdfSample = RAB_EmptyLightSample();
    RTXDI_DIReservoir brdfReservoir = RTXDI_SampleBrdf(rng, surface, sampleParams, lightBufferParams, brdfSample);

    RTXDI_DIReservoir state = RTXDI_EmptyDIReservoir();
    RTXDI_CombineDIReservoirs(state, localReservoir, 0.5, localReservoir.targetPdf);
    bool selectInfinite = RTXDI_CombineDIReservoirs(state, infiniteReservoir, RAB_GetNextRandom(rng), infiniteReservoir.targetPdf);

    bool selectEnvironment = RTXDI_CombineDIReservoirs(state, environmentReservoir, RAB_GetNextRandom(rng), environmentReservoir.targetPdf);

    bool selectBrdf = RTXDI_CombineDIReservoirs(state, brdfReservoir, RAB_GetNextRandom(rng), brdfReservoir.targetPdf);
    
    RTXDI_FinalizeResampling(state, 1.0, 1.0);
    state.M = 1;

    if (selectBrdf)
        o_lightSample = brdfSample;
    else

    if (selectEnvironment)
        o_lightSample = environmentSample;
    else if (selectInfinite)
        o_lightSample = infiniteSample;
    else
        o_lightSample = localSample;

    return state;
}