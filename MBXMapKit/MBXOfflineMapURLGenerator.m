//
//  MBXOfflineMapURLGenerator.h
//  MBXMapKit
//
//  Copyright (c) 2014 Mapbox. All rights reserved.
//

#import "MBXMapKit.h"

#import "MBXOfflineMapURLGenerator.h"

typedef struct {
    NSUInteger minX;
    NSUInteger maxX;
    NSUInteger minY;
    NSUInteger maxY;
} MapBounds;

NSValue * NSValueFromMapBounds(MapBounds bounds) {
    return [NSValue valueWithBytes:&bounds objCType:@encode(MapBounds)];
}

MapBounds MapBoundsFromNSValue(NSValue * value) {
    MapBounds bounds;
    [value getValue:&bounds];
    return bounds;
}

@implementation MBXOfflineMapURLGenerator
{
    NSInteger _urlCount;
    NSInteger _minimumZoom;
    NSInteger _maximumZoom;
    NSMutableArray * _zoomLevelBounds;
}

- (instancetype) initWithMinLat:(CLLocationDegrees)minLat maxLat:(CLLocationDegrees)maxLat minLon:(CLLocationDegrees)minLon maxLon:(CLLocationDegrees)maxLon minimumZ:(NSInteger)minimumZ maximumZ:(NSInteger)maximumZ
{
    self = [super init];
    if (self) {
        _zoomLevelBounds = [[NSMutableArray alloc] init];
        _minimumZoom = minimumZ;
        _maximumZoom = maximumZ;
        _urlCount = 0;
        for (NSUInteger zoom = minimumZ; zoom <= maximumZ; zoom++)
        {
            NSUInteger tilesPerSide = pow(2.0, zoom);
            NSUInteger minX = floor(((minLon + 180.0) / 360.0) * tilesPerSide);
            NSUInteger maxX = floor(((maxLon + 180.0) / 360.0) * tilesPerSide);
            NSUInteger minY = floor((1.0 - (logf(tanf(maxLat * M_PI / 180.0) + 1.0 / cosf(maxLat * M_PI / 180.0)) / M_PI)) / 2.0 * tilesPerSide);
            NSUInteger maxY = floor((1.0 - (logf(tanf(minLat * M_PI / 180.0) + 1.0 / cosf(minLat * M_PI / 180.0)) / M_PI)) / 2.0 * tilesPerSide);
            MapBounds bounds = {.minX = minX, .maxX = maxX, .minY = minY, .maxY = maxY};
            [_zoomLevelBounds addObject:NSValueFromMapBounds(bounds)];
            _urlCount += (maxX - minX + 1) * (maxY - minY + 1);
        }
    }
    return self;
}

@synthesize urlCount = _urlCount;

- (NSString *) urlForIndex:(NSInteger)index mapID:(NSString*)mapID imageQualityExtension:(NSString*)imageQualityExtension
{
    if (index > _urlCount)
    {
        return nil;
    }
    
    NSInteger zoom, x, y;
    // Middle condition intentionally 'less than' instead of 'less than or equal'.
    // If the 'break' is never hit, the last increment will make zoom equal to this.maximumZoom and end the loop.
    for (zoom = _minimumZoom; zoom < _maximumZoom; zoom++)
    {
        NSInteger boundsIndex = zoom - _minimumZoom;
        MapBounds bounds = MapBoundsFromNSValue([_zoomLevelBounds objectAtIndex:boundsIndex]);
        NSUInteger urlsInThisLevel = (bounds.maxX - bounds.minX + 1) * (bounds.maxY - bounds.minY + 1);
        if (index < urlsInThisLevel)
        {
            break;
        }
        else
        {
            index -= urlsInThisLevel;
        }
    }
    
    MapBounds bounds = MapBoundsFromNSValue([_zoomLevelBounds objectAtIndex:zoom - _minimumZoom]);
    NSInteger yCount = bounds.maxY - bounds.minY + 1;
    x = (index / yCount) + bounds.minX;
    y = (index % yCount) + bounds.minY;
    
    NSString * url = [NSString stringWithFormat:@"https://a.tiles.mapbox.com/v4/%@/%ld/%ld/%ld%@.%@%@", mapID, (long)zoom, (long)x, (long)y,
#if TARGET_OS_IPHONE
                         [[UIScreen mainScreen] scale] > 1.0 ? @"@2x" : @"",
#else
                         // Making this smart enough to handle a Retina MacBook with a normal dpi external display
                         // is complicated. For now, just default to @1x images and a 1.0 scale.
                         //
                         @"",
#endif
                         imageQualityExtension,
                         [@"?access_token=" stringByAppendingString:[MBXMapKit accessToken]]
                         ];
    return url;
}

@end
