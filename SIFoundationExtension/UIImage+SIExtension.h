//
//  UIImage+SIExtension.h
//  SIKit
//
//  Created by Matias Pequeno on 9/13/12.
//  Copyright (c) 2012 Silicon Illusions, Inc. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface UIImage (SIExtension)

- (UIImage *)scaledImage:(CGSize)size;
- (UIImage *)croppedAndResizedImage:(CGSize)size;
- (UIImage *)scaledAndRotatedImage;

@end
