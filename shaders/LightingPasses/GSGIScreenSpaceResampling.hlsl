
#pragma pack_matrix(row_major)

#include "GSGIUtils.hlsli"
#include "RtxdiApplicationBridge.hlsli"

#include <rtxdi/InitialSamplingFunctions.hlsli>
#include <rtxdi/DIResamplingFunctions.hlsli>


#if USE_RAY_QUERY
[numthreads(16, 16, 1)]
void main(uint2 GlobalIndex : SV_DispatchThreadID)
#else
[shader("raygeneration")]
void RayGen()
#endif
{
#if !USE_RAY_QUERY
    uint2 GlobalIndex = DispatchRaysIndex().xy;
#endif
    
    uint origBufferIndex = globalIndexToGBufferPointer(GlobalIndex);
    GSGIGBufferData origGBufferData = u_GSGIGBuffer[origBufferIndex];
    RAB_Surface origSurface = ConvertGSGIGBufferToSurface(origGBufferData);
    RTXDI_DIReservoir curSample = RTXDI_UnpackDIReservoir(u_GSGIReservoirs[origBufferIndex]);
    
    // Initialize the output reservoir
    RTXDI_DIReservoir state = RTXDI_EmptyDIReservoir();
    RTXDI_CombineDIReservoirs(state, curSample, /* random = */0.5, curSample.targetPdf);
    
    RandomSamplerState rng = initRandomSampler(GlobalIndex, g_Const.frameIndex);

    // These should be configurable
    float normalThreshold = 0.5f;
    float depthThreshold = 1.0f;
    
    // Find pixel position of reservoir
    float4 clipPos = mul(float4(origGBufferData.worldPos, 1.0), g_Const.view.matWorldToClip);
    int2 pixelPosition = int2(clipPos.xy);
    float viewDepth = clipPos.w;
    
    if (pixelPosition.x < 0 || pixelPosition.x >= g_Const.view.viewportSize.x || pixelPosition.y < 0 || pixelPosition.y >= g_Const.view.viewportSize.y)
        return;
    
    // Combine screen space reservior with existing reservoir
    RAB_Surface screenSurface = RAB_GetGBufferSurface(pixelPosition, false);

    if (!RTXDI_IsValidNeighbor(origGBufferData.geoNormal, screenSurface.geoNormal, viewDepth, screenSurface.viewDepth, normalThreshold, depthThreshold))
        return;
    
    uint2 screenReservoirPos = RTXDI_PixelPosToReservoirPos(pixelPosition, g_Const.runtimeParams.activeCheckerboardField);
    RTXDI_DIReservoir screenSample = RTXDI_LoadDIReservoir(g_Const.restirDI.reservoirBufferParams,
            screenReservoirPos, g_Const.restirDI.bufferIndices.spatialResamplingOutputBufferIndex);

    bool sampleSelected = RTXDI_CombineDIReservoirs(state, screenSample, sampleUniformRng(rng), screenSample.targetPdf);
    
    RTXDI_FinalizeResampling(state, 1.0, state.M);
    
    u_GSGIReservoirs[origBufferIndex] = RTXDI_PackDIReservoir(state);
}
