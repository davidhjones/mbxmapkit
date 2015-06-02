//
//  MBXOfflineMapDownloadIterator.h
//  MBXMapKit
//
//  Copyright (c) 2015 Mapbox. All rights reserved.
//

@import Foundation;

@class MBXOfflineMapURLGenerator;

@interface MBXOfflineMapDownloadIterator : NSObject

- (instancetype)initWithURLs:(NSArray *)urls generator:(MBXOfflineMapURLGenerator *)generator mapID:(NSString *)mapID imageQualityExtension:(NSString *)imageQualityExtension;

- (BOOL)hasNext;
- (NSString *)nextIsTile:(BOOL *)isTile;

- (instancetype)init UNAVAILABLE_ATTRIBUTE;

@end
