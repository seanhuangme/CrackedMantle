//
//  FCModelDatabaseManager.m
//  Mantle
//
//  Created by Jordan Kay on 1/11/14.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

#import <objc/runtime.h>
#import "FCModel.h"
#import "FCModel+Private.h"
#import "FMDatabase.h"
#import "FMDatabase+Private.h"
#import "FMDatabaseQueue.h"
#import "FCDatabaseManager.h"

static FMDatabaseQueue *databaseQueue;
static NSDictionary *fieldInfo;
static NSDictionary *primaryKeyFieldName;

@implementation FCDatabaseManager

+ (void)openDatabaseAtPath:(NSString *)path withSchemaBuilder:(void (^)(FMDatabase *db, int *schemaVersion))schemaBuilder
{
	[self openDatabaseAtPath:path withDatabaseInitializer:nil schemaBuilder:schemaBuilder];
}

+ (void)openDatabaseAtPath:(NSString *)path withDatabaseInitializer:(void (^)(FMDatabase *db))databaseInitializer schemaBuilder:(void (^)(FMDatabase *db, int *schemaVersion))schemaBuilder
{
	databaseQueue = [FMDatabaseQueue databaseQueueWithPath:path];
	NSMutableDictionary *mutableFieldInfo = [NSMutableDictionary dictionary];
	NSMutableDictionary *mutablePrimaryKeyFieldName = [NSMutableDictionary dictionary];

	[databaseQueue inDatabase:^(FMDatabase *db) {
		if (databaseInitializer) databaseInitializer(db);

		int startingSchemaVersion = 0;
		FMResultSet *rs = [db executeQuery:@"SELECT value FROM _FCModelMetadata WHERE key = 'schema_version'"];
		if ([rs next]) {
			startingSchemaVersion = [rs intForColumnIndex:0];
		} else {
			[db executeUpdate:@"CREATE TABLE _FCModelMetadata (key TEXT, value TEXT, PRIMARY KEY (key))"];
			[db executeUpdate:@"INSERT INTO _FCModelMetadata VALUES ('schema_version', 0)"];
		}
		[rs close];

		int newSchemaVersion = startingSchemaVersion;
		schemaBuilder(db, &newSchemaVersion);
		if (newSchemaVersion != startingSchemaVersion) {
			[db executeUpdate:@"UPDATE _FCModelMetadata SET value = ? WHERE key = 'schema_version'", @(newSchemaVersion)];
		}

		// Read schema for field names and primary keys
		FMResultSet *tablesRS = [db executeQuery:
								 @"SELECT DISTINCT tbl_name FROM (SELECT * FROM sqlite_master UNION ALL SELECT * FROM sqlite_temp_master) WHERE type != 'meta' AND name NOT LIKE 'sqlite_%' AND name != '_FCModelMetadata'"
								 ];
		while ([tablesRS next]) {
			NSString *tableName = [tablesRS stringForColumnIndex:0];
			Class tableModelClass = NSClassFromString(tableName);
			if (!tableModelClass || ![tableModelClass isSubclassOfClass:[FCModel class]]) continue;

			NSString *primaryKeyName = nil;
			BOOL isMultiColumnPrimaryKey = NO;
			NSMutableDictionary *fields = [NSMutableDictionary dictionary];
			FMResultSet *columnsRS = [db executeQuery:[NSString stringWithFormat: @"PRAGMA table_info('%@')", tableName]];
			while ([columnsRS next]) {
				NSString *fieldName = [columnsRS stringForColumnIndex:1];
				if (NULL == class_getProperty(tableModelClass, [fieldName UTF8String])) {
					NSLog(@"[FCModel] ignoring column %@.%@, no matching model property", tableName, fieldName);
					continue;
				}

				int isPK = [columnsRS intForColumnIndex:5];
				if (isPK == 1) {
					primaryKeyName = fieldName;
				} else if (isPK > 1) {
					isMultiColumnPrimaryKey = YES;
				}

				NSString *fieldType = [columnsRS stringForColumnIndex:2];
				FCModelFieldInfo *info = [FCModelFieldInfo new];
				info.nullAllowed = ![columnsRS boolForColumnIndex:3];

				// Type-parsing algorithm from SQLite's column-affinity rules: http://www.sqlite.org/datatype3.html
				// except the addition of BOOL as its own recognized type
				if ([fieldType rangeOfString:@"INT"].location != NSNotFound) {
					info.type = FCFieldTypeInteger;
					if ([fieldType rangeOfString:@"UNSIGNED"].location != NSNotFound) {
						info.defaultValue = [NSNumber numberWithUnsignedLongLong:[columnsRS unsignedLongLongIntForColumnIndex:4]];
					} else {
						info.defaultValue = [NSNumber numberWithLongLong:[columnsRS longLongIntForColumnIndex:4]];
					}
				} else if ([fieldType rangeOfString:@"BOOL"].location != NSNotFound) {
					info.type = FCFieldTypeBool;
					info.defaultValue = [NSNumber numberWithBool:[columnsRS boolForColumnIndex:4]];
				} else if (
						   [fieldType rangeOfString:@"TEXT"].location != NSNotFound ||
						   [fieldType rangeOfString:@"CHAR"].location != NSNotFound ||
						   [fieldType rangeOfString:@"CLOB"].location != NSNotFound
						   ) {
					info.type = FCFieldTypeText;
					info.defaultValue = [[[columnsRS stringForColumnIndex:4]
										  stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"'"]]
										 stringByReplacingOccurrencesOfString:@"''" withString:@"'"
										 ];
				} else if (
						   [fieldType rangeOfString:@"REAL"].location != NSNotFound ||
						   [fieldType rangeOfString:@"FLOA"].location != NSNotFound ||
						   [fieldType rangeOfString:@"DOUB"].location != NSNotFound
						   ) {
					info.type = FCFieldTypeDouble;
					info.defaultValue = [NSNumber numberWithDouble:[columnsRS doubleForColumnIndex:4]];
				} else {
					info.type = FCFieldTypeOther;
					info.defaultValue = nil;
				}

				if (isPK) {
					info.defaultValue = nil;
				} else if ([[columnsRS stringForColumnIndex:4] isEqualToString:@"NULL"]) {
					info.defaultValue = nil;
				}

				[fields setObject:info forKey:fieldName];
			}

			if (!primaryKeyName || isMultiColumnPrimaryKey) {
				[[NSException exceptionWithName:NSInvalidArgumentException reason:[NSString stringWithFormat:@"FCModel tables must have a single-column primary key, not found in %@", tableName] userInfo:nil] raise];
			}

			id classKey = tableModelClass;
			[mutableFieldInfo setObject:fields forKey:classKey];
			[mutablePrimaryKeyFieldName setObject:primaryKeyName forKey:classKey];
			[columnsRS close];
		}
		[tablesRS close];

		fieldInfo = [mutableFieldInfo copy];
		primaryKeyFieldName = [mutablePrimaryKeyFieldName copy];
	}];
}

// Note: use of +closeDatabase is unsupported for apps - it's purely to enable unit testing
+ (void)closeDatabase
{
	[databaseQueue close];
	databaseQueue = nil;
	primaryKeyFieldName = nil;
	fieldInfo = nil;
	[FCModel removeAllInstances];
}

+ (FMDatabaseQueue *)databaseQueue
{
	return databaseQueue;
}

+ (NSDictionary *)fieldInfo
{
	return fieldInfo;
}

+ (NSDictionary *)primaryKeyFieldName
{
	return primaryKeyFieldName;
}

+ (void)dataWasUpdatedExternally
{
	[NSNotificationCenter.defaultCenter postNotificationName:FCModelReloadNotification object:nil userInfo:@{FCModelClassKey: self}];
}

+ (NSError *)executeUpdateQuery:(NSString *)query, ...
{
	va_list args;
	va_list *foolTheStaticAnalyzer = &args;
	va_start(args, query);

	__block BOOL success = NO;
	__block NSError *error = nil;
	[databaseQueue inDatabase:^(FMDatabase *db) {
		success = [db executeUpdate:[FCModel expandQuery:query] error:nil withArgumentsInArray:nil orDictionary:nil orVAList:*foolTheStaticAnalyzer];
		if (!success) {
			error = [db.lastError copy];
		}
	}];

	va_end(args);
	if (success) {
		[self dataWasUpdatedExternally];
	}
	return error;
}

@end
