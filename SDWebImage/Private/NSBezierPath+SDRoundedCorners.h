/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageCompat.h"

#if SD_MAC

#import "UIImage+Transform.h"

@interface NSBezierPath (SDRoundedCorners)

/**
 Convenience way to create a bezier path with the specify rounding corners on macOS. Same as the one on `UIBezierPath`.
 在macOS上使用指定圆角创建bezier路径的方便方法。和“UIBezierPath”中的一样。
 */
+ (nonnull instancetype)sd_bezierPathWithRoundedRect:(NSRect)rect byRoundingCorners:(SDRectCorner)corners cornerRadius:(CGFloat)cornerRadius;

@end

#endif
