#import "SecretStore.h"
#import <Security/Security.h>

static void StoreError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"Clinklet" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL SecurityResult(OSStatus status, NSError **error) {
    if (status == errSecSuccess) return YES;
    NSString *message = CFBridgingRelease(SecCopyErrorMessageString(status, NULL));
    if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status
                                      userInfo:@{NSLocalizedDescriptionKey: message ?: @"Keychain operation failed."}];
    return NO;
}

NSDictionary *ReadSecretIndex(NSString *path, NSError **error) {
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return @{};
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data) return nil;
    id index = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (!index) return nil;
    if (![index isKindOfClass:NSDictionary.class]) {
        StoreError(error, @"The metadata index must be a JSON object.");
        return nil;
    }
    for (id name in index) {
        if (![index[name] isKindOfClass:NSDictionary.class]) {
            StoreError(error, @"The metadata index contains an invalid entry. Restore it before saving.");
            return nil;
        }
    }
    return index;
}

static BOOL WriteSecretIndex(NSString *path, NSDictionary *index, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:index options:(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys) error:error];
    if (!data) return NO;
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES
                          attributes:@{NSFilePosixPermissions: @0700} error:error]) return NO;
    if (![data writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    return [files setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:path error:error];
}

static NSString *EntryString(NSDictionary *entry, NSString *key, NSString *fallback) {
    id value = entry[key];
    return [value isKindOfClass:NSString.class] && [value length] > 0 ? value : fallback;
}

static NSString *LoginKeychain(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Keychains/login.keychain-db"];
}

static NSMutableDictionary *KeychainQuery(NSDictionary *entry, NSError **error) {
    NSString *service = EntryString(entry, @"service", @"");
    NSString *account = EntryString(entry, @"account", NSUserName());
    if (service.length == 0) { StoreError(error, @"A Keychain service is required."); return nil; }
    SecKeychainRef keychain = NULL;
    // Explicit file-based Keychains preserve existing CLI entries and custom Keychain selection.
    // SecItem itself has no path-taking replacement for opening a legacy Keychain file.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    OSStatus status = SecKeychainOpen(EntryString(entry, @"keychain", LoginKeychain()).fileSystemRepresentation, &keychain);
#pragma clang diagnostic pop
    if (!SecurityResult(status, error)) return nil;
    NSMutableDictionary *query = [@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                                   (__bridge id)kSecAttrService: service,
                                   (__bridge id)kSecAttrAccount: account,
                                   (__bridge id)kSecMatchSearchList: @[(__bridge id)keychain]} mutableCopy];
    CFRelease(keychain);
    return query;
}

// Preserve the CLI's existing trust in /usr/bin/security for newly created items.
// Never grant "all applications" access; the native app and the system CLI are explicit.
static id NewItemAccess(NSError **error) {
    SecTrustedApplicationRef app = NULL;
    SecTrustedApplicationRef cli = NULL;
    SecAccessRef access = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    OSStatus status = SecTrustedApplicationCreateFromPath(NULL, &app);
    if (status == errSecSuccess) status = SecTrustedApplicationCreateFromPath("/usr/bin/security", &cli);
    if (status == errSecSuccess) {
        status = SecAccessCreate(CFSTR("Clinklet secret"), (__bridge CFArrayRef)@[(__bridge id)app, (__bridge id)cli], &access);
    }
#pragma clang diagnostic pop
    if (app) CFRelease(app);
    if (cli) CFRelease(cli);
    if (!SecurityResult(status, error)) return nil;
    return CFBridgingRelease(access);
}

NSString *ReadSecretValue(NSDictionary *entry, NSError **error) {
    NSMutableDictionary *query = KeychainQuery(entry, error);
    if (!query) return nil;
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    if (!SecurityResult(SecItemCopyMatching((__bridge CFDictionaryRef)query, &result), error)) return nil;
    NSData *data = CFBridgingRelease(result);
    NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!value) StoreError(error, @"The stored value is not UTF-8 text.");
    return value;
}

BOOL SaveSecretEntry(NSString *indexPath, NSString *name, NSDictionary *entry, NSString *value,
                     BOOL creating, NSError **error) {
    NSDictionary *current = ReadSecretIndex(indexPath, error);
    if (!current) return NO;
    NSDictionary *previous = current[name];
    if (creating && previous) { StoreError(error, @"This name already exists. Select it to edit."); return NO; }
    if (!creating && !previous) { StoreError(error, @"This entry was removed. Refresh before editing."); return NO; }
    if (value == nil) {
        if (!previous) { StoreError(error, @"A secret value is required for a new entry."); return NO; }
        for (NSString *key in @[@"service", @"account", @"keychain"]) {
            NSString *fallback = [key isEqualToString:@"service"] ? name : [key isEqualToString:@"account"] ? NSUserName() : LoginKeychain();
            if (![EntryString(previous, key, fallback) isEqualToString:EntryString(entry, key, fallback)]) {
                StoreError(error, @"A secret value is required when changing service, account, or Keychain.");
                return NO;
            }
        }
    } else {
        NSMutableDictionary *query = KeychainQuery(entry, error);
        if (!query) return NO;
        NSDictionary *attributes = @{(__bridge id)kSecValueData: [value dataUsingEncoding:NSUTF8StringEncoding],
                                     (__bridge id)kSecAttrLabel: name,
                                     (__bridge id)kSecAttrDescription: @"application password",
                                     (__bridge id)kSecAttrComment: entry[@"note"] ?: @""};
        OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);
        if (status == errSecItemNotFound) {
            id keychain = [query[(__bridge id)kSecMatchSearchList] firstObject];
            [query removeObjectForKey:(__bridge id)kSecMatchSearchList];
            query[(__bridge id)kSecUseKeychain] = keychain;
            id access = NewItemAccess(error);
            if (!access) return NO;
            query[(__bridge id)kSecAttrAccess] = access;
            [query addEntriesFromDictionary:attributes];
            status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
        }
        if (!SecurityResult(status, error)) return NO;
    }
    NSMutableDictionary *updated = [entry mutableCopy];
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    updated[@"updated_at"] = [formatter stringFromDate:NSDate.date];
    NSMutableDictionary *index = [current mutableCopy];
    index[name] = updated;
    if (!WriteSecretIndex(indexPath, index, error)) {
        if (value != nil) StoreError(error, @"Keychain was updated, but its metadata could not be saved. Check the index permissions and retry.");
        return NO;
    }
    return YES;
}

BOOL DeleteSecretEntry(NSString *indexPath, NSString *name, NSError **error) {
    NSDictionary *current = ReadSecretIndex(indexPath, error);
    if (!current) return NO;
    NSDictionary *entry = current[name];
    if (!entry) { StoreError(error, @"This entry was already removed. Refresh the list."); return NO; }
    NSMutableDictionary *resolved = [entry mutableCopy];
    resolved[@"service"] = EntryString(entry, @"service", name);
    NSMutableDictionary *query = KeychainQuery(resolved, error);
    if (!query) return NO;
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    if (status != errSecItemNotFound && !SecurityResult(status, error)) return NO;
    NSMutableDictionary *index = [current mutableCopy];
    [index removeObjectForKey:name];
    if (!WriteSecretIndex(indexPath, index, error)) {
        StoreError(error, @"The Keychain value was deleted, but its metadata could not be removed. Check the index permissions and retry.");
        return NO;
    }
    return YES;
}
