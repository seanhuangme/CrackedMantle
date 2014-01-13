//
//  FCModelDatabaseManager.h
//  Mantle
//
//  Created by Jordan Kay on 1/11/14.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

@class FMDatabase;
@class FMDatabaseQueue;

@interface FCDatabaseManager : NSObject

+ (void)openDatabaseAtPath:(NSString *)path withSchemaBuilder:(void (^)(FMDatabase *db, int *schemaVersion))schemaBuilder;
+ (void)openDatabaseAtPath:(NSString *)path withDatabaseInitializer:(void (^)(FMDatabase *db))databaseInitializer schemaBuilder:(void (^)(FMDatabase *db, int *schemaVersion))schemaBuilder;

// Feel free to operate on the same database queue with your own queries (IMPORTANT: READ THE NEXT METHOD DEFINITION)
+ (FMDatabaseQueue *)databaseQueue;

+ (NSDictionary *)fieldInfo;
+ (NSDictionary *)primaryKeyFieldName;

/**
 * Call if you perform INSERT/UPDATE/DELETE outside of the `instance*` or `save` methods.
 * This will cause any instances in existence to reload their data from the database.
 *
 * - Call on a subclass to reload all instances of that model and any subclasses.
 * - Call on FCModel to reload all instances of ALL models.
 */
+ (void)dataWasUpdatedExternally;

/**
 * Or use this convenience method, which calls dataWasUpdatedExternally automatically and offers $T/$PK parsing.
 * If you don’t know which tables will be affected, or if it will affect more than one, call on FCModel, not a subclass.
 * Only call on a subclass if only that model’s table will be affected.
 */
+ (NSError *)executeUpdateQuery:(NSString *)query, ...;

@end
