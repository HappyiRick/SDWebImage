/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDImageCoderHelper.h"
#import "SDImageFrame.h"
#import "NSImage+Compatibility.h"
#import "NSData+ImageContentType.h"
#import "SDAnimatedImageRep.h"
#import "UIImage+ForceDecode.h"
#import "SDAssociatedObject.h"
#import "UIImage+Metadata.h"
#import "SDInternalMacros.h"
#import <Accelerate/Accelerate.h>

static inline size_t SDByteAlign(size_t size, size_t alignment) {
    return ((size + (alignment - 1)) / alignment) * alignment;
}

static const size_t kBytesPerPixel = 4;
static const size_t kBitsPerComponent = 8;

static const CGFloat kBytesPerMB = 1024.0f * 1024.0f;
/*
 * Defines the maximum size in MB of the decoded image when the flag `SDWebImageScaleDownLargeImages` is set
 * Suggested value for iPad1 and iPhone 3GS: 60.
 * Suggested value for iPad2 and iPhone 4: 120.
 * Suggested value for iPhone 3G and iPod 2 and earlier devices: 30.
 */
#if SD_MAC
static CGFloat kDestImageLimitBytes = 90.f * kBytesPerMB;
#elif SD_UIKIT
static CGFloat kDestImageLimitBytes = 60.f * kBytesPerMB;
#elif SD_WATCH
static CGFloat kDestImageLimitBytes = 30.f * kBytesPerMB;
#endif

static const CGFloat kDestSeemOverlap = 2.0f;   // the numbers of pixels to overlap the seems where tiles meet.

@implementation SDImageCoderHelper
/// 将元素为SDImageFrame对象的数组转换为动图
+ (UIImage *)animatedImageWithFrames:(NSArray<SDImageFrame *> *)frames {
    /// 如果数组中没有元素就不是动图, 则返回nil
    NSUInteger frameCount = frames.count;
    if (frameCount == 0) {
        return nil;
    }
    /// 生成临时变量保存动图
    UIImage *animatedImage;
#if SD_UIKIT || SD_WATCH
    /// 生成一个元素为非负整数, 长度为动图帧数的数组, 保存每一帧的展示时间
    NSUInteger durations[frameCount];
    for (size_t i = 0; i < frameCount; i++) {
        /// 遍历传入的SDImageFrame对象数组, 获取每一帧的展示时间
        durations[i] = frames[i].duration * 1000;
    }
    /// 计算所有帧展示时长的最大公约数
    NSUInteger const gcd = gcdArray(frameCount, durations);
    /// 生成临时变量保存总时长
    __block NSUInteger totalDuration = 0;
    /// 生成临时变量保存动图数组
    NSMutableArray<UIImage *> *animatedImages = [NSMutableArray arrayWithCapacity:frameCount];
    /// 遍历传入的SDImageFrame对象数组
    [frames enumerateObjectsUsingBlock:^(SDImageFrame * _Nonnull frame, NSUInteger idx, BOOL * _Nonnull stop) {
        /// 获取SDImageFrame对象保存的每一帧的图像
        UIImage *image = frame.image;
        /// 获取SDImageFrame对象保存的每一帧的展示时间
        NSUInteger duration = frame.duration * 1000;
        /// 增加总时长
        totalDuration += duration;
        /// 生成临时变量保存重复次数
        NSUInteger repeatCount;
        /// 如果计算出的最大公约数大于0，每一帧的重复次数就是展示时间除以最大公约数
        /// 否则每一帧只重复一次，也就说不重复
        if (gcd) {
            repeatCount = duration / gcd;
        } else {
            repeatCount = 1;
        }
        /// 根据重复次数向动图数组中重复添加同一帧
        for (size_t i = 0; i < repeatCount; ++i) {
            [animatedImages addObject:image];
        }
    }];
    /// 利用生成的动图数组和时长生成动图对象
    animatedImage = [UIImage animatedImageWithImages:animatedImages duration:totalDuration / 1000.f];
#else
    NSMutableData *imageData = [NSMutableData data];
    CFStringRef imageUTType = [NSData sd_UTTypeFromImageFormat:SDImageFormatGIF];
    // Create an image destination. GIF does not support EXIF image orientation
    CGImageDestinationRef imageDestination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)imageData, imageUTType, frameCount, NULL);
    if (!imageDestination) {
        // Handle failure.
        return nil;
    }
    
    for (size_t i = 0; i < frameCount; i++) {
        @autoreleasepool {
            SDImageFrame *frame = frames[i];
            NSTimeInterval frameDuration = frame.duration;
            CGImageRef frameImageRef = frame.image.CGImage;
            NSDictionary *frameProperties = @{(__bridge NSString *)kCGImagePropertyGIFDictionary : @{(__bridge NSString *)kCGImagePropertyGIFDelayTime : @(frameDuration)}};
            CGImageDestinationAddImage(imageDestination, frameImageRef, (__bridge CFDictionaryRef)frameProperties);
        }
    }
    // Finalize the destination.
    if (CGImageDestinationFinalize(imageDestination) == NO) {
        // Handle failure.
        CFRelease(imageDestination);
        return nil;
    }
    CFRelease(imageDestination);
    CGFloat scale = MAX(frames.firstObject.image.scale, 1);
    
    SDAnimatedImageRep *imageRep = [[SDAnimatedImageRep alloc] initWithData:imageData];
    NSSize size = NSMakeSize(imageRep.pixelsWide / scale, imageRep.pixelsHigh / scale);
    imageRep.size = size;
    animatedImage = [[NSImage alloc] initWithSize:size];
    [animatedImage addRepresentation:imageRep];
#endif
    
    return animatedImage;
}

+ (NSArray<SDImageFrame *> *)framesFromAnimatedImage:(UIImage *)animatedImage {
    /// 如果没传参就不继续执行了, 直接返回空
    if (!animatedImage) {
        return nil;
    }
    /// 生成临时变量保存SDImageFrame对象和数量
    NSMutableArray<SDImageFrame *> *frames = [NSMutableArray array];
    NSUInteger frameCount = 0;
    
#if SD_UIKIT || SD_WATCH
    /// 获取动图的帧图片数组
    NSArray<UIImage *> *animatedImages = animatedImage.images;
    /// 获取动图的帧图片数量
    frameCount = animatedImages.count;
    /// 如果帧图片的数量为0就不继续执行了, 直接返回空
    if (frameCount == 0) {
        return nil;
    }
    /// 计算每一帧的平均展示时间
    NSTimeInterval avgDuration = animatedImage.duration / frameCount;
    /// 如果这个动图没有展示时间就默认每一帧展示100ms
    if (avgDuration == 0) {
        avgDuration = 0.1; // if it's a animated image but no duration, set it to default 100ms (this do not have that 10ms limit like GIF or WebP to allow custom coder provide the limit)
    }
    /// 记录一帧图片的重复次数
    __block NSUInteger repeatCount = 1;
    /// 记录当前遍历到的图片之前的图片
    __block UIImage *previousImage = animatedImages.firstObject;
    [animatedImages enumerateObjectsUsingBlock:^(UIImage * _Nonnull image, NSUInteger idx, BOOL * _Nonnull stop) {
        // ignore first
        // 第一张图片不处理
        if (idx == 0) {
            return;
        }
        if ([image isEqual:previousImage]) {
            /// 如果这一帧的图片和之前一帧图片相同就添加重复次数
            repeatCount++;
        } else {
            /// 如果两帧图片不相同, 就生成SDImageFrame对象
            SDImageFrame *frame = [SDImageFrame frameWithImage:previousImage duration:avgDuration * repeatCount];
            /// 数组记录对象
            [frames addObject:frame];
            /// 重复次数设置为1次
            repeatCount = 1;
        }
        previousImage = image;
    }];
    // last one
    /// 如果是最后一张图片就直接添加
    SDImageFrame *frame = [SDImageFrame frameWithImage:previousImage duration:avgDuration * repeatCount];
    [frames addObject:frame];
    
#else
    
    NSRect imageRect = NSMakeRect(0, 0, animatedImage.size.width, animatedImage.size.height);
    NSImageRep *imageRep = [animatedImage bestRepresentationForRect:imageRect context:nil hints:nil];
    NSBitmapImageRep *bitmapImageRep;
    if ([imageRep isKindOfClass:[NSBitmapImageRep class]]) {
        bitmapImageRep = (NSBitmapImageRep *)imageRep;
    }
    if (!bitmapImageRep) {
        return nil;
    }
    frameCount = [[bitmapImageRep valueForProperty:NSImageFrameCount] unsignedIntegerValue];
    if (frameCount == 0) {
        return nil;
    }
    CGFloat scale = animatedImage.scale;
    
    for (size_t i = 0; i < frameCount; i++) {
        @autoreleasepool {
            // NSBitmapImageRep need to manually change frame. "Good taste" API
            [bitmapImageRep setProperty:NSImageCurrentFrame withValue:@(i)];
            NSTimeInterval frameDuration = [[bitmapImageRep valueForProperty:NSImageCurrentFrameDuration] doubleValue];
            NSImage *frameImage = [[NSImage alloc] initWithCGImage:bitmapImageRep.CGImage scale:scale orientation:kCGImagePropertyOrientationUp];
            SDImageFrame *frame = [SDImageFrame frameWithImage:frameImage duration:frameDuration];
            [frames addObject:frame];
        }
    }
#endif
    
    return frames;
}

/// 获取色彩空间
+ (CGColorSpaceRef)colorSpaceGetDeviceRGB {
#if SD_MAC
    CGColorSpaceRef screenColorSpace = NSScreen.mainScreen.colorSpace.CGColorSpace;
    if (screenColorSpace) {
        return screenColorSpace;
    }
#endif
    static CGColorSpaceRef colorSpace;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
#if SD_UIKIT
        if (@available(iOS 9.0, tvOS 9.0, *)) {
            colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        } else {
            colorSpace = CGColorSpaceCreateDeviceRGB();
        }
#else
        colorSpace = CGColorSpaceCreateDeviceRGB();
#endif
    });
    return colorSpace;
}

/// 判断CGImage是否有alpha通道
+ (BOOL)CGImageContainsAlpha:(CGImageRef)cgImage {
    if (!cgImage) {
        return NO;
    }
    CGImageAlphaInfo alphaInfo = CGImageGetAlphaInfo(cgImage);
    BOOL hasAlpha = !(alphaInfo == kCGImageAlphaNone ||
                      alphaInfo == kCGImageAlphaNoneSkipFirst ||
                      alphaInfo == kCGImageAlphaNoneSkipLast);
    return hasAlpha;
}

+ (CGImageRef)CGImageCreateDecoded:(CGImageRef)cgImage {
    return [self CGImageCreateDecoded:cgImage orientation:kCGImagePropertyOrientationUp];
}

+ (CGImageRef)CGImageCreateDecoded:(CGImageRef)cgImage orientation:(CGImagePropertyOrientation)orientation {
    if (!cgImage) {
        return NULL;
    }
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0) return NULL;
    size_t newWidth;
    size_t newHeight;
    switch (orientation) {
        case kCGImagePropertyOrientationLeft:
        case kCGImagePropertyOrientationLeftMirrored:
        case kCGImagePropertyOrientationRight:
        case kCGImagePropertyOrientationRightMirrored: {
            // These orientation should swap width & height
            newWidth = height;
            newHeight = width;
        }
            break;
        default: {
            newWidth = width;
            newHeight = height;
        }
            break;
    }
    
    BOOL hasAlpha = [self CGImageContainsAlpha:cgImage];
    // iOS prefer BGRA8888 (premultiplied) or BGRX8888 bitmapInfo for screen rendering, which is same as `UIGraphicsBeginImageContext()` or `- [CALayer drawInContext:]`
    // Though you can use any supported bitmapInfo (see: https://developer.apple.com/library/content/documentation/GraphicsImaging/Conceptual/drawingwithquartz2d/dq_context/dq_context.html#//apple_ref/doc/uid/TP30001066-CH203-BCIBHHBB ) and let Core Graphics reorder it when you call `CGContextDrawImage`
    // But since our build-in coders use this bitmapInfo, this can have a little performance benefit
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Host;
    bitmapInfo |= hasAlpha ? kCGImageAlphaPremultipliedFirst : kCGImageAlphaNoneSkipFirst;
    CGContextRef context = CGBitmapContextCreate(NULL, newWidth, newHeight, 8, 0, [self colorSpaceGetDeviceRGB], bitmapInfo);
    if (!context) {
        return NULL;
    }
    
    // Apply transform
    CGAffineTransform transform = SDCGContextTransformFromOrientation(orientation, CGSizeMake(newWidth, newHeight));
    CGContextConcatCTM(context, transform);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage); // The rect is bounding box of CGImage, don't swap width & height
    CGImageRef newImageRef = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    
    return newImageRef;
}

+ (CGImageRef)CGImageCreateScaled:(CGImageRef)cgImage size:(CGSize)size {
    if (!cgImage) {
        return NULL;
    }
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == size.width && height == size.height) {
        CGImageRetain(cgImage);
        return cgImage;
    }
    
    __block vImage_Buffer input_buffer = {}, output_buffer = {};
    @onExit {
        if (input_buffer.data) free(input_buffer.data);
        if (output_buffer.data) free(output_buffer.data);
    };
    BOOL hasAlpha = [self CGImageContainsAlpha:cgImage];
    // iOS display alpha info (BGRA8888/BGRX8888)
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Host;
    bitmapInfo |= hasAlpha ? kCGImageAlphaPremultipliedFirst : kCGImageAlphaNoneSkipFirst;
    vImage_CGImageFormat format = (vImage_CGImageFormat) {
        .bitsPerComponent = 8,
        .bitsPerPixel = 32,
        .colorSpace = NULL,
        .bitmapInfo = bitmapInfo,
        .version = 0,
        .decode = NULL,
        .renderingIntent = kCGRenderingIntentDefault,
    };
    
    vImage_Error a_ret = vImageBuffer_InitWithCGImage(&input_buffer, &format, NULL, cgImage, kvImageNoFlags);
    if (a_ret != kvImageNoError) return NULL;
    output_buffer.width = MAX(size.width, 0);
    output_buffer.height = MAX(size.height, 0);
    output_buffer.rowBytes = SDByteAlign(output_buffer.width * 4, 64);
    output_buffer.data = malloc(output_buffer.rowBytes * output_buffer.height);
    if (!output_buffer.data) return NULL;
    
    vImage_Error ret = vImageScale_ARGB8888(&input_buffer, &output_buffer, NULL, kvImageHighQualityResampling);
    if (ret != kvImageNoError) return NULL;
    
    CGImageRef outputImage = vImageCreateCGImageFromBuffer(&output_buffer, &format, NULL, NULL, kvImageNoFlags, &ret);
    if (ret != kvImageNoError) {
        CGImageRelease(outputImage);
        return NULL;
    }
    
    return outputImage;
}

+ (UIImage *)decodedImageWithImage:(UIImage *)image {
    if (![self shouldDecodeImage:image]) {
        return image;
    }
    
    CGImageRef imageRef = [self CGImageCreateDecoded:image.CGImage];
    if (!imageRef) {
        return image;
    }
#if SD_MAC
    UIImage *decodedImage = [[UIImage alloc] initWithCGImage:imageRef scale:image.scale orientation:kCGImagePropertyOrientationUp];
#else
    UIImage *decodedImage = [[UIImage alloc] initWithCGImage:imageRef scale:image.scale orientation:image.imageOrientation];
#endif
    CGImageRelease(imageRef);
    SDImageCopyAssociatedObject(image, decodedImage);
    decodedImage.sd_isDecoded = YES;
    return decodedImage;
}

+ (UIImage *)decodedAndScaledDownImageWithImage:(UIImage *)image limitBytes:(NSUInteger)bytes {
    if (![self shouldDecodeImage:image]) {
        return image;
    }
    
    if (![self shouldScaleDownImage:image limitBytes:bytes]) {
        return [self decodedImageWithImage:image];
    }
    
    CGFloat destTotalPixels;
    CGFloat tileTotalPixels;
    if (bytes == 0) {
        bytes = kDestImageLimitBytes;
    }
    destTotalPixels = bytes / kBytesPerPixel;
    tileTotalPixels = destTotalPixels / 3;
    CGContextRef destContext;
    
    // autorelease the bitmap context and all vars to help system to free memory when there are memory warning.
    // on iOS7, do not forget to call [[SDImageCache sharedImageCache] clearMemory];
    @autoreleasepool {
        CGImageRef sourceImageRef = image.CGImage;
        
        CGSize sourceResolution = CGSizeZero;
        sourceResolution.width = CGImageGetWidth(sourceImageRef);
        sourceResolution.height = CGImageGetHeight(sourceImageRef);
        CGFloat sourceTotalPixels = sourceResolution.width * sourceResolution.height;
        // Determine the scale ratio to apply to the input image
        // that results in an output image of the defined size.
        // see kDestImageSizeMB, and how it relates to destTotalPixels.
        CGFloat imageScale = sqrt(destTotalPixels / sourceTotalPixels);
        CGSize destResolution = CGSizeZero;
        destResolution.width = MAX(1, (int)(sourceResolution.width * imageScale));
        destResolution.height = MAX(1, (int)(sourceResolution.height * imageScale));
        
        // device color space
        CGColorSpaceRef colorspaceRef = [self colorSpaceGetDeviceRGB];
        BOOL hasAlpha = [self CGImageContainsAlpha:sourceImageRef];
        // iOS display alpha info (BGRA8888/BGRX8888)
        CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Host;
        bitmapInfo |= hasAlpha ? kCGImageAlphaPremultipliedFirst : kCGImageAlphaNoneSkipFirst;
        
        // kCGImageAlphaNone is not supported in CGBitmapContextCreate.
        // Since the original image here has no alpha info, use kCGImageAlphaNoneSkipFirst
        // to create bitmap graphics contexts without alpha info.
        destContext = CGBitmapContextCreate(NULL,
                                            destResolution.width,
                                            destResolution.height,
                                            kBitsPerComponent,
                                            0,
                                            colorspaceRef,
                                            bitmapInfo);
        
        if (destContext == NULL) {
            return image;
        }
        CGContextSetInterpolationQuality(destContext, kCGInterpolationHigh);
        
        // Now define the size of the rectangle to be used for the
        // incremental bits from the input image to the output image.
        // we use a source tile width equal to the width of the source
        // image due to the way that iOS retrieves image data from disk.
        // iOS must decode an image from disk in full width 'bands', even
        // if current graphics context is clipped to a subrect within that
        // band. Therefore we fully utilize all of the pixel data that results
        // from a decoding operation by anchoring our tile size to the full
        // width of the input image.
        CGRect sourceTile = CGRectZero;
        sourceTile.size.width = sourceResolution.width;
        // The source tile height is dynamic. Since we specified the size
        // of the source tile in MB, see how many rows of pixels high it
        // can be given the input image width.
        sourceTile.size.height = MAX(1, (int)(tileTotalPixels / sourceTile.size.width));
        sourceTile.origin.x = 0.0f;
        // The output tile is the same proportions as the input tile, but
        // scaled to image scale.
        CGRect destTile;
        destTile.size.width = destResolution.width;
        destTile.size.height = sourceTile.size.height * imageScale;
        destTile.origin.x = 0.0f;
        // The source seem overlap is proportionate to the destination seem overlap.
        // this is the amount of pixels to overlap each tile as we assemble the output image.
        float sourceSeemOverlap = (int)((kDestSeemOverlap/destResolution.height)*sourceResolution.height);
        CGImageRef sourceTileImageRef;
        // calculate the number of read/write operations required to assemble the
        // output image.
        int iterations = (int)( sourceResolution.height / sourceTile.size.height );
        // If tile height doesn't divide the image height evenly, add another iteration
        // to account for the remaining pixels.
        int remainder = (int)sourceResolution.height % (int)sourceTile.size.height;
        if(remainder) {
            iterations++;
        }
        // Add seem overlaps to the tiles, but save the original tile height for y coordinate calculations.
        float sourceTileHeightMinusOverlap = sourceTile.size.height;
        sourceTile.size.height += sourceSeemOverlap;
        destTile.size.height += kDestSeemOverlap;
        for( int y = 0; y < iterations; ++y ) {
            @autoreleasepool {
                sourceTile.origin.y = y * sourceTileHeightMinusOverlap + sourceSeemOverlap;
                destTile.origin.y = destResolution.height - (( y + 1 ) * sourceTileHeightMinusOverlap * imageScale + kDestSeemOverlap);
                sourceTileImageRef = CGImageCreateWithImageInRect( sourceImageRef, sourceTile );
                if( y == iterations - 1 && remainder ) {
                    float dify = destTile.size.height;
                    destTile.size.height = CGImageGetHeight( sourceTileImageRef ) * imageScale;
                    dify -= destTile.size.height;
                    destTile.origin.y += dify;
                }
                CGContextDrawImage( destContext, destTile, sourceTileImageRef );
                CGImageRelease( sourceTileImageRef );
            }
        }
        
        CGImageRef destImageRef = CGBitmapContextCreateImage(destContext);
        CGContextRelease(destContext);
        if (destImageRef == NULL) {
            return image;
        }
#if SD_MAC
        UIImage *destImage = [[UIImage alloc] initWithCGImage:destImageRef scale:image.scale orientation:kCGImagePropertyOrientationUp];
#else
        UIImage *destImage = [[UIImage alloc] initWithCGImage:destImageRef scale:image.scale orientation:image.imageOrientation];
#endif
        CGImageRelease(destImageRef);
        if (destImage == nil) {
            return image;
        }
        SDImageCopyAssociatedObject(image, destImage);
        destImage.sd_isDecoded = YES;
        return destImage;
    }
}

+ (NSUInteger)defaultScaleDownLimitBytes {
    return kDestImageLimitBytes;
}

+ (void)setDefaultScaleDownLimitBytes:(NSUInteger)defaultScaleDownLimitBytes {
    if (defaultScaleDownLimitBytes < kBytesPerPixel) {
        return;
    }
    kDestImageLimitBytes = defaultScaleDownLimitBytes;
}

#if SD_UIKIT || SD_WATCH
// Convert an EXIF image orientation to an iOS one.
+ (UIImageOrientation)imageOrientationFromEXIFOrientation:(CGImagePropertyOrientation)exifOrientation {
    UIImageOrientation imageOrientation = UIImageOrientationUp;
    switch (exifOrientation) {
        case kCGImagePropertyOrientationUp:
            imageOrientation = UIImageOrientationUp;
            break;
        case kCGImagePropertyOrientationDown:
            imageOrientation = UIImageOrientationDown;
            break;
        case kCGImagePropertyOrientationLeft:
            imageOrientation = UIImageOrientationLeft;
            break;
        case kCGImagePropertyOrientationRight:
            imageOrientation = UIImageOrientationRight;
            break;
        case kCGImagePropertyOrientationUpMirrored:
            imageOrientation = UIImageOrientationUpMirrored;
            break;
        case kCGImagePropertyOrientationDownMirrored:
            imageOrientation = UIImageOrientationDownMirrored;
            break;
        case kCGImagePropertyOrientationLeftMirrored:
            imageOrientation = UIImageOrientationLeftMirrored;
            break;
        case kCGImagePropertyOrientationRightMirrored:
            imageOrientation = UIImageOrientationRightMirrored;
            break;
        default:
            break;
    }
    return imageOrientation;
}

// Convert an iOS orientation to an EXIF image orientation.
+ (CGImagePropertyOrientation)exifOrientationFromImageOrientation:(UIImageOrientation)imageOrientation {
    CGImagePropertyOrientation exifOrientation = kCGImagePropertyOrientationUp;
    switch (imageOrientation) {
        case UIImageOrientationUp:
            exifOrientation = kCGImagePropertyOrientationUp;
            break;
        case UIImageOrientationDown:
            exifOrientation = kCGImagePropertyOrientationDown;
            break;
        case UIImageOrientationLeft:
            exifOrientation = kCGImagePropertyOrientationLeft;
            break;
        case UIImageOrientationRight:
            exifOrientation = kCGImagePropertyOrientationRight;
            break;
        case UIImageOrientationUpMirrored:
            exifOrientation = kCGImagePropertyOrientationUpMirrored;
            break;
        case UIImageOrientationDownMirrored:
            exifOrientation = kCGImagePropertyOrientationDownMirrored;
            break;
        case UIImageOrientationLeftMirrored:
            exifOrientation = kCGImagePropertyOrientationLeftMirrored;
            break;
        case UIImageOrientationRightMirrored:
            exifOrientation = kCGImagePropertyOrientationRightMirrored;
            break;
        default:
            break;
    }
    return exifOrientation;
}
#endif

#pragma mark - Helper Function
+ (BOOL)shouldDecodeImage:(nullable UIImage *)image {
    // Prevent "CGBitmapContextCreateImage: invalid context 0x0" error
    if (image == nil) {
        return NO;
    }
    // Avoid extra decode
    if (image.sd_isDecoded) {
        return NO;
    }
    // do not decode animated images
    if (image.sd_isAnimated) {
        return NO;
    }
    // do not decode vector images
    if (image.sd_isVector) {
        return NO;
    }
    
    return YES;
}

+ (BOOL)shouldScaleDownImage:(nonnull UIImage *)image limitBytes:(NSUInteger)bytes {
    BOOL shouldScaleDown = YES;
    
    CGImageRef sourceImageRef = image.CGImage;
    CGSize sourceResolution = CGSizeZero;
    sourceResolution.width = CGImageGetWidth(sourceImageRef);
    sourceResolution.height = CGImageGetHeight(sourceImageRef);
    float sourceTotalPixels = sourceResolution.width * sourceResolution.height;
    if (sourceTotalPixels <= 0) {
        return NO;
    }
    CGFloat destTotalPixels;
    if (bytes == 0) {
        bytes = [self defaultScaleDownLimitBytes];
    }
    bytes = MAX(bytes, kBytesPerPixel);
    destTotalPixels = bytes / kBytesPerPixel;
    float imageScale = destTotalPixels / sourceTotalPixels;
    if (imageScale < 1) {
        shouldScaleDown = YES;
    } else {
        shouldScaleDown = NO;
    }
    
    return shouldScaleDown;
}

static inline CGAffineTransform SDCGContextTransformFromOrientation(CGImagePropertyOrientation orientation, CGSize size) {
    // Inspiration from @libfeihu
    // We need to calculate the proper transformation to make the image upright.
    // We do it in 2 steps: Rotate if Left/Right/Down, and then flip if Mirrored.
    CGAffineTransform transform = CGAffineTransformIdentity;
    
    switch (orientation) {
        case kCGImagePropertyOrientationDown:
        case kCGImagePropertyOrientationDownMirrored:
            transform = CGAffineTransformTranslate(transform, size.width, size.height);
            transform = CGAffineTransformRotate(transform, M_PI);
            break;
            
        case kCGImagePropertyOrientationLeft:
        case kCGImagePropertyOrientationLeftMirrored:
            transform = CGAffineTransformTranslate(transform, size.width, 0);
            transform = CGAffineTransformRotate(transform, M_PI_2);
            break;
            
        case kCGImagePropertyOrientationRight:
        case kCGImagePropertyOrientationRightMirrored:
            transform = CGAffineTransformTranslate(transform, 0, size.height);
            transform = CGAffineTransformRotate(transform, -M_PI_2);
            break;
        case kCGImagePropertyOrientationUp:
        case kCGImagePropertyOrientationUpMirrored:
            break;
    }
    
    switch (orientation) {
        case kCGImagePropertyOrientationUpMirrored:
        case kCGImagePropertyOrientationDownMirrored:
            transform = CGAffineTransformTranslate(transform, size.width, 0);
            transform = CGAffineTransformScale(transform, -1, 1);
            break;
            
        case kCGImagePropertyOrientationLeftMirrored:
        case kCGImagePropertyOrientationRightMirrored:
            transform = CGAffineTransformTranslate(transform, size.height, 0);
            transform = CGAffineTransformScale(transform, -1, 1);
            break;
        case kCGImagePropertyOrientationUp:
        case kCGImagePropertyOrientationDown:
        case kCGImagePropertyOrientationLeft:
        case kCGImagePropertyOrientationRight:
            break;
    }
    
    return transform;
}

#if SD_UIKIT || SD_WATCH
/// 计算两个整数a和b的最大公约数
static NSUInteger gcd(NSUInteger a, NSUInteger b) {
    NSUInteger c;
    while (a != 0) {
        c = a;
        a = b % a;
        b = c;
    }
    return b;
}

/// 这个函数是计算一个整数数组的最大公约数
static NSUInteger gcdArray(size_t const count, NSUInteger const * const values) {
    if (count == 0) {
        return 0;
    }
    NSUInteger result = values[0];
    for (size_t i = 1; i < count; ++i) {
        result = gcd(values[i], result);
    }
    return result;
}
#endif

@end
