
#ifndef RTXDI_GSGI_PARAMETERS_H
#define RTXDI_GSGI_PARAMETERS_H

#include <rtxdi/ReSTIRDIParameters.h>

enum VirtualLightType
{
    Point,
    Disk,
    Spot
};

struct GSGI_Parameters
{
    uint32_t samplesPerFrame;
    uint32_t sampleLifespan;
    float scalingFactor;
    float boilingFilter;
    VirtualLightType virtualLightType;
    float lightSize;
};

#endif // RTXDI_BRDFPT_PARAMETERS_H