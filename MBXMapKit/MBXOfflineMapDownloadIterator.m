//
//  MBXOfflineMapDownloadIterator.m
//  MBXMapKit
//
//  Copyright (c) 2015 Mapbox. All rights reserved.
//

#import "MBXOfflineMapDownloadIterator.h"

#import "MBXMapKit.h"
#import "MBXOfflineMapURLGenerator.h"

@interface MBXOfflineMapDownloadIterator ()

@property (readwrite, nonatomic) NSUInteger index;
@property (readwrite, nonatomic) NSArray *urls;
@property (readwrite, nonatomic) MBXOfflineMapURLGenerator *generator;
@property (readwrite, nonatomic) NSString *mapID;
@property (readwrite, nonatomic) NSString *imageQualityExtension;

@property (readwrite, nonatomic) NSUInteger urlCount;
@property (readwrite, nonatomic) NSUInteger totalCount;

@end

@implementation MBXOfflineMapDownloadIterator

- (instancetype)initWithURLs:(NSArray *)urls generator:(MBXOfflineMapURLGenerator *)generator mapID:(NSString *)mapID imageQualityExtension:(NSString *)imageQualityExtension
{
    self = [super init];
    if (self)
    {
        _index = 0;
        _urls = urls;
        _generator = generator;
        _mapID = mapID;
        _imageQualityExtension = imageQualityExtension;
        
        _urlCount = [urls count];
        _totalCount = _urlCount + [generator urlCount];
    }
    return self;
}

- (BOOL)hasNext
{
    @synchronized (self)
    {
        return _index < _totalCount;
    }
}

- (NSString *)nextIsTile:(BOOL *)isTile
{
    @synchronized (self)
    {
        NSString *toReturn = nil;
        if (_index < _urlCount)
        {
            toReturn = [_urls objectAtIndex:_index];
            if (isTile)
            {
                *isTile = NO;
            }
        }
        else if (_index < _totalCount)
        {
            toReturn = [_generator urlForIndex:(_index - _urlCount) mapID:_mapID imageQualityExtension:_imageQualityExtension];
            if (isTile)
            {
                *isTile = YES;
            }
        }
        else
        {
            return nil;
        }
        _index++;
        return toReturn;
    }
}

@end
