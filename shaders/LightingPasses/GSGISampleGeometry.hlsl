
#include "../HelperFunctions.hlsli"
#include "../SceneGeometry.hlsli"
#include "../ShaderParameters.h"

RaytracingAccelerationStructure SceneBVH : register(t30);
StructuredBuffer<InstanceData> t_InstanceData : register(t32);
StructuredBuffer<GeometryData> t_GeometryData : register(t33);
StructuredBuffer<MaterialConstants> t_MaterialConstants : register(t34);

ConstantBuffer<ResamplingConstants> g_Const : register(b0);
VK_PUSH_CONSTANT ConstantBuffer <PerPassConstants>g_PerPassConstants : register(b1);

RWBuffer<uint> u_RayCountBuffer : register(u12);

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
    uint rayFlags = RAY_FLAG_NONE;
    
    uint2 GlobalIndex = DispatchRaysIndex().xy;
    RandomSamplerState rng = initRandomSampler(GlobalIndex, 1);
    
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
    
    IgnoreHit();
   
}

[shader("closesthit")]
void ClosestHit(inout RayPayload payload : SV_RayPayload, in Attributes attrib : SV_IntersectionAttributes)
{
    // payload.instanceID = InstanceID();
}
#endif