#pragma once

#include "renderer.h"

#ifdef __OBJC__
#include <atomic>

#import <Metal/Metal.h>
class VTBaseRenderer : public IFFmpegRenderer {
public:
    VTBaseRenderer(IFFmpegRenderer::RendererType type);
    virtual ~VTBaseRenderer();
    bool checkDecoderCapabilities(PDECODER_PARAMETERS params);
    void setHdrMode(bool enabled) override;
    void appendDebugOverlayStats(char* output, int length, int* offset) override;
    bool configureDecoderSession(AVCodecContext* context) override;

protected:
    void updateHdrOutputState(int colorTrc, bool wantsEdr);
    bool configureHwFramesContext(AVCodecContext* context, AVBufferRef* hwContext, AVPixelFormat pixelFormat);

    enum class HdrOutputState {
        Unknown = 0,
        Sdr,
        HdrPq,
        HdrHlg,
        HdrUnknown,
    };

    bool m_HdrMetadataChanged; // Manual reset
    CFDataRef m_MasteringDisplayColorVolume;
    CFDataRef m_ContentLightLevelInfo;
    std::atomic<int> m_HdrOutputState;
};
#endif

// A factory is required to avoid pulling in
// incompatible Objective-C headers.

class VTMetalRendererFactory {
public:
    static
    IFFmpegRenderer* createRenderer(bool hwAccel);
};

class VTRendererFactory {
public:
    static
    IFFmpegRenderer* createRenderer();
};
