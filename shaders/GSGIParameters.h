
#ifndef RTXDI_GSGI_PARAMETERS_H
#define RTXDI_GSGI_PARAMETERS_H

#include <rtxdi/ReSTIRDIParameters.h>

enum VirtualLightType
{
    Point,
    Disk,
    Spot
};

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
    VirtualLightType virtualLightType;
    float lightSize;
    float distanceLimit;
    VirtualLightContribution virtualLightContribution;
    uint32_t lockLights;
};

#endif // RTXDI_BRDFPT_PARAMETERS_H