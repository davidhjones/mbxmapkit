//
//  MBXOfflineMapURLGenerator.h
//  MBXMapKit
//
//  Copyright (c) 2014 Mapbox. All rights reserved.
//

@import Foundation;

@interface MBXOfflineMapURLGenerator : NSObject

- (instancetype) initWithMinLat:(CLLocationDegrees)minLat maxLat:(CLLocationDegrees)maxLat minLon:(CLLocationDegrees)minLon maxLon:(CLLocationDegrees)maxLon minimumZ:(NSInteger)minimumZ maximumZ:(NSInteger)maximumZ;

@property (readonly) NSInteger urlCount;

- (NSString *) urlForIndex:(NSInteger)index mapID:(NSString*)mapID imageQualityExtension:(NSString*)imageQualityExtension;

@end
