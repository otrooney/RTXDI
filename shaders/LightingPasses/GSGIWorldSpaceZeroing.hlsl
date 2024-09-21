
#pragma pack_matrix(row_major)

#include "RtxdiApplicationBridge.hlsli"


[numthreads(256, 1, 1)]
void main(uint GlobalIndex : SV_DispatchThreadID)
{
    u_GSGIGridBuffer[GlobalIndex.x] = -1;
}
