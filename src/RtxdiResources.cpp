/***************************************************************************
 # Copyright (c) 2020-2023, NVIDIA CORPORATION.  All rights reserved.
 #
 # NVIDIA CORPORATION and its licensors retain all intellectual property
 # and proprietary rights in and to this software, related documentation
 # and any modifications thereto.  Any use, reproduction, disclosure or
 # distribution of this software and related documentation without an express
 # license agreement from NVIDIA CORPORATION is strictly prohibited.
 **************************************************************************/

#include "RtxdiResources.h"
#include <rtxdi/ReSTIRDI.h>
#include <rtxdi/ReSTIRGI.h>
#include <rtxdi/RISBufferSegmentAllocator.h>

#include <donut/core/math/math.h>

using namespace dm;
#include "../shaders/ShaderParameters.h"

RtxdiResources::RtxdiResources(
    nvrhi::IDevice* device, 
    const rtxdi::ReSTIRDIContext& context,
    const rtxdi::RISBufferSegmentAllocator& risBufferSegmentAllocator,
    uint32_t maxEmissiveMeshes,
    uint32_t maxEmissiveTriangles,
    uint32_t maxPrimitiveLights,
    uint32_t maxGeometryInstances,
    uint32_t environmentMapWidth,
    uint32_t environmentMapHeight,
    uint32_t virtualLightSamplesPerFrame,
    uint32_t virtualLightSampleLifespan,
    uint32_t reGIRCellCount)
    : m_MaxEmissiveMeshes(maxEmissiveMeshes)
    , m_MaxEmissiveTriangles(maxEmissiveTriangles)
    , m_MaxPrimitiveLights(maxPrimitiveLights)
    , m_MaxGeometryInstances(maxGeometryInstances)
{
    m_VirtualLightSamplesPerFrame = virtualLightSamplesPerFrame;
    m_VirtualLightSampleLifespan = virtualLightSampleLifespan;

    uint32_t maxVirtualLights = m_VirtualLightSamplesPerFrame * m_VirtualLightSampleLifespan;

    nvrhi::BufferDesc taskBufferDesc;
    taskBufferDesc.byteSize = sizeof(PrepareLightsTask) * (maxEmissiveMeshes + maxPrimitiveLights + maxVirtualLights);
    taskBufferDesc.structStride = sizeof(PrepareLightsTask);
    taskBufferDesc.initialState = nvrhi::ResourceStates::ShaderResource;
    taskBufferDesc.keepInitialState = true;
    taskBufferDesc.debugName = "TaskBuffer";
    taskBufferDesc.canHaveUAVs = true;
    TaskBuffer = device->createBuffer(taskBufferDesc);


    nvrhi::BufferDesc primitiveLightBufferDesc;
    primitiveLightBufferDesc.byteSize = sizeof(PolymorphicLightInfo) * maxPrimitiveLights;
    primitiveLightBufferDesc.structStride = sizeof(PolymorphicLightInfo);
    primitiveLightBufferDesc.initialState = nvrhi::ResourceStates::ShaderResource;
    primitiveLightBufferDesc.keepInitialState = true;
    primitiveLightBufferDesc.debugName = "PrimitiveLightBuffer";
    PrimitiveLightBuffer = device->createBuffer(primitiveLightBufferDesc);


    nvrhi::BufferDesc virtualLightBufferDesc;
    virtualLightBufferDesc.byteSize = sizeof(PolymorphicLightInfo) * m_VirtualLightSamplesPerFrame;
    virtualLightBufferDesc.structStride = sizeof(PolymorphicLightInfo);
    virtualLightBufferDesc.initialState = nvrhi::ResourceStates::ShaderResource;
    virtualLightBufferDesc.keepInitialState = true;
    virtualLightBufferDesc.debugName = "VirtualLightBuffer";
    virtualLightBufferDesc.canHaveUAVs = true;
    VirtualLightBuffer = device->createBuffer(virtualLightBufferDesc);


    nvrhi::BufferDesc risBufferDesc;
    risBufferDesc.byteSize = sizeof(uint32_t) * 2 * std::max(risBufferSegmentAllocator.getTotalSizeInElements(), 1u); // RG32_UINT per element
    risBufferDesc.format = nvrhi::Format::RG32_UINT;
    risBufferDesc.canHaveTypedViews = true;
    risBufferDesc.initialState = nvrhi::ResourceStates::ShaderResource;
    risBufferDesc.keepInitialState = true;
    risBufferDesc.debugName = "RisBuffer";
    risBufferDesc.canHaveUAVs = true;
    RisBuffer = device->createBuffer(risBufferDesc);

    risBufferDesc.byteSize = sizeof(uint32_t) * 8 * std::max(risBufferSegmentAllocator.getTotalSizeInElements(), 1u); // RGBA32_UINT x 2 per element
    risBufferDesc.format = nvrhi::Format::RGBA32_UINT;
    risBufferDesc.debugName = "RisLightDataBuffer";
    RisLightDataBuffer = device->createBuffer(risBufferDesc);


    nvrhi::BufferDesc dirReGIRBufferDesc;
    dirReGIRBufferDesc.byteSize = sizeof(uint32_t) * 2 * std::max(reGIRCellCount * 16 * 16, 1u); // RG32_UINT per element
    dirReGIRBufferDesc.format = nvrhi::Format::RG32_UINT;
    dirReGIRBufferDesc.canHaveTypedViews = true;
    dirReGIRBufferDesc.initialState = nvrhi::ResourceStates::ShaderResource;
    dirReGIRBufferDesc.keepInitialState = true;
    dirReGIRBufferDesc.debugName = "DirReGIRBuffer";
    dirReGIRBufferDesc.canHaveUAVs = true;
    DirReGIRBuffer = device->createBuffer(dirReGIRBufferDesc);

    dirReGIRBufferDesc.byteSize = sizeof(uint32_t) * 8 * std::max(reGIRCellCount * 16 * 16, 1u); // RGBA32_UINT x 2 per element
    dirReGIRBufferDesc.format = nvrhi::Format::RGBA32_UINT;
    dirReGIRBufferDesc.debugName = "DirReGIRLightDataBuffer";
    DirReGIRLightDataBuffer = device->createBuffer(dirReGIRBufferDesc);


    uint32_t maxLocalLights = maxEmissiveTriangles + maxPrimitiveLights + maxVirtualLights;
    uint32_t lightBufferElements = maxLocalLights * 2;

    nvrhi::BufferDesc lightBufferDesc;
    lightBufferDesc.byteSize = sizeof(PolymorphicLightInfo) * lightBufferElements;
    lightBufferDesc.structStride = sizeof(PolymorphicLightInfo);
    lightBufferDesc.initialState = nvrhi::ResourceStates::ShaderResource;
    lightBufferDesc.keepInitialState = true;
    lightBufferDesc.debugName = "LightDataBuffer";
    lightBufferDesc.canHaveUAVs = true;
    LightDataBuffer = device->createBuffer(lightBufferDesc);


    nvrhi::BufferDesc geometryInstanceToLightBufferDesc;
    geometryInstanceToLightBufferDesc.byteSize = sizeof(uint32_t) * maxGeometryInstances;
    geometryInstanceToLightBufferDesc.structStride = sizeof(uint32_t);
    geometryInstanceToLightBufferDesc.initialState = nvrhi::ResourceStates::ShaderResource;
    geometryInstanceToLightBufferDesc.keepInitialState = true;
    geometryInstanceToLightBufferDesc.debugName = "GeometryInstanceToLightBuffer";
    geometryInstanceToLightBufferDesc.canHaveUAVs = true;
    GeometryInstanceToLightBuffer = device->createBuffer(geometryInstanceToLightBufferDesc);


    nvrhi::BufferDesc primitiveInstanceToLightBufferDesc;
    primitiveInstanceToLightBufferDesc.byteSize = sizeof(uint32_t) * maxGeometryInstances * PRIMITIVE_SLOTS_PER_GEOMETRY_INSTANCE;
    primitiveInstanceToLightBufferDesc.structStride = sizeof(uint32_t);
    primitiveInstanceToLightBufferDesc.initialState = nvrhi::ResourceStates::ShaderResource;
    primitiveInstanceToLightBufferDesc.keepInitialState = true;
    primitiveInstanceToLightBufferDesc.debugName = "PrimitiveInstanceToLightBuffer";
    primitiveInstanceToLightBufferDesc.canHaveUAVs = true;
    PrimitiveInstanceToLightBuffer = device->createBuffer(primitiveInstanceToLightBufferDesc);


    nvrhi::BufferDesc lightIndexMappingBufferDesc;
    lightIndexMappingBufferDesc.byteSize = sizeof(uint32_t) * lightBufferElements;
    lightIndexMappingBufferDesc.format = nvrhi::Format::R32_UINT;
    lightIndexMappingBufferDesc.canHaveTypedViews = true;
    lightIndexMappingBufferDesc.initialState = nvrhi::ResourceStates::ShaderResource;
    lightIndexMappingBufferDesc.keepInitialState = true;
    lightIndexMappingBufferDesc.debugName = "LightIndexMappingBuffer";
    lightIndexMappingBufferDesc.canHaveUAVs = true;
    LightIndexMappingBuffer = device->createBuffer(lightIndexMappingBufferDesc);
    

    nvrhi::BufferDesc neighborOffsetBufferDesc;
    neighborOffsetBufferDesc.byteSize = context.getStaticParameters().NeighborOffsetCount * 2;
    neighborOffsetBufferDesc.format = nvrhi::Format::RG8_SNORM;
    neighborOffsetBufferDesc.canHaveTypedViews = true;
    neighborOffsetBufferDesc.debugName = "NeighborOffsets";
    neighborOffsetBufferDesc.initialState = nvrhi::ResourceStates::ShaderResource;
    neighborOffsetBufferDesc.keepInitialState = true;
    NeighborOffsetsBuffer = device->createBuffer(neighborOffsetBufferDesc);


    nvrhi::BufferDesc lightReservoirBufferDesc;
    lightReservoirBufferDesc.byteSize = sizeof(RTXDI_PackedDIReservoir) * context.getReservoirBufferParameters().reservoirArrayPitch * rtxdi::c_NumReSTIRDIReservoirBuffers;
    lightReservoirBufferDesc.structStride = sizeof(RTXDI_PackedDIReservoir);
    lightReservoirBufferDesc.initialState = nvrhi::ResourceStates::UnorderedAccess;
    lightReservoirBufferDesc.keepInitialState = true;
    lightReservoirBufferDesc.debugName = "LightReservoirBuffer";
    lightReservoirBufferDesc.canHaveUAVs = true;
    LightReservoirBuffer = device->createBuffer(lightReservoirBufferDesc);


    nvrhi::BufferDesc secondaryGBufferDesc;
    secondaryGBufferDesc.byteSize = sizeof(SecondaryGBufferData) * context.getReservoirBufferParameters().reservoirArrayPitch;
    secondaryGBufferDesc.structStride = sizeof(SecondaryGBufferData);
    secondaryGBufferDesc.initialState = nvrhi::ResourceStates::UnorderedAccess;
    secondaryGBufferDesc.keepInitialState = true;
    secondaryGBufferDesc.debugName = "SecondaryGBuffer";
    secondaryGBufferDesc.canHaveUAVs = true;
    SecondaryGBuffer = device->createBuffer(secondaryGBufferDesc);


    nvrhi::BufferDesc GSGIGBufferDesc;
    GSGIGBufferDesc.byteSize = sizeof(GSGIGBufferData) * m_VirtualLightSamplesPerFrame;
    GSGIGBufferDesc.structStride = sizeof(GSGIGBufferData);
    GSGIGBufferDesc.initialState = nvrhi::ResourceStates::UnorderedAccess;
    GSGIGBufferDesc.keepInitialState = true;
    GSGIGBufferDesc.debugName = "GSGIGBuffer";
    GSGIGBufferDesc.canHaveUAVs = true;
    GSGIGBuffer = device->createBuffer(GSGIGBufferDesc);


    nvrhi::TextureDesc environmentPdfDesc;
    environmentPdfDesc.width = environmentMapWidth;
    environmentPdfDesc.height = environmentMapHeight;
    environmentPdfDesc.mipLevels = uint32_t(ceilf(::log2f(float(std::max(environmentPdfDesc.width, environmentPdfDesc.height)))) + 1); // full mip chain up to 1x1
    environmentPdfDesc.isUAV = true;
    environmentPdfDesc.debugName = "EnvironmentPdf";
    environmentPdfDesc.initialState = nvrhi::ResourceStates::ShaderResource;
    environmentPdfDesc.keepInitialState = true;
    environmentPdfDesc.format = nvrhi::Format::R16_FLOAT;
    EnvironmentPdfTexture = device->createTexture(environmentPdfDesc);

    nvrhi::TextureDesc localLightPdfDesc;
    rtxdi::ComputePdfTextureSize(maxLocalLights, localLightPdfDesc.width, localLightPdfDesc.height, localLightPdfDesc.mipLevels);
    assert(localLightPdfDesc.width * localLightPdfDesc.height >= maxLocalLights);
    localLightPdfDesc.isUAV = true;
    localLightPdfDesc.debugName = "LocalLightPdf";
    localLightPdfDesc.initialState = nvrhi::ResourceStates::ShaderResource;
    localLightPdfDesc.keepInitialState = true;
    localLightPdfDesc.format = nvrhi::Format::R32_FLOAT; // Use FP32 here to allow a wide range of flux values, esp. when downsampled.
    LocalLightPdfTexture = device->createTexture(localLightPdfDesc);
    
    nvrhi::BufferDesc giReservoirBufferDesc;
    giReservoirBufferDesc.byteSize = sizeof(RTXDI_PackedGIReservoir) * context.getReservoirBufferParameters().reservoirArrayPitch * rtxdi::c_NumReSTIRGIReservoirBuffers;
    giReservoirBufferDesc.structStride = sizeof(RTXDI_PackedGIReservoir);
    giReservoirBufferDesc.initialState = nvrhi::ResourceStates::UnorderedAccess;
    giReservoirBufferDesc.keepInitialState = true;
    giReservoirBufferDesc.debugName = "GIReservoirBuffer";
    giReservoirBufferDesc.canHaveUAVs = true;
    GIReservoirBuffer = device->createBuffer(giReservoirBufferDesc);

    nvrhi::BufferDesc GSGIReservoirBufferDesc;
    GSGIReservoirBufferDesc.byteSize = sizeof(RTXDI_PackedDIReservoir) * m_VirtualLightSamplesPerFrame;
    GSGIReservoirBufferDesc.structStride = sizeof(RTXDI_PackedDIReservoir);
    GSGIReservoirBufferDesc.initialState = nvrhi::ResourceStates::UnorderedAccess;
    GSGIReservoirBufferDesc.keepInitialState = true;
    GSGIReservoirBufferDesc.debugName = "GSGIReservoirBuffer";
    GSGIReservoirBufferDesc.canHaveUAVs = true;
    GSGIReservoirBuffer = device->createBuffer(GSGIReservoirBufferDesc);

    nvrhi::BufferDesc GSGIGridBufferDesc;
    GSGIGridBufferDesc.byteSize = sizeof(int32_t) * std::max(risBufferSegmentAllocator.getTotalSizeInElements(), 1u);
    GSGIGridBufferDesc.format = nvrhi::Format::R32_SINT;
    GSGIGridBufferDesc.canHaveTypedViews = true;
    GSGIGridBufferDesc.initialState = nvrhi::ResourceStates::ShaderResource;
    GSGIGridBufferDesc.keepInitialState = true;
    GSGIGridBufferDesc.debugName = "GSGIGridBuffer";
    GSGIGridBufferDesc.canHaveUAVs = true;
    GSGIGridBuffer = device->createBuffer(GSGIGridBufferDesc);
}

void RtxdiResources::InitializeNeighborOffsets(nvrhi::ICommandList* commandList, uint32_t neighborOffsetCount)
{
    if (m_NeighborOffsetsInitialized)
        return;

    std::vector<uint8_t> offsets;
    offsets.resize(neighborOffsetCount * 2);

    rtxdi::FillNeighborOffsetBuffer(offsets.data(), neighborOffsetCount);

    commandList->writeBuffer(NeighborOffsetsBuffer, offsets.data(), offsets.size());

    m_NeighborOffsetsInitialized = true;
}
