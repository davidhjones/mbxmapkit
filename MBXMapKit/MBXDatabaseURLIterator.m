//
//  MBXDatabaseURLIterator.m
//  MBXMapKit
//
//  Copyright (c) 2015 Mapbox. All rights reserved.
//

#import "MBXDatabaseURLIterator.h"

@implementation MBXDatabaseURLIterator
{
    NSRecursiveLock *_lock;
    sqlite3_stmt *_stmt;
    NSString *_thisString;
}

- (instancetype) initWithSQLiteStatement:(sqlite3_stmt *)stmt
{
    self = [super init];
    if (self) {
        _stmt = stmt;
    }
    _lock = [[NSRecursiveLock alloc] init];
    [self moveToNext];
    return self;
}

- (BOOL) hasNext
{
    [_lock lock];
    BOOL toReturn = !!_thisString;
    [_lock unlock];
    return toReturn;
}

- (NSURL *) next
{
    [_lock lock];
    NSString *returnString = _thisString;
    if (returnString != nil)
    {
        [self moveToNext];
    }
    [_lock unlock];

    if (returnString != nil)
    {
        return [NSURL URLWithString:returnString];
    }
    else
    {
        return nil;
    }
}

- (void) moveToNext
{
    [_lock lock];
    if (_stmt) {
        int ret = sqlite3_step(_stmt);
        if (ret == SQLITE_ROW && sqlite3_column_count(_stmt) == 1) {
            _thisString = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(_stmt, 0)];
        } else {
            [self releaseResources];
        }
    }
    [_lock unlock];
}

- (void) releaseResources
{
    [_lock lock];
    _thisString = nil;
    if (_stmt) {
        sqlite3_finalize(_stmt);
        _stmt = NULL;
    }
    [_lock unlock];
}

@end
