#pragma pack_matrix(row_major)

#include "RtxdiApplicationBridge.hlsli"

#include <rtxdi/InitialSamplingFunctions.hlsli>
//#include <rtxdi/ReGIRSampling.hlsli>


// Sample a local light from the Directional ReGIR buffer using the surface BRDF
void SelectNextLocalLightWithDirectionalReGIR(
    RAB_Surface surface,
    int cellIndex,
    inout RAB_RandomSamplerState rng,
    out RAB_LightInfo lightInfo,
    out uint lightIndex,
    out float invSourcePdf)
{
    //float3 worldPos = surface.worldPos;
    //float3 normal = surface.normal;
    //int cellIndex = RTXDI_ReGIR_WorldPosToCellIndex(g_Const.regir, worldPos);
    
    //float pdf;
    //float2 randxy = { RAB_GetNextRandom(rng), RAB_GetNextRandom(rng) };
    //float3 h = SampleCosHemisphere(randxy, pdf);
    //float3 sampleDir = tangentToWorld(surface, h);
    
    float3 sampleDir;
    RAB_GetSurfaceBrdfSample(surface, rng, sampleDir);
    float2 sampleDirOct = ndirToOctSigned(sampleDir);
    
    uint bufferLocX = sampleDirOct.x * 32;
    uint bufferLocY = sampleDirOct.y * 32;
    uint bufferIndex = (cellIndex * 32 * 32) + (bufferLocY * 32) + bufferLocX;
    
    uint2 tileData = u_DirReGIRBuffer[bufferIndex];
    lightIndex = tileData.x & RTXDI_LIGHT_INDEX_MASK;
    invSourcePdf = asfloat(tileData.y);
    
    if ((tileData.x & RTXDI_LIGHT_COMPACT_BIT) != 0)
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
    int cellIndex = RTXDI_CalculateReGIRCellIndex(coherentRng, regirParams, surface);
    
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