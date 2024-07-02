
#pragma pack_matrix(row_major)

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

uint2 globalIndexToDebugVisPointer(uint2 GlobalIndex, uint offset)
{
    // Represent as 64px wide 2D for visibility, offset on x axis
    uint2 debugBufferIndex;
    debugBufferIndex.x = (GlobalIndex.x % 64) + 512 + offset;
    debugBufferIndex.y = GlobalIndex.x / 64;
    return debugBufferIndex;
}

void writeToGBuffer(
    float3 origin,
    float3 direction,
    RayPayload payload,
    uint2 GlobalIndex,
    float rDensity
)
{
    GSGIGBufferData gsgiGBufferData = (GSGIGBufferData) 0;
    
    if (payload.instanceID != ~0u)
    {
        GeometrySample gs = getGeometryFromHit(payload.instanceID, payload.geometryIndex, payload.primitiveIndex, payload.barycentrics,
            GeomAttr_All, t_InstanceData, t_GeometryData, t_MaterialConstants);
            
        MaterialSample ms = sampleGeometryMaterial(gs, 0, 0, 0, MatAttr_BaseColor | MatAttr_Normal, s_MaterialSampler);
        
        gsgiGBufferData.worldPos = origin + direction * payload.committedRayT;
        gsgiGBufferData.diffuseAlbedo = Pack_R11G11B10_UFLOAT(ms.diffuseAlbedo);
        gsgiGBufferData.normal = ms.shadingNormal;
        gsgiGBufferData.geoNormal = gs.flatNormal;
        gsgiGBufferData.distance = payload.committedRayT;
        gsgiGBufferData.rSampleDensity = rDensity;
        gsgiGBufferData.sumOfWeights = payload.sumOfWeights;
    }
    else
    {
        gsgiGBufferData.worldPos = float3(0, 0, 0);
        gsgiGBufferData.diffuseAlbedo = 0;
        gsgiGBufferData.normal = float3(0, 0, 0);
        gsgiGBufferData.geoNormal = float3(0, 0, 0);
        gsgiGBufferData.distance = 0.0f;
        gsgiGBufferData.rSampleDensity = 1.0f;
        gsgiGBufferData.sumOfWeights = 0.0f;
    }
    
    // Write to GSGI G buffer
    uint gbufferIndex = globalIndexToGBufferPointer(GlobalIndex);
    u_GSGIGBuffer[gbufferIndex] = gsgiGBufferData;
    
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
    
    //float theta = 2 * c_pi * sampleUniformRng(rng);
    //float phi = acos(1 - 2 * sampleUniformRng(rng));
    //float dirX = sin(phi) * cos(theta);
    //float dirY = sin(phi) * sin(theta);
    //float dirZ = cos(phi);
    //float3 direction = float3(dirX, dirY, dirZ);
    
    // Randomly offset ray origin to reduce noise from acute angles
    float3 origin = g_Const.view.cameraDirectionOrPosition.xyz;
    origin.x = origin.x + (sampleUniformRng(rng) * g_Const.gsgi.sampleOriginOffset) - (g_Const.gsgi.sampleOriginOffset / 2);
    origin.y = origin.y + (sampleUniformRng(rng) * g_Const.gsgi.sampleOriginOffset) - (g_Const.gsgi.sampleOriginOffset / 2);
    origin.z = origin.z + (sampleUniformRng(rng) * g_Const.gsgi.sampleOriginOffset) - (g_Const.gsgi.sampleOriginOffset / 2);
    
    float2 rands = float2(sampleUniformRng(rng), sampleUniformRng(rng));
    float solidAnglePdf;
    float3 direction = sampleSphere(rands, solidAnglePdf);
    
    RayDesc ray;
    ray.Origin = origin;
    ray.Direction = direction;
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
    
    float rDensity = (4 * c_pi) / (g_Const.gsgi.samplesPerFrame * g_Const.gsgi.sampleLifespan);
    
    writeToGBuffer(origin, direction, payload, GlobalIndex, rDensity);
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
    
    // Double check the maths here
    float angleCos = dot(rayDirection, flatNormal);
    float weight = 1 / abs(angleCos);
    
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