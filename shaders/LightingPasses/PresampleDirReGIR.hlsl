#pragma pack_matrix(row_major)

#include "RtxdiApplicationBridge.hlsli"

#include <rtxdi/PresamplingFunctions.hlsli>

#define THREADS_PER_WORKGROUP 256
#define INVALID_LIGHT_INDEX 0x40000000u

groupshared float weightSumArray[32][32];
groupshared uint lightIndexArray[32][32];

[numthreads(THREADS_PER_WORKGROUP, 1, 1)]
void main(uint GlobalIndex : SV_DispatchThreadID)
{    
    uint cellIndex = GlobalIndex / THREADS_PER_WORKGROUP;
    uint threadIndex = GlobalIndex - (cellIndex * THREADS_PER_WORKGROUP);
    uint threadX = (threadIndex % 16) * 2;
    uint threadY = ((threadIndex - threadX) / 16) * 2;
    
    // First, initialize groupshared memory
    for (uint j = 0; j <= 1; j++)
    {
        for (uint k = 0; k <= 1; k++)
        {
            weightSumArray[threadX + j][threadY + k] = 0;
            lightIndexArray[threadX + j][threadY + k] = INVALID_LIGHT_INDEX;
        }
    }
    
    RAB_RandomSamplerState rng = RAB_InitRandomSampler(uint2(GlobalIndex & 0xfff, GlobalIndex >> 12), 1);
    RAB_RandomSamplerState coherentRng = RAB_InitRandomSampler(uint2(GlobalIndex >> 8, 0), 1);

    float3 cellCenter;
    float cellRadius;
    if (!RTXDI_ReGIR_CellIndexToWorldPos(g_Const.regir, int(cellIndex), cellCenter, cellRadius))
    {
        // TODO: Write out zeros to DirReGIR buffer
        return;
    }

    cellRadius *= (g_Const.regir.commonParams.samplingJitter + 1.0);

    RAB_LightInfo selectedLightInfo = RAB_EmptyLightInfo();
    uint selectedLight = 0;
    float selectedTargetPdf = 0;

    // With 4 slots per thread (1024 slots total, 256 threads), average num samples is 1/4 the samples per
    // thread. 
    // TODO: Think about whether using an average here makes any sense at all.
    float invNumSamples = 4.0 / float(g_Const.regir.commonParams.numRegirBuildSamples);

    RTXDI_LocalLightSelectionContext ctx;
    if (g_Const.regir.commonParams.localLightPresamplingMode == REGIR_LOCAL_LIGHT_PRESAMPLING_MODE_POWER_RIS)
        ctx = RTXDI_InitializeLocalLightSelectionContextRIS(coherentRng, g_Const.localLightsRISBufferSegmentParams);
    else
        ctx = RTXDI_InitializeLocalLightSelectionContextUniform(g_Const.lightBufferParams.localLightBufferRegion);

    for (uint i = 0; i < g_Const.regir.commonParams.numRegirBuildSamples * 2; i++)
    {
        RAB_LightInfo lightInfo = RAB_EmptyLightInfo();
        uint rndLight;
        float invSourcePdf;

        RTXDI_SelectNextLocalLight(ctx, rng, lightInfo, rndLight, invSourcePdf);
        invSourcePdf *= invNumSamples;
        
        // Choose random point in cell
        float sampleX = cellCenter.x + (RAB_GetNextRandom(rng) - 1) * 2 * cellRadius;
        float sampleY = cellCenter.y + (RAB_GetNextRandom(rng) - 1) * 2 * cellRadius;
        float sampleZ = cellCenter.z + (RAB_GetNextRandom(rng) - 1) * 2 * cellRadius;
        float3 samplePos = { sampleX, sampleY, sampleZ };
        
        // Sample light from that point
        float2 randomUV = { RAB_GetNextRandom(rng), RAB_GetNextRandom(rng) };
        PolymorphicLightSample pls = PolymorphicLight::calcSample(lightInfo, randomUV, samplePos, g_Const.gsgi.clampingRatio);
        
        float3 lightDirNorm = normalize(pls.position - samplePos);
        float2 lightDirOct = ndirToOctSigned(lightDirNorm);
        uint arrayLocX = lightDirOct.x * 32;
        uint arrayLocY = lightDirOct.y * 32;
        uint2 arrayLoc = { arrayLocX, arrayLocY };
        
        // TODO: Add jitter to arrayLoc here?
        
        float targetPdf = calcLuminance(pls.radiance) / pls.solidAnglePdf;
        float risRnd = RAB_GetNextRandom(rng);

        float risWeight = targetPdf * invSourcePdf;
        float weightSum;
        
        // TODO: Handle this with atomics or other thread-safe solution
        weightSumArray[arrayLoc.x][arrayLoc.y] += risWeight;

        if (risRnd * weightSumArray[arrayLoc.x][arrayLoc.y] < risWeight)
            lightIndexArray[arrayLoc.x][arrayLoc.y] = rndLight;

    }

    // Once all samples have been calculated, we write the final data to the buffer.
    // Each thread is responsible for four locations in the buffer.
    GroupMemoryBarrierWithGroupSync();
    
    for (uint a = 0; a <= 1; a++)
    {
        for (uint b = 0; b <= 1; b++)
        {
            uint bufferIndex = (cellIndex * 32 * 32) + ((threadY + b) * 32) + threadX + a;
            int lightIndex = lightIndexArray[threadX + a][threadY + b];
            RAB_LightInfo lightInfo = RAB_EmptyLightInfo();
            float targetPdf = 0;
            float weight = 0;
            
            if (lightIndex != INVALID_LIGHT_INDEX)
            {
                lightInfo = RAB_LoadLightInfo(lightIndex, false);

                // As we don't have enough space to store the selected target PDF in shared memory, we recalculate here
                float sampleX = cellCenter.x + (RAB_GetNextRandom(rng) - 1) * 2 * cellRadius;
                float sampleY = cellCenter.y + (RAB_GetNextRandom(rng) - 1) * 2 * cellRadius;
                float sampleZ = cellCenter.z + (RAB_GetNextRandom(rng) - 1) * 2 * cellRadius;
                float3 samplePos = { sampleX, sampleY, sampleZ };
        
                float2 randomUV = { RAB_GetNextRandom(rng), RAB_GetNextRandom(rng) };
                PolymorphicLightSample pls = PolymorphicLight::calcSample(lightInfo, randomUV, samplePos, g_Const.gsgi.clampingRatio);
                targetPdf = calcLuminance(pls.radiance) / pls.solidAnglePdf;
            
                weight = (targetPdf > 0) ? weightSumArray[threadX + a][threadY + b] / targetPdf : 0;
            }
            
            bool compact = false;
            
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
    }

}