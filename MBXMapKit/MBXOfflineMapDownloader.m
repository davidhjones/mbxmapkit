//
//  MBXOfflineMapDownloader.m
//  MBXMapKit
//
//  Copyright (c) 2014 Mapbox. All rights reserved.
//

#import "MBXMapKit.h"
#import "MBXOfflineMapURLGenerator.h"
#import "MBXOfflineMapDownloadIterator.h"

#import <sqlite3.h>

#pragma mark - Private API for creating verbose errors

@interface NSError (MBXError)

+ (NSError *)mbx_errorWithCode:(NSInteger)code reason:(NSString *)reason description:(NSString *)description;
+ (NSError *)mbx_errorCannotOpenOfflineMapDatabase:(NSString *)path sqliteError:(const char *)sqliteError;
+ (NSError *)mbx_errorQueryFailedForOfflineMapDatabase:(NSString *)path sqliteError:(const char *)sqliteError;

@end


#pragma mark - Private API for cooperating with MBXRasterTileOverlay

@interface MBXRasterTileOverlay ()

+ (NSString *)qualityExtensionForImageQuality:(MBXRasterImageQuality)imageQuality;
+ (NSURL *)markerIconURLForSize:(NSString *)size symbol:(NSString *)symbol color:(NSString *)color;

@end


#pragma mark - Private API for cooperating with MBXOfflineMapDatabase

@interface MBXOfflineMapDatabase ()

- (instancetype)initWithContentsOfFile:(NSString *)path;
- (instancetype)initWithPath:(NSString *)path mapID:(NSString *)mapID metadata:(NSDictionary *)metadata withError:(NSError **)error;
- (void)invalidate;
- (void)updateMetadata:(NSDictionary *)metadata withError:(NSError **)error;
- (BOOL)isAlreadyDataForURL:(NSURL *)url;
- (BOOL)setData:(NSData *)data forURL:(NSURL *)url;
- (void)closeDatabaseIfNeeded;

@end


#pragma mark -

@interface MBXOfflineMapDownloader ()

@property (readwrite, nonatomic) MBXOfflineMapDatabase* downloadingDatabase;
@property (readwrite, nonatomic) MBXOfflineMapDownloadIterator* downloadIterator;
@property (readwrite, nonatomic) MBXOfflineMapDownloaderState state;
@property (readwrite, nonatomic) NSUInteger totalFilesWritten;
@property (readwrite, nonatomic) NSUInteger totalFilesExpectedToWrite;

@property (nonatomic) NSMutableArray *mutableOfflineMapDatabases;
@property (nonatomic) NSURL *offlineMapDirectory;

@property (nonatomic) NSOperationQueue *backgroundWorkQueue;
@property (nonatomic) NSOperationQueue *sqliteQueue;
@property (nonatomic) NSURLSession *dataSession;

@end


#pragma mark -

@implementation MBXOfflineMapDownloader

#pragma mark - API: Shared downloader singleton

+ (MBXOfflineMapDownloader *)sharedOfflineMapDownloader
{
    static id _sharedDownloader = nil;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        _sharedDownloader = [[self alloc] init];
    });
    
    return _sharedDownloader;
}


#pragma mark - Initialize and restore saved state from disk

- (instancetype)init
{
    // MBXMapKit expects libsqlite to have been compiled with SQLITE_THREADSAFE=2 (multi-thread mode), which means
    // that it can handle its own thread safety as long as you don't attempt to re-use database connections.
    //
    assert(sqlite3_threadsafe()==2);

    // NOTE: MBXOfflineMapDownloader is designed with the intention that init should be used _only_ by +sharedOfflineMapDownloader.
    // Please use the shared downloader singleton rather than attempting to create your own MBXOfflineMapDownloader objects.
    //
    self = [super init];

    if(self)
    {
        // Calculate the path in Application Support for storing offline maps
        //
        NSFileManager *fm = [NSFileManager defaultManager];
        NSURL *appSupport = [fm URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:nil];
        _offlineMapDirectory = [appSupport URLByAppendingPathComponent:@"MBXMapKit/OfflineMaps"];

        // Make sure the offline map directory exists
        //
        NSError *error;
        [fm createDirectoryAtURL:_offlineMapDirectory withIntermediateDirectories:YES attributes:nil error:&error];
        if(error)
        {
            NSLog(@"There was an error with creating the offline map directory: %@", error);
            error = nil;
        }

        // Figure out if the offline map directory already has a value for NSURLIsExcludedFromBackupKey. If so,
        // then leave that value alone. Otherwise, set a default value to exclude offline maps from backups.
        //
        NSNumber *excluded;
        [_offlineMapDirectory getResourceValue:&excluded forKey:NSURLIsExcludedFromBackupKey error:&error];
        if(error)
        {
            NSLog(@"There was an error with checking the offline map directory's resource values: %@", error);
            error = nil;
        }
        if(excluded != nil)
        {
            _offlineMapsAreExcludedFromBackup = [excluded boolValue];
        }
        else
        {
            [self setOfflineMapsAreExcludedFromBackup:YES];
        }

        // Restore persistent state from disk
        //
        _mutableOfflineMapDatabases = [[NSMutableArray alloc] init];
        error = nil;
        NSArray *files = [fm contentsOfDirectoryAtPath:[_offlineMapDirectory path] error:&error];
        if(error)
        {
            NSLog(@"There was an error with listing the contents of the offline map directory: %@", error);
        }
        if (files)
        {
            MBXOfflineMapDatabase *db;
            for(NSString *path in files)
            {
                // Find the completed map databases
                //
                if([path hasSuffix:@".complete"])
                {
                    db = [[MBXOfflineMapDatabase alloc] initWithContentsOfFile:[[_offlineMapDirectory URLByAppendingPathComponent:path] path]];
                    if(db)
                    {
                        [_mutableOfflineMapDatabases addObject:db];
                    }
                    else
                    {
                        NSLog(@"Error: %@ is not a valid offline map database",path);
                    }
                }
            }
        }

        _state = MBXOfflineMapDownloaderStateAvailable;

        // Configure the background and sqlite operation queues as a serial queues
        //
        _backgroundWorkQueue = [[NSOperationQueue alloc] init];
        [_backgroundWorkQueue setMaxConcurrentOperationCount:1];
        _sqliteQueue = [[NSOperationQueue alloc] init];
        [_sqliteQueue setMaxConcurrentOperationCount:1];

        // Configure the download session
        //
        [self setUpNewDataSession];
    }

    return self;
}

- (void)setOfflineMapsAreExcludedFromBackup:(BOOL)offlineMapsAreExcludedFromBackup
{
    NSError *error;
    NSNumber *boolNumber = offlineMapsAreExcludedFromBackup ? @YES : @NO;
    [_offlineMapDirectory setResourceValue:boolNumber forKey:NSURLIsExcludedFromBackupKey error:&error];
    if(error)
    {
        NSLog(@"There was an error setting NSURLIsExcludedFromBackupKey on the offline map directory: %@",error);
    }
    else
    {
        _offlineMapsAreExcludedFromBackup = offlineMapsAreExcludedFromBackup;
    }
}

- (void)setUpNewDataSession
{
    // Create a new NSURLDataSession. This is necessary after a call to invalidateAndCancel
    //
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.allowsCellularAccess = YES;
    config.HTTPMaximumConnectionsPerHost = 4;
    config.URLCache = [NSURLCache sharedURLCache];
    config.HTTPAdditionalHeaders = @{ @"User-Agent" : [MBXMapKit userAgent] };
    _dataSession = [NSURLSession sessionWithConfiguration:config];
}


#pragma mark - Delegate Notifications

- (void)notifyDelegateOfStateChange
{
    assert(![NSThread isMainThread]);

    if([_delegate respondsToSelector:@selector(offlineMapDownloader:stateChangedTo:)])
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [_delegate offlineMapDownloader:self stateChangedTo:_state];
        });
    }
}


- (void)notifyDelegateOfInitialCount
{
    if([_delegate respondsToSelector:@selector(offlineMapDownloader:totalFilesExpectedToWrite:)])
    {
        // Update the delegate with the file count so it can display a progress indicator
        //
        dispatch_async(dispatch_get_main_queue(), ^{
            [_delegate offlineMapDownloader:self totalFilesExpectedToWrite:_totalFilesExpectedToWrite];
        });
    }
}


- (void)notifyDelegateOfProgress
{
    assert(![NSThread isMainThread]);

    if([_delegate respondsToSelector:@selector(offlineMapDownloader:totalFilesWritten:totalFilesExpectedToWrite:)])
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [_delegate offlineMapDownloader:self totalFilesWritten:_totalFilesWritten totalFilesExpectedToWrite:_totalFilesExpectedToWrite];
        });
    }
}


- (void)notifyDelegateOfNetworkConnectivityError:(NSError *)error
{
    assert(![NSThread isMainThread]);

    if([_delegate respondsToSelector:@selector(offlineMapDownloader:didEncounterRecoverableError:)])
    {
        NSError *networkError = [NSError mbx_errorWithCode:MBXMapKitErrorCodeURLSessionConnectivity reason:[error localizedFailureReason] description:[error localizedDescription]];

        dispatch_async(dispatch_get_main_queue(), ^{
            [_delegate offlineMapDownloader:self didEncounterRecoverableError:networkError];
        });
    }
}


- (void)notifyDelegateOfSqliteError:(NSError *)error
{
    assert(![NSThread isMainThread]);

    if([_delegate respondsToSelector:@selector(offlineMapDownloader:didEncounterRecoverableError:)])
    {
        NSError *networkError = [NSError mbx_errorWithCode:MBXMapKitErrorCodeOfflineMapSqlite reason:[error localizedFailureReason] description:[error localizedDescription]];

        dispatch_async(dispatch_get_main_queue(), ^{
            [_delegate offlineMapDownloader:self didEncounterRecoverableError:networkError];
        });
    }
}


- (void)notifyDelegateOfHTTPStatusError:(NSInteger)status url:(NSURL *)url
{
    assert(![NSThread isMainThread]);

    if([_delegate respondsToSelector:@selector(offlineMapDownloader:didEncounterRecoverableError:)])
    {
        NSString *reason = [NSString stringWithFormat:@"HTTP status %li was received for %@", (long)status,[url absoluteString]];
        NSError *statusError = [NSError mbx_errorWithCode:MBXMapKitErrorCodeHTTPStatus reason:reason description:@"HTTP status error"];

        dispatch_async(dispatch_get_main_queue(), ^{
            [_delegate offlineMapDownloader:self didEncounterRecoverableError:statusError];
        });
    }
}


- (void)notifyDelegateOfCompletionWithOfflineMapDatabase:(MBXOfflineMapDatabase *)offlineMap withError:(NSError *)error
{
    assert(![NSThread isMainThread]);

    if([_delegate respondsToSelector:@selector(offlineMapDownloader:didCompleteOfflineMapDatabase:withError:)])
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [_delegate offlineMapDownloader:self didCompleteOfflineMapDatabase:offlineMap withError:error];
        });
    }
}


#pragma mark - Implementation: download urls

- (void)startDownloadingWithURLs:(NSArray *)urls generator:(MBXOfflineMapURLGenerator *)generator mapID:(NSString *)mapID imageQualityExtension:(NSString *)imageQualityExtension
{
    _downloadIterator = [[MBXOfflineMapDownloadIterator alloc] initWithURLs:urls generator:generator mapID:mapID imageQualityExtension:imageQualityExtension];
    [self startDownloading];
}

- (void)startDownloading
{
    assert(![NSThread isMainThread]);

    [_sqliteQueue addOperationWithBlock:^{
        NSError *error;
        if(error)
        {
            NSLog(@"Error while reading offline map urls: %@",error);
        }
        else
        {
            if (![_downloadIterator hasNext])
            {
                [self allFilesDownloaded];
            }
            else
            {
                for (int i = 0; i < 8; i++)
                {
                    [self startSingleTile];
                }
            }
        }
    }];
}

- (void) startSingleTile
{
    if (_state != MBXOfflineMapDownloaderStateRunning)
    {
        return;
    }

    if ([_downloadIterator hasNext]) {
        NSURL *nextUrl = [NSURL URLWithString:[_downloadIterator next]];
        BOOL alreadyHasData = [_downloadingDatabase isAlreadyDataForURL:nextUrl];
        
        void (^finish)() = ^{
            if (_state != MBXOfflineMapDownloaderStateCanceling && _state != MBXOfflineMapDownloaderStateAvailable)
            {
                [self markOneFileDownloaded];
            }
            
            if (_state == MBXOfflineMapDownloaderStateRunning)
            {
                [_sqliteQueue addOperationWithBlock:^{
                    [self startSingleTile];
                }];
            }
        };
        
        if (alreadyHasData)
        {
            finish();
        }
        else
        {
            NSURLSessionDataTask *task;
            NSURLRequest *request = [NSURLRequest requestWithURL:nextUrl cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:60];
            task = [_dataSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error)
            {
                if (error && _state == MBXOfflineMapDownloaderStateRunning)
                {
                    // We got a session level error which probably indicates a connectivity problem such as airplane mode.
                    // Notify the delegate.
                    //
                    [self notifyDelegateOfNetworkConnectivityError:error];
                }
                if (!error)
                {
                    if ([response isKindOfClass:[NSHTTPURLResponse class]] && ((NSHTTPURLResponse *)response).statusCode != 200)
                    {
                        if (_state == MBXOfflineMapDownloaderStateRunning)
                        {
                            // This url didn't work. For now, use the primitive error handling method of notifying the delegate and
                            // continuing to request the url (this will eventually cycle back through the download queue since we're
                            // not marking the url as done in the database).
                            //
                            [self notifyDelegateOfHTTPStatusError:((NSHTTPURLResponse *)response).statusCode url:response.URL];
                        }
                    }
                    else if (_state != MBXOfflineMapDownloaderStateCanceling && _state != MBXOfflineMapDownloaderStateAvailable)
                    {
                        // Since the URL was successfully retrieved, save the data
                        //
                        [_downloadingDatabase setData:data forURL:nextUrl];
                    }
                }

                finish();
            }];
            [task resume];
        }
    }
}

#pragma mark - Implementation: sqlite stuff
- (void)markOneFileDownloaded
{
    [_sqliteQueue addOperationWithBlock:^{
        // Update the progress
        //
        _totalFilesWritten += 1;
        [self notifyDelegateOfProgress];
        // If all the downloads are done, clean up and notify the delegate
        //
        if(_totalFilesWritten >= _totalFilesExpectedToWrite)
        {
            [self allFilesDownloaded];
        }
    }];
}

- (void)allFilesDownloaded
{
    NSError *error;
    // This is what to do when we've downloaded all the files
    //
    MBXOfflineMapDatabase *offlineMap = _downloadingDatabase;
    [self closeDatabaseIfNeeded];
    if(offlineMap && !error && ![_mutableOfflineMapDatabases containsObject:offlineMap]) {
        [_mutableOfflineMapDatabases addObject:offlineMap];
    }
    [self notifyDelegateOfCompletionWithOfflineMapDatabase:offlineMap withError:error];

    _state = MBXOfflineMapDownloaderStateAvailable;
    [self notifyDelegateOfStateChange];
}

- (BOOL)sqliteCreateOrUpdateDatabaseUsingMetadata:(NSDictionary *)metadata urlArray:(NSArray *)urls generator:(MBXOfflineMapURLGenerator *)generator withError:(NSError **)error
{
    assert(![NSThread isMainThread]);
    
    if (_downloadingDatabase)
    {
        [_downloadingDatabase updateMetadata:metadata withError:error];
    }
    else
    {
        NSString *path = [NSString stringWithFormat:@"%@.complete", [metadata objectForKey:@"uniqueID"]];
        _downloadingDatabase = [[MBXOfflineMapDatabase alloc] initWithPath:[[_offlineMapDirectory URLByAppendingPathComponent:path] path] mapID:[metadata objectForKey:@"mapID"] metadata:metadata withError:error];
    }
    
    _totalFilesExpectedToWrite = [urls count] + [generator urlCount];
    _totalFilesWritten = 0;
    return YES;
}

#pragma mark - API: Begin an offline map download

- (void)beginDownloadingMapID:(NSString *)mapID mapRegion:(MKCoordinateRegion)mapRegion minimumZ:(NSInteger)minimumZ maximumZ:(NSInteger)maximumZ
{
    [self beginDownloadingMapID:mapID mapRegion:mapRegion minimumZ:minimumZ maximumZ:maximumZ includeMetadata:YES includeMarkers:YES imageQuality:MBXRasterImageQualityFull];
}

- (void)beginDownloadingMapID:(NSString *)mapID mapRegion:(MKCoordinateRegion)mapRegion minimumZ:(NSInteger)minimumZ maximumZ:(NSInteger)maximumZ includeMetadata:(BOOL)includeMetadata includeMarkers:(BOOL)includeMarkers
{
    [self beginDownloadingMapID:mapID mapRegion:mapRegion minimumZ:minimumZ maximumZ:maximumZ includeMetadata:includeMetadata includeMarkers:includeMarkers imageQuality:MBXRasterImageQualityFull];
}

- (void)beginDownloadingMapID:(NSString *)mapID mapRegion:(MKCoordinateRegion)mapRegion minimumZ:(NSInteger)minimumZ maximumZ:(NSInteger)maximumZ includeMetadata:(BOOL)includeMetadata includeMarkers:(BOOL)includeMarkers imageQuality:(MBXRasterImageQuality)imageQuality
{
    assert(_state == MBXOfflineMapDownloaderStateAvailable);

    [self setUpNewDataSession];

    [_backgroundWorkQueue addOperationWithBlock:^{

        // Start a download job to retrieve all the resources needed for using the specified map offline
        //
        NSString *uniqueID = [[NSUUID UUID] UUIDString];
        _state = MBXOfflineMapDownloaderStateRunning;
        [self notifyDelegateOfStateChange];
        
        BOOL realIncludeMarkers = includeMarkers;
        BOOL realIncludeMetadata = includeMetadata;
        _downloadingDatabase = [self offlineMapDatabaseWithMapID:mapID];
        NSMutableDictionary *metadataDictionary = [[NSMutableDictionary alloc] init];
        if (!_downloadingDatabase)
        {
            [metadataDictionary addEntriesFromDictionary:@{
              @"uniqueID": uniqueID,
              @"mapID": mapID,
              @"includesMetadata": includeMetadata ? @"YES" : @"NO",
              @"includesMarkers": includeMarkers ? @"YES" : @"NO",
              @"imageQuality": [NSString stringWithFormat:@"%ld",(long)imageQuality]
            }];
        }
        else
        {
            BOOL didIncludeMarkers = [_downloadingDatabase includesMarkers];
            BOOL didIncludeMetadata = [_downloadingDatabase includesMetadata];
            if (!didIncludeMarkers && includeMarkers)
            {
                [metadataDictionary setObject:@"YES" forKey:@"includesMarkers"];
            }
            else
            {
                // Don't download the data if it's already in the db or not requested
                realIncludeMarkers = NO;
            }
            
            if (!didIncludeMetadata && includeMetadata)
            {
                [metadataDictionary setObject:@"YES" forKey:@"includesMetadata"];
            }
            else
            {
                // Don't download the data if it's already in the db or not requested
                realIncludeMetadata = NO;
            }
        }

        NSMutableArray *urls = [[NSMutableArray alloc] init];

        // Include URLs for the metadata and markers json if applicable
        //
        if (realIncludeMetadata)
        {
            [urls addObject:[NSString stringWithFormat:@"https://a.tiles.mapbox.com/v4/%@.json?secure%@",
                                mapID,
                                [@"&access_token=" stringByAppendingString:[MBXMapKit accessToken]]]];
        }
        if (realIncludeMarkers)
        {
            [urls addObject:[NSString stringWithFormat:@"https://a.tiles.mapbox.com/v4/%@/features.json%@",
                                mapID,
                                [@"?access_token=" stringByAppendingString:[MBXMapKit accessToken]]]];
        }

        // Loop through the zoom levels and lat/lon bounds to generate a list of urls which should be included in the offline map
        //
        CLLocationDegrees minLat = mapRegion.center.latitude - (mapRegion.span.latitudeDelta / 2.0);
        CLLocationDegrees maxLat = minLat + mapRegion.span.latitudeDelta;
        CLLocationDegrees minLon = mapRegion.center.longitude - (mapRegion.span.longitudeDelta / 2.0);
        CLLocationDegrees maxLon = minLon + mapRegion.span.longitudeDelta;
        MBXOfflineMapURLGenerator * generator = [[MBXOfflineMapURLGenerator alloc] initWithMinLat:minLat maxLat:maxLat minLon:minLon maxLon:maxLon minimumZ:minimumZ maximumZ:maximumZ];

        NSString *imageQualityExtension = [MBXRasterTileOverlay qualityExtensionForImageQuality:imageQuality];

        // Determine if we need to add marker icon urls (i.e. parse markers.geojson/features.json), and if so, add them
        //
        if (realIncludeMarkers)
        {
            NSURL *geojson = [NSURL URLWithString:[NSString stringWithFormat:@"https://a.tiles.mapbox.com/v4/%@/features.json%@",
                mapID,
                [@"?access_token=" stringByAppendingString:[MBXMapKit accessToken]]]];

            NSURLSessionDataTask *task;
            NSURLRequest *request = [NSURLRequest requestWithURL:geojson cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:60];
            task = [_dataSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error)
            {
                if(error)
                {
                    // We got a session level error which probably indicates a connectivity problem such as airplane mode.
                    // Since we must fetch and parse markers.geojson/features.json in order to determine which marker icons need to be
                    // added to the list of urls to download, the lack of network connectivity is a non-recoverable error
                    // here.
                    //
                    [self notifyDelegateOfNetworkConnectivityError:error];
                    [self cancelImmediatelyWithError:error];
                }
                else
                {
                    if ([response isKindOfClass:[NSHTTPURLResponse class]] && ((NSHTTPURLResponse *)response).statusCode != 200)
                    {
                        // The url for markers.geojson/features.json didn't work (some maps don't have any markers). Notify the delegate of the
                        // problem, and stop attempting to add marker icons, but don't bail out on whole the offline map download.
                        // The delegate can decide for itself whether it wants to continue or cancel.
                        //
                        [self notifyDelegateOfHTTPStatusError:((NSHTTPURLResponse *)response).statusCode url:response.URL];
                    }
                    else
                    {
                        // The marker geojson was successfully retrieved, so parse it for marker icons. Note that we shouldn't
                        // try to save it here, because it may already be in the download queue and saving it twice will mess
                        // up the count of urls to be downloaded!
                        //
                        NSArray *markerIconURLStrings = [self parseMarkerIconURLStringsFromGeojsonData:(NSData *)data];
                        if(markerIconURLStrings)
                        {
                            [urls addObjectsFromArray:markerIconURLStrings];
                        }
                    }


                    // ==========================================================================================================
                    // == WARNING! WARNING! WARNING!                                                                           ==
                    // == This stuff is a duplicate of the code immediately below it, but this copy is inside of a completion  ==
                    // == block while the other isn't. You will be sad and confused if you try to eliminate the "duplication". ==
                    //===========================================================================================================

                    // Create the database and start the download
                    //
                    NSError *error;
                    [self sqliteCreateOrUpdateDatabaseUsingMetadata:metadataDictionary urlArray:urls generator:generator withError:&error];
                    if(error)
                    {
                        [self cancelImmediatelyWithError:error];
                    }
                    else
                    {
                        [self notifyDelegateOfInitialCount];
                        [self startDownloadingWithURLs:urls generator:generator mapID:mapID imageQualityExtension:imageQualityExtension];
                    }
                }
            }];
            [task resume];
        }
        else
        {
            // There aren't any marker icons to worry about, so just create database and start downloading
            //
            NSError *error;
            [self sqliteCreateOrUpdateDatabaseUsingMetadata:metadataDictionary urlArray:urls generator:generator withError:&error];
            if(error)
            {
                [self cancelImmediatelyWithError:error];
            }
            else
            {
                [self notifyDelegateOfInitialCount];
                [self startDownloadingWithURLs:urls generator:generator mapID:mapID imageQualityExtension:imageQualityExtension];
            }
        }
    }];
}


- (NSArray *)parseMarkerIconURLStringsFromGeojsonData:(NSData *)data
{
    id markers;
    id value;
    NSMutableArray *iconURLStrings = [[NSMutableArray alloc] init];
    NSError *error;
    NSDictionary *simplestyleJSONDictionary = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if(!error)
    {
        // Find point features in the markers dictionary (if there are any) and add them to the map.
        //
        markers = simplestyleJSONDictionary[@"features"];

        if (markers && [markers isKindOfClass:[NSArray class]])
        {
            for (value in (NSArray *)markers)
            {
                if ([value isKindOfClass:[NSDictionary class]])
                {
                    NSDictionary *feature = (NSDictionary *)value;
                    NSString *type = feature[@"geometry"][@"type"];

                    if ([@"Point" isEqualToString:type])
                    {
                        NSString *size        = feature[@"properties"][@"marker-size"];
                        NSString *color       = feature[@"properties"][@"marker-color"];
                        NSString *symbol      = feature[@"properties"][@"marker-symbol"];
                        if (size && color && symbol)
                        {
                            NSURL *markerURL = [MBXRasterTileOverlay markerIconURLForSize:size symbol:symbol color:color];
                            if(markerURL && iconURLStrings )
                            {
                                [iconURLStrings addObject:[markerURL absoluteString]];
                            }
                        }
                    }
                }
                // This is the last line of the loop
            }
        }
    }

    // Return only the unique icon urls
    //
    NSSet *uniqueIcons = [NSSet setWithArray:iconURLStrings];
    return [uniqueIcons allObjects];
}


- (void)cancelImmediatelyWithError:(NSError *)error
{
    // Creating the database failed for some reason, so clean up and change the state back to available
    //
    _state = MBXOfflineMapDownloaderStateCanceling;
    [self notifyDelegateOfStateChange];

    if([_delegate respondsToSelector:@selector(offlineMapDownloader:didCompleteOfflineMapDatabase:withError:)])
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [_delegate offlineMapDownloader:self didCompleteOfflineMapDatabase:nil withError:error];
        });
    }

    [_dataSession invalidateAndCancel];
    [_sqliteQueue cancelAllOperations];

    [_sqliteQueue addOperationWithBlock:^{
        [self closeDatabaseIfNeeded];
        [self setUpNewDataSession];
        _totalFilesWritten = 0;
        _totalFilesExpectedToWrite = 0;

        _state = MBXOfflineMapDownloaderStateAvailable;
        [self notifyDelegateOfStateChange];
    }];
}


#pragma mark - API: Control an in-progress offline map download

- (void)cancel
{
    if(_state != MBXOfflineMapDownloaderStateCanceling && _state != MBXOfflineMapDownloaderStateAvailable)
    {
        // Stop a download job and discard the associated files
        //
        [_backgroundWorkQueue addOperationWithBlock:^{
            _state = MBXOfflineMapDownloaderStateCanceling;
            [self notifyDelegateOfStateChange];

            [_dataSession invalidateAndCancel];
            [_sqliteQueue cancelAllOperations];
            [_sqliteQueue addOperationWithBlock:^{
                [self setUpNewDataSession];
                _totalFilesWritten = 0;
                _totalFilesExpectedToWrite = 0;
                [self closeDatabaseIfNeeded];

                if([_delegate respondsToSelector:@selector(offlineMapDownloader:didCompleteOfflineMapDatabase:withError:)])
                {
                    NSError *canceled = [NSError mbx_errorWithCode:MBXMapKitErrorCodeDownloadingCanceled reason:@"The download job was canceled" description:@"Download canceled"];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [_delegate offlineMapDownloader:self didCompleteOfflineMapDatabase:nil withError:canceled];
                    });
                }

                _state = MBXOfflineMapDownloaderStateAvailable;
                [self notifyDelegateOfStateChange];
            }];

        }];
    }
}


- (void)resume
{
    assert(_state == MBXOfflineMapDownloaderStateSuspended);

    // Resume a previously suspended download job
    //
    [_backgroundWorkQueue addOperationWithBlock:^{
        _state = MBXOfflineMapDownloaderStateRunning;
        [self startDownloading];
        [self notifyDelegateOfStateChange];
    }];
}


- (void)suspend
{
    if(_state == MBXOfflineMapDownloaderStateRunning)
    {
        // Stop a download job, preserving the necessary state to resume later
        //
        [_backgroundWorkQueue addOperationWithBlock:^{
            _state = MBXOfflineMapDownloaderStateSuspended;
            [self notifyDelegateOfStateChange];
        }];
    }
}


#pragma mark - API: Access or delete completed offline map databases on disk

- (NSArray *)offlineMapDatabases
{
    // Return an array with offline map database objects representing each of the *complete* map databases on disk
    //
    return [NSArray arrayWithArray:_mutableOfflineMapDatabases];
}


- (void)removeOfflineMapDatabase:(MBXOfflineMapDatabase *)offlineMapDatabase
{
    // Mark the offline map object as invalid in case there are any references to it still floating around
    //
    [offlineMapDatabase invalidate];

    // If this assert fails, an MBXOfflineMapDatabase object has somehow been initialized with a database path which is not
    // inside of the directory for completed ofline map databases. That should definitely not be happening, and we should definitely
    // not proceed to recursively remove whatever the path string actually is pointed at.
    //
    assert([offlineMapDatabase.path hasPrefix:[_offlineMapDirectory path]]);

    // Remove the offline map object from the array and delete it's backing database
    //
    [_mutableOfflineMapDatabases removeObject:offlineMapDatabase];

    NSError *error;
    [[NSFileManager defaultManager] removeItemAtPath:offlineMapDatabase.path error:&error];
    if(error)
    {
        NSLog(@"There was an error while attempting to delete an offline map database: %@", error);
    }
}

- (MBXOfflineMapDatabase*)offlineMapDatabaseWithMapID:(NSString *)mapID
{
    for (MBXOfflineMapDatabase *database in [self offlineMapDatabases])
    {
        if ([database.mapID isEqualToString:mapID])
        {
            return database;
        }
    }
    return nil;
}

- (void)removeOfflineMapDatabaseWithID:(NSString *)uniqueID
{
    for (MBXOfflineMapDatabase *database in [self offlineMapDatabases])
    {
        if ([database.uniqueID isEqualToString:uniqueID])
        {
            [self removeOfflineMapDatabase:database];
            return;
        }
    }
}

- (void)closeDatabaseIfNeeded
{
    [_downloadingDatabase closeDatabaseIfNeeded];
    _downloadingDatabase = nil;
}

@end
