

#include "../HelperFunctions.hlsli"
#include "../SceneGeometry.hlsli"
#include "../ShaderParameters.h"
#include "../GBufferHelpers.hlsli"

RaytracingAccelerationStructure SceneBVH : register(t30);
StructuredBuffer<InstanceData> t_InstanceData : register(t32);
StructuredBuffer<GeometryData> t_GeometryData : register(t33);
StructuredBuffer<MaterialConstants> t_MaterialConstants : register(t34);

ConstantBuffer<ResamplingConstants> g_Const : register(b0);
VK_PUSH_CONSTANT ConstantBuffer <PerPassConstants>g_PerPassConstants : register(b1);
SamplerState s_MaterialSampler : register(s0);

RWBuffer<uint> u_RayCountBuffer : register(u12);
RWStructuredBuffer<GSGIGBufferData> u_GSGIGBuffer : register(u14);

// For debug vis
RWTexture2D<uint> t_GBufferDiffuseAlbedo : register(u15);

struct RayPayload
{
    float committedRayT;
    uint instanceID;
    uint geometryIndex;
    uint primitiveIndex;
    float2 barycentrics;
    float sumOfWeights;
    RandomSamplerState rngState;
};

uint globalIndexToGBufferPointer(uint2 GlobalIndex)
{
    // Dispatch size should be 1 in y dimension
    uint gbufferIndex = GlobalIndex.x;
    return gbufferIndex;
}

uint2 globalIndexToDebugVisPointer(uint2 GlobalIndex)
{
    // Represent as 64px wide 2D for visibility
    uint2 debugBufferIndex;
    debugBufferIndex.x = GlobalIndex.x % 64;
    debugBufferIndex.y = GlobalIndex.x / 64;
    return debugBufferIndex;
}

void writeToGBuffer(
    RayDesc ray,
    RayPayload payload,
    uint2 GlobalIndex
)
{
    GSGIGBufferData gsgiGBufferData = (GSGIGBufferData) 0;
    
    if (payload.instanceID != ~0u)
    {
        GeometrySample gs = getGeometryFromHit(payload.instanceID, payload.geometryIndex, payload.primitiveIndex, payload.barycentrics,
            GeomAttr_All, t_InstanceData, t_GeometryData, t_MaterialConstants);
    
        MaterialSample ms = sampleGeometryMaterial(gs, 0, 0, 0, MatAttr_BaseColor | MatAttr_Normal, s_MaterialSampler);
    
        gsgiGBufferData.worldPos = ray.Origin + ray.Direction * payload.committedRayT;
        gsgiGBufferData.diffuseAlbedo = Pack_R11G11B10_UFLOAT(ms.diffuseAlbedo);
    }
    else
    {
        gsgiGBufferData.worldPos = float3(0, 0, 0);
        gsgiGBufferData.diffuseAlbedo = 0;
    }
    
    // Write to GSGI G buffer
    uint gbufferIndex = globalIndexToGBufferPointer(GlobalIndex);
    u_GSGIGBuffer[gbufferIndex] = gsgiGBufferData;
    
    uint2 debugVisIndex = globalIndexToDebugVisPointer(GlobalIndex);
    t_GBufferDiffuseAlbedo[debugVisIndex] = gsgiGBufferData.diffuseAlbedo;

}

#if USE_RAY_QUERY
[numthreads(16, 16, 1)]
void main(uint2 pixelPosition : SV_DispatchThreadID)
{
}
#else
[shader("raygeneration")]
void RayGen()
{
    // Generate some rays
    
    uint instanceMask = INSTANCE_MASK_OPAQUE;
    uint rayFlags = RAY_FLAG_SKIP_CLOSEST_HIT_SHADER | RAY_FLAG_FORCE_NON_OPAQUE;
    
    uint2 GlobalIndex = DispatchRaysIndex().xy;
    RandomSamplerState rng = initRandomSampler(GlobalIndex, g_Const.frameIndex);
    
    float theta = 2 * c_pi * sampleUniformRng(rng);
    float phi = acos(1 - 2 * sampleUniformRng(rng));
    float dirX = sin(phi) * cos(theta);
    float dirY = sin(phi) * sin(theta);
    float dirZ = cos(phi);
    
    RayDesc ray;
    ray.Origin = g_Const.view.cameraDirectionOrPosition.xyz;
    ray.Direction = float3(dirX, dirY, dirZ);
    ray.TMin = 0.0f;
    ray.TMax = 1e+30f;
    
    RayPayload payload;
    payload.committedRayT = 0;
    payload.instanceID = ~0u;
    payload.primitiveIndex = 0;
    payload.barycentrics = 0;
    payload.sumOfWeights = 0;
    payload.rngState = rng;

    TraceRay(SceneBVH, rayFlags, instanceMask, 0, 0, 0, ray, payload);
    REPORT_RAY(payload.instanceID != ~0u);
    
    writeToGBuffer(ray, payload, GlobalIndex);
    
}
#endif

struct Attributes
{
    float2 uv;
};

#if !USE_RAY_QUERY
[shader("miss")]
void Miss(inout RayPayload payload : SV_RayPayload)
{
}

[shader("anyhit")]
void AnyHit(inout RayPayload payload : SV_RayPayload, in Attributes attrib : SV_IntersectionAttributes)
{
    uint instanceIndex = InstanceID();
    uint geometryIndex = GeometryIndex();
    uint primitiveIndex = PrimitiveIndex();
    float2 rayBarycentrics = attrib.uv;
    
    GeometrySample gs = getGeometryFromHit(instanceIndex, geometryIndex, primitiveIndex, rayBarycentrics,
        GeomAttr_Position, t_InstanceData, t_GeometryData, t_MaterialConstants);
    
    // Determine weight based on angle of geometry normal to ray
    float3 flatNormal = gs.flatNormal;
    float3 rayDirection = WorldRayDirection();
    
    float angleCos = dot(rayDirection, flatNormal);
    float weight = rsqrt(1 - angleCos * angleCos);
    
    // Use reservoir sampling to determine whether to use this hit
    payload.sumOfWeights += weight;
    float sampleProb = weight / payload.sumOfWeights;
    float rndSample = sampleUniformRng(payload.rngState);
    
    if (rndSample < sampleProb)
    {
        // Use sample
        payload.committedRayT = RayTCurrent();
        payload.instanceID = instanceIndex;
        payload.geometryIndex = geometryIndex;
        payload.primitiveIndex = primitiveIndex;
        payload.barycentrics = rayBarycentrics;
    }
}

[shader("closesthit")]
void ClosestHit(inout RayPayload payload : SV_RayPayload, in Attributes attrib : SV_IntersectionAttributes)
{
}
#endif