
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
    surface.viewDir = gsgiGBufferData.normal;
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
    // testing, as we're not doing spatial or temporal resampling
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
    
    // Account for distance, sample density and scaling factor
    luminance *= pow(gsgiGBufferData.distance, 2) * gsgiGBufferData.rSampleDensity * gsgiGBufferData.sumOfAdjWeights;
    luminance *= g_Const.gsgi.scalingFactor;
    float3 radiance = surface.diffuseAlbedo * luminance;
    
    // Represent as a point light with 180 degree cone
    //LightShaping lightShaping;
    //lightShaping.cosConeAngle = -1.0;
    //lightShaping.primaryAxis = gsgiGBufferData.normal;
    //lightShaping.cosConeSoftness = 1.0;
    //lightShaping.isSpot = true;
    //lightShaping.iesProfileIndex = -1;
    
    //PointLight pointLight;
    //pointLight.position = gsgiGBufferData.worldPos;
    //pointLight.flux = lightSample.radiance;
    //pointLight.shaping = lightShaping;

    // Represent as a simple point light
    // Write to virtual light buffer
    PolymorphicLightInfo lightInfo = (PolymorphicLightInfo) 0;
    lightInfo.center = gsgiGBufferData.worldPos;
    packLightColor(radiance, lightInfo);
    lightInfo.colorTypeAndFlags |= uint(PolymorphicLightType::kPoint) << kPolymorphicLightTypeShift;
    
    uint gbufferIndex = globalIndexToGBufferPointer(GlobalIndex);
    u_VirtualLightDataBuffer[gbufferIndex] = lightInfo;
    
    // Write radiance to debug visualisation buffer (temporary)
    uint2 debugVisIndex = globalIndexToDebugVisPointer(GlobalIndex, 96);
    t_GSGIGBufferDiffuseAlbedo[debugVisIndex] = Pack_R11G11B10_UFLOAT(radiance);
    
    // Write world position to vis buffer (temporary)
    uint2 worldPosDebugVisIndex = globalIndexToDebugVisPointer(GlobalIndex, 192);
    t_GSGIGBufferDiffuseAlbedo[worldPosDebugVisIndex] = Pack_R11G11B10_UFLOAT(gsgiGBufferData.worldPos);
    
    
}
