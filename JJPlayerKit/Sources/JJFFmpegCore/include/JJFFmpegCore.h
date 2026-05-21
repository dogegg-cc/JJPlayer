//
//  JJFFmpegCore.h
//  JJPlayerKit
//
//  Created by Antigravity.
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

@interface JJFFmpegBridge : NSObject

// 媒体文件/流的核心元数据属性
@property (nonatomic, readonly) double duration;
@property (nonatomic, readonly) int videoWidth;
@property (nonatomic, readonly) int videoHeight;
@property (nonatomic, readonly, copy) NSString *videoCodecName;
@property (nonatomic, readonly, copy) NSString *audioCodecName;
@property (nonatomic, readonly) int videoStreamIndex;
@property (nonatomic, readonly) int audioStreamIndex;

// 双通道统一分发闭包回调
@property (nonatomic, copy) void (^onVideoFrameDecoded)(CVPixelBufferRef pixelBuffer);
@property (nonatomic, copy) void (^onAudioFrameDecoded)(NSData *pcmData);

// 打开多媒体输入源并探测流信息
- (BOOL)openURL:(NSString *)url error:(NSError **)error;

// 关闭输入源释放核心 C 对象资源
- (void)close;

// 【旧接口已废弃】请使用一站式 initializeDecoders: 与 decodeAndDispatch
- (BOOL)initializeVideoDecoder:(NSError **)error __attribute__((deprecated("请使用一站式 initializeDecoders:")));
- (CVPixelBufferRef)decodeNextFrame __attribute__((deprecated("请使用一站式 decodeAndDispatch")));

// 【阶段三：一站式音视频双路解码分发】
// 同时初始化并打开视频与音频解码器上下文，配置 libswresample 重采样
- (BOOL)initializeDecoders:(NSError **)error;

// 一站式读取、解码并分发单个数据包
// 返回值：0 代表成功处理视频帧/音频帧；1 代表处理了无关数据包；-1 代表流读取结束(EOF)或出错
- (int)decodeAndDispatch;

@end

