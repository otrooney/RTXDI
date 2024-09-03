
#ifndef RTXDI_DIRREGIR_PARAMETERS_H
#define RTXDI_DIRREGIR_PARAMETERS_H

#include <rtxdi/ReSTIRDIParameters.h>


#define ReGIRType_STANDARD 0
#define ReGIRType_DIRECTIONAL 1

#define DirReGIRSampling_UNIFORM 0
#define DirReGIRSampling_UNIFORM_HEMISPHERE 1
#define DirReGIRSampling_DIFFUSE 2
#define DirReGIRSampling_BRDF 3


#ifdef __cplusplus
//#include <stdint.h>

enum class ReGIRType : uint32_t
{
    Standard = ReGIRType_STANDARD,
    Directional = ReGIRType_DIRECTIONAL,
};

enum class DirReGIRSampling : uint32_t
{
    Uniform = DirReGIRSampling_UNIFORM,
    UniformHemisphere = DirReGIRSampling_UNIFORM_HEMISPHERE,
    Diffuse = DirReGIRSampling_DIFFUSE,
    BRDF = DirReGIRSampling_BRDF
};

#else
#define ReGIRType uint32_t
#define DirReGIRSampling uint32_t
#endif

#endif // RTXDI_DIRREGIR_PARAMETERS_H