
#pragma pack_matrix(row_major)

#include "RtxdiApplicationBridge.hlsli"
#include "../PolymorphicLight.hlsli"

#include <rtxdi/InitialSamplingFunctions.hlsli>


// Need to move this into a utils shader file
uint globalIndexToGBufferPointer(uint2 GlobalIndex)
{
    // Dispatch size should be 1 in y dimension
    uint gbufferIndex = GlobalIndex.x;
    return gbufferIndex;
}

uint2 globalIndexToDebugVisPointer(uint2 GlobalIndex, uint offset)
{
    // Represent as 64px wide 2D for visibility, offset on x axis
    uint2 debugBufferIndex;
    debugBufferIndex.x = (GlobalIndex.x % 64) + 512 + offset;
    debugBufferIndex.y = GlobalIndex.x / 64;
    return debugBufferIndex;
}

GSGIGBufferData GetGSGIGBufferData(uint2 GlobalIndex)
{
    uint gbufferIndex = globalIndexToGBufferPointer(GlobalIndex);
    GSGIGBufferData gsgiGBufferData = u_GSGIGBuffer[gbufferIndex];
    return gsgiGBufferData;
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

#if USE_RAY_QUERY
[numthreads(16, 16, 1)]
void main(uint2 GlobalIndex : SV_DispatchThreadID)
#else
[shader("raygeneration")]
void RayGen()
#endif
{
    // Largely duplicated from DIGenerateInitialSamples.hlsl, but we go straight to final visibility
    // testing, as we're not doing resampling (yet)
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
    
    float3 visibility = GetFinalVisibility(SceneBVH, surface, lightSample.position);

    lightSample.radiance *= visibility.rgb;
    
    // "Shade" light sample
    lightSample.radiance *= RTXDI_GetDIReservoirInvPdf(reservoir) / lightSample.solidAnglePdf;
    SplitBrdf brdf = EvaluateBrdf(surface, lightSample.position);
    float3 diffuse = brdf.demodulatedDiffuse * lightSample.radiance;
    
    float luminance = calcLuminance(diffuse * surface.diffuseAlbedo);
    
    // Account for scaling factor, sample density, etc.
    luminance *= g_Const.gsgi.scalingFactor;
    // luminance = min(luminance, g_Const.gsgi.boilingFilter);
    
    luminance *= gsgiGBufferData.rSampleDensity * gsgiGBufferData.sumOfWeights;
    float3 radiance = surface.diffuseAlbedo * luminance * 0.01;
    
    PolymorphicLightInfo lightInfo = (PolymorphicLightInfo) 0;
    
    if (g_Const.gsgi.virtualLightType == VirtualLightType::Disk)
    {
        // Represent as a disk light
        float radius = gsgiGBufferData.distance * g_Const.gsgi.lightSize;
        radiance /= pow(g_Const.gsgi.lightSize, 2);

        packLightColor(radiance, lightInfo);
        lightInfo.center = gsgiGBufferData.worldPos;
        lightInfo.colorTypeAndFlags |= uint(PolymorphicLightType::kDisk) << kPolymorphicLightTypeShift;
        lightInfo.scalars = f32tof16(radius);
        lightInfo.direction1 = ndirToOctUnorm32(gsgiGBufferData.geoNormal);
    }
    else if (g_Const.gsgi.virtualLightType == VirtualLightType::Spot)
    {
        // Represent as a spot light
        float radius = gsgiGBufferData.distance * g_Const.gsgi.lightSize;
        radiance /= pow(g_Const.gsgi.lightSize, 2);

        packLightColor(radiance, lightInfo);
        lightInfo.colorTypeAndFlags |= uint(PolymorphicLightType::kSphere) << kPolymorphicLightTypeShift;
        lightInfo.colorTypeAndFlags |= kPolymorphicLightShapingEnableBit;
        lightInfo.center = gsgiGBufferData.worldPos;
        lightInfo.scalars = f32tof16(radius);
        
        lightInfo.primaryAxis = ndirToOctUnorm32(gsgiGBufferData.geoNormal);
        lightInfo.cosConeAngleAndSoftness = f32tof16(-1.0f);
        lightInfo.cosConeAngleAndSoftness |= f32tof16(0.0f) << 16;
    }
    else
    {
        // Represent as a point light
        radiance *= gsgiGBufferData.distance * gsgiGBufferData.distance;
        
        packLightColor(radiance, lightInfo);
        lightInfo.center = gsgiGBufferData.worldPos;
        lightInfo.colorTypeAndFlags |= uint(PolymorphicLightType::kPoint) << kPolymorphicLightTypeShift;
    }
    
    // Write to virtual light buffer
    uint gbufferIndex = globalIndexToGBufferPointer(GlobalIndex);
    u_VirtualLightDataBuffer[gbufferIndex] = lightInfo;
    
    // Write radiance to debug visualisation buffer (temporary)
    uint2 debugVisIndex = globalIndexToDebugVisPointer(GlobalIndex, 96);
    t_GSGIGBufferDiffuseAlbedo[debugVisIndex] = Pack_R11G11B10_UFLOAT(radiance);
    
    // Write world position to vis buffer (temporary)
    uint2 worldPosDebugVisIndex = globalIndexToDebugVisPointer(GlobalIndex, 192);
    t_GSGIGBufferDiffuseAlbedo[worldPosDebugVisIndex] = Pack_R11G11B10_UFLOAT(gsgiGBufferData.worldPos);
    
    // Write sum of weights to vis buffer (temporary)
    uint2 sumOfWeightsDebugVisIndex = globalIndexToDebugVisPointer(GlobalIndex, 288);
    t_GSGIGBufferDiffuseAlbedo[sumOfWeightsDebugVisIndex] = Pack_R11G11B10_UFLOAT(float3(gsgiGBufferData.sumOfWeights, 0.0f, 0.0f));
    
    // Write normal to vis buffer (temporary)
    uint2 normalDebugVisIndex = globalIndexToDebugVisPointer(GlobalIndex, 96);
    t_GSGIGBufferNormals[normalDebugVisIndex] = ndirToOctUnorm32(gsgiGBufferData.normal);
    
    // Write geonormal to vis buffer (temporary)
    uint2 geonormalDebugVisIndex = globalIndexToDebugVisPointer(GlobalIndex, 192);
    t_GSGIGBufferNormals[geonormalDebugVisIndex] = ndirToOctUnorm32(gsgiGBufferData.geoNormal);
}
