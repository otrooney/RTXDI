
#pragma pack_matrix(row_major)

#include "GSGIUtils.hlsli"
#include "RtxdiApplicationBridge.hlsli"

#include <rtxdi/ReGIRSampling.hlsli>


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
        
        // Iterate through each slot for this cell, and use the atomic function InterlockedCompareExchange
        // to write the value. All empty slots contain the value -1, so if it returns -1, then the value has
        // been written and we can exit the loop.
        [allow_uav_condition] for (int n = 0; n < g_Const.regir.commonParams.lightsPerCell; n++)
        {
            InterlockedCompareExchange(u_GSGIGridBuffer[bufferOffset + n], -1, gbufferIndexInt, existingValue);

            if (existingValue == -1)
                break;
        }
    }
}
