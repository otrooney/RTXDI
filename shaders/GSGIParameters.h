
#ifndef RTXDI_GSGI_PARAMETERS_H
#define RTXDI_GSGI_PARAMETERS_H

#include <rtxdi/ReSTIRDIParameters.h>

enum GSGIResamplingMode
{
    None,
    WorldSpace,
    ScreenSpace
};

enum VirtualLightContribution
{
    DiffuseAndSpecular,
    DiffuseOnly
};

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

#endif // RTXDI_BRDFPT_PARAMETERS_H