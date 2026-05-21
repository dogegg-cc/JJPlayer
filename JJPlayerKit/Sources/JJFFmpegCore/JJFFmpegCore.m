//
//  JJFFmpegCore.m
//  JJPlayerKit
//
//  Created by Antigravity.
//

#import "JJFFmpegCore.h"
#import "DebugLog.h"

// 核心：在 C/ObjC 层级直接引入底层的 C 头文件，完美兼容任何 Clang Module / Header Search Path 解析
#import <ffmpegkit/FFmpegKitConfig.h>
#import <libavformat/avformat.h>
#import <libavcodec/avcodec.h>
#import <libavutil/avutil.h>
#import <libswscale/swscale.h>
#import <libswresample/swresample.h>
#import <libavutil/channel_layout.h>
#import <CoreVideo/CoreVideo.h>

@implementation JJFFmpegBridge {
    // 原始的 FFmpeg C 语言多媒体解复用上下文指针
    AVFormatContext *_formatContext;
    
    // 【阶段二：视频解码核心变量】
    AVCodecContext *_videoCodecContext; // 视频解码上下文，负责硬件/软件解码管道分配
    AVFrame *_videoFrame;               // 解码出的未压缩原始 YUV 图像帧
    AVPacket *_packet;                  // 从解复用中读取的压缩数据包（双路共用同一个 packet）
    struct SwsContext *_swsContext;     // sws 像素重排与格式转换上下文，用于 YUV -> BGRA 高效映射
    
    // 【阶段三：音频解码与重采样核心变量】
    AVCodecContext *_audioCodecContext; // 音频解码上下文
    AVFrame *_audioFrame;               // 解码出的未压缩原始音频帧（如 FLTP 格式）
    struct SwrContext *_swrContext;     // swr 重采样上下文，负责将任意音频转为 iOS 契合的 PCM
    uint8_t *_audioOutBuffer;           // 物理重采样输出字节缓冲区
    int _audioOutBufferSize;            // 重采样缓冲区的分配容量大小（字节）
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _formatContext = NULL;
        _videoCodecContext = NULL;
        _videoFrame = NULL;
        _packet = NULL;
        _swsContext = NULL;
        
        // 音频相关指针与缓冲区初始化
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
    }
    return self;
}

- (void)dealloc {
    // 析构红线：当 Objective-C 桥接对象被销毁时，必须强制触发 close 释放全部未托管 C 指针，杜绝物理泄露！
    [self close];
}

- (BOOL)openURL:(NSString *)url error:(NSError **)error {
    // 1. 每次打开新视频前，先清理并重置旧的上下文，防止多重流数据驻留内存
    [self close];
    
    AVFormatContext *ctx = NULL;
    
    // 2. 打开媒体文件输入源
    int ret = avformat_open_input(&ctx, [url UTF8String], NULL, NULL);
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
    
    // 3. 探测媒体流深度信息
    ret = avformat_find_stream_info(ctx, NULL);
    if (ret < 0) {
        [self close];
        if (error) {
            NSString *desc = [NSString stringWithFormat:@"FFmpeg: 无法解析媒体流信息，错误码: %d", ret];
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:ret userInfo:@{NSLocalizedDescriptionKey: desc}];
        }
        return NO;
    }
    
    // 4. 遍历多媒体容器中的所有流，锁定视频流与音频流的物理位置
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
    
    // 5. 解析总时长
    if (ctx->duration != AV_NOPTS_VALUE) {
        _duration = (double)ctx->duration / AV_TIME_BASE;
    }
    
    return YES;
}

- (void)close {
    // 1. 释放视频流解码与像素转换资源
    if (_videoCodecContext) {
        avcodec_free_context(&_videoCodecContext);
        _videoCodecContext = NULL;
    }
    if (_videoFrame) {
        av_frame_free(&_videoFrame);
        _videoFrame = NULL;
    }
    if (_swsContext) {
        sws_freeContext(_swsContext);
        _swsContext = NULL;
    }
    
    // 2. 释放音频流解码与重采样资源
    if (_audioCodecContext) {
        avcodec_free_context(&_audioCodecContext);
        _audioCodecContext = NULL;
    }
    if (_audioFrame) {
        av_frame_free(&_audioFrame);
        _audioFrame = NULL;
    }
    if (_swrContext) {
        swr_free(&_swrContext);
        _swsContext = NULL;
    }
    if (_audioOutBuffer) {
        av_free(_audioOutBuffer);
        _audioOutBuffer = NULL;
        _audioOutBufferSize = 0;
    }
    
    // 3. 释放共享解密包及多媒体容器
    if (_packet) {
        av_packet_free(&_packet);
        _packet = NULL;
    }
    if (_formatContext) {
        avformat_close_input(&_formatContext);
        _formatContext = NULL;
    }
    
    // 4. 重置状态属性
    _videoStreamIndex = -1;
    _audioStreamIndex = -1;
    _videoWidth = 0;
    _videoHeight = 0;
    _duration = 0.0;
    _videoCodecName = @"Unknown";
    _audioCodecName = @"Unknown";
}

// ==============================================================================
// MARK: - 【阶段三：一站式音视频双路解码分发核心实现】
// ==============================================================================

- (BOOL)initializeDecoders:(NSError **)error {
    // 1. 安全红线防护：必须至少有一个流被成功探测解析
    if (_videoStreamIndex == -1 && _audioStreamIndex == -1) {
        if (error) {
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"未找到任何有效的视频流或音频流索引"}];
        }
        return NO;
    }
    
    // 2. 幂等双路重置，杜绝重复打开的 C 上下文堆积
    if (_videoCodecContext) avcodec_free_context(&_videoCodecContext);
    if (_audioCodecContext) avcodec_free_context(&_audioCodecContext);
    if (_videoFrame) av_frame_free(&_videoFrame);
    if (_audioFrame) av_frame_free(&_audioFrame);
    if (_packet) av_packet_free(&_packet);
    if (_swrContext) swr_free(&_swrContext);
    if (_audioOutBuffer) { av_free(_audioOutBuffer); _audioOutBuffer = NULL; _audioOutBufferSize = 0; }
    
    // --------------------------------------------------
    // A. 视频解码器初始化
    // --------------------------------------------------
    if (_videoStreamIndex != -1) {
        AVStream *videoStream = _formatContext->streams[_videoStreamIndex];
        const AVCodec *videoCodec = avcodec_find_decoder(videoStream->codecpar->codec_id);
        if (!videoCodec) {
            if (error) {
                NSString *desc = [NSString stringWithFormat:@"FFmpeg: 找不到视频解码器 '%@'", _videoCodecName];
                *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:-2 userInfo:@{NSLocalizedDescriptionKey: desc}];
            }
            return NO;
        }
        
        _videoCodecContext = avcodec_alloc_context3(videoCodec);
        if (!_videoCodecContext) {
            if (error) {
                *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"FFmpeg: 无法分配视频解码器上下文"}];
            }
            return NO;
        }
        
        int ret = avcodec_parameters_to_context(_videoCodecContext, videoStream->codecpar);
        if (ret < 0) {
            avcodec_free_context(&_videoCodecContext);
            _videoCodecContext = NULL;
            if (error) {
                char errbuf[1024];
                av_strerror(ret, errbuf, sizeof(errbuf));
                NSString *desc = [NSString stringWithFormat:@"FFmpeg: 拷贝视频参数失败，错误: %s", errbuf];
                *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:ret userInfo:@{NSLocalizedDescriptionKey: desc}];
            }
            return NO;
        }
        
        // 开启多线程视频硬/软解码提速
        _videoCodecContext->thread_count = 0; // 让 FFmpeg 自动决定最适合当前 CPU 核心数的线程数
        
        ret = avcodec_open2(_videoCodecContext, videoCodec, NULL);
        if (ret < 0) {
            avcodec_free_context(&_videoCodecContext);
            _videoCodecContext = NULL;
            if (error) {
                char errbuf[1024];
                av_strerror(ret, errbuf, sizeof(errbuf));
                NSString *desc = [NSString stringWithFormat:@"FFmpeg: 无法打开视频解码器，错误: %s", errbuf];
                *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:ret userInfo:@{NSLocalizedDescriptionKey: desc}];
            }
            return NO;
        }
        
        _videoFrame = av_frame_alloc();
    }
    
    // --------------------------------------------------
    // B. 音频解码器与 Swr 重采样初始化
    // --------------------------------------------------
    if (_audioStreamIndex != -1) {
        AVStream *audioStream = _formatContext->streams[_audioStreamIndex];
        const AVCodec *audioCodec = avcodec_find_decoder(audioStream->codecpar->codec_id);
        if (!audioCodec) {
            if (error) {
                NSString *desc = [NSString stringWithFormat:@"FFmpeg: 找不到音频解码器 '%@'", _audioCodecName];
                *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:-4 userInfo:@{NSLocalizedDescriptionKey: desc}];
            }
            return NO;
        }
        
        _audioCodecContext = avcodec_alloc_context3(audioCodec);
        if (!_audioCodecContext) {
            if (error) {
                *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:-5 userInfo:@{NSLocalizedDescriptionKey: @"FFmpeg: 无法分配音频解码器上下文"}];
            }
            return NO;
        }
        
        int ret = avcodec_parameters_to_context(_audioCodecContext, audioStream->codecpar);
        if (ret < 0) {
            avcodec_free_context(&_audioCodecContext);
            _audioCodecContext = NULL;
            if (error) {
                char errbuf[1024];
                av_strerror(ret, errbuf, sizeof(errbuf));
                NSString *desc = [NSString stringWithFormat:@"FFmpeg: 拷贝音频参数失败，错误: %s", errbuf];
                *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:ret userInfo:@{NSLocalizedDescriptionKey: desc}];
            }
            return NO;
        }
        
        ret = avcodec_open2(_audioCodecContext, audioCodec, NULL);
        if (ret < 0) {
            avcodec_free_context(&_audioCodecContext);
            _audioCodecContext = NULL;
            if (error) {
                char errbuf[1024];
                av_strerror(ret, errbuf, sizeof(errbuf));
                NSString *desc = [NSString stringWithFormat:@"FFmpeg: 无法打开音频解码器，错误: %s", errbuf];
                *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:ret userInfo:@{NSLocalizedDescriptionKey: desc}];
            }
            return NO;
        }
        
        _audioFrame = av_frame_alloc();
        
        // --------------------------------------------------
        // C. 配置 libswresample 物理重采样
        // --------------------------------------------------
        // iOS 物理声卡最契合的音频播放配置：44100Hz, S16 (16-bit 线性), 双声道立体声
        AVChannelLayout outLayout;
        av_channel_layout_default(&outLayout, 2); // 物理双声道布局描述
        
        AVChannelLayout inLayout = _audioCodecContext->ch_layout; // 源音频声道布局
        
        // 核心 C API：使用 swr_alloc_set_opts2 物理配置重采样参数（现代 FFmpeg v6.0+ 标准，防范旧函数废弃报错）
        ret = swr_alloc_set_opts2(&_swrContext,
                                  &outLayout,
                                  AV_SAMPLE_FMT_S16, // 目标采样位深：16-bit 整数交错型（iOS 声卡黄金标准）
                                  44100,             // 目标物理采样率：44.1kHz 标准 CD 级音质
                                  &inLayout,
                                  _audioCodecContext->sample_fmt,
                                  _audioCodecContext->sample_rate,
                                  0,
                                  NULL);
        if (ret < 0 || !_swrContext) {
            DLog(@"❌ [JJFFmpegBridge] swr_alloc_set_opts2 分配重采样上下文失败，错误码: %d", ret);
            if (error) {
                *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:ret userInfo:@{NSLocalizedDescriptionKey: @"FFmpeg: 无法分配音频重采样器"}];
            }
            return NO;
        }
        
        ret = swr_init(_swrContext);
        if (ret < 0) {
            DLog(@"❌ [JJFFmpegBridge] swr_init 激活音频重采样管道失败，错误码: %d", ret);
            swr_free(&_swrContext);
            if (error) {
                *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:ret userInfo:@{NSLocalizedDescriptionKey: @"FFmpeg: 无法初始化音频重采样管道"}];
            }
            return NO;
        }
        
        // 预分配临时重采样字节写入缓冲区：44.1kHz * 双声道 * 2字节(16bit) = 176.4KB，足够容纳秒级采样，绝不溢出！
        _audioOutBufferSize = 44100 * 2 * 2; 
        _audioOutBuffer = (uint8_t *)av_malloc(_audioOutBufferSize);
        if (!_audioOutBuffer) {
            swr_free(&_swrContext);
            if (error) {
                *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:-6 userInfo:@{NSLocalizedDescriptionKey: @"FFmpeg: 无法为重采样器分配输出缓冲区"}];
            }
            return NO;
        }
        
        DLog(@"🎵 [JJFFmpegBridge] 音频解码及物理重采样器初始化成功！源: %dHz/格式:%d -> 目标: 44100Hz/S16(Packed)/2声道", _audioCodecContext->sample_rate, _audioCodecContext->sample_fmt);
    }
    
    // --------------------------------------------------
    // D. 分配共享的解包 packet
    // --------------------------------------------------
    _packet = av_packet_alloc();
    
    return YES;
}

- (int)decodeAndDispatch {
    // 1. 安全红线防护：保障底层多媒体容器与共享包空间健全
    if (!_formatContext || !_packet) {
        return -1;
    }
    
    int ret;
    // 2. 从输入源读取单个压缩数据包，跑在全局唯一的 av_read_frame 入口中
    ret = av_read_frame(_formatContext, _packet);
    if (ret < 0) {
        // 读取到媒体流尾部(EOF)或发生严重 I/O 中断
        return -1;
    }
    
    int processedStatus = 1; // 默认 1 代表读取到了无关的数据包（如字幕或其它流），已安全释放
    
    // --------------------------------------------------
    // A. 视频包解码与直刷分发
    // --------------------------------------------------
    if (_packet->stream_index == _videoStreamIndex && _videoCodecContext && _videoFrame) {
        ret = avcodec_send_packet(_videoCodecContext, _packet);
        if (ret >= 0) {
            ret = avcodec_receive_frame(_videoCodecContext, _videoFrame);
            if (ret == 0) {
                // 成功解码出一帧 YUV 帧！立即重排颜色直出 iOS 原生 CVPixelBuffer
                CVPixelBufferRef pixelBuffer = [self convertFrameToPixelBuffer:_videoFrame];
                if (pixelBuffer) {
                    // 💥【阶段四：高精度时钟同步】换算视频帧的显示时间戳（PTS，以秒为单位）
                    double ptsSeconds = 0.0;
                    if (_videoFrame->best_effort_timestamp != AV_NOPTS_VALUE) {
                        ptsSeconds = _videoFrame->best_effort_timestamp * av_q2d(_formatContext->streams[_videoStreamIndex]->time_base);
                    } else if (_videoFrame->pts != AV_NOPTS_VALUE) {
                        ptsSeconds = _videoFrame->pts * av_q2d(_formatContext->streams[_videoStreamIndex]->time_base);
                    }
                    
                    // 若 Swift 注册了视频渲染闭包，直接高效率回调抛给 Swift 强安全接管
                    if (self.onVideoFrameDecoded) {
                        self.onVideoFrameDecoded(pixelBuffer, ptsSeconds);
                    }
                    // 核心内存防线：Swift 侧 takeRetainedValue() 会接管引用计数，在此安全释放 ObjC 侧强引用
                    CVPixelBufferRelease(pixelBuffer);
                }
                processedStatus = 0; // 成功处理了视频帧
            }
        }
    }
    // --------------------------------------------------
    // B. 音频包解码与 Swr 重采样分发
    // --------------------------------------------------
    else if (_packet->stream_index == _audioStreamIndex && _audioCodecContext && _audioFrame && _swrContext && _audioOutBuffer) {
        ret = avcodec_send_packet(_audioCodecContext, _packet);
        if (ret >= 0) {
            ret = avcodec_receive_frame(_audioCodecContext, _audioFrame);
            if (ret == 0) {
                // 1. 使用 64 位整型安全接收重采样大小计算结果，防范溢出与损坏数据
                int64_t rescaledSamples = av_rescale_rnd(swr_get_delay(_swrContext, _audioFrame->sample_rate) + _audioFrame->nb_samples,
                                                         44100,
                                                         _audioFrame->sample_rate,
                                                         AV_ROUND_UP);
                
                // 💥【安全防线：阈值哨兵】若计算出的采样点数小于等于0，或超过物理最大阈值（100,000），判定为损坏数据，安全跳过
                if (rescaledSamples <= 0 || rescaledSamples > 100000) {
                    av_packet_unref(_packet);
                    return 1; // 丢弃该异常帧，平滑驱动至下一包，杜绝崩溃与内存越界
                }
                
                int outSamples = (int)rescaledSamples;
                
                // 2. 执行底层的物理格式重采样，将 Planar 等不兼容格式转换为 standard PCM
                int convertedSamples = swr_convert(_swrContext,
                                                   &_audioOutBuffer,
                                                   outSamples,
                                                   (const uint8_t **)_audioFrame->data,
                                                   _audioFrame->nb_samples);
                
                if (convertedSamples > 0) {
                    // 3. 计算实际产出的交错型 PCM 字节大小：采样点数 * 双声道 * 2字节(16-bit)
                    int pcmBytes = convertedSamples * 2 * 2;
                    
                    // 💥【阶段四：高精度时钟同步】换算音频帧的起始时间戳（PTS，以秒为单位）
                    double ptsSeconds = 0.0;
                    if (_audioFrame->best_effort_timestamp != AV_NOPTS_VALUE) {
                        ptsSeconds = _audioFrame->best_effort_timestamp * av_q2d(_formatContext->streams[_audioStreamIndex]->time_base);
                    } else if (_audioFrame->pts != AV_NOPTS_VALUE) {
                        ptsSeconds = _audioFrame->pts * av_q2d(_formatContext->streams[_audioStreamIndex]->time_base);
                    }
                    
                    // 4. 包装为零拷贝的 NSData，派发回调抛出给 Swift 的生产者队列
                    if (self.onAudioFrameDecoded) {
                        NSData *pcmData = [NSData dataWithBytesNoCopy:_audioOutBuffer length:pcmBytes freeWhenDone:NO];
                        self.onAudioFrameDecoded(pcmData, ptsSeconds);
                    }
                }
                processedStatus = 0; // 成功处理了音频帧
            }
        }
    }
    
    // 3. 极其关键的物理防线：必须强制 unref 释放共享数据包的内容，否则高频读取下内存会在几秒内瞬间爆炸！
    av_packet_unref(_packet);
    
    return processedStatus;
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
    
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          width,
                                          height,
                                          kCVPixelFormatType_32BGRA,
                                          (__bridge CFDictionaryRef)options,
                                          &pixelBuffer);
    if (status != kCVReturnSuccess) {
        DLog(@"❌ [JJFFmpegBridge] CVPixelBufferCreate 物理创建失败！错误码: %d", status);
        return NULL;
    }
    
    if (CVPixelBufferLockBaseAddress(pixelBuffer, 0) != kCVReturnSuccess) {
        DLog(@"❌ [JJFFmpegBridge] CVPixelBufferLockBaseAddress 锁定基地址失败");
        CFRelease(pixelBuffer);
        return NULL;
    }
    
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    
    _swsContext = sws_getCachedContext(_swsContext,
                                       width,
                                       height,
                                       frame->format,
                                       width,
                                       height,
                                       AV_PIX_FMT_BGRA,
                                       SWS_FAST_BILINEAR,
                                       NULL,
                                       NULL,
                                       NULL);
    
    if (!_swsContext) {
        DLog(@"❌ [JJFFmpegBridge] sws_getCachedContext 像素缩放重排上下文分配失败！");
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CFRelease(pixelBuffer);
        return NULL;
    }
    
    uint8_t *dstData[4] = { (uint8_t *)baseAddress, NULL, NULL, NULL };
    int dstLinesize[4] = { (int)bytesPerRow, 0, 0, 0 };
    
    sws_scale(_swsContext,
              (const uint8_t *const *)frame->data,
              frame->linesize,
              0,
              height,
              dstData,
              dstLinesize);
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    return pixelBuffer;
}

@end
