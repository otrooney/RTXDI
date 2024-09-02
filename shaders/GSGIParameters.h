
#ifndef RTXDI_GSGI_PARAMETERS_H
#define RTXDI_GSGI_PARAMETERS_H

#include <rtxdi/ReSTIRDIParameters.h>
#include <rtxdi/RtxdiTypes.h>


#define GSGIResamplingMode_NONE 0
#define GSGIResamplingMode_WORLDSPACE 1
#define GSGIResamplingMode_SCREENSPACE 2

#define VirtualLightContribution_DIFFUSE_SPECULAR 0
#define VirtualLightContribution_DIFFUSE 1


#ifdef __cplusplus
enum class GSGIResamplingMode : uint32_t
{
    None = GSGIResamplingMode_NONE,
    WorldSpace = GSGIResamplingMode_WORLDSPACE,
    ScreenSpace = GSGIResamplingMode_SCREENSPACE
};

enum class VirtualLightContribution : uint32_t
{
    DiffuseAndSpecular = VirtualLightContribution_DIFFUSE_SPECULAR,
    DiffuseOnly = VirtualLightContribution_DIFFUSE
};

#else
#define GSGIResamplingMode uint32_t
#define VirtualLightContribution uint32_t
#endif


struct GSGI_Parameters
{
    uint32_t samplesPerFrame;
    uint32_t sampleLifespan;
    float sampleOriginOffset;
    GSGIResamplingMode resamplingMode;
    float scalingFactor;
    float lightSize;
    float clampingDistance;
    float clampingRatio;
    VirtualLightContribution virtualLightContribution;
    uint32_t lockLights;
};

struct PMGI_Parameters
{
    uint32_t samplesPerFrame;
    uint32_t sampleLifespan;
    float scalingFactor;
    float lightSize;
    float clampingDistance;
    VirtualLightContribution virtualLightContribution;
    uint32_t lockLights;
    float invTotalVirtualLights;
};

#endif // RTXDI_GSGI_PARAMETERS_H