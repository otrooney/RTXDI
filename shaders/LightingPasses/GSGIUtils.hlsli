
#pragma pack_matrix(row_major)

#include "RtxdiApplicationBridge.hlsli"

uint globalIndexToGBufferPointer(uint2 GlobalIndex)
{
    // Dispatch size should be 1 in y dimension
    return GlobalIndex.x;
}

RAB_Surface ConvertGSGIGBufferToSurface(GSGIGBufferData gsgiGBufferData)
{
    RAB_Surface surface;
    
    surface.worldPos = gsgiGBufferData.worldPos;
    surface.normal = gsgiGBufferData.normal;
    surface.geoNormal = gsgiGBufferData.geoNormal;
    surface.diffuseAlbedo = Unpack_R11G11B10_UFLOAT(gsgiGBufferData.diffuseAlbedo);
    
    // For now, treat all surfaces as 100% diffuse
    surface.diffuseProbability = 1.0f;
    surface.viewDir = -gsgiGBufferData.normal;
    surface.viewDepth = 1;
    surface.specularF0 = float3(0, 0, 0);
    surface.roughness = 0.0f;
    
    return surface;
}
