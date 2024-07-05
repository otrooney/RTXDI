
#pragma pack_matrix(row_major)

#include "RtxdiApplicationBridge.hlsli"

#include <rtxdi/ReGIRSampling.hlsli>


// Need to move this into a utils shader file
uint globalIndexToGBufferPointer(uint2 GlobalIndex)
{
    // Dispatch size should be 1 in y dimension
    uint gbufferIndex = GlobalIndex.x;
    return gbufferIndex;
}

[numthreads(256, 1, 1)]
void main(uint GlobalIndex : SV_DispatchThreadID)
{
    uint gbufferIndex = globalIndexToGBufferPointer(GlobalIndex);
    GSGIGBufferData gsgiGBufferData = u_GSGIGBuffer[gbufferIndex];
    
    int gbufferIndexInt = int(gbufferIndex);
    int cellIndex = RTXDI_ReGIR_WorldPosToCellIndex(g_Const.regir, gsgiGBufferData.worldPos);
    
    if (cellIndex != -1)
    {
        int existingValue = 0;
        
        int bufferOffset = cellIndex * g_Const.regir.commonParams.lightsPerCell;
        
        [allow_uav_condition] for (int n = 0; n < g_Const.regir.commonParams.lightsPerCell; n++)
        {
            InterlockedCompareExchange(u_GSGIGridBuffer[bufferOffset + n], -1, gbufferIndexInt, existingValue);

            if (existingValue == -1)
                break;
        }
    }
}
