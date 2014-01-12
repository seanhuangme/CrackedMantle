//
//  FCModel.m
//
//  Created by Marco Arment on 7/18/13.
//  Copyright (c) 2013 Marco Arment. All rights reserved.
//

#import <objc/runtime.h>
#import <sqlite3.h>
#import <string.h>
#import "FCModel.h"
#import "FCModelDatabaseManager.h"
#import "FMDatabase.h"
#import "FMDatabaseQueue.h"

NSString *const FCModelInsertNotification = @"FCModelInsertNotification";
NSString *const FCModelUpdateNotification = @"FCModelUpdateNotification";
NSString *const FCModelDeleteNotification = @"FCModelDeleteNotification";
NSString *const FCModelReloadNotification = @"FCModelReloadNotification";
NSString *const FCModelSaveNotification = @"FCModelSaveNotification";
NSString *const FCModelInstanceKey = @"FCModelInstanceKey";
NSString *const FCModelClassKey = @"class";

static NSMutableDictionary *instances;
static dispatch_semaphore_t instancesReadLock;

@implementation FCModelFieldInfo

- (NSString *)description
{
	return [NSString stringWithFormat:@"<FCFieldInfo {%@ %@, default=%@}>",
		(_type == FCFieldTypeText ? @"text": (_type == FCFieldTypeInteger ? @"integer": (_type == FCFieldTypeDouble ? @"double": (_type == FCFieldTypeBool ? @"bool": @"other")))),
		_nullAllowed ? @"NULL": @"NOT NULL",
		_defaultValue ? _defaultValue: @"NULL"
	];
}

@end

@interface FCModel ()

@property (nonatomic, strong) NSMutableDictionary *changedProperties;
@property (nonatomic) NSError *lastSQLiteError;
@property (nonatomic) BOOL existsInDatabase;
@property (nonatomic, getter = isPrimaryKeySet) BOOL primaryKeySet;
@property (nonatomic, getter = isDeleted) BOOL deleted;
@property (nonatomic, getter = isPrimaryKeyLocked) BOOL primaryKeyLocked;

@end

@implementation FCModel

+ (instancetype)instanceWithPrimaryKey:(id)primaryKeyValue
{
	return [self instanceWithPrimaryKey:primaryKeyValue databaseRowValues:nil createIfNonexistent:YES];
}

+ (instancetype)instanceWithPrimaryKey:(id)primaryKeyValue createIfNonexistent:(BOOL)create
{
	return [self instanceWithPrimaryKey:primaryKeyValue databaseRowValues:nil createIfNonexistent:create];
}

+ (instancetype)instanceWithPrimaryKey:(id)primaryKeyValue databaseRowValues:(NSDictionary *)fieldValues createIfNonexistent:(BOOL)create
{
	if (!primaryKeyValue || primaryKeyValue == [NSNull null]) {
		return [self new];
	}
	[self _uniqueMapInit];

	FCModel *instance;
	dispatch_semaphore_wait(instancesReadLock, DISPATCH_TIME_FOREVER);
	NSMapTable *classCache = instances[self];
	if (!classCache) {
		classCache = instances[(id) self] = [NSMapTable strongToWeakObjectsMapTable];
	}
	instance = [classCache objectForKey:primaryKeyValue];
	dispatch_semaphore_signal(instancesReadLock);

	if (!instance) {
		// Not in memory yet. Check DB.
		instance = fieldValues ? [[self alloc] initWithFieldValues:fieldValues existsInDatabaseAlready:YES] : [self _instanceFromDatabaseWithPrimaryKey:primaryKeyValue];
		if (!instance && create) {
			// Create new with this key.
			NSDictionary *primaryKeyFieldName = [FCModelDatabaseManager primaryKeyFieldName];
			instance = [[self alloc] initWithFieldValues:@{primaryKeyFieldName[self]: primaryKeyValue} existsInDatabaseAlready:NO];
		}

		if (instance) {
			dispatch_semaphore_wait(instancesReadLock, DISPATCH_TIME_FOREVER);
			FCModel *racedInstance = [classCache objectForKey:primaryKeyValue];
			if (racedInstance) {
				instance = racedInstance;
			} else {
				[classCache setObject:instance forKey:primaryKeyValue];
			}
			dispatch_semaphore_signal(instancesReadLock);
		}
	}

	return instance;
}

+ (void)saveAll
{
	[NSNotificationCenter.defaultCenter postNotificationName:FCModelSaveNotification object:nil userInfo:@{FCModelClassKey: self}];
}

+ (NSString *)expandQuery:(NSString *)query
{
	if (self == FCModel.class) {
		return query;
	}

	NSDictionary *primaryKeyFieldName = [FCModelDatabaseManager primaryKeyFieldName];
	query = [query stringByReplacingOccurrencesOfString:@"$PK" withString:primaryKeyFieldName[self]];
	return [query stringByReplacingOccurrencesOfString:@"$T" withString:NSStringFromClass(self)];
}

+ (void)queryFailedInDatabase:(FMDatabase *)db
{
	[[NSException exceptionWithName:@"FCModelSQLiteException" reason:db.lastErrorMessage userInfo:nil] raise];
}

+ (void)removeAllInstances
{
	[instances removeAllObjects];
}

- (instancetype)initWithFieldValues:(NSDictionary *)fieldValues existsInDatabaseAlready:(BOOL)existsInDB
{
	if (self = [super init]) {
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(_reload:) name:FCModelReloadNotification object:nil];
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(_saveByNotification:) name:FCModelSaveNotification object:nil];

		self.existsInDatabase = existsInDB;
		self.deleted = NO;
		self.primaryKeyLocked = NO;
		self.primaryKeySet = self.existsInDatabase;

		NSDictionary *fieldInfo = [FCModelDatabaseManager fieldInfo];
		[fieldInfo[self.class] enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
			FCModelFieldInfo *info = (FCModelFieldInfo *)obj;
			if (info.defaultValue) [self setValue:info.defaultValue forKey:key];
			[self addObserver:self forKeyPath:key options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld) context:NULL];
		}];

		[fieldValues enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
			[self _decodeFieldValue:obj intoPropertyName:key];
		}];

		self.primaryKeyLocked = YES;
		self.changedProperties = [NSMutableDictionary dictionary];
	}
	return self;
}

- (id)valueOfFieldName:(NSString *)fieldName byResolvingReloadConflictWithDatabaseValue:(id)valueInDatabase
{
	// A very simple subclass implementation could just always accept the locally modified value:
	//	 return [self valueForKeyPath:fieldName]
	//
	// ...or always accept the database value:
	//	 return valueInDatabase;
	//
	// But this is a decision that you should really make knowingly and deliberately in each case.

	[[NSException exceptionWithName:@"FCReloadConflict" reason:
	  [NSString stringWithFormat:@"%@ ID %@ cannot resolve reload conflict for \"%@\"", NSStringFromClass(self.class), self.primaryKey, fieldName]
						   userInfo:nil] raise];
	return nil;
}

- (FCModelSaveResult)revertUnsavedChanges
{
	if ([self.changedProperties count] == 0) return FCModelSaveNoChanges;
	[self.changedProperties enumerateKeysAndObjectsUsingBlock:^(NSString *fieldName, id oldValue, BOOL *stop) {
		[self setValue:(oldValue == [NSNull null] ? nil: oldValue) forKeyPath:fieldName];
	}];
	[self.changedProperties removeAllObjects];
	return FCModelSaveSucceeded;
}

- (FCModelSaveResult)revertUnsavedChangeToFieldName:(NSString *)fieldName
{
	id oldValue = self.changedProperties[fieldName];
	if (oldValue) {
		[self setValue:(oldValue == [NSNull null] ? nil: oldValue) forKeyPath:fieldName];
		[self.changedProperties removeObjectForKey:fieldName];
		return FCModelSaveSucceeded;
	} else {
		return FCModelSaveNoChanges;
	}
}

- (FCModelSaveResult)save
{
	if (self.isDeleted) {
		[[NSException exceptionWithName:@"FCAttemptToSaveAfterDelete" reason:@"Cannot save deleted instance" userInfo:nil] raise];
	}
	BOOL dirty = [self.changedProperties count] > 0;
	if (!dirty && self.existsInDatabase) {
		return FCModelSaveNoChanges;
	}

	BOOL update = self.existsInDatabase;
	NSArray *columnNames;
	NSMutableArray *values;

	NSString *tableName = NSStringFromClass(self.class);
	NSDictionary *primaryKeyFieldName = [FCModelDatabaseManager primaryKeyFieldName];
	NSString *pkName = primaryKeyFieldName[self.class];
	id primaryKey = self.isPrimaryKeySet ? [self _encodedValueForFieldName:pkName]: nil;
	if (!primaryKey) {
		NSAssert1(!update, @"Cannot update %@ without primary key", NSStringFromClass(self.class));
		primaryKey = [NSNull null];
	}

	NSDictionary *fieldInfo;
	fieldInfo = [self _validateNotNULLColumnsForTableName:tableName];

	if (update) {
		if (![self shouldUpdate]) {
			[self saveWasRefused];
			return FCModelSaveRefused;
		}
		columnNames = [self.changedProperties allKeys];
	} else {
		if (![self shouldInsert]) {
			[self saveWasRefused];
			return FCModelSaveRefused;
		}
		NSMutableSet *columnNamesMinusPK = [[NSSet setWithArray:[fieldInfo[self.class] allKeys]] mutableCopy];
		[columnNamesMinusPK removeObject:pkName];
		columnNames = [columnNamesMinusPK allObjects];
	}

	values = [NSMutableArray arrayWithCapacity:[columnNames count]];
	[columnNames enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		[values addObject:[self _encodedValueForFieldName:obj]];
	}];
	[values addObject:primaryKey];

	NSString *query = [self _queryForPrimaryKeyName:pkName tableName:tableName columnNames:columnNames update:update];
	return [self _finishSavingValues:values withQuery:query primaryKey:primaryKey update:update];
}

- (FCModelSaveResult)delete
{
	if (self.isDeleted) {
		return FCModelSaveNoChanges;
	}
	if (![self shouldDelete]) {
		[self saveWasRefused];
		return FCModelSaveRefused;
	}

	__block BOOL success = NO;
	[[FCModelDatabaseManager databaseQueue] inDatabase:^(FMDatabase *db) {
		NSString *query = [self.class expandQuery:@"DELETE FROM \"$T\" WHERE \"$PK\" = ?"];
		success = [db executeUpdate:query, [self primaryKey]];
		self.lastSQLiteError = success ? nil: db.lastError;
	}];

	if (!success) {
		[self saveDidFail];
		return FCModelSaveFailed;
	}

	self.deleted = YES;
	self.existsInDatabase = NO;
	[self didDelete];
	[NSNotificationCenter.defaultCenter postNotificationName:FCModelDeleteNotification object:self.class userInfo:@{FCModelInstanceKey: self}];
	[self _removeUniqueInstance];

	return FCModelSaveSucceeded;
}

- (id)serializedDatabaseRepresentationOfValue:(id)instanceValue forPropertyNamed:(NSString *)propertyName
{
	if ([instanceValue isKindOfClass:NSArray.class] || [instanceValue isKindOfClass:NSDictionary.class]) {
		NSError *error = nil;
		NSData *bplist = [NSPropertyListSerialization dataWithPropertyList:instanceValue format:NSPropertyListBinaryFormat_v1_0 options:NSPropertyListImmutable error:&error];
		if (error) {
			[[NSException exceptionWithName:NSInvalidArgumentException reason:[NSString stringWithFormat:@"Cannot serialize %@ to plist for %@.%@: %@", NSStringFromClass(((NSObject *)instanceValue).class), NSStringFromClass(self.class), propertyName, error.localizedDescription] userInfo:nil] raise];
		}
		return bplist;
	} else if ([instanceValue isKindOfClass:NSURL.class]) {
		return [(NSURL *)instanceValue absoluteString];
	} else if ([instanceValue isKindOfClass:NSDate.class]) {
		return [NSNumber numberWithDouble:[(NSDate *)instanceValue timeIntervalSince1970]];
	}
	
	return instanceValue;
}

- (id)unserializedRepresentationOfDatabaseValue:(id)databaseValue forPropertyNamed:(NSString *)propertyName
{
	objc_property_t property = class_getProperty(self.class, propertyName.UTF8String);
	if (property) {
		const char *attrs = property_getAttributes(property);
		if (attrs[0] == 'T' && attrs[1] == '@' && attrs[2] == '"') {
			attrs = &(attrs[3]);
		}

		if (databaseValue && strncmp(attrs, "NSURL", 5) == 0) {
			return [NSURL URLWithString:databaseValue];
		} else if (databaseValue && strncmp(attrs, "NSDate", 6) == 0) {
			return [NSDate dateWithTimeIntervalSince1970:[databaseValue integerValue]];
		} else if (databaseValue && strncmp(attrs, "NSDictionary", 12) == 0) {
			NSDictionary *dict = [NSPropertyListSerialization propertyListWithData:databaseValue options:kCFPropertyListImmutable format:NULL error:NULL];
			return dict && [dict isKindOfClass:NSDictionary.class] ? dict: @{};
		} else if (databaseValue && strncmp(attrs, "NSArray", 7) == 0) {
			NSArray *array = [NSPropertyListSerialization propertyListWithData:databaseValue options:kCFPropertyListImmutable format:NULL error:NULL];
			return array && [array isKindOfClass:NSArray.class] ? array: @[];
		}
	}

	return databaseValue;
}

- (BOOL)shouldInsert
{
	return YES;
}

- (BOOL)shouldUpdate
{
	return YES;
}

- (BOOL)shouldDelete
{
	return YES;
}

- (void)didInsert
{
	return;
}

- (void)didUpdate
{
	return;
}

- (void)didDelete
{
	return;
}

- (void)saveWasRefused
{
	return;
}

- (void)saveDidFail
{
	return;
}

- (id)primaryKey
{
	NSDictionary *primaryKeyFieldName = [FCModelDatabaseManager primaryKeyFieldName];
	return [self valueForKey:primaryKeyFieldName[self.class]];
}

- (NSDictionary *)allFields
{
	NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
	NSDictionary *fieldInfo = [FCModelDatabaseManager fieldInfo];
	[[fieldInfo[self] allKeys] enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		id value = [self valueForKey:obj];
		if (value) [dictionary setObject:value forKey:obj];
	}];
	return dictionary;
}

- (BOOL)hasUnsavedChanges
{
	return !self.existsInDatabase || [self.changedProperties count];
}

+ (void)_uniqueMapInit
{
	static dispatch_once_t token;
	dispatch_once(&token, ^{
		instancesReadLock = dispatch_semaphore_create(1);
		instances = [NSMutableDictionary dictionary];
	});
}

- (void)_registerUniqueInstance
{
	id primaryKeyValue = self.primaryKey;
	if (!primaryKeyValue || primaryKeyValue == [NSNull null]) {
        return;
    }
	[self.class _uniqueMapInit];

	dispatch_semaphore_wait(instancesReadLock, DISPATCH_TIME_FOREVER);
	NSMapTable *classCache = instances[self.class];
	if (!classCache) {
        classCache = instances[(id) self.class] = [NSMapTable strongToWeakObjectsMapTable];
    }
	[classCache setObject:self forKey:primaryKeyValue];
	dispatch_semaphore_signal(instancesReadLock);
}

- (void)_removeUniqueInstance
{
	id primaryKeyValue = self.primaryKey;
	if (!primaryKeyValue || primaryKeyValue == [NSNull null]) {
		return;
	}
	[self.class _uniqueMapInit];
	
	dispatch_semaphore_wait(instancesReadLock, DISPATCH_TIME_FOREVER);
	NSMapTable *classCache = instances[self.class];
	[classCache removeObjectForKey:primaryKeyValue];
	dispatch_semaphore_signal(instancesReadLock);
}

+ (instancetype)_instanceFromDatabaseWithPrimaryKey:(id)key
{
	__block FCModel *model;
	[[FCModelDatabaseManager databaseQueue] inDatabase:^(FMDatabase *db) {
		FMResultSet *s = [db executeQuery:[self expandQuery:@"SELECT * FROM \"$T\" WHERE \"$PK\"=?"], key];
		if (!s) {
			[self queryFailedInDatabase:db];
		}
		if ([s next]) {
			model = [[self alloc] initWithFieldValues:s.resultDictionary existsInDatabaseAlready:YES];
		}
		[s close];
	}];
	
	return model;
}

- (id)_encodedValueForFieldName:(NSString *)fieldName
{
	id value = [self serializedDatabaseRepresentationOfValue:[self valueForKey:fieldName] forPropertyNamed:fieldName];
	return value ?: [NSNull null];
}

- (void)_decodeFieldValue:(id)value intoPropertyName:(NSString *)propertyName
{
	if (value == [NSNull null]) {
		value = nil;
	}
	if (class_getProperty(self.class, propertyName.UTF8String)) {
		[self setValue:[self unserializedRepresentationOfDatabaseValue:value forPropertyNamed:propertyName] forKeyPath:propertyName];
	}
}

- (void)_saveByNotification:(NSNotification *)n
{
	Class targetedClass = n.userInfo[FCModelClassKey];
	if (targetedClass && ![self isKindOfClass:targetedClass]) {
		return;
	}
	[self save];
}

- (void)_reload:(NSNotification *)n
{
	Class targetedClass = n.userInfo[FCModelClassKey];
	if (targetedClass && ![self isKindOfClass:targetedClass]) {
		return;
	}
	if (!self.existsInDatabase) {
		return;
	}

	if (self.hasUnsavedChanges) {
		[[NSException exceptionWithName:@"FCReloadConflict" reason:
		  [NSString stringWithFormat:@"%@ ID %@ has unsaved changes during a write-consistency reload: %@", NSStringFromClass(self.class), self.primaryKey, self.changedProperties]
							   userInfo:nil] raise];
	}

	__block NSDictionary *resultDictionary = nil;
	[[FCModelDatabaseManager databaseQueue] inDatabase:^(FMDatabase *db) {
		FMResultSet *s = [db executeQuery:[self.class expandQuery:@"SELECT * FROM \"$T\" WHERE \"$PK\"=?"], self.primaryKey];
		if (!s) {
			[self.class queryFailedInDatabase:db];
		}
		if ([s next]) {
			// Update from new database values
			resultDictionary = [s.resultDictionary copy];
		} else {
			// This instance no longer exists in database
			self.deleted = YES;
			self.existsInDatabase = NO;
		}
		[s close];
	}];

	[self _finishReloadWithResultsDictionary:resultDictionary];
}

- (void)_finishReloadWithResultsDictionary:(NSDictionary *)resultDictionary
{
	if (self.isDeleted) {
		[self didDelete];
		[NSNotificationCenter.defaultCenter postNotificationName:FCModelDeleteNotification object:self.class userInfo:@{FCModelInstanceKey: self}];
	} else {
		__block BOOL didUpdate = NO;
		[resultDictionary enumerateKeysAndObjectsUsingBlock:^(NSString *fieldName, id fieldValue, BOOL *stop) {
			NSDictionary *primaryKeyFieldName = [FCModelDatabaseManager primaryKeyFieldName];
			if ([fieldName isEqualToString:primaryKeyFieldName[self.class]]) {
				return;
			}

			id existing = [self valueForKeyPath:fieldName];
			if (![existing isEqual:fieldValue]) {
				// Conflict resolution

				BOOL valueIsStillChanged = NO;
				if (self.changedProperties[fieldName]) {
					id newFieldValue = [self valueOfFieldName:fieldName byResolvingReloadConflictWithDatabaseValue:fieldValue];
					valueIsStillChanged = ![fieldValue isEqual:newFieldValue];
					fieldValue = newFieldValue;
				}

				// NSLog(@"%@ %@ updating \"%@\" [%@]=>[%@]", NSStringFromClass(self.class), self.primaryKey, fieldName, existing, fieldValue);
				[self _decodeFieldValue:fieldValue intoPropertyName:fieldName];
				if (!valueIsStillChanged) {
					[self.changedProperties removeObjectForKey:fieldName];
				}
				didUpdate = YES;
			}
		}];

		if (didUpdate) {
			[self didUpdate];
			[NSNotificationCenter.defaultCenter postNotificationName:FCModelUpdateNotification object:self.class userInfo:@{FCModelInstanceKey: self}];
		}
	}
}

- (FCModelSaveResult)_finishSavingValues:(NSMutableArray *)values withQuery:(NSString *)query primaryKey:(id)primaryKey update:(BOOL)update
{
	__block BOOL success = NO;
	__block sqlite_int64 lastInsertID;
	[[FCModelDatabaseManager databaseQueue] inDatabase:^(FMDatabase *db) {
		success = [db executeUpdate:query withArgumentsInArray:values];
		if (success) {
			lastInsertID = [db lastInsertRowId];
			self.lastSQLiteError = nil;
		} else {
			self.lastSQLiteError = db.lastError;
		}
	}];

	if (!success) {
		[self saveDidFail];
		return FCModelSaveFailed;
	}

	if (!primaryKey || primaryKey == [NSNull null]) {
		NSDictionary *primaryKeyFieldName = [FCModelDatabaseManager primaryKeyFieldName];
		[self setValue:[NSNumber numberWithUnsignedLongLong:lastInsertID] forKey:primaryKeyFieldName[self.class]];
		[self _registerUniqueInstance];
	}

	[self.changedProperties removeAllObjects];
	self.primaryKeySet = YES;
	self.existsInDatabase = YES;

	if (update) {
		[self didUpdate];
		[NSNotificationCenter.defaultCenter postNotificationName:FCModelUpdateNotification object:self.class userInfo:@{FCModelInstanceKey: self}];
	} else {
		[self didInsert];
		[NSNotificationCenter.defaultCenter postNotificationName:FCModelInsertNotification object:self.class userInfo:@{FCModelInstanceKey: self}];
	}

	return FCModelSaveSucceeded;
}

- (NSString *)_queryForPrimaryKeyName:(NSString *)pkName tableName:(NSString *)tableName columnNames:(NSArray *)columnNames update:(BOOL)update
{
	NSString *query;
	if (update) {
		query = [NSString stringWithFormat:
				 @"UPDATE \"%@\" SET \"%@\"=? WHERE \"%@\"=?",
				 tableName,
				 [columnNames componentsJoinedByString:@"\"=?,\""],
				 pkName
				 ];
	} else {
		if ([columnNames count] > 0) {
			query = [NSString stringWithFormat:
					 @"INSERT INTO \"%@\" (\"%@\",\"%@\") VALUES (%@?)",
					 tableName,
					 [columnNames componentsJoinedByString:@"\",\""],
					 pkName,
					 [@"" stringByPaddingToLength:([columnNames count] * 2) withString:@"?," startingAtIndex:0]
					 ];
		} else {
			query = [NSString stringWithFormat:
					 @"INSERT INTO \"%@\" (\"%@\") VALUES (?)",
					 tableName,
					 pkName
					 ];
		}
	}
	return query;
}

- (NSDictionary *)_validateNotNULLColumnsForTableName:(NSString *)tableName
{
	// Validate NOT NULL columns
	NSDictionary *fieldInfo = [FCModelDatabaseManager fieldInfo];
	[fieldInfo[self.class] enumerateKeysAndObjectsUsingBlock:^(id key, FCModelFieldInfo *info, BOOL *stop) {
		if (info.nullAllowed) return;

		id value = [self valueForKey:key];
		if (!value || value == [NSNull null]) {
			[[NSException exceptionWithName:NSInvalidArgumentException reason:[NSString stringWithFormat:@"Cannot save NULL to NOT NULL property %@.%@", tableName, key] userInfo:nil] raise];
		}
	}];
	return fieldInfo;
}

#pragma mark - NSObject

- (instancetype)init
{
	return [self initWithFieldValues:@{} existsInDatabaseAlready:NO];
}

- (void)dealloc
{
	[NSNotificationCenter.defaultCenter removeObserver:self name:FCModelReloadNotification object:nil];
	[NSNotificationCenter.defaultCenter removeObserver:self name:FCModelSaveNotification object:nil];

	NSDictionary *fieldInfo = [FCModelDatabaseManager fieldInfo];
	[fieldInfo[self.class] enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
		[self removeObserver:self forKeyPath:key];
	}];
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@#%@: 0x%p>", NSStringFromClass(self.class), self.primaryKey, self];
}

- (NSUInteger)hash
{
	return ((NSObject *)self.primaryKey).hash;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	NSDictionary *primaryKeyFieldName = [FCModelDatabaseManager primaryKeyFieldName];
	if ([keyPath isEqualToString:primaryKeyFieldName[self.class]]) {
		self.primaryKeySet = YES;
	}
	if (!self.isPrimaryKeyLocked) {
		return;
	}

	NSObject *oldValue, *newValue;
	if ((oldValue = change[NSKeyValueChangeOldKey]) && (newValue = change[NSKeyValueChangeNewKey])) {
		if ([oldValue isKindOfClass:[NSURL class]]) {
			oldValue = ((NSURL *)oldValue).absoluteString;
		} else if ([oldValue isKindOfClass:[NSDate class]]) {
			oldValue = [NSNumber numberWithDouble:[(NSDate *)oldValue timeIntervalSince1970]];
		}

		if ([newValue isKindOfClass:[NSURL class]]) {
			newValue = ((NSURL *)newValue).absoluteString;
		} else if ([newValue isKindOfClass:[NSDate class]]) {
			newValue = [NSNumber numberWithDouble:[(NSDate *)newValue timeIntervalSince1970]];
		}

		if ([oldValue isEqual:newValue]) {
			return;
		}
	}

	BOOL isPrimaryKey = [keyPath isEqualToString:primaryKeyFieldName[self.class]];
	if (self.existsInDatabase && isPrimaryKey) {
		if (self.primaryKeyLocked) {
			[[NSException exceptionWithName:NSInvalidArgumentException reason:@"Cannot change primary key value for already-saved FCModel" userInfo:nil] raise];
		}
	} else if (isPrimaryKey) {
		self.primaryKeySet = YES;
	}

	if (!isPrimaryKey && self.changedProperties && !self.changedProperties[keyPath]) {
		[self.changedProperties setObject:(oldValue ?: [NSNull null]) forKey:keyPath];
	}
}

@end
