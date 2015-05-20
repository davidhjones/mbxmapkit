//
//  MBXDatabaseURLIterator.m
//  MBXMapKit
//
//  Copyright (c) 2015 Mapbox. All rights reserved.
//

#import "MBXDatabaseURLIterator.h"

@implementation MBXDatabaseURLIterator
{
    sqlite3_stmt *_stmt;
    NSString *_thisString;
}

- (instancetype) initWithSQLite3Statement:(sqlite3_stmt *)stmt
{
    self = [super init];
    if (self) {
        _stmt = stmt;
    }
    [self moveToNext];
    return self;
}

- (BOOL) hasNext
{
    return !!_thisString;
}

- (NSString *) next
{
    NSString *returnString = _thisString;
    [self moveToNext];
    return returnString;
}

- (void) moveToNext
{
    if (_stmt) {
        int ret = sqlite3_step(_stmt);
        if (ret == SQLITE_ROW && sqlite3_column_count(_stmt) == 1) {
            _thisString = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(_stmt, 0)];
        } else {
            _thisString = NULL;
            sqlite3_finalize(_stmt);
            _stmt = NULL;
        }
    }
}

@end
