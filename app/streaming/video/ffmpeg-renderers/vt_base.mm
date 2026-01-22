// Nasty hack to avoid conflict between AVFoundation and
// libavutil both defining AVMediaType
#define AVMediaType AVMediaType_FFmpeg
#include "vt.h"
#undef AVMediaType

#import <Cocoa/Cocoa.h>
#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <Limelight.h>
#include <simd/simd.h>

extern "C" {
    #include <libavutil/hwcontext.h>
    #include <libavutil/hwcontext_videotoolbox.h>
    #include <libavcodec/videotoolbox.h>
    #include <libavutil/pixfmt.h>
}

namespace {

CFDataRef createMasteringDisplayColorVolume(const SS_HDR_METADATA& hdrMetadata) {
    if (hdrMetadata.displayPrimaries[0].x == 0 || hdrMetadata.maxDisplayLuminance == 0) {
        return nullptr;
    }

    struct {
        vector_ushort2 primaries[3];
        vector_ushort2 white_point;
        uint32_t luminance_max;
        uint32_t luminance_min;
    } __attribute__((packed, aligned(4))) mdcv;

    mdcv.primaries[0].x = __builtin_bswap16(hdrMetadata.displayPrimaries[1].x);
    mdcv.primaries[0].y = __builtin_bswap16(hdrMetadata.displayPrimaries[1].y);
    mdcv.primaries[1].x = __builtin_bswap16(hdrMetadata.displayPrimaries[2].x);
    mdcv.primaries[1].y = __builtin_bswap16(hdrMetadata.displayPrimaries[2].y);
    mdcv.primaries[2].x = __builtin_bswap16(hdrMetadata.displayPrimaries[0].x);
    mdcv.primaries[2].y = __builtin_bswap16(hdrMetadata.displayPrimaries[0].y);

    mdcv.white_point.x = __builtin_bswap16(hdrMetadata.whitePoint.x);
    mdcv.white_point.y = __builtin_bswap16(hdrMetadata.whitePoint.y);

    mdcv.luminance_max = __builtin_bswap32((uint32_t)hdrMetadata.maxDisplayLuminance * 10000);
    mdcv.luminance_min = __builtin_bswap32(hdrMetadata.minDisplayLuminance);

    return CFDataCreate(nullptr, (const UInt8*)&mdcv, sizeof(mdcv));
}

CFDataRef createContentLightLevelInfo(const SS_HDR_METADATA& hdrMetadata) {
    if (hdrMetadata.maxContentLightLevel == 0 || hdrMetadata.maxFrameAverageLightLevel == 0) {
        return nullptr;
    }

    struct {
        uint16_t max_content_light_level;
        uint16_t max_frame_average_light_level;
    } __attribute__((packed, aligned(2))) cll;

    cll.max_content_light_level = __builtin_bswap16(hdrMetadata.maxContentLightLevel);
    cll.max_frame_average_light_level = __builtin_bswap16(hdrMetadata.maxFrameAverageLightLevel);

    return CFDataCreate(nullptr, (const UInt8*)&cll, sizeof(cll));
}

}

VTBaseRenderer::VTBaseRenderer(IFFmpegRenderer::RendererType type) :
    IFFmpegRenderer(type),
    m_HdrMetadataChanged(false),
    m_MasteringDisplayColorVolume(nullptr),
    m_ContentLightLevelInfo(nullptr),
    m_HdrOutputState(static_cast<int>(HdrOutputState::Unknown)) {

}

VTBaseRenderer::~VTBaseRenderer() {
    if (m_MasteringDisplayColorVolume != nullptr) {
        CFRelease(m_MasteringDisplayColorVolume);
    }

    if (m_ContentLightLevelInfo != nullptr) {
        CFRelease(m_ContentLightLevelInfo);
    }
}

bool VTBaseRenderer::checkDecoderCapabilities(PDECODER_PARAMETERS params) {
    if (params->videoFormat & VIDEO_FORMAT_MASK_H264) {
        if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)) {
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                        "No HW accelerated H.264 decode via VT");
            return false;
        }
    }
    else if (params->videoFormat & VIDEO_FORMAT_MASK_H265) {
        if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                        "No HW accelerated HEVC decode via VT");
            return false;
        }
    }
    else if (params->videoFormat & VIDEO_FORMAT_MASK_AV1) {
    #if __MAC_OS_X_VERSION_MAX_ALLOWED >= 130000
        if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) {
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                        "No HW accelerated AV1 decode via VT");
            return false;
        }

        // 10-bit is part of the Main profile for AV1, so it will always
        // be present on hardware that supports 8-bit.
    #else
        SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                    "AV1 requires building with Xcode 14 or later");
        return false;
    #endif
    }

    return true;
}

bool VTBaseRenderer::configureHwFramesContext(AVCodecContext* context, AVBufferRef* hwContext, AVPixelFormat pixelFormat) {
    av_buffer_unref(&context->hw_frames_ctx);

    int err = avcodec_get_hw_frames_parameters(context, hwContext, pixelFormat, &context->hw_frames_ctx);
    if (err < 0) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                     "Failed to get VideoToolbox hwframes context parameters: %d",
                     err);
        return false;
    }

    auto framesContext = (AVHWFramesContext*)context->hw_frames_ctx->data;
    if (framesContext->hwctx == nullptr) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                     "VideoToolbox hwframes context is missing");
        av_buffer_unref(&context->hw_frames_ctx);
        return false;
    }

    auto vtFramesContext = (AVVTFramesContext*)framesContext->hwctx;

    // Match the decoder color range to avoid extra full/limited range conversions.
    vtFramesContext->color_range = (getDecoderColorRange() == COLOR_RANGE_FULL) ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG;

    // Mirror FFmpeg's default headroom to reduce the chance of stalling the decoder.
    if (framesContext->initial_pool_size) {
        framesContext->initial_pool_size += 3;
    }

    err = av_hwframe_ctx_init(context->hw_frames_ctx);
    if (err < 0) {
        av_buffer_unref(&context->hw_frames_ctx);
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                     "Failed to initialize VideoToolbox hwframes context: %d",
                     err);
        return false;
    }

    return true;
}

void VTBaseRenderer::updateHdrOutputState(int colorTrc, bool wantsEdr) {
    HdrOutputState newState = HdrOutputState::Unknown;

    if (!wantsEdr) {
        newState = HdrOutputState::Sdr;
    }
    else {
        switch (colorTrc) {
        case AVCOL_TRC_SMPTE2084:
            newState = HdrOutputState::HdrPq;
            break;
        case AVCOL_TRC_ARIB_STD_B67:
            newState = HdrOutputState::HdrHlg;
            break;
        default:
            newState = HdrOutputState::HdrUnknown;
            break;
        }
    }

    m_HdrOutputState.store(static_cast<int>(newState), std::memory_order_relaxed);
}

void VTBaseRenderer::appendDebugOverlayStats(char* output, int length, int* offset) {
    const auto state = static_cast<HdrOutputState>(m_HdrOutputState.load(std::memory_order_relaxed));
    const char* label = nullptr;

    switch (state) {
    case HdrOutputState::Sdr:
        label = "HDR output (EDR): Off";
        break;
    case HdrOutputState::HdrPq:
        label = "HDR output (EDR): On (PQ)";
        break;
    case HdrOutputState::HdrHlg:
        label = "HDR output (EDR): On (HLG)";
        break;
    case HdrOutputState::HdrUnknown:
        label = "HDR output (EDR): On";
        break;
    case HdrOutputState::Unknown:
    default:
        break;
    }

    if (label == nullptr) {
        return;
    }

    // Expose the current EDR/transfer mode to help validate HDR output behavior.
    int ret = snprintf(&output[*offset],
                       length - *offset,
                       "%s\n",
                       label);
    if (ret < 0 || ret >= length - *offset) {
        SDL_assert(false);
        return;
    }

    *offset += ret;
}

bool VTBaseRenderer::configureDecoderSession(AVCodecContext* context) {
    if (context == nullptr || context->hw_device_ctx == nullptr) {
        return true;
    }

    auto deviceContext = reinterpret_cast<AVHWDeviceContext*>(context->hw_device_ctx->data);
    if (deviceContext == nullptr || deviceContext->type != AV_HWDEVICE_TYPE_VIDEOTOOLBOX) {
        return true;
    }

    auto vtContext = reinterpret_cast<AVVideotoolboxContext*>(context->hwaccel_context);
    if (vtContext == nullptr || vtContext->session == nullptr) {
        // Session isn't ready yet; retry once decode has produced output.
        return false;
    }

    // Keep VideoToolbox configured for real-time playback to minimize buffering.
    OSStatus status = VTSessionSetProperty(vtContext->session,
                                           kVTDecompressionPropertyKey_RealTime,
                                           kCFBooleanTrue);
    if (status != noErr) {
        SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                    "VTSessionSetProperty(RealTime) failed: %d",
                    status);
    }

    return true;
}

void VTBaseRenderer::setHdrMode(bool enabled) {
    bool hadMetadata = m_MasteringDisplayColorVolume != nullptr || m_ContentLightLevelInfo != nullptr;

    if (m_MasteringDisplayColorVolume != nullptr) {
        CFRelease(m_MasteringDisplayColorVolume);
        m_MasteringDisplayColorVolume = nullptr;
    }
    if (m_ContentLightLevelInfo != nullptr) {
        CFRelease(m_ContentLightLevelInfo);
        m_ContentLightLevelInfo = nullptr;
    }

    bool metadataApplied = false;
    SS_HDR_METADATA hdrMetadata;
    if (enabled && LiGetHdrMetadata(&hdrMetadata)) {
        auto mastering = createMasteringDisplayColorVolume(hdrMetadata);
        if (mastering != nullptr) {
            m_MasteringDisplayColorVolume = mastering;
            metadataApplied = true;
        }

        auto contentLightLevel = createContentLightLevelInfo(hdrMetadata);
        if (contentLightLevel != nullptr) {
            m_ContentLightLevelInfo = contentLightLevel;
            metadataApplied = true;
        }
    }

    bool metadataRemoved = hadMetadata && (m_MasteringDisplayColorVolume == nullptr && m_ContentLightLevelInfo == nullptr);
    m_HdrMetadataChanged = metadataApplied || metadataRemoved;
}
