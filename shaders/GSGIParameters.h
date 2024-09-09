
#ifndef RTXDI_GSGI_PARAMETERS_H
#define RTXDI_GSGI_PARAMETERS_H

#include <rtxdi/ReSTIRDIParameters.h>


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
    int pad;
};

struct PMGI_Parameters
{
    uint32_t samplesPerFrame;
    uint32_t sampleLifespan;
    float scalingFactor;
    float lightSize;
    float clampingDistance;
    float invTotalVirtualLights;
    int pad;
    int pad2;
};

struct VirtualLight_Parameters
{
    VirtualLightContribution virtualLightContribution;
    uint32_t lockLights;
    float clampingRatio;
    uint32_t includeInBrdfLightSampling;
    uint32_t totalVirtualLights;
    int pad;
    int pad2;
    int pad3;
};

#endif // RTXDI_GSGI_PARAMETERS_H