#import <Foundation/Foundation.h>

// Desktop persistence uses the same index schema and file-based Keychain items as the CLI.
FOUNDATION_EXPORT NSDictionary *ReadSecretIndex(NSString *path, NSError **error);
FOUNDATION_EXPORT BOOL SaveSecretEntry(NSString *indexPath, NSString *name, NSDictionary *entry,
                                      NSString *value, BOOL creating, NSError **error);
FOUNDATION_EXPORT BOOL DeleteSecretEntry(NSString *indexPath, NSString *name, NSError **error);
FOUNDATION_EXPORT NSString *ReadSecretValue(NSDictionary *entry, NSError **error);
