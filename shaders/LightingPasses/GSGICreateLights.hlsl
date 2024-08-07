
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
#if !USE_RAY_QUERY
    uint2 GlobalIndex = DispatchRaysIndex().xy;
#endif
    
    GSGIGBufferData gsgiGBufferData = GetGSGIGBufferData(GlobalIndex);
    RAB_Surface surface = ConvertGSGIGBufferToSurface(gsgiGBufferData);
    
    uint bufferIndex = globalIndexToGBufferPointer(GlobalIndex);
    RTXDI_DIReservoir reservoir = RTXDI_UnpackDIReservoir(u_GSGIReservoirs[bufferIndex]);
    
    RAB_LightInfo sourceLightInfo = RAB_LoadLightInfo(RTXDI_GetDIReservoirLightIndex(reservoir), false);

    RAB_LightSample lightSample = RAB_SamplePolymorphicLight(sourceLightInfo,
            surface, RTXDI_GetDIReservoirSampleUV(reservoir));
    
    float3 visibility = GetFinalVisibility(SceneBVH, surface, lightSample.position);

    lightSample.radiance *= visibility.rgb;
    
    // "Shade" light sample
    lightSample.radiance *= RTXDI_GetDIReservoirInvPdf(reservoir) / lightSample.solidAnglePdf;
    SplitBrdf brdf = EvaluateBrdf(surface, lightSample.position);
    float3 diffuse = brdf.demodulatedDiffuse * lightSample.radiance;
    
    // Account for scaling factor, sample density, etc.
    float scalingFactor = gsgiGBufferData.rSampleDensity * gsgiGBufferData.sumOfWeights * g_Const.gsgi.scalingFactor;
    float3 radiance = surface.diffuseAlbedo * diffuse * scalingFactor;
    
    float radius = gsgiGBufferData.distanceToRayOrigin * g_Const.gsgi.lightSize;
    radiance /= square(g_Const.gsgi.lightSize);
    
    // Represent as a virtual light type
    PolymorphicLightInfo lightInfo = (PolymorphicLightInfo) 0;
    packLightColor(radiance, lightInfo);
    lightInfo.center = gsgiGBufferData.worldPos;
    lightInfo.colorTypeAndFlags |= uint(PolymorphicLightType::kVirtual) << kPolymorphicLightTypeShift;
    lightInfo.scalars = f32tof16(radius);
    lightInfo.direction1 = ndirToOctUnorm32(gsgiGBufferData.geoNormal);

    // Write to virtual light buffer
    uint gbufferIndex = globalIndexToGBufferPointer(GlobalIndex);
    u_VirtualLightDataBuffer[gbufferIndex] = lightInfo;
}
