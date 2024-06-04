


#if USE_RAY_QUERY
[numthreads(16, 16, 1)]
void main(uint2 pixelPosition : SV_DispatchThreadID)
#else
[shader("raygeneration")]
void RayGen()
#endif
{
    // Generate some rays
}

#if !USE_RAY_QUERY
struct RayPayload
{
    float2 barycentrics;
};

struct Attributes
{
    float2 uv;
};

[shader("miss")]
void Miss(inout RayPayload payload : SV_RayPayload)
{
}

[shader("anyhit")]
void AnyHit(inout RayPayload payload : SV_RayPayload, in Attributes attrib : SV_IntersectionAttributes)
{
}
#endif