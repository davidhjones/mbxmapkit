//
//  MBXOfflineMapDatabase.h
//  MBXMapKit
//
//  Copyright (c) 2014 Mapbox. All rights reserved.
//

@import Foundation;
@import MapKit;

#import "MBXConstantsAndTypes.h"

#pragma mark -

/** An instance of the `MBXOfflineMapDatabase` class represents a store of offline map data, including map tiles, JSON metadata, and marker images.
*
*   @warning The `MBXOfflineMapDatabase` class is not meant to be instantiated directly. Instead, instances are created and managed by the shared `MBXOfflineMapDownloader` instance. */
@interface MBXOfflineMapDatabase : NSObject


#pragma mark - Properties and methods for accessing stored map data

/** @name Getting and Setting Properties */

/** A unique identifier for the offline map database. */
@property (readonly, nonatomic) NSString *uniqueID;

/** The Mapbox map ID from which the map resources in this offline map were downloaded. */
@property (readonly, nonatomic) NSString *mapID;

/** Whether this offline map database includes the map's metadata JSON. */
@property (readonly, nonatomic) BOOL includesMetadata;

/** Whether this offline map database includes the map's markers JSON and marker icons. */
@property (readonly, nonatomic) BOOL includesMarkers;

/** The image quality used to download the raster tile images stored in this offline map database. */
@property (readonly, nonatomic) MBXRasterImageQuality imageQuality;

/** Whether this offline map database has been invalidated. This is to help prevent the completion handlers in `MBXRasterTileOverlay` from causing problems after overlay layers are removed from an `MKMapView`. */
@property (readonly, nonatomic, getter=isInvalid) BOOL invalid;

/** Initial creation date of the offline map database. */
@property (readonly, nonatomic) NSDate *creationDate;

/** The filesystem path of the database. */
@property (readonly, nonatomic) NSString *path;

/** @name Manipulating data */

/** Returns the NSData* for the given URL in the database.
    @param error Contains an error describing what went wrong, or nil if no error occurred.
    @return The data, or nil if the data could not be retrieved. */
- (NSData *)dataForURL:(NSURL *)url withError:(NSError **)error;
/** Returns TRUE if data already exists for the given URL in the database. */
- (BOOL)isAlreadyDataForURL:(NSURL *)url;
/** Removes data for the given url in the database.
    @return TRUE if the removal was successful. */
- (BOOL)removeDataForURL:(NSURL *)url;
/** Sets the given data for the given URL in the database.
    @return TRUE if the insertion was successful. */
- (BOOL)setData:(NSData *)data forURL:(NSURL *)url;

- (instancetype)init UNAVAILABLE_ATTRIBUTE;

@end
