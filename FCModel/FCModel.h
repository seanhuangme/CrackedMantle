//
//  FCModel.h
//
//  Created by Marco Arment on 7/18/13.
//  Copyright (c) 2013 Marco Arment. All rights reserved.
//

#import "FMDatabase.h"
#import "FMDatabaseQueue.h"

typedef NS_ENUM(NSInteger, FCModelSaveResult) {
    FCModelSaveFailed = 0, // SQLite refused a query. Check .lastSQLiteError
    FCModelSaveRefused,    // The instance blocked the operation from a should* method.
    FCModelSaveSucceeded,
    FCModelSaveNoChanges
};

typedef NS_ENUM(NSInteger, FCFieldType) {
	FCFieldTypeOther = 0,
	FCFieldTypeText,
	FCFieldTypeInteger,
	FCFieldTypeDouble,
	FCFieldTypeBool
};

/** 
 * These notifications use the relevant model’s Class as the “object” for convenience so observers can,
 * for instance, observe every update to any instance of the Person class:
 *
 *  [NSNotificationCenter.defaultCenter addObserver:... selector:... name:FCModelUpdateNotification object:Person.class];
 *
 * The specific instance acted upon is passed as userInfo[FCModelInstanceKey].
 */
extern NSString *const FCModelInsertNotification;
extern NSString *const FCModelUpdateNotification;
extern NSString *const FCModelDeleteNotification;
extern NSString *const FCModelReloadNotification;
extern NSString *const FCModelInstanceKey;
extern NSString *const FCModelSaveNotification;
extern NSString *const FCModelInstanceKey;
extern NSString *const FCModelClassKey;

@interface FCModel : NSObject

// CRUD basics
+ (instancetype)instanceWithPrimaryKey:(id)primaryKeyValue; // will create if nonexistent
+ (instancetype)instanceWithPrimaryKey:(id)primaryKeyValue createIfNonexistent:(BOOL)create;
- (FCModelSaveResult)revertUnsavedChanges;
- (FCModelSaveResult)revertUnsavedChangeToFieldName:(NSString *)fieldName;
- (FCModelSaveResult)delete;
- (FCModelSaveResult)save;
+ (void)saveAll; // Resolved by class: call on FCModel to save all, on a subclass to save just those and their subclasses, etc.

// For subclasses to override, all optional:
- (BOOL)shouldInsert;
- (BOOL)shouldUpdate;
- (BOOL)shouldDelete;
- (void)didInsert;
- (void)didUpdate;
- (void)didDelete;
- (void)saveWasRefused;
- (void)saveDidFail;

/**
 * Subclasses can customize how properties are serialized for the database.
 *
 * FCModel automatically handles numeric primitives, NSString, NSNumber, NSData, NSURL, NSDate, NSDictionary, and NSArray.
 * (Note that NSDate is stored as a time_t, so values before 1970 won’t serialize properly.)
 *
 * To override this behavior or customize it for other types, you can implement these methods.
 * You MUST call the super implementation for values that you’re not handling.
 *
 * Database values may be NSString or NSNumber for INTEGER/FLOAT/TEXT columns, or NSData for BLOB columns.
 */
- (id)serializedDatabaseRepresentationOfValue:(id)instanceValue forPropertyNamed:(NSString *)propertyName;
- (id)unserializedRepresentationOfDatabaseValue:(id)databaseValue forPropertyNamed:(NSString *)propertyName;

/**
 * Called on subclasses if there’s a reload conflict:
 * - The instance changes field X but doesn’t save the changes to the database.
 * - Database updates are executed outside of FCModel that cause instances to reload their data.
 * - This instance’s value for field X in the database is different from the unsaved value it has.
 *
 * The default implementation raises an exception, so implement this if you use +dataWasUpdatedExternally or +executeUpdateQuery,
 *  and don’t call super.
 */
- (id)valueOfFieldName:(NSString *)fieldName byResolvingReloadConflictWithDatabaseValue:(id)valueInDatabase;

@property (readonly) id primaryKey;
@property (readonly) NSDictionary *allFields;
@property (readonly) BOOL hasUnsavedChanges;
@property (readonly) BOOL existsInDatabase;
@property (readonly) NSError *lastSQLiteError;

@end

/**
 * Used for NULL/NOT NULL rules and default values
 */

@interface FCModelFieldInfo : NSObject

@property (nonatomic, assign) BOOL nullAllowed;
@property (nonatomic, assign) FCFieldType type;
@property (nonatomic) id defaultValue;

@end

