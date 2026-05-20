//
//  JJFFmpegCore.m
//  JJPlayerKit
//
//  Created by Antigravity.
//

#import "JJFFmpegCore.h"

// 核心：在 C/ObjC 层级直接引入底层的 C 头文件，完美兼容任何 Clang Module / Header Search Path 解析
#import <ffmpegkit/FFmpegKitConfig.h>
#import <libavformat/avformat.h>
#import <libavcodec/avcodec.h>
#import <libavutil/avutil.h>

@implementation JJFFmpegBridge {
    // 原始的 FFmpeg C 语言多媒体上下文指针。
    // 在 C 语言世界中，这些指针不受 iOS ARC 自动引用计数管理，必须手动分配与释放，否则会造成致命的内存泄漏！
    AVFormatContext *_formatContext;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _formatContext = NULL;
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
    // 析构红线：当 Objective-C 桥接对象被销毁时，必须强制触发 close 释放全部未托管的 C 指针内存！
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

@end
