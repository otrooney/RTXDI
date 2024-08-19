#pragma pack_matrix(row_major)

#include "RtxdiApplicationBridge.hlsli"

#include <rtxdi/InitialSamplingFunctions.hlsli>
//#include <rtxdi/ReGIRSampling.hlsli>

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
    RTXDI_DIReservoir state = RTXDI_EmptyDIReservoir();
    return state;
}