// Copyright (c) 2011 emo-framework project
// All rights reserved.
// 
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// 
// * Redistributions of source code must retain the above copyright notice,
//   this list of conditions and the following disclaimer.
// * Redistributions in binary form must reproduce the above copyright notice,
//   this list of conditions and the following disclaimer in the documentation
//   and/or other materials provided with the distribution.
// * Neither the name of the project nor the names of its contributors may be
//   used to endorse or promote products derived from this software without
//   specific prior written permission.
// 
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS 
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT 
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS 
// FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
// OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
// WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
// OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, 
// EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
// 
#import "EmoDatabase.h"
#import "Constants.h"
#import "EmoEngine.h"
#import "EmoEngine_glue.h"
#include "Util.h"

NSString* char2ns(const char* str) {
	return [NSString stringWithCString:(char*)str
							  encoding:NSUTF8StringEncoding];
}

NSString* data2ns(NSData* data) {
	return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

NSString * decryptNSString(NSString *cipher) {
    // base64 decoding
    int size = 0;
    unsigned char * decodedBytes = base64Decode( [cipher UTF8String], &size );
    
    // retrieve common (private) key
    const unsigned char * key = (unsigned char *)AES_PRIVATE_KEY;
    
    // decrypt bytes
    int plainSize = 0;
    const unsigned char * decryptedBytes = emoDecrypt(key, decodedBytes, size, &plainSize);
    NSString *dst = char2ns((char *)decryptedBytes);
    
    return dst;
}

NSString * encryptNSString(NSString *plainText) {
    // convert string to a single space if null string specified
    NSString *targetString = plainText;
    if (plainText.length == 0){
        targetString = @" ";
    }
    
    // get bytes from string
    int size = targetString.length;
    unsigned char *  bytes = (unsigned char *)[targetString UTF8String];
    
    // retrieve the common (private) key
    const unsigned char * key = (unsigned char *)AES_PRIVATE_KEY;
    
    // encrypt bytes
    int cipherSize = 0;
    unsigned char * encryptedBytes = emoEncrypt(key, bytes, size, &cipherSize);
    
    // base64 encoding
    char * encodedChars = base64Encode(encryptedBytes, cipherSize) ;
    NSString *dst = char2ns(encodedChars);
    
    return dst;
}

static int database_preference_callback(void *arg, int argc, char **argv, char **column)  {
    CipherHolder* value = (__bridge CipherHolder*)arg;
    if (argc > 0){
        value.cipher = char2ns(argv[0]);
    }
    return SQLITE_OK;
}

static int database_count_callback(void *arg, int argc, char **argv, char **column)  {
    int* count = (int*)arg;
    if (argc > 0) *count = atoi(argv[0]);
    return SQLITE_OK;
}

static int database_query_vector_callback(void *arg, int argc, char **argv, char **column)  {
    NSMutableArray* values = (__bridge NSMutableArray*)arg;
	
    for (int i = 0; i < argc; i++) {
        CipherHolder *holder = [[CipherHolder alloc] init];
        holder.cipher = char2ns(argv[i]);
        [values addObject:holder];
    }
	
    return SQLITE_OK;
}

@implementation CipherHolder

@dynamic plainText, cipher;

- (id)init {
    self = [super init];
    if (self != nil) {
        self.plainText = @"";
    }
    return self;
}


- (NSString *)cipher {
    return _cipher;
}

- (void)setCipher:(NSString *)cipher {
    _plainText  = decryptNSString(cipher);
    _cipher     = cipher;
}

- (NSString *)plainText {
    return _plainText;
}

- (void)setPlainText:(NSString *)plainText {
    _plainText = plainText;
    _cipher     = encryptNSString(plainText);
}

- (BOOL)hasCipher {
    return self.cipher.length != 0;
}

- (BOOL)compareWithCipher:(NSString *)cipher {
    return [self.plainText isEqualToString:decryptNSString(cipher)];
}

- (BOOL)compareWithHolder:(CipherHolder *)holder {
    return [self.plainText isEqualToString:holder.plainText];
}

@end

@interface EmoDatabase (PrivateMethods)
-(NSInteger)exec:(const char*) sql;
-(NSInteger)exec_count:(const char*)sql count:(NSInteger*)count;
-(NSInteger)query_vector:(const char*) sql values:(NSMutableArray*)values;
@end

@implementation EmoDatabase
@synthesize lastError;
@synthesize lastErrorMessage;

- (id)init {
    self = [super init];
    if (self != nil) {
		isOpen = FALSE;
		lastError = SQLITE_OK;
		lastErrorMessage = [NSString string];
    }
    return self;
}

-(NSInteger)exec:(const char*) sql {
	char* error;
	int rcode = sqlite3_exec(db, sql, NULL, 0, &error);
	if (rcode != SQLITE_OK) {
		self.lastError = rcode;
		self.lastErrorMessage = char2ns(error);
		sqlite3_free(error);
	}
	return rcode;
}

-(NSInteger)exec_count:(const char*)sql count:(NSInteger*)count {
	char* error;
	int rcode = sqlite3_exec(db, sql, database_count_callback, count, &error);
	if (rcode != SQLITE_OK) {
		self.lastError = rcode;
		self.lastErrorMessage = char2ns(error);
		sqlite3_free(error);
	}
	return rcode;
}

-(NSInteger)query_vector:(const char*) sql values:(NSMutableArray*)values {
	char* error;
	int rcode = sqlite3_exec(db, sql, database_query_vector_callback, (__bridge void *)(values), &error);
	if (rcode != SQLITE_OK) {
		self.lastError = rcode;
		self.lastErrorMessage = char2ns(error);
		sqlite3_free(error);
	}
	return rcode;
}

-(BOOL)open:(NSString*) name {
	return [self open:name force:FALSE];
}

-(BOOL)open:(NSString*) name force:(BOOL)force {
	if (isOpen) return FALSE;
	
	NSString* path = [self getPath:name];
	NSFileManager* manager = [NSFileManager defaultManager];
	if (!force && ![manager fileExistsAtPath:path]) {
		lastError = ERR_DATABASE_OPEN;
		lastErrorMessage = @"Database file is not found. use openOrCreate to open and create new database.";
		return FALSE;
	}
		
	int rcode = sqlite3_open([path UTF8String], &db);
	
	if (rcode != SQLITE_OK) {
		self.lastError = rcode;
		self.lastErrorMessage =  char2ns(sqlite3_errmsg(db));
	}
	
	isOpen = TRUE;
	return TRUE;
}

-(BOOL)openOrCreate:(NSString*)name mode:(NSInteger)mode {
	if (mode != FILE_MODE_PRIVATE) {
		lastError = ERR_INVALID_PARAM;
		lastErrorMessage = @"Only FILE_MODE_PRIVATE is supported for iOS.";
		return FALSE;
	}
	
	return [self open:name force:TRUE];
}
-(BOOL)close {
	if (!isOpen) return FALSE;
	
	sqlite3_close(db);
	
	isOpen = FALSE;
	return TRUE;
}
-(BOOL)deleteDatabase:(NSString*)name {
	NSString* path = [self getPath:name];
	NSFileManager* manager = [NSFileManager defaultManager];
	if ([manager fileExistsAtPath:path]) {
		NSError* error = nil;
		[manager removeItemAtPath:path error:&error];
		if (error) {
			self.lastError = ERR_FILE_OPEN;
			self.lastErrorMessage = [error localizedDescription];
			return FALSE;
		}
	} else {
		self.lastError = ERR_FILE_OPEN;
		self.lastErrorMessage = @"Database file is not found.";
		return FALSE;
	}
	return TRUE;
}

-(BOOL)openOrCreatePreference {
	BOOL result = [self openOrCreate:@DEFAULT_DATABASE_NAME mode:FILE_MODE_PRIVATE];
	if (!result) return FALSE;
	
	char* sql = sqlite3_mprintf("CREATE TABLE IF NOT EXISTS %q (KEY TEXT PRIMARY KEY, VALUE TEXT)", PREFERENCE_TABLE_NAME);
	int rcode = [self exec:sql];
	sqlite3_free(sql);
	
	return rcode == SQLITE_OK;
}

-(BOOL)openPreference {
	return [self open:@DEFAULT_DATABASE_NAME];
}

-(NSString*)getPreference:(NSString*)key {
	BOOL forceClose = FALSE;
	
	if (!isOpen) {
		[self openOrCreatePreference];
		forceClose = TRUE;
	}
	
    CipherHolder *keyHolder = nil;
    NSArray *keyList = [self getPreferenceKeys];
    for( CipherHolder *aKeyHolder in keyList ) {
        if( [aKeyHolder.plainText isEqualToString:key] ){
            keyHolder = aKeyHolder;
            break;
        }
    }

    if(!keyHolder.hasCipher){
		self.lastError = ERR_INVALID_PARAM;
		self.lastErrorMessage = [NSString stringWithFormat:@"Database::getPreference : key %@ does not exist", key];
        return @"";
    }

    CipherHolder *value = [[CipherHolder alloc] init];
    char* sql = sqlite3_mprintf("SELECT VALUE FROM %q WHERE KEY=%Q", PREFERENCE_TABLE_NAME, [keyHolder.cipher UTF8String]);
	
	char* error;
	int rcode = sqlite3_exec(db, sql, database_preference_callback, (__bridge void *)(value), &error);
	if (rcode != SQLITE_OK) {
		self.lastError = rcode;
		self.lastErrorMessage = char2ns(error);
		sqlite3_free(error);
	}
	sqlite3_free(sql);
	
	if (forceClose) {
		[self close];
	}
	return value.plainText;
}
-(BOOL)setPreference:(NSString*) key value:(NSString*)value {
	BOOL forceClose = FALSE;
	if (!isOpen) {
		[self openOrCreatePreference];
		forceClose = TRUE;
	}
	
    CipherHolder *keyHolder;
    NSArray *keyList = [self getPreferenceKeys];
    for( CipherHolder *aKeyHolder in keyList ) {
        if( [aKeyHolder.plainText isEqualToString:key] ){
            keyHolder = aKeyHolder;
            break;
        }
    }

    NSString *encryptedValue = encryptNSString(value);
    	
	int rcode = SQLITE_OK;
    char* sql;
    if(!keyHolder.hasCipher){
        NSString *encryptedKey = encryptNSString(key);
		sql = sqlite3_mprintf("INSERT INTO %q(KEY,VALUE) VALUES(%Q,%Q)", PREFERENCE_TABLE_NAME, [encryptedKey UTF8String], [encryptedValue UTF8String]);
	} else {
		sql = sqlite3_mprintf("UPDATE %q SET VALUE=%Q WHERE KEY=%Q", PREFERENCE_TABLE_NAME, [encryptedValue UTF8String], [keyHolder.cipher UTF8String]);
	}
    rcode = [self exec:sql];
    sqlite3_free(sql);
	
	if (forceClose) {
		[self close];
	}
	
	return rcode == SQLITE_OK;
}
-(NSArray*)getPreferenceKeys {
	BOOL forceClose = FALSE;
	if (!isOpen) {
		[self openOrCreatePreference];
		forceClose = TRUE;
	}
	
	NSMutableArray* keys = [NSMutableArray array];
	char *sql = sqlite3_mprintf("SELECT KEY FROM %q", PREFERENCE_TABLE_NAME);
	[self query_vector:sql values:keys];
	sqlite3_free(sql);
	
	if (forceClose) {
		[self close];
	}
	return keys;
}
-(BOOL)deletePreference:(NSString*)key {
	BOOL forceClose = FALSE;
	if (!isOpen) {
		[self openOrCreatePreference];
		forceClose = TRUE;
	}
	
    CipherHolder *keyHolder;
    NSArray *keyList = [self getPreferenceKeys];
    for( CipherHolder *aKeyHolder in keyList ) {
        if( [aKeyHolder.plainText isEqualToString:key] ){
            keyHolder = aKeyHolder;
            break;
        }
    }
    
    if(!keyHolder.hasCipher){
		self.lastError = ERR_INVALID_PARAM;
		self.lastErrorMessage = [NSString stringWithFormat:@"Database::deletePreference : key %@ does not exist", key];
        return NO;
    }
	char *sql = sqlite3_mprintf("DELETE FROM %q WHERE KEY=%Q", PREFERENCE_TABLE_NAME, [keyHolder.cipher UTF8String]);
	int rcode = [self exec:sql];
	sqlite3_free(sql);
	
	if (forceClose) {
		[self close];
	}
	return rcode == SQLITE_OK;
}
-(NSInteger)getLastError {
	return lastError;
}

-(NSString*)getLastErrorMessage {
	return lastErrorMessage;
}

-(NSString*)getPath:(NSString*)name {
	NSString* docDir = [NSSearchPathForDirectoriesInDomains(
			NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
	return [NSString stringWithFormat:@"%@/%@", docDir, name];
}

@end
