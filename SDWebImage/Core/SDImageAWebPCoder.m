/*
* This file is part of the SDWebImage package.
* (c) Olivier Poitrey <rs@dailymotion.com>
*
* For the full copyright and license information, please view the LICENSE
* file that was distributed with this source code.
*/

#import "SDImageAWebPCoder.h"
#import "SDImageIOAnimatedCoderInternal.h"

// These constants are available from iOS 14+ and Xcode 12. This raw value is used for toolchain and firmware compatibility
// 这些常量在iOS 14+和Xcode 12中可用。这个原始值用于工具链和固件兼容性
static NSString * kSDCGImagePropertyWebPDictionary = @"{WebP}";
static NSString * kSDCGImagePropertyWebPLoopCount = @"LoopCount";
static NSString * kSDCGImagePropertyWebPDelayTime = @"DelayTime";
static NSString * kSDCGImagePropertyWebPUnclampedDelayTime = @"UnclampedDelayTime";

@implementation SDImageAWebPCoder

+ (void)initialize {
#if __IPHONE_14_0 || __TVOS_14_0 || __MAC_11_0 || __WATCHOS_7_0
    // Xcode 12
    if (@available(iOS 14, tvOS 14, macOS 11, watchOS 7, *)) {
        // Use SDK instead of raw value
        kSDCGImagePropertyWebPDictionary = (__bridge NSString *)kCGImagePropertyWebPDictionary;
        kSDCGImagePropertyWebPLoopCount = (__bridge NSString *)kCGImagePropertyWebPLoopCount;
        kSDCGImagePropertyWebPDelayTime = (__bridge NSString *)kCGImagePropertyWebPDelayTime;
        kSDCGImagePropertyWebPUnclampedDelayTime = (__bridge NSString *)kCGImagePropertyWebPUnclampedDelayTime;
    }
#endif
}
/// 创建单例
+ (instancetype)sharedCoder {
    static SDImageAWebPCoder *coder;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coder = [[SDImageAWebPCoder alloc] init];
    });
    return coder;
}

#pragma mark - SDImageCoder
/// 是否支持从数据解码
- (BOOL)canDecodeFromData:(nullable NSData *)data {
    switch ([NSData sd_imageFormatForImageData:data]) {
        case SDImageFormatWebP:
            // Check WebP decoding compatibility
            return [self.class canDecodeFromFormat:SDImageFormatWebP];
        default:
            return NO;
    }
}
/// 是否支持从数据增量解码
- (BOOL)canIncrementalDecodeFromData:(NSData *)data {
    return [self canDecodeFromData:data];
}
/// 是否支持编码格式
- (BOOL)canEncodeToFormat:(SDImageFormat)format {
    switch (format) {
        case SDImageFormatWebP:
            // Check WebP encoding compatibility
            return [self.class canEncodeToFormat:SDImageFormatWebP];
        default:
            return NO;
    }
}

#pragma mark - Subclass Override
/// 图片格式
+ (SDImageFormat)imageFormat {
    return SDImageFormatWebP;
}
/// 图片格式唯一标识
+ (NSString *)imageUTType {
    return (__bridge NSString *)kSDUTTypeWebP;
}

+ (NSString *)dictionaryProperty {
    return kSDCGImagePropertyWebPDictionary;
}

+ (NSString *)unclampedDelayTimeProperty {
    return kSDCGImagePropertyWebPUnclampedDelayTime;
}

+ (NSString *)delayTimeProperty {
    return kSDCGImagePropertyWebPDelayTime;
}

+ (NSString *)loopCountProperty {
    return kSDCGImagePropertyWebPLoopCount;
}

+ (NSUInteger)defaultLoopCount {
    return 0;
}

@end
