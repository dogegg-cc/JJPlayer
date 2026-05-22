//
//  JJFFmpegCore.m
//  JJPlayerKit
//
//  Created by Antigravity.
//

#import "JJFFmpegCore.h"
#import "DebugLog.h"

#import <libavformat/avformat.h>
#import <libavcodec/avcodec.h>
#import <libavutil/avutil.h>
#import <libswscale/swscale.h>
#import <libswresample/swresample.h>
#import <libavutil/channel_layout.h>
#import <libavutil/opt.h>
#import <CoreVideo/CoreVideo.h>

@interface JJFFmpegBridge () {
    // 原始的 FFmpeg C 语言多媒体解复用上下文指针
    AVFormatContext *_formatContext;
    
    // 视频解码核心变量
    AVCodecContext *_videoCodecContext; // 视频解码上下文
    AVFrame *_videoFrame;               // 未压缩原始 YUV 图像帧
    AVPacket *_packet;                  // 压缩数据包（双路共用）
    struct SwsContext *_swsContext;     // sws 像素重排与格式转换上下文，用于 YUV -> BGRA 高效映射
    
    // 音频解码与重采样核心变量
    AVCodecContext *_audioCodecContext; // 音频解码上下文
    AVFrame *_audioFrame;               // 未压缩原始音频帧
    struct SwrContext *_swrContext;     // swr 重采样上下文
    uint8_t *_audioOutBuffer;           // 重采样输出字节缓冲区
    int _audioOutBufferSize;            // 重采样缓冲区的分配容量大小（字节）
    
    // 基础流索引与元数据参数
    int _videoStreamIndex;
    int _audioStreamIndex;
    double _duration;
    int _videoWidth;
    int _videoHeight;
    NSString *_videoCodecName;
    NSString *_audioCodecName;
    double _maxReadPTS;
    
    // I/O 中断控制标志（volatile 确保跨线程立即可见，@package 使同文件 C 函数可访问）
    @package volatile int _abortRequested;
}

// 内部声明私有的视频 YUV 转 RGB CVPixelBuffer 助手方法签名
- (CVPixelBufferRef)convertFrameToPixelBuffer:(AVFrame *)frame;

// 内部声明私有初始化拆分方法签名
- (BOOL)initVideoDecoder:(NSError **)error;
- (BOOL)initAudioDecoder:(NSError **)error;
- (BOOL)initAudioResampler:(NSError **)error;
- (void)resetDecoders;

@end

// FFmpeg I/O 中断回调：返回 1 时立即中断 av_read_frame 等阻塞 I/O 操作
static int interruptCallback(void *opaque) {
    JJFFmpegBridge *bridge = (__bridge JJFFmpegBridge *)opaque;
    if (bridge == nil) return 1;
    return bridge->_abortRequested;
}

@implementation JJFFmpegBridge

- (instancetype)init {
    self = [super init];
    if (self) {
        _formatContext = NULL;
        _videoCodecContext = NULL;
        _videoFrame = NULL;
        _packet = NULL;
        _swsContext = NULL;
        
        _audioCodecContext = NULL;
        _audioFrame = NULL;
        _swrContext = NULL;
        _audioOutBuffer = NULL;
        _audioOutBufferSize = 0;
        
        _videoStreamIndex = -1;
        _audioStreamIndex = -1;
        _duration = 0.0;
        _videoWidth = 0;
        _videoHeight = 0;
        _videoCodecName = @"Unknown";
        _audioCodecName = @"Unknown";
        _maxReadPTS = 0.0;
        _abortRequested = 0;
    }
    return self;
}

- (void)dealloc {
    [self close];
}

- (BOOL)openURL:(NSString *)url error:(NSError **)error {
    [self close];
    
    AVDictionary *opts = NULL;
    av_dict_set(&opts, "reconnect", "1", 0);
    av_dict_set(&opts, "reconnect_streamed", "1", 0);
    av_dict_set(&opts, "reconnect_at_eof", "1", 0);       // 断点续连
    av_dict_set(&opts, "reconnect_delay_max", "5", 0);
    av_dict_set(&opts, "timeout", "10000000", 0); // 10秒连接超时
    av_dict_set(&opts, "user_agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 JJPlayer/1.0", 0);
    av_dict_set(&opts, "http_persistent", "1", 0);           // TCP 链路复用 (Keep-Alive)
    
    // A. 仅对 HLS/m3u8 注入激进首开参数（普通 MP4 使用 FFmpeg 默认宽裕值）
    BOOL isHLS = [url containsString:@".m3u8"] || [url containsString:@"pure_variant"];
    if (isHLS) {
        av_dict_set(&opts, "probesize", "150000", 0);            // 150KB 极轻量嗅探
        av_dict_set(&opts, "max_analyze_duration", "500000", 0); // 500ms 嗅探超时上限
        av_dict_set(&opts, "fflags", "nobuffer", 0);             // 无缓冲（低延迟直播）
        av_dict_set(&opts, "scan_all_pmts", "0", 0);             // 关闭全部 PMT 扫描
    }
    
    // B. 预分配 AVFormatContext 并直接在结构体上设置 max_streams（比字典传参更可靠）
    AVFormatContext *ctx = avformat_alloc_context();
    if (!ctx) {
        av_dict_free(&opts);
        if (error) {
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"FFmpeg: 无法分配 AVFormatContext"}];
        }
        return NO;
    }
    ctx->max_streams = 100; // 直接写入结构体，100% 确保 HLS demuxer 不会因流数量超限崩溃
    
    // C. 仅对本地文件设置协议白名单（提纯 m3u8 内嵌 HTTPS 子链接需要放行）
    //    直接的 HTTPS URL 不需要设置，FFmpeg 内部自动处理协议链路
    if ([url hasPrefix:@"/"]) {
        av_opt_set(ctx, "protocol_whitelist", "file,http,https,tls,tcp,crypto,data", 0);
    }
    
    // D. 注册 I/O 中断回调：close() 时置 _abortRequested=1，让 av_read_frame 立即中断返回
    _abortRequested = 0;
    ctx->interrupt_callback.callback = interruptCallback;
    ctx->interrupt_callback.opaque = (__bridge void *)self;
    
    int ret = avformat_open_input(&ctx, [url UTF8String], NULL, &opts);
    av_dict_free(&opts);
    
    if (ret != 0) {
        if (error) {
            char errbuf[1024];
            av_strerror(ret, errbuf, sizeof(errbuf));
            NSString *desc = [NSString stringWithFormat:@"FFmpeg: 无法打开输入源 '%@'，错误信息: %s", url, errbuf];
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:ret userInfo:@{NSLocalizedDescriptionKey: desc}];
        }
        return NO;
    }
    
    _formatContext = ctx;
    
    // B. 物理流过滤拦截：仅保留首个视频和首个音频流，其余物理 discard 掉，极速起播
    int video_count = 0;
    int audio_count = 0;
    for (unsigned int i = 0; i < ctx->nb_streams; i++) {
        AVStream *stream = ctx->streams[i];
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            video_count++;
            if (video_count > 1) {
                stream->discard = AVDISCARD_ALL;
            }
        } else if (stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            audio_count++;
            if (audio_count > 1) {
                stream->discard = AVDISCARD_ALL;
            }
        } else {
            stream->discard = AVDISCARD_ALL;
        }
    }
    
    ret = avformat_find_stream_info(ctx, NULL);
    if (ret < 0) {
        [self close];
        if (error) {
            NSString *desc = [NSString stringWithFormat:@"FFmpeg: 无法解析媒体流信息，错误码: %d", ret];
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:ret userInfo:@{NSLocalizedDescriptionKey: desc}];
        }
        return NO;
    }
    
    for (unsigned int i = 0; i < ctx->nb_streams; i++) {
        AVStream *stream = ctx->streams[i];
        AVCodecParameters *codecpar = stream->codecpar;
        
        if (codecpar->codec_type == AVMEDIA_TYPE_VIDEO && _videoStreamIndex == -1) {
            _videoStreamIndex = i;
            _videoWidth = codecpar->width;
            _videoHeight = codecpar->height;
            const AVCodec *codec = avcodec_find_decoder(codecpar->codec_id);
            if (codec) {
                _videoCodecName = [NSString stringWithUTF8String:codec->name];
            }
        } 
        else if (codecpar->codec_type == AVMEDIA_TYPE_AUDIO && _audioStreamIndex == -1) {
            _audioStreamIndex = i;
            const AVCodec *codec = avcodec_find_decoder(codecpar->codec_id);
            if (codec) {
                _audioCodecName = [NSString stringWithUTF8String:codec->name];
            }
        }
    }
    
    if (ctx->duration != AV_NOPTS_VALUE) {
        _duration = (double)ctx->duration / AV_TIME_BASE;
    }
    _maxReadPTS = 0.0;
    
    return YES;
}

- (void)close {
    // 先置中断标志，让卡在 I/O 重连循环中的 av_read_frame 立即返回
    _abortRequested = 1;
    
    @synchronized (self) {
        [self resetDecoders];
        
        if (_formatContext) {
            avformat_close_input(&_formatContext);
            _formatContext = NULL;
        }
        
        _videoStreamIndex = -1;
        _audioStreamIndex = -1;
        _videoWidth = 0;
        _videoHeight = 0;
        _duration = 0.0;
        _videoCodecName = @"Unknown";
        _audioCodecName = @"Unknown";
        _maxReadPTS = 0.0;
    }
}

// ==============================================================================

#pragma mark - 物理初始化与拆分配置

// ==============================================================================

- (BOOL)initializeDecoders:(NSError **)error {
    if (self->_videoStreamIndex == -1 && self->_audioStreamIndex == -1) {
        if (error) {
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"未找到任何有效的视频流或音频流索引"}];
        }
        return NO;
    }
    
    [self resetDecoders];
    
    if (self->_videoStreamIndex != -1) {
        if (![self initVideoDecoder:error]) {
            return NO;
        }
    }
    
    if (self->_audioStreamIndex != -1) {
        if (![self initAudioDecoder:error] || ![self initAudioResampler:error]) {
            return NO;
        }
    }
    
    self->_packet = av_packet_alloc();
    return YES;
}

- (BOOL)initVideoDecoder:(NSError **)error {
    AVStream *videoStream = self->_formatContext->streams[self->_videoStreamIndex];
    const AVCodec *videoCodec = avcodec_find_decoder(videoStream->codecpar->codec_id);
    if (!videoCodec) {
        if (error) {
            NSString *desc = [NSString stringWithFormat:@"FFmpeg: 找不到视频解码器 '%@'", self.videoCodecName];
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:-2 userInfo:@{NSLocalizedDescriptionKey: desc}];
        }
        return NO;
    }
    
    self->_videoCodecContext = avcodec_alloc_context3(videoCodec);
    if (!self->_videoCodecContext) {
        if (error) {
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"FFmpeg: 无法分配视频解码器上下文"}];
        }
        return NO;
    }
    
    int ret = avcodec_parameters_to_context(self->_videoCodecContext, videoStream->codecpar);
    if (ret < 0) {
        avcodec_free_context(&(self->_videoCodecContext));
        if (error) {
            char errbuf[1024];
            av_strerror(ret, errbuf, sizeof(errbuf));
            NSString *desc = [NSString stringWithFormat:@"FFmpeg: 拷贝视频参数失败，错误: %s", errbuf];
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:ret userInfo:@{NSLocalizedDescriptionKey: desc}];
        }
        return NO;
    }
    
    self->_videoCodecContext->thread_count = 0; // 自动多线程解码
    ret = avcodec_open2(self->_videoCodecContext, videoCodec, NULL);
    if (ret < 0) {
        avcodec_free_context(&(self->_videoCodecContext));
        if (error) {
            char errbuf[1024];
            av_strerror(ret, errbuf, sizeof(errbuf));
            NSString *desc = [NSString stringWithFormat:@"FFmpeg: 无法打开视频解码器，错误: %s", errbuf];
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:ret userInfo:@{NSLocalizedDescriptionKey: desc}];
        }
        return NO;
    }
    
    self->_videoFrame = av_frame_alloc();
    return YES;
}

- (BOOL)initAudioDecoder:(NSError **)error {
    AVStream *audioStream = self->_formatContext->streams[self->_audioStreamIndex];
    const AVCodec *audioCodec = avcodec_find_decoder(audioStream->codecpar->codec_id);
    if (!audioCodec) {
        if (error) {
            NSString *desc = [NSString stringWithFormat:@"FFmpeg: 找不到音频解码器 '%@'", self.audioCodecName];
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:-4 userInfo:@{NSLocalizedDescriptionKey: desc}];
        }
        return NO;
    }
    
    self->_audioCodecContext = avcodec_alloc_context3(audioCodec);
    if (!self->_audioCodecContext) {
        if (error) {
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:-5 userInfo:@{NSLocalizedDescriptionKey: @"FFmpeg: 无法分配音频解码器上下文"}];
        }
        return NO;
    }
    
    int ret = avcodec_parameters_to_context(self->_audioCodecContext, audioStream->codecpar);
    if (ret < 0) {
        avcodec_free_context(&(self->_audioCodecContext));
        if (error) {
            char errbuf[1024];
            av_strerror(ret, errbuf, sizeof(errbuf));
            NSString *desc = [NSString stringWithFormat:@"FFmpeg: 拷贝音频参数失败，错误: %s", errbuf];
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:ret userInfo:@{NSLocalizedDescriptionKey: desc}];
        }
        return NO;
    }
    
    ret = avcodec_open2(self->_audioCodecContext, audioCodec, NULL);
    if (ret < 0) {
        avcodec_free_context(&(self->_audioCodecContext));
        if (error) {
            char errbuf[1024];
            av_strerror(ret, errbuf, sizeof(errbuf));
            NSString *desc = [NSString stringWithFormat:@"FFmpeg: 无法打开音频解码器，错误: %s", errbuf];
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:ret userInfo:@{NSLocalizedDescriptionKey: desc}];
        }
        return NO;
    }
    
    self->_audioFrame = av_frame_alloc();
    return YES;
}

- (BOOL)initAudioResampler:(NSError **)error {
    AVChannelLayout outLayout;
    av_channel_layout_default(&outLayout, 2); // 左右双声道
    AVChannelLayout inLayout = self->_audioCodecContext->ch_layout;
    
    int ret = swr_alloc_set_opts2(&(self->_swrContext),
                                  &outLayout,
                                  AV_SAMPLE_FMT_S16, // S16 格式
                                  44100,             // 44.1kHz 标准音质
                                  &inLayout,
                                  self->_audioCodecContext->sample_fmt,
                                  self->_audioCodecContext->sample_rate,
                                  0,
                                  NULL);
    if (ret < 0 || !self->_swrContext) {
        if (error) {
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:ret userInfo:@{NSLocalizedDescriptionKey: @"FFmpeg: 无法分配音频重采样器"}];
        }
        return NO;
    }
    
    ret = swr_init(self->_swrContext);
    if (ret < 0) {
        swr_free(&(self->_swrContext));
        if (error) {
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:ret userInfo:@{NSLocalizedDescriptionKey: @"FFmpeg: 无法初始化音频重采样管道"}];
        }
        return NO;
    }
    
    self->_audioOutBufferSize = 44100 * 2 * 2;
    self->_audioOutBuffer = (uint8_t *)av_malloc(self->_audioOutBufferSize);
    if (!self->_audioOutBuffer) {
        swr_free(&(self->_swrContext));
        if (error) {
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:-6 userInfo:@{NSLocalizedDescriptionKey: @"FFmpeg: 无法为重采样器分配输出缓冲区"}];
        }
        return NO;
    }
    
    return YES;
}

- (void)resetDecoders {
    if (self->_videoCodecContext) { avcodec_free_context(&(self->_videoCodecContext)); self->_videoCodecContext = NULL; }
    if (self->_audioCodecContext) { avcodec_free_context(&(self->_audioCodecContext)); self->_audioCodecContext = NULL; }
    if (self->_videoFrame) { av_frame_free(&(self->_videoFrame)); self->_videoFrame = NULL; }
    if (self->_audioFrame) { av_frame_free(&(self->_audioFrame)); self->_audioFrame = NULL; }
    if (self->_packet) { av_packet_free(&(self->_packet)); self->_packet = NULL; }
    if (self->_swrContext) { swr_free(&(self->_swrContext)); self->_swrContext = NULL; }
    if (self->_audioOutBuffer) { av_free(self->_audioOutBuffer); self->_audioOutBuffer = NULL; self->_audioOutBufferSize = 0; }
    if (self->_swsContext) { sws_freeContext(self->_swsContext); self->_swsContext = NULL; }
}

// ==============================================================================

#pragma mark - 物理一站式音视频双路解码

// ==============================================================================

- (int)decodeAndDispatch {
    @synchronized (self) {
        if (!self->_formatContext || !self->_packet) {
            return -1;
        }
        
        int ret = av_read_frame(self->_formatContext, self->_packet);
        if (ret < 0) {
            if (ret == AVERROR_EOF) {
                return -1; // 真正的正常播放完毕 (EOF)
            } else {
                return -2; // 异常的网络断开/读取错误 (I/O)
            }
        }
        
        if (self->_packet->pts != AV_NOPTS_VALUE) {
            double pktPts = self->_packet->pts * av_q2d(self->_formatContext->streams[self->_packet->stream_index]->time_base);
            self.maxReadPTS = MAX(self.maxReadPTS, pktPts);
        }
        
        int processedStatus = 1; // 默认 1 代表读取到了无关数据包
        
        // A. 视频包解码与直刷分发
        if (self->_packet->stream_index == self->_videoStreamIndex && self->_videoCodecContext && self->_videoFrame) {
            ret = avcodec_send_packet(self->_videoCodecContext, self->_packet);
            if (ret >= 0) {
                ret = avcodec_receive_frame(self->_videoCodecContext, self->_videoFrame);
                if (ret == 0) {
                    CVPixelBufferRef pixelBuffer = [self convertFrameToPixelBuffer:self->_videoFrame];
                    if (pixelBuffer) {
                        double ptsSeconds = 0.0;
                        if (self->_videoFrame->best_effort_timestamp != AV_NOPTS_VALUE) {
                            ptsSeconds = self->_videoFrame->best_effort_timestamp * av_q2d(self->_formatContext->streams[self->_videoStreamIndex]->time_base);
                        } else if (self->_videoFrame->pts != AV_NOPTS_VALUE) {
                            ptsSeconds = self->_videoFrame->pts * av_q2d(self->_formatContext->streams[self->_videoStreamIndex]->time_base);
                        }
                        
                        if (self.onVideoFrameDecoded) {
                            self.onVideoFrameDecoded(pixelBuffer, ptsSeconds);
                        }
                        CVPixelBufferRelease(pixelBuffer);
                    }
                    processedStatus = 0;
                }
            }
        }
        // B. 音频包解码与 Swr 重采样分发
        else if (self->_packet->stream_index == self->_audioStreamIndex && self->_audioCodecContext && self->_audioFrame && self->_swrContext && self->_audioOutBuffer) {
            ret = avcodec_send_packet(self->_audioCodecContext, self->_packet);
            if (ret >= 0) {
                ret = avcodec_receive_frame(self->_audioCodecContext, self->_audioFrame);
                if (ret == 0) {
                    int64_t rescaledSamples = av_rescale_rnd(swr_get_delay(self->_swrContext, self->_audioFrame->sample_rate) + self->_audioFrame->nb_samples,
                                                             44100,
                                                             self->_audioFrame->sample_rate,
                                                             AV_ROUND_UP);
                    
                    if (rescaledSamples > 0 && rescaledSamples <= 100000) {
                        int outSamples = (int)rescaledSamples;
                        int convertedSamples = swr_convert(self->_swrContext,
                                                           &(self->_audioOutBuffer),
                                                           outSamples,
                                                           (const uint8_t **)self->_audioFrame->data,
                                                           self->_audioFrame->nb_samples);
                        
                        if (convertedSamples > 0) {
                            int pcmBytes = convertedSamples * 2 * 2;
                            double ptsSeconds = 0.0;
                            if (self->_audioFrame->best_effort_timestamp != AV_NOPTS_VALUE) {
                                ptsSeconds = self->_audioFrame->best_effort_timestamp * av_q2d(self->_formatContext->streams[self->_audioStreamIndex]->time_base);
                            } else if (self->_audioFrame->pts != AV_NOPTS_VALUE) {
                                ptsSeconds = self->_audioFrame->pts * av_q2d(self->_formatContext->streams[self->_audioStreamIndex]->time_base);
                            }
                            
                            if (self.onAudioFrameDecoded) {
                                NSData *pcmData = [NSData dataWithBytesNoCopy:self->_audioOutBuffer length:pcmBytes freeWhenDone:NO];
                                self.onAudioFrameDecoded(pcmData, ptsSeconds);
                            }
                        }
                    }
                    processedStatus = 0;
                }
            }
        }
        
        av_packet_unref(self->_packet);
        return processedStatus;
    }
}

- (CVPixelBufferRef)convertFrameToPixelBuffer:(AVFrame *)frame {
    int width = frame->width;
    int height = frame->height;
    CVPixelBufferRef pixelBuffer = NULL;
    
    NSDictionary *options = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)options, &pixelBuffer);
    if (status != kCVReturnSuccess) {
        return NULL;
    }
    
    if (CVPixelBufferLockBaseAddress(pixelBuffer, 0) != kCVReturnSuccess) {
        CFRelease(pixelBuffer);
        return NULL;
    }
    
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    
    self->_swsContext = sws_getCachedContext(self->_swsContext, width, height, frame->format, width, height, AV_PIX_FMT_BGRA, SWS_FAST_BILINEAR, NULL, NULL, NULL);
    if (!self->_swsContext) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CFRelease(pixelBuffer);
        return NULL;
    }
    
    uint8_t *dstData[4] = { (uint8_t *)baseAddress, NULL, NULL, NULL };
    int dstLinesize[4] = { (int)bytesPerRow, 0, 0, 0 };
    
    sws_scale(self->_swsContext, (const uint8_t *const *)frame->data, frame->linesize, 0, height, dstData, dstLinesize);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    return pixelBuffer;
}

// ==============================================================================

#pragma mark - 物理跳转 Seek

// ==============================================================================

- (BOOL)seekToTime:(double)seconds {
    @synchronized (self) {
        if (!self->_formatContext) {
            return NO;
        }
        
        int64_t timestamp = (int64_t)(seconds * AV_TIME_BASE);
        int ret = av_seek_frame(self->_formatContext, -1, timestamp, AVSEEK_FLAG_BACKWARD);
        
        if (self->_videoCodecContext) {
            avcodec_flush_buffers(self->_videoCodecContext);
        }
        if (self->_audioCodecContext) {
            avcodec_flush_buffers(self->_audioCodecContext);
        }
        
        self.maxReadPTS = seconds;
        return ret >= 0;
    }
}

@end
