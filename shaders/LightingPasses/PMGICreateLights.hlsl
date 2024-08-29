#pragma pack_matrix(row_major)

#include "../HelperFunctions.hlsli"
#include "RtxdiApplicationBridge.hlsli"
#include <rtxdi/PresamplingFunctions.hlsli>


#if USE_RAY_QUERY
[numthreads(16, 16, 1)]
void main(uint2 pixelPosition : SV_DispatchThreadID)
{
}
#else
[shader("raygeneration")]
void RayGen()
{
    uint2 GlobalIndex = DispatchRaysIndex().xy;
    RandomSamplerState rng = initRandomSampler(GlobalIndex, g_Const.frameIndex);
    
    // Sample a local light using the PDF texture
    uint2 texelPosition;
    float pdf;
    RTXDI_SamplePdfMipmap(rng, t_LocalLightPdfTexture, g_Const.localLightPdfTextureSize, texelPosition, pdf);
    uint lightIndex = RTXDI_ZCurveToLinearIndex(texelPosition);
    
    RAB_LightInfo lightInfo = RAB_LoadLightInfo(lightIndex + g_Const.lightBufferParams.localLightBufferRegion.firstLightIndex, false);
    
    // Sample a photon for that local light
    float4 rand = { sampleUniformRng(rng), sampleUniformRng(rng), sampleUniformRng(rng), sampleUniformRng(rng) };
    PolymorphicLightPhotonSample photonSample = PolymorphicLight::calcPhotonSample(lightInfo, rand);
    
    // Trace ray for that photon
    uint instanceMask = INSTANCE_MASK_OPAQUE;
    uint rayFlags = RAY_FLAG_NONE;
    
    if (g_Const.sceneConstants.enableAlphaTestedGeometry)
        instanceMask |= INSTANCE_MASK_ALPHA_TESTED;

    if (g_Const.sceneConstants.enableTransparentGeometry)
        instanceMask |= INSTANCE_MASK_TRANSPARENT;

    if (!g_Const.sceneConstants.enableTransparentGeometry && !g_Const.sceneConstants.enableAlphaTestedGeometry)
        rayFlags |= RAY_FLAG_CULL_NON_OPAQUE;
    
    RayDesc ray;
    ray.Origin = photonSample.position;
    ray.Direction = photonSample.direction;
    ray.TMin = 0.0f;
    ray.TMax = 1e+30f;
    
    RayPayload payload = (RayPayload) 0;
    payload.instanceID = ~0u;
    
    TraceRay(SceneBVH, rayFlags, instanceMask, 0, 0, 0, ray, payload);
    REPORT_RAY(payload.instanceID != ~0u);
    
    // Use 
    PolymorphicLightInfo virtualLightInfo = (PolymorphicLightInfo) 0;
    uint virtualLightBufferIndex = GlobalIndex.x;
    
    if (payload.instanceID != ~0u && payload.frontFace)
    {
        GeometrySample gs = getGeometryFromHit(payload.instanceID, payload.geometryIndex, payload.primitiveIndex, payload.barycentrics,
            GeomAttr_All, t_InstanceData, t_GeometryData, t_MaterialConstants);
            
        MaterialSample ms = sampleGeometryMaterial(gs, 0, 0, 0, MatAttr_BaseColor | MatAttr_Normal, s_MaterialSampler);
        
        float3 virtualLightPos = ray.Origin + ray.Direction * payload.committedRayT;
        
        RAB_Surface surface = (RAB_Surface)0;
        surface.normal = gs.geometryNormal;
        surface.worldPos = virtualLightPos;
        surface.roughness = 0;
        SplitBrdf brdf = EvaluateBrdf(surface, photonSample.position);
        
        float3 diffuse = brdf.demodulatedDiffuse * photonSample.radiance / calcLuminance(photonSample.radiance);
        float3 radiance = surface.diffuseAlbedo * diffuse * g_Const.pmgi.scalingFactor;
        radiance /= square(g_Const.pmgi.lightSize);
        
        // Create virtual light
        packLightColor(radiance, virtualLightInfo);
        lightInfo.center = virtualLightPos;
        lightInfo.colorTypeAndFlags |= uint(PolymorphicLightType::kVirtual) << kPolymorphicLightTypeShift;
        lightInfo.scalars = f32tof16(g_Const.pmgi.lightSize);
        lightInfo.direction1 = ndirToOctUnorm32(gs.geometryNormal);
    }
    
    // Write virtual light to buffer
    u_VirtualLightDataBuffer[virtualLightBufferIndex] = virtualLightInfo;
    
}
#endif