#pragma pack_matrix(row_major)

#include "RtxdiApplicationBridge.hlsli"

#include <rtxdi/PresamplingFunctions.hlsli>

#define THREADS_PER_WORKGROUP 256
#define INVALID_LIGHT_INDEX 0x40000000u
#define LOCK_OPEN 0x80000000u
#define MAX_LOCK_ATTEMPTS 10

groupshared float weightSumArray[16][16];
groupshared uint lightIndexArray[16][16];
groupshared uint nSamplesArray[16][16];
groupshared float selectedTargetPdfArray[16][16];
groupshared uint accessLockArray[16][16];

[numthreads(THREADS_PER_WORKGROUP, 1, 1)]
void main(uint GlobalIndex : SV_DispatchThreadID)
{    
    uint cellIndex = GlobalIndex / THREADS_PER_WORKGROUP;
    uint threadIndex = GlobalIndex - (cellIndex * THREADS_PER_WORKGROUP);
    uint threadX = (threadIndex % 16);
    uint threadY = ((threadIndex - threadX) / 16);
    uint bufferIndex = (cellIndex * 16 * 16) + (threadY * 16) + threadX;
    
    // First, initialize groupshared memory
    weightSumArray[threadX][threadY] = 0;
    lightIndexArray[threadX][threadY] = INVALID_LIGHT_INDEX;
    nSamplesArray[threadX][threadY] = 0;
    selectedTargetPdfArray[threadX][threadY] = 0;
    accessLockArray[threadX][threadY] = LOCK_OPEN;
    
    RAB_RandomSamplerState rng = RAB_InitRandomSampler(uint2(GlobalIndex & 0xfff, GlobalIndex >> 12), 1);
    RAB_RandomSamplerState coherentRng = RAB_InitRandomSampler(uint2(GlobalIndex >> 8, 0), 1);

    float3 cellCenter;
    float cellRadius;
    if (!RTXDI_ReGIR_CellIndexToWorldPos(g_Const.regir, int(cellIndex), cellCenter, cellRadius))
    {
        u_DirReGIRBuffer[bufferIndex] = uint2(INVALID_LIGHT_INDEX, asuint(0.0f));
        return;
    }

    cellRadius *= (g_Const.regir.commonParams.samplingJitter + 1.0);

    RAB_LightInfo selectedLightInfo = RAB_EmptyLightInfo();
    uint selectedLight = 0;
    float selectedTargetPdf = 0;

    RTXDI_LocalLightSelectionContext ctx;
    if (g_Const.regir.commonParams.localLightPresamplingMode == REGIR_LOCAL_LIGHT_PRESAMPLING_MODE_POWER_RIS)
        ctx = RTXDI_InitializeLocalLightSelectionContextRIS(coherentRng, g_Const.localLightsRISBufferSegmentParams);
    else
        ctx = RTXDI_InitializeLocalLightSelectionContextUniform(g_Const.lightBufferParams.localLightBufferRegion);

    for (uint i = 0; i < g_Const.regir.commonParams.numRegirBuildSamples; i++)
    {
        RAB_LightInfo lightInfo = RAB_EmptyLightInfo();
        uint rndLight;
        float invSourcePdf;

        RTXDI_SelectNextLocalLight(ctx, rng, lightInfo, rndLight, invSourcePdf);
        
        // Choose random point in cell
        float sampleX = cellCenter.x + (RAB_GetNextRandom(rng) - 1) * 2 * cellRadius;
        float sampleY = cellCenter.y + (RAB_GetNextRandom(rng) - 1) * 2 * cellRadius;
        float sampleZ = cellCenter.z + (RAB_GetNextRandom(rng) - 1) * 2 * cellRadius;
        float3 samplePos = { sampleX, sampleY, sampleZ };
        
        // Sample light from that point
        float2 randomUV = { RAB_GetNextRandom(rng), RAB_GetNextRandom(rng) };
        PolymorphicLightSample pls = PolymorphicLight::calcSample(lightInfo, randomUV, samplePos, g_Const.gsgi.clampingRatio);
        
        uint2 arrayLoc;
        
        if (g_Const.bypassDirectionalDirReGIRBuild)
        {
            arrayLoc.x = threadX;
            arrayLoc.y = threadY;
        }
        else
        {
            float3 lightDirNorm = normalize(pls.position - samplePos);
            float2 lightDirOct = ndirToOctSigned(lightDirNorm);
            lightDirOct = (lightDirOct + 1) / 2;
            arrayLoc = lightDirOct * 16;
            
            // TODO: Add controls for amount of jitter
            arrayLoc.x += (RAB_GetNextRandom(rng) - 0.5) * 4;
            arrayLoc.y += (RAB_GetNextRandom(rng) - 0.5) * 4;
            arrayLoc = arrayLoc % 16;
        }

        float targetPdf = calcLuminance(pls.radiance) / pls.solidAnglePdf;
        float risRnd = RAB_GetNextRandom(rng);

        float risWeight = targetPdf * invSourcePdf;
        float weightSum;
        
        uint lockValue;
        for (uint j = 0; j < MAX_LOCK_ATTEMPTS; j++)
        {
            InterlockedCompareExchange(accessLockArray[arrayLoc.x][arrayLoc.y], LOCK_OPEN, threadIndex, lockValue);
            if (lockValue == LOCK_OPEN)
            {
                weightSumArray[arrayLoc.x][arrayLoc.y] += risWeight;

                if (risRnd * weightSumArray[arrayLoc.x][arrayLoc.y] < risWeight)
                {
                    lightIndexArray[arrayLoc.x][arrayLoc.y] = rndLight;
                    selectedTargetPdfArray[arrayLoc.x][arrayLoc.y] = targetPdf;
                }
                nSamplesArray[arrayLoc.x][arrayLoc.y] += 1;
                accessLockArray[arrayLoc.x][arrayLoc.y] = LOCK_OPEN;
                break;
            }
        }
    }

    // Once all samples have been calculated, we write the final data to the buffer.
    GroupMemoryBarrierWithGroupSync();
    
    int lightIndex = lightIndexArray[threadX][threadY];
    RAB_LightInfo lightInfo = RAB_EmptyLightInfo();
    float targetPdf = 0;
    float weight = 0;
    bool compact = false;
    
    if (lightIndex != INVALID_LIGHT_INDEX)
    {
        lightInfo = RAB_LoadLightInfo(lightIndex, false);
        targetPdf = selectedTargetPdfArray[threadX][threadY];
            
        weight = (targetPdf > 0) ? weightSumArray[threadX][threadY] / (targetPdf * nSamplesArray[threadX][threadY]) : 0;
    }
    
    if (weight > 0)
    {
        uint4 data1, data2;
        if (packCompactLightInfo(lightInfo, data1, data2))
        {
            compact = true;
            u_DirReGIRLightDataBuffer[bufferIndex * 2 + 0] = data1;
            u_DirReGIRLightDataBuffer[bufferIndex * 2 + 1] = data2;
        }
    }

    if (compact)
    {
        lightIndex |= RTXDI_LIGHT_COMPACT_BIT;
    }

    u_DirReGIRBuffer[bufferIndex] = uint2(lightIndex, asuint(weight));

}