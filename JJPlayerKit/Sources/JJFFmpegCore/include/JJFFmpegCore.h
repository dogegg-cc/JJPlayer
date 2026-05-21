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

// 打开多媒体输入源并探测流信息
- (BOOL)openURL:(NSString *)url error:(NSError **)error;

// 关闭输入源释放核心 C 对象资源
- (void)close;

// 【阶段二：视频解码与渲染】
// 初始化并打开视频解码器上下文
- (BOOL)initializeVideoDecoder:(NSError **)error;

// 解码并提取下一帧视频图像，返回 iOS 原生的 CoreVideo 像素缓冲区 CVPixelBufferRef
- (CVPixelBufferRef)decodeNextFrame;

@end

