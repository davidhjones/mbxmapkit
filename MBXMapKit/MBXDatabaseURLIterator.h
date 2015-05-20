//
//  MBXDatabaseURLIterator.h
//  MBXMapKit
//
//  Copyright (c) 2015 Mapbox. All rights reserved.
//

@import Foundation;

#include <sqlite3.h>

@interface MBXDatabaseURLIterator : NSObject

- (instancetype) initWithSQLite3Statement:(sqlite3_stmt *)stmt;

- (BOOL) hasNext;
- (NSString *) next;

@end
