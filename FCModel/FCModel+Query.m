//
//  FCModel+Query.m
//  FCModel
//
//  Created by Jordan Kay on 1/11/14.
//  Copyright (c) 2014 Jordan Kay. All rights reserved.
//

#import "FCModel.h"
#import "FCModel+Private.h"
#import "FCModel+Query.h"
#import "FCModelDatabaseManager.h"
#import "FMDatabase+Private.h"

@implementation FCModel (Query)

+ (NSError *)executeUpdateQuery:(NSString *)query, ...
{
	va_list args;
	va_list *foolTheStaticAnalyzer = &args;
	va_start(args, query);

	__block BOOL success = NO;
	__block NSError *error = nil;
	[[FCModelDatabaseManager databaseQueue] inDatabase:^(FMDatabase *db) {
		success = [db executeUpdate:[self expandQuery:query] error:nil withArgumentsInArray:nil orDictionary:nil orVAList:*foolTheStaticAnalyzer];
		if (!success) {
			error = [db.lastError copy];
		}
	}];

	va_end(args);
	if (success) {
		[FCModelDatabaseManager dataWasUpdatedExternally];
	}
	return error;
}

+ (id)_instancesWhere:(NSString *)query andArgs:(va_list)args orArgsArray:(NSArray *)argsArray orResultSet:(FMResultSet *)existingResultSet onlyFirst:(BOOL)onlyFirst keyed:(BOOL)keyed
{
	NSMutableArray *instances;
	NSMutableDictionary *keyedInstances;
	__block FCModel *instance;

	if (!onlyFirst) {
		if (keyed) keyedInstances = [NSMutableDictionary dictionary];
		else instances = [NSMutableArray array];
	}

	void (^processResult)(FMResultSet *, BOOL *) = ^(FMResultSet *s, BOOL *stop){
		NSDictionary *rowDictionary = s.resultDictionary;
		NSDictionary *primaryKeyFieldName = [FCModelDatabaseManager primaryKeyFieldName];
		instance = [self instanceWithPrimaryKey:rowDictionary[primaryKeyFieldName[self]] databaseRowValues:rowDictionary createIfNonexistent:NO];
		if (onlyFirst) {
			*stop = YES;
			return;
		}
		if (keyed) {
			[keyedInstances setValue:instance forKey:[instance primaryKey]];
		} else {
			[instances addObject:instance];
		}
	};

	if (existingResultSet) {
		BOOL stop = NO;
		while (!stop && [existingResultSet next]) {
			processResult(existingResultSet, &stop);
		}
	} else {
		[[FCModelDatabaseManager databaseQueue] inDatabase:^(FMDatabase *db) {
			NSString *queryString = query ? [self expandQuery:[@"SELECT * FROM \"$T\" WHERE " stringByAppendingString:query]]: [self expandQuery:@"SELECT * FROM \"$T\""];
			FMResultSet *s = [db executeQuery:queryString withArgumentsInArray:argsArray orDictionary:nil orVAList:args];
			if (!s) {
				[self queryFailedInDatabase:db];
			}

			BOOL stop = NO;
			while (!stop && [s next]) {
				processResult(s, &stop);
			}
			[s close];
		}];
	}

	return onlyFirst ? instance: (keyed ? keyedInstances: instances);
}

+ (NSArray *)instancesFromResultSet:(FMResultSet *)rs
{
	return [self _instancesWhere:nil andArgs:NULL orArgsArray:nil orResultSet:rs onlyFirst:NO keyed:NO];
}

+ (NSDictionary *)keyedInstancesFromResultSet:(FMResultSet *)rs
{
	return [self _instancesWhere:nil andArgs:NULL orArgsArray:nil orResultSet:rs onlyFirst:NO keyed:YES];
}

+ (instancetype)firstInstanceFromResultSet:(FMResultSet *)rs
{
	return [self _instancesWhere:nil andArgs:NULL orArgsArray:nil orResultSet:rs onlyFirst:YES keyed:NO];
}

+ (instancetype)firstInstanceWhere:(NSString *)query, ...
{
	va_list args;
	va_start(args, query);
	id result = [self _instancesWhere:query andArgs:args orArgsArray:nil orResultSet:nil onlyFirst:YES keyed:NO];
	va_end(args);
	return result;
}

+ (NSArray *)instancesWhere:(NSString *)query, ...
{
	va_list args;
	va_start(args, query);
	NSArray *results = [self _instancesWhere:query andArgs:args orArgsArray:nil orResultSet:nil onlyFirst:NO keyed:NO];
	va_end(args);
	return results;
}

+ (NSDictionary *)keyedInstancesWhere:(NSString *)query, ...
{
	va_list args;
	va_start(args, query);
	NSDictionary *results = [self _instancesWhere:query andArgs:args orArgsArray:nil orResultSet:nil onlyFirst:NO keyed:NO];
	va_end(args);
	return results;
}

+ (instancetype)firstInstanceOrderedBy:(NSString *)query, ...
{
	va_list args;
	va_start(args, query);
	id result = [self _instancesWhere:[@"1 ORDER BY " stringByAppendingString:query] andArgs:args orArgsArray:nil orResultSet:nil onlyFirst:YES keyed:NO];
	va_end(args);
	return result;
}

+ (NSArray *)instancesOrderedBy:(NSString *)query, ...
{
	va_list args;
	va_start(args, query);
	id result = [self _instancesWhere:[@"1 ORDER BY " stringByAppendingString:query] andArgs:args orArgsArray:nil orResultSet:nil onlyFirst:NO keyed:NO];
	va_end(args);
	return result;
}

+ (NSArray *)allInstances
{
	return [self _instancesWhere:nil andArgs:NULL orArgsArray:nil orResultSet:nil onlyFirst:NO keyed:NO];
}

+ (NSDictionary *)keyedAllInstances
{
	return [self _instancesWhere:nil andArgs:NULL orArgsArray:nil orResultSet:nil onlyFirst:NO keyed:YES];
}

+ (NSArray *)instancesWithPrimaryKeyValues:(NSArray *)primaryKeyValues
{
	if ([primaryKeyValues count] == 0) {
		return @[];
	}

	__block NSUInteger maxParameterCount = 0;
	[[FCModelDatabaseManager databaseQueue] inDatabase:^(FMDatabase *db) {
		maxParameterCount = sqlite3_limit(db.sqliteHandle, SQLITE_LIMIT_VARIABLE_NUMBER, -1);
	}];

	__block NSArray *allFoundInstances = nil;
	NSMutableArray *valuesArray = [NSMutableArray arrayWithCapacity:MIN([primaryKeyValues count], maxParameterCount)];
	NSDictionary *primaryKeyFieldName = [FCModelDatabaseManager primaryKeyFieldName];
	NSMutableString *whereClause = [NSMutableString stringWithFormat:@"%@ IN (", primaryKeyFieldName[self]];

	void (^fetchChunk)() = ^{
		if ([valuesArray count] == 0) {
			return;
		}
		[whereClause appendString:@")"];
		NSArray *newInstancesThisChunk = [self _instancesWhere:whereClause andArgs:NULL orArgsArray:valuesArray orResultSet:nil onlyFirst:NO keyed:NO];
		allFoundInstances = allFoundInstances ? [allFoundInstances arrayByAddingObjectsFromArray:newInstancesThisChunk]: newInstancesThisChunk;

		// reset state for next chunk
		[whereClause deleteCharactersInRange:NSMakeRange(7, whereClause.length - 7)];
		[valuesArray removeAllObjects];
	};

	for (id pkValue in primaryKeyValues) {
		[whereClause appendString:([valuesArray count] ? @",?": @"?")];
		[valuesArray addObject:pkValue];
		if ([valuesArray count] == maxParameterCount) {
			fetchChunk();
		}
	}
	fetchChunk();

	return allFoundInstances;
}

+ (NSDictionary *)keyedInstancesWithPrimaryKeyValues:(NSArray *)primaryKeyValues
{
	NSArray *instances = [self instancesWithPrimaryKeyValues:primaryKeyValues];
	NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithCapacity:[instances count]];
	for (FCModel *instance in instances) {
		[dictionary setObject:instance forKey:instance.primaryKey];
	}
	return dictionary;
}

+ (NSArray *)firstColumnArrayFromQuery:(NSString *)query, ...
{
	NSMutableArray *columnArray = [NSMutableArray array];
	va_list args;
	va_list *foolTheStaticAnalyzer = &args;
	va_start(args, query);
	[[FCModelDatabaseManager databaseQueue] inDatabase:^(FMDatabase *db) {
		FMResultSet *s = [db executeQuery:[self expandQuery:query] withArgumentsInArray:nil orDictionary:nil orVAList:*foolTheStaticAnalyzer];
		if (!s) {
			[self queryFailedInDatabase:db];
		}
		while ([s next]) {
			[columnArray addObject:[s objectForColumnIndex:0]];
		}
		[s close];
	}];
	va_end(args);
	return columnArray;
}

+ (NSArray *)resultDictionariesFromQuery:(NSString *)query, ...
{
	NSMutableArray *rows = [NSMutableArray array];
	va_list args;
	va_list *foolTheStaticAnalyzer = &args;
	va_start(args, query);
	[[FCModelDatabaseManager databaseQueue] inDatabase:^(FMDatabase *db) {
		FMResultSet *s = [db executeQuery:[self expandQuery:query] withArgumentsInArray:nil orDictionary:nil orVAList:*foolTheStaticAnalyzer];
		if (!s) {
			[self queryFailedInDatabase:db];
		}
		while ([s next]) {
			[rows addObject:s.resultDictionary];
		}
		[s close];
	}];
	va_end(args);
	return rows;
}

+ (id)firstValueFromQuery:(NSString *)query, ...
{
	__block id firstValue = nil;
	va_list args;
	va_list *foolTheStaticAnalyzer = &args;
	va_start(args, query);
	[[FCModelDatabaseManager databaseQueue] inDatabase:^(FMDatabase *db) {
		FMResultSet *s = [db executeQuery:[self expandQuery:query] withArgumentsInArray:nil orDictionary:nil orVAList:*foolTheStaticAnalyzer];
		if (!s) {
			[self queryFailedInDatabase:db];
		}
		if ([s next]) {
			firstValue = [[s objectForColumnIndex:0] copy];
		}
		[s close];
	}];
	va_end(args);
	return firstValue;
}

@end
