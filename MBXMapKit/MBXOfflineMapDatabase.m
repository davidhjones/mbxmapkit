//
//  MBXOfflineMapDatabase.m
//  MBXMapKit
//
//  Copyright (c) 2014 Mapbox. All rights reserved.
//

#import "MBXMapKit.h"

#import <sqlite3.h>

#pragma mark - Private API for creating verbose errors

@interface NSError (MBXError)

+ (NSError *)mbx_errorWithCode:(NSInteger)code reason:(NSString *)reason description:(NSString *)description;

+ (NSError *)mbx_errorCannotOpenOfflineMapDatabase:(NSString *)path sqliteError:(const char *)sqliteError;

+ (NSError *)mbx_errorQueryFailedForOfflineMapDatabase:(NSString *)path sqliteError:(const char *)sqliteError;

@end


#pragma mark -

@interface MBXOfflineMapDatabase ()

@property (readwrite, nonatomic) NSString *uniqueID;
@property (readwrite, nonatomic) NSString *mapID;
@property (readwrite, nonatomic) BOOL includesMetadata;
@property (readwrite, nonatomic) BOOL includesMarkers;
@property (readwrite, nonatomic) MBXRasterImageQuality imageQuality;
@property (readwrite, nonatomic) NSString *path;
@property (readwrite, nonatomic) BOOL invalid;
@property (readwrite, nonatomic) sqlite3 *db;

@property (nonatomic) BOOL initializedProperly;

@end


#pragma mark -

@implementation MBXOfflineMapDatabase

- (instancetype)initWithPath:(NSString *)path mapID:(NSString *)mapID metadata:(NSDictionary *)metadata withError:(NSError **)error
{
    self = [super init];
    if (self)
    {
        _path = path;
        [self updateMetadata:metadata withError:error];
    }
    return self;
}

- (instancetype)initWithContentsOfFile:(NSString *)path
{
    self = [super init];

    if (self)
    {
        _path = path;
        BOOL hadAllMetadata = [self refreshMetadata];
        
        if (hadAllMetadata)
        {
            _initializedProperly = YES;
        }
        else
        {
            // Reaching this point means the file at path isn't a valid offline map database, so we can't use it.
            //
            self = nil;
        }
        [self closeDatabaseIfNeeded];
    }

    return self;
}


- (NSData *)dataForURL:(NSURL *)url withError:(NSError **)error
{
    NSData *data = [self sqliteDataForURL:url];
    if (!data && error)
    {
        NSString *reason = [NSString stringWithFormat:@"The offline database has no data for %@",[url absoluteString]];
        *error = [NSError mbx_errorWithCode:MBXMapKitErrorCodeOfflineMapHasNoDataForURL reason:reason description:@"No offline data for key error"];
    }
    return data;
}


- (void)invalidate
{
    @synchronized(self)
    {
        // This is to let MBXOfflineMapDownloader mark an MBXOfflineMapDatabase object as invalid when it has been asked to delete
        // the backing database on disk. This is important because there's a possibility that an MBXRasterTileOverlay layer could still
        // be holding a reference to the MBXOfflineMapDatabase at the time that the backing file is deleted. If that happens, it would
        // be a logic error, but it seems like a pretty easy error to make, so this helps to catch it (see assert in MBXRasterTileOverlay).
        //
        self.invalid = YES;
        [self closeDatabaseIfNeeded];
    }
}

- (NSString *)uniqueID
{
    @synchronized(self)
    {
        return _uniqueID;
    }
}

- (NSString *)mapID
{
    @synchronized(self)
    {
        return _mapID;
    }
}

- (BOOL)includesMetadata
{
    @synchronized(self)
    {
        return _includesMetadata;
    }
}

- (BOOL)includesMarkers
{
    @synchronized(self)
    {
        return _includesMarkers;
    }
}

- (MBXRasterImageQuality)imageQuality
{
    @synchronized(self)
    {
        return _imageQuality;
    }
}

- (BOOL)isInvalid
{
    @synchronized(self)
    {
        return _invalid;
    }
}

- (NSDate *)creationDate
{
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:_path error:nil];
    
    if (attributes) return (NSDate *)[attributes objectForKey: NSFileCreationDate];
    
    return nil;
}

- (BOOL)refreshMetadata
{
    @synchronized(self)
    {
        NSString *uniqueID = [self sqliteMetadataForName:@"uniqueID"];
        NSString *mapID = [self sqliteMetadataForName:@"mapID"];
        NSString *includesMetadata = [self sqliteMetadataForName:@"includesMetadata"];
        NSString *includesMarkers = [self sqliteMetadataForName:@"includesMarkers"];
        NSString *imageQuality = [self sqliteMetadataForName:@"imageQuality"];

        if (uniqueID && mapID && includesMetadata && includesMarkers && imageQuality)
        {
            // Reaching this point means that the specified database file at path pointed to an sqlite file which had
            // all the required values in its metadata table. That means the file passed the test for being a valid
            // offline map database.
            //
            _uniqueID = uniqueID;
            _mapID = mapID;
            _includesMetadata = [includesMetadata boolValue];
            _includesMarkers =  [includesMarkers boolValue];

            _imageQuality = (MBXRasterImageQuality)[imageQuality integerValue];
            return YES;
        }
        else
        {
            return NO;
        }
    }
}

- (void)updateMetadata:(NSDictionary *)metadata withError:(NSError **)error
{
    @synchronized(self)
    {
        sqlite3 *db = [self databaseWithError:error];
        if (db == NULL)
        {
            return;
        }
        
        NSString *startTransaction = @"BEGIN TRANSACTION;";
        BOOL success = [self executeNoDataQuery:startTransaction];
        if (!success)
        {
            return;
        }
        
        for (NSString *key in metadata) {
            [self executeNoDataStatement:@"INSERT INTO metadata VALUES(?, ?);" withArguments:@[ key, [metadata valueForKey:key] ]];
        }
        
        NSString *endTransaction = @"COMMIT;";
        success = [self executeNoDataQuery:endTransaction];
        if (!success)
        {
            return;
        }
        
        [self refreshMetadata];
    }
}

#pragma mark - sqlite stuff
- (NSString *)sqliteMetadataForName:(NSString *)name
{
    NSData *data = [self executeSingleColumnDataStatement:@"SELECT value FROM metadata WHERE name=?;" withArguments:@[name]];
    return data ? [[NSString alloc] initWithBytes:data.bytes length:data.length encoding:NSUTF8StringEncoding] : nil;
}

- (NSData *)sqliteDataForURL:(NSURL *)url
{
    return [self executeSingleColumnDataStatement:@"SELECT data FROM resources WHERE url=?;" withArguments:@[[url absoluteString]]];
}

- (BOOL)isAlreadyDataForURL:(NSURL *)url
{
    int count = [self executeSingleColumnIntStatement:@"SELECT COUNT(*) AS count FROM resources WHERE url=?;" withArguments:@[[url absoluteString]]];
    return count == 1;
}

- (BOOL)removeDataForURL:(NSURL *)url
{
    return [self executeNoDataStatement:@"DELETE FROM resources WHERE url=?" withArguments:@[[url absoluteString]]];
}

- (BOOL)setData:(NSData *)data forURL:(NSURL *)url
{
    NSString *queryString = @"INSERT OR REPLACE INTO resources (url, data) VALUES (?, ?);";
    return [self executeNoDataStatement:queryString withArguments:@[[url absoluteString], data]];
}

- (BOOL)executeNoDataQuery:(NSString *)query
{
    sqlite3 *db = [self databaseWithError:nil];
    if (db == NULL)
    {
        return NO;
    }

    const char *zSql = [query cStringUsingEncoding:NSUTF8StringEncoding];
    if (sqlite3_exec(db, zSql, NULL, NULL, NULL) != SQLITE_OK)
    {
        return NO;
    }
    
    return YES;
}

- (BOOL)executeNoDataStatement:(NSString *)query withArguments:(NSArray *)arguments
{
    sqlite3 *db = [self databaseWithError:nil];
    if (db == NULL)
    {
        return NO;
    }

    BOOL success = NO;
    sqlite3_stmt *ppStmt = NULL;
    const char *zSql = [query cStringUsingEncoding:NSUTF8StringEncoding];
    if (sqlite3_prepare(db, zSql, -1, &ppStmt, NULL) != SQLITE_OK)
    {
        goto cleanup;
    }
    
    if (![self bindArguments:arguments inStatement:ppStmt])
    {
        goto cleanup;
    }
    
    if (sqlite3_step(ppStmt) != SQLITE_DONE)
    {
        goto cleanup;
    }
    
    success = YES;
cleanup:
    sqlite3_finalize(ppStmt);
    return success;
}

- (id)executeSingleColumnObjectStatement:(NSString *)query withArguments:(NSArray *)arguments objectExtractor:(id (^)(sqlite3_stmt *))extractor
{
    sqlite3 *db = [self databaseWithError:nil];
    if (db == NULL)
    {
        return nil;
    }

    id object = nil;
    sqlite3_stmt *ppStmt = NULL;
    const char *zSql = [query cStringUsingEncoding:NSUTF8StringEncoding];
    if (sqlite3_prepare(db, zSql, -1, &ppStmt, NULL) != SQLITE_OK)
    {
        goto cleanup;
    }
    
    if (![self bindArguments:arguments inStatement:ppStmt])
    {
        goto cleanup;
    }
    
    int rc = sqlite3_step(ppStmt);
    if (rc == SQLITE_ROW)
    {
        // The query is supposed to be for exactly one column
        assert(sqlite3_column_count(ppStmt)==1);

        // Success!
        object = extractor(ppStmt);

        // Check if any more rows match
        if (sqlite3_step(ppStmt) != SQLITE_DONE)
        {
            // Oops, the query apparently matched more than one row (could also be an error)... not fatal, but not good.
            NSLog(@"Warning, query may match more than one row: %@",query);
        }
    }
    else if (rc == SQLITE_DONE)
    {
        // The query returned no results.
    }
    else if (rc == SQLITE_BUSY)
    {
        // This is bad, but theoretically it should never happen
        NSLog(@"sqlite3_step() returned SQLITE_BUSY. You probably have a concurrency problem.");
    }
    else
    {
        NSLog(@"sqlite3_step() produced an error: %s", sqlite3_errmsg(db));
    }
    
cleanup:
    sqlite3_finalize(ppStmt);
    return object;
}

- (BOOL)bindArguments:(NSArray *)arguments inStatement:(sqlite3_stmt *)ppStmt
{
    for (NSUInteger i = 0; i < [arguments count]; i++)
    {
        id argument = [arguments objectAtIndex:i];
        if ([argument isKindOfClass:[NSData class]])
        {
            NSData *argData = argument;
            const void *argBytes = [argData bytes];
            int argLength = (int)[argData length];
            if (sqlite3_bind_blob(ppStmt, (int)(i+1), argBytes, argLength, SQLITE_TRANSIENT) != SQLITE_OK)
            {
                return NO;
            }
        }
        else if ([argument isKindOfClass:[NSString class]])
        {
            NSString *argString = argument;
            const char *zArg = [argString cStringUsingEncoding:NSUTF8StringEncoding];
            if (sqlite3_bind_text(ppStmt, (int)(i+1), zArg, -1, SQLITE_TRANSIENT) != SQLITE_OK)
            {
                return NO;
            }
        }
        else
        {
            NSLog(@"Unexpected value for binding in sqlite query: %@", argument);
        }
    }
    return YES;
}

- (NSData *)executeSingleColumnDataStatement:(NSString *)query withArguments:(NSArray *)arguments
{
    return [self executeSingleColumnObjectStatement:query withArguments:arguments objectExtractor:^id(sqlite3_stmt *ppStmt) {
        return [NSData dataWithBytes:sqlite3_column_blob(ppStmt, 0) length:sqlite3_column_bytes(ppStmt, 0)];
    }];
}

- (int)executeSingleColumnIntStatement:(NSString *)query withArguments:(NSArray *)arguments
{
    NSNumber *number = [self executeSingleColumnObjectStatement:query withArguments:arguments objectExtractor:^id(sqlite3_stmt *ppStmt) {
        return [NSNumber numberWithInt:sqlite3_column_int(ppStmt, 0)];
    }];
    return [number intValue];
}

- (sqlite3 *)databaseWithError:(NSError **)error
{
    @synchronized(self)
    {
        if (_invalid || !_path)
        {
            [self closeDatabaseIfNeeded];
            return NULL;
        }
        
        // MBXMapKit expects libsqlite to have been compiled with SQLITE_THREADSAFE=2 (multi-thread mode), which means
        // that it can handle its own thread safety.
        // We need to open the sqlite database in serialized mode (SQLITE_OPEN_FULLMUTEX), and sqlite3_threadsafe()==2 guarantees that
        // that thread safety mode is available.
        // Some relevant sqlite documentation:
        // - http://sqlite.org/faq.html#q5
        // - http://www.sqlite.org/threadsafe.html
        // - http://www.sqlite.org/c3ref/threadsafe.html
        // - http://www.sqlite.org/c3ref/c_config_covering_index_scan.html#sqliteconfigmultithread
        //
        assert(sqlite3_threadsafe()==2);

        // Open the database read-write and multi-threaded. The slightly obscure c-style variable names here and below are
        // used to stay consistent with the sqlite documentaion. See http://sqlite.org/c3ref/open.html
        int rc;
        if (_db == NULL)
        {
            BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:_path];
            if (!fileExists)
            {
                [self createDatabaseAtPath:_path];
            }
            else
            {
                const char *filename = [_path cStringUsingEncoding:NSUTF8StringEncoding];
                rc = sqlite3_open_v2(filename, &_db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, NULL);
                if (rc)
                {
                    const char *errmsg = sqlite3_errmsg(_db);
                    NSLog(@"Can't open database %@: %s", _path, errmsg);
                    if (error != nil)
                    {
                        *error = [NSError mbx_errorCannotOpenOfflineMapDatabase:_path sqliteError:errmsg];
                    }
                    
                    sqlite3_close(_db);
                    _db = NULL;
                }
            }
        }
        return _db;
    }
}

- (void)createDatabaseAtPath:(NSString *)path
{
    @synchronized(self)
    {
        const char *filename = [_path cStringUsingEncoding:NSUTF8StringEncoding];
        int rc = sqlite3_open_v2(filename, &_db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, NULL);
        if (rc)
        {
            NSLog(@"Couldn't create database: %@: %s", _path, sqlite3_errmsg(_db));
            sqlite3_close(_db);
            _db = NULL;
            return;
        }

        NSMutableString *createQuery = [[NSMutableString alloc] init];
        [createQuery appendString:@"BEGIN TRANSACTION;\n"];
        [createQuery appendString:@"CREATE TABLE metadata (name TEXT UNIQUE, value TEXT);\n"];
        [createQuery appendString:@"CREATE TABLE resources (url TEXT UNIQUE, data BLOB);\n"];
        [createQuery appendString:@"COMMIT;"];
        BOOL querySuccess = [self executeNoDataQuery:createQuery];
        
        if (!querySuccess)
        {
            sqlite3_close(_db);
            _db = NULL;
            return;
        }
    }
}

- (void)closeDatabaseIfNeeded
{
    @synchronized(self)
    {
        if (_db != NULL)
        {
            sqlite3_close(_db);
            _db = NULL;
        }
    }
}

@end
