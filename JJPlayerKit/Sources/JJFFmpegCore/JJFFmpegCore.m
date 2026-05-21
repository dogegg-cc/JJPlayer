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
#import <CoreVideo/CoreVideo.h>

@implementation JJFFmpegBridge {
    // 原始的 FFmpeg C 语言多媒体上下文指针。
    // 在 C 语言世界中，这些指针不受 iOS ARC 自动引用计数管理，必须手动分配与释放，否则会造成致命的内存泄漏！
    AVFormatContext *_formatContext;
    
    // 【阶段二新增】视频解码核心变量
    AVCodecContext *_videoCodecContext; // 视频解码上下文，负责硬件/软件解码管道分配
    AVFrame *_videoFrame;               // 解码出的未压缩原始 YUV 图像帧
    AVPacket *_packet;                  // 从解复用中读取的压缩数据包
    struct SwsContext *_swsContext;     // sws 像素重排与格式转换上下文，用于 YUV -> BGRA 高效映射
}


- (instancetype)init {
    self = [super init];
    if (self) {
        _formatContext = NULL;
        _videoCodecContext = NULL;
        _videoFrame = NULL;
        _packet = NULL;
        _swsContext = NULL;
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
    // 析构红线：当 Objective-C 桥接对象被销毁时，必须强制触发 close 释放全部未托管 C 指针与解码通道，拒绝泄露！
    [self close];
}

- (BOOL)openURL:(NSString *)url error:(NSError **)error {
    // 1. 每次打开新视频前，先清理并重置旧的上下文，防止之前的视频数据驻留内存
    [self close];
    
    AVFormatContext *ctx = NULL;
    
    // 2. 打开媒体文件输入源 (可以是本地文件的绝对路径，也可以是 rtmp/http/rtsp 等网络流)
    // 原始 C 接口：avformat_open_input 负责解析流的头部协议信息，并为 ctx 分配核心格式上下文内存
    int ret = avformat_open_input(&ctx, [url UTF8String], NULL, NULL);
    if (ret != 0) {
        if (error) {
            // 如果打开失败，通过 C 接口 av_strerror 将原始的负数错误码转换为人类可读的字符串，并包装成 NSError 向上抛给 Swift
            char errbuf[1024];
            av_strerror(ret, errbuf, sizeof(errbuf));
            NSString *desc = [NSString stringWithFormat:@"FFmpeg: 无法打开输入源 '%@'，错误信息: %s", url, errbuf];
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:ret userInfo:@{NSLocalizedDescriptionKey: desc}];
        }
        return NO;
    }
    
    _formatContext = ctx;
    
    // 3. 探测媒体流深度信息 (这步是极其关键的 I/O 密集型操作，它会读取部分包数据来精准分析流的音视频格式、比特率等)
    ret = avformat_find_stream_info(ctx, NULL);
    if (ret < 0) {
        [self close];
        if (error) {
            NSString *desc = [NSString stringWithFormat:@"FFmpeg: 无法解析媒体流信息，错误码: %d", ret];
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:ret userInfo:@{NSLocalizedDescriptionKey: desc}];
        }
        return NO;
    }
    
    // 4. 遍历多媒体容器中的所有流 (Streams)。一个媒体文件通常包含一个视频流、一个音频流、甚至字幕流
    for (unsigned int i = 0; i < ctx->nb_streams; i++) {
        AVStream *stream = ctx->streams[i];
        AVCodecParameters *codecpar = stream->codecpar; // 提取当前流的编解码配置参数
        
        // 视频流判定：如果是视频流，且我们还没有锁定首个视频流索引
        if (codecpar->codec_type == AVMEDIA_TYPE_VIDEO && _videoStreamIndex == -1) {
            _videoStreamIndex = i;
            _videoWidth = codecpar->width;   // 物理像素宽度
            _videoHeight = codecpar->height; // 物理像素高度
            
            // 顺藤摸瓜：根据编解码配置中的 ID (例如 AV_CODEC_ID_H264) 查找系统注册的视频解码器
            const AVCodec *codec = avcodec_find_decoder(codecpar->codec_id);
            if (codec) {
                // 将 C 语言的解码器简短名称 (例如 "h264", "hevc") 封装成 NSString 传给上层
                _videoCodecName = [NSString stringWithUTF8String:codec->name];
            }
        } 
        // 音频流判定：如果是音频流，且我们还没有锁定首个音频流索引
        else if (codecpar->codec_type == AVMEDIA_TYPE_AUDIO && _audioStreamIndex == -1) {
            _audioStreamIndex = i;
            
            // 同理，查找音频解码器 (例如 "aac", "mp3")
            const AVCodec *codec = avcodec_find_decoder(codecpar->codec_id);
            if (codec) {
                _audioCodecName = [NSString stringWithUTF8String:codec->name];
            }
        }
    }
    
    // 5. 解析并计算多媒体的总时长
    // FFmpeg 内部是以时间基 (AV_TIME_BASE，即微秒) 来度量时长的，我们需要将其除以 1,000,000 转换为秒 (double)
    if (ctx->duration != AV_NOPTS_VALUE) {
        _duration = (double)ctx->duration / AV_TIME_BASE;
    }
    
    return YES;
}

- (void)close {
    // 1. 释放视频解码上下文物理资源
    if (_videoCodecContext) {
        avcodec_free_context(&_videoCodecContext);
        _videoCodecContext = NULL;
    }
    
    // 2. 释放存放图像物理帧和读取包的 C 内存
    if (_videoFrame) {
        av_frame_free(&_videoFrame);
        _videoFrame = NULL;
    }
    if (_packet) {
        av_packet_free(&_packet);
        _packet = NULL;
    }
    
    // 3. 释放像素重组 SwsContext 上下文
    if (_swsContext) {
        sws_freeContext(_swsContext);
        _swsContext = NULL;
    }

    // 内存安全保障：手动释放 FFmpeg 核心多媒体格式上下文，释放占用的 C 内存，防止严重泄露！
    if (_formatContext) {
        avformat_close_input(&_formatContext);
        _formatContext = NULL;
    }
    // 重置所有桥接属性，使当前 Bridge 回归干净的初始态
    _videoStreamIndex = -1;
    _audioStreamIndex = -1;
    _videoWidth = 0;
    _videoHeight = 0;
    _duration = 0.0;
    _videoCodecName = @"Unknown";
    _audioCodecName = @"Unknown";
}

// ==============================================================================
// MARK: - 【阶段二：视频解码与渲染核心实现】
// ==============================================================================

- (BOOL)initializeVideoDecoder:(NSError **)error {
    // 1. 防护红线：确保已经探测出有效的视频流索引
    if (_videoStreamIndex == -1) {
        if (error) {
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"未找到有效的视频流索引"}];
        }
        return NO;
    }
    
    // 2. 幂等清理：防止多次误触重复分配，引发内存堆积
    if (_videoCodecContext) {
        avcodec_free_context(&_videoCodecContext);
        _videoCodecContext = NULL;
    }
    
    AVStream *stream = _formatContext->streams[_videoStreamIndex];
    
    // 3. 顺藤摸瓜：根据容器流的 Codec ID 查找对应的系统解码器（如 h264, hevc 等）
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) {
        if (error) {
            NSString *desc = [NSString stringWithFormat:@"FFmpeg: 找不到对应编解码器 '%@'", _videoCodecName];
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:-2 userInfo:@{NSLocalizedDescriptionKey: desc}];
        }
        return NO;
    }
    
    // 4. 分配解码器上下文
    _videoCodecContext = avcodec_alloc_context3(codec);
    if (!_videoCodecContext) {
        if (error) {
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"FFmpeg: 无法分配解码器上下文"}];
        }
        return NO;
    }
    
    // 5. 参数复制：将解复用拿到的 stream 编解码物理参数拷贝至解码上下文，对齐分辨率/色彩格式
    int ret = avcodec_parameters_to_context(_videoCodecContext, stream->codecpar);
    if (ret < 0) {
        avcodec_free_context(&_videoCodecContext);
        _videoCodecContext = NULL;
        if (error) {
            char errbuf[1024];
            av_strerror(ret, errbuf, sizeof(errbuf));
            NSString *desc = [NSString stringWithFormat:@"FFmpeg: 拷贝编解码参数失败，错误: %s", errbuf];
            *error = [NSError errorWithDomain:@"JJFFmpegBridge" code:ret userInfo:@{NSLocalizedDescriptionKey: desc}];
        }
        return NO;
    }
    
    // 6. 开启硬核解码通道：打开编解码器上下文
    ret = avcodec_open2(_videoCodecContext, codec, NULL);
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
    
    // 7. 预先分配空闲帧（AVFrame）和解复用读取数据包（AVPacket）空间
    _videoFrame = av_frame_alloc();
    _packet = av_packet_alloc();
    
    return YES;
}

- (CVPixelBufferRef)decodeNextFrame {
    // 逻辑红线：保障底层 C 上下文齐全
    if (!_formatContext || !_videoCodecContext || !_videoFrame || !_packet) {
        return NULL;
    }
    
    int ret;
    // 循环从多媒体流中源源不断读取数据包
    while (av_read_frame(_formatContext, _packet) >= 0) {
        // 精准隔离：仅处理视频流包
        if (_packet->stream_index == _videoStreamIndex) {
            // 将视频包发送进解码器的解码队列
            ret = avcodec_send_packet(_videoCodecContext, _packet);
            if (ret >= 0) {
                // 尝试从解码器提取解码后的原始未压缩图像帧 (AVFrame)
                ret = avcodec_receive_frame(_videoCodecContext, _videoFrame);
                if (ret == 0) {
                    // 🎉 成功收获一帧！立即将其 YUV 像素颜色重组并写入 iOS 的 CoreVideo 缓冲区
                    CVPixelBufferRef pixelBuffer = [self convertFrameToPixelBuffer:_videoFrame];
                    av_packet_unref(_packet); // 解套内存引用
                    return pixelBuffer;      // 成功直出，所有权移交给 Swift 侧 ARC
                } else if (ret == AVERROR(EAGAIN)) {
                    // 解码器需要送入更多数据包才能吐出新帧，继续循环读取流
                } else {
                    // 解码抛错或结束
                    break;
                }
            }
        }
        // 关键防护：非视频包或读取完毕的包，必须强制 unref，否则发生可怕的物理内存爆炸！
        av_packet_unref(_packet);
    }
    return NULL;
}

- (CVPixelBufferRef)convertFrameToPixelBuffer:(AVFrame *)frame {
    int width = frame->width;
    int height = frame->height;
    
    CVPixelBufferRef pixelBuffer = NULL;
    
    // 打造 Premium 高性能渲染：设置 kCVPixelBufferIOSurfacePropertiesKey 选项
    // 这能让 CoreVideo 像素缓冲区在底层使用 iOS 显卡专用的 IOSurface 内存，支持 GPU 零内存拷贝极速直出渲染！
    NSDictionary *options = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    
    // 💥 终极修复：回滚至 iOS/macOS 平台原生百分百完美支持的通用 32 位 BGRA 格式
    // 虽然 RGBA 在 NEON 汇编色彩空间转换下有加速支持，但在 iOS 模拟器的普通的 CVPixelBufferCreate 中直接分配 32RGBA 可能会引发 -6680 (kCVReturnInvalidPixelFormat) 格式异常。
    // 我们将其安全切换回最稳健的 32BGRA 色彩格式，同时保留极其关键的 sws_getCachedContext 动态上下文缓存重构银弹，彻底消灭黑屏故障！
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
    
    // 物理锁定 CoreVideo 缓冲区基地址，供 sws_scale 执行 CPU/GPU 指令高速直出写入
    if (CVPixelBufferLockBaseAddress(pixelBuffer, 0) != kCVReturnSuccess) {
        DLog(@"❌ [JJFFmpegBridge] CVPixelBufferLockBaseAddress 锁定基地址失败");
        CFRelease(pixelBuffer);
        return NULL;
    }
    
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    
    // 💥 终极修复：引入缓存型自适应重构上下文 sws_getCachedContext，阻断首帧宽高/格式漂移引发的黑屏
    // 💥 终极修复：将像素格式改回 AV_PIX_FMT_BGRA，与上方的 kCVPixelFormatType_32BGRA 字节排布完全对齐
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
        DLog(@"❌ [JJFFmpegBridge] sws_getCachedContext 像素缩放重排上下文分配失败！宽: %d, 高: %d, 源格式: %d", width, height, frame->format);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CFRelease(pixelBuffer);
        return NULL;
    }
    
    // 将一维的 CoreVideo 像素基地址指针包装为 sws_scale 所需的四通道输出物理映射
    uint8_t *dstData[4] = { (uint8_t *)baseAddress, NULL, NULL, NULL };
    int dstLinesize[4] = { (int)bytesPerRow, 0, 0, 0 };
    
    // 执行底层的像素重排，这是一段由 CPU NEON/SIMD 汇编优化的极速高效率色彩空间转换与填充操作
    sws_scale(_swsContext,
              (const uint8_t *const *)frame->data,
              frame->linesize,
              0,
              height,
              dstData,
              dstLinesize);
    
    // 写入结束，必须成对解锁基地址，归还 CoreVideo 缓冲区的 CPU 控制权，交由 GPU 提交显示
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    return pixelBuffer;
}

@end
