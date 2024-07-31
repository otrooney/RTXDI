
#pragma pack_matrix(row_major)

#include "GSGIUtils.hlsli"
#include "RtxdiApplicationBridge.hlsli"

#include <rtxdi/InitialSamplingFunctions.hlsli>
#include <rtxdi/DIResamplingFunctions.hlsli>

#include <rtxdi/ReGIRSampling.hlsli>


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
    RTXDI_DIReservoir origReservoir = RTXDI_UnpackDIReservoir(u_GSGIReservoirs[origBufferIndex]);
    
    // Initialize the output reservoir
    RTXDI_DIReservoir state = RTXDI_EmptyDIReservoir();
    state.canonicalWeight = 0.0f;
    
    int cellIndex = RTXDI_ReGIR_WorldPosToCellIndex(g_Const.regir, origGBufferData.worldPos);
    int bufferOffset = cellIndex * g_Const.regir.commonParams.lightsPerCell;
    
    int maxValidLights = g_Const.regir.commonParams.lightsPerCell;
    
    RandomSamplerState rng = initRandomSampler(GlobalIndex, g_Const.frameIndex);
    
    uint validSamples = 0;
    
    // These should be configurable
    uint maxAttempts = 100;
    uint numSamples = 8;
    float normalThreshold = 0.5f;
    float depthThreshold = 1.0f;
    
    for (int n = 0; n < maxAttempts; n++)
    {
        int rndIndex = int(sampleUniformRng(rng) * maxValidLights);
        int neighbourBufferIndex = u_GSGIGridBuffer[bufferOffset + rndIndex];
        
        // If the slot is empty, we set that slot as the maximum and continue. This stochastic bisection
        // approach makes it much more likely we'll find samples even if most slots are empty.
        if (neighbourBufferIndex == -1)
        {
            maxValidLights = rndIndex;
            if (maxValidLights == 1)
                break;
            continue;
        }
        
        // Don't stream this reservior into itself.
        // TODO: Avoid streaming the same neighbour multiple times.
        if (neighbourBufferIndex == origBufferIndex)
            continue;
        
        GSGIGBufferData neighbourGBufferData = u_GSGIGBuffer[neighbourBufferIndex];
        
        if (!RTXDI_IsValidNeighbor(origGBufferData.geoNormal, neighbourGBufferData.geoNormal, origGBufferData.distanceToCamera, neighbourGBufferData.distanceToCamera, normalThreshold, depthThreshold))
            continue;
        
        validSamples++;
        RTXDI_DIReservoir neighbourReservoir = RTXDI_UnpackDIReservoir(u_GSGIReservoirs[neighbourBufferIndex]);
        if (neighbourReservoir.M <= 0)
            continue;
            
        RAB_Surface neighborSurface = ConvertGSGIGBufferToSurface(neighbourGBufferData);
            
        RTXDI_StreamNeighborWithPairwiseMIS(state, sampleUniformRng(rng),
            neighbourReservoir, neighborSurface,
            origReservoir, origSurface,
            numSamples);

        if (validSamples >= numSamples)
            break;
    }
    
    // If we've seen no usable neighbor samples, set the weight of the central one to 1
    state.canonicalWeight = (validSamples <= 0) ? 1.0f : state.canonicalWeight;
    
    // Stream the canonical sample (i.e., from prior computations at this pixel in this frame) using pairwise MIS.
    RTXDI_StreamCanonicalWithPairwiseStep(state, sampleUniformRng(rng), origReservoir, origSurface);

    RTXDI_FinalizeResampling(state, 1.0, float(max(1, validSamples)));
    
    u_GSGIReservoirs[origBufferIndex] = RTXDI_PackDIReservoir(state);
}
