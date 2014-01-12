//
//  FCModel+Private.h
//  Mantle
//
//  Created by Jordan Kay on 1/11/14.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import "FCModel.h"

@class FMDatabase;

@interface FCModel (Private)

+ (instancetype)instanceWithPrimaryKey:(id)primaryKeyValue databaseRowValues:(NSDictionary *)fieldValues createIfNonexistent:(BOOL)create;
+ (NSString *)expandQuery:(NSString *)query;
+ (void)queryFailedInDatabase:(FMDatabase *)db;
+ (void)removeAllInstances;

@end
