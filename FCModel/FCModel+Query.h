//
//  FCModel+Query.h
//  FCModel
//
//  Created by Jordan Kay on 1/11/14.
//  Copyright (c) 2014 Jordan Kay. All rights reserved.
//

#import "FCModel.h"
#import "FMDatabase.h"

@interface FCModel (Query)

/**
 * SELECTs
 * - `keyed` variants return dictionaries keyed by each instance’s primary-key value.
 * - `FromResultSet` variants will iterate through the supplied result set, but the caller is still responsible for closing it.
 * - Optional query placeholders:
 *      $T  - This model’s table name
 *      $PK - This model’s primary-key field name
 */
+ (NSArray *)allInstances;
+ (NSDictionary *)keyedAllInstances;

+ (NSArray *)instancesFromResultSet:(FMResultSet *)rs;
+ (NSDictionary *)keyedInstancesFromResultSet:(FMResultSet *)rs;
+ (instancetype)firstInstanceFromResultSet:(FMResultSet *)rs;

+ (instancetype)firstInstanceWhere:(NSString *)queryAfterWHERE, ...;
+ (NSArray *)instancesWhere:(NSString *)queryAfterWHERE, ...;
+ (NSDictionary *)keyedInstancesWhere:(NSString *)queryAfterWHERE, ...;

+ (instancetype)firstInstanceOrderedBy:(NSString *)queryAfterORDERBY, ...;
+ (NSArray *)instancesOrderedBy:(NSString *)queryAfterORDERBY, ...;

// Fetch a set of primary keys, i.e. `WHERE key IN (...)`
+ (NSArray *)instancesWithPrimaryKeyValues:(NSArray *)primaryKeyValues;
+ (NSDictionary *)keyedInstancesWithPrimaryKeyValues:(NSArray *)primaryKeyValues;

// Return data instead of completed objects (convenient accessors to FCModel’s database queue with $T/$PK parsing)
+ (NSArray *)resultDictionariesFromQuery:(NSString *)query, ...;
+ (NSArray *)firstColumnArrayFromQuery:(NSString *)query, ...;
+ (id)firstValueFromQuery:(NSString *)query, ...;

@end
