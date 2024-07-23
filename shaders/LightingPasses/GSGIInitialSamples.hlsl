
#pragma pack_matrix(row_major)

#include "GSGIUtils.hlsli"
#include "RtxdiApplicationBridge.hlsli"
#include "../PolymorphicLight.hlsli"

#include <rtxdi/InitialSamplingFunctions.hlsli>


GSGIGBufferData GetGSGIGBufferData(uint2 GlobalIndex)
{
    uint gbufferIndex = globalIndexToGBufferPointer(GlobalIndex);
    GSGIGBufferData gsgiGBufferData = u_GSGIGBuffer[gbufferIndex];
    return gsgiGBufferData;
}

#if USE_RAY_QUERY
[numthreads(16, 16, 1)]
void main(uint2 GlobalIndex : SV_DispatchThreadID)
#else
[shader("raygeneration")]
void RayGen()
#endif
{
    // Largely duplicated from DIGenerateInitialSamples.hlsl
#if !USE_RAY_QUERY
    uint2 GlobalIndex = DispatchRaysIndex().xy;
#endif
    const RTXDI_RuntimeParameters params = g_Const.runtimeParams;
    
    RAB_RandomSamplerState rng = RAB_InitRandomSampler(GlobalIndex, 1);
    RAB_RandomSamplerState tileRng = RAB_InitRandomSampler(GlobalIndex / RTXDI_TILE_SIZE_IN_PIXELS, 1);

    GSGIGBufferData gsgiGBufferData = GetGSGIGBufferData(GlobalIndex);
    RAB_Surface surface = ConvertGSGIGBufferToSurface(gsgiGBufferData);

    RTXDI_SampleParameters sampleParams = RTXDI_InitSampleParameters(
        g_Const.restirDI.initialSamplingParams.numPrimaryLocalLightSamples,
        g_Const.restirDI.initialSamplingParams.numPrimaryInfiniteLightSamples,
        g_Const.restirDI.initialSamplingParams.numPrimaryEnvironmentSamples,
        g_Const.restirDI.initialSamplingParams.numPrimaryBrdfSamples,
        g_Const.restirDI.initialSamplingParams.brdfCutoff,
        0.001f);

    RAB_LightSample lightSample;
    RTXDI_DIReservoir reservoir = RTXDI_SampleLightsForSurface(rng, tileRng, surface,
        sampleParams, g_Const.lightBufferParams, g_Const.restirDI.initialSamplingParams.localLightSamplingMode,
#ifdef RTXDI_ENABLE_PRESAMPLING
        g_Const.localLightsRISBufferSegmentParams, g_Const.environmentLightRISBufferSegmentParams,
#if RTXDI_REGIR_MODE != RTXDI_REGIR_MODE_DISABLED
        g_Const.regir,
#endif
#endif
        lightSample);
    
    // Check conservative visibility
    if (RTXDI_IsValidDIReservoir(reservoir) && g_Const.gsgi.resamplingMode != GSGIResamplingMode::None)
    {
        if (!RAB_GetConservativeVisibility(surface, lightSample))
        {
            RTXDI_StoreVisibilityInDIReservoir(reservoir, 0, true);
        }
    }
    
    // Write to GSGI reservoir buffer
    uint bufferIndex = globalIndexToGBufferPointer(GlobalIndex);
    u_GSGIReservoirs[bufferIndex] = RTXDI_PackDIReservoir(reservoir);

}
