#define main KeychainSecretsApplicationMain
#import "../macos/KeychainSecretsApp.m"
#undef main

static NSString *ToolPath(void) {
    return [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"keychain_secrets.py"];
}

// Test-only subprocess helper for CLI interoperability and screenshots.
static NSString *RunProcess(NSString *path, NSArray *arguments, NSString *input __unused, int *status) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) { *status = -1; return error.localizedDescription; }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    *status = task.terminationStatus;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

#define CHECK(condition) do { if (!(condition)) { NSLog(@"FAIL line %d: %s", __LINE__, #condition); exit(1); } } while (0)

@interface TestDelegate : AppDelegate
@property NSString *lastError;
@end
@implementation TestDelegate
- (void)showError:(NSString *)message { self.lastError = message; }
@end

static void PumpUntil(BOOL (^done)(void), NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!done() && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    CHECK(done());
}

int main(void) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        InstallMainMenu();
        NSString *folder = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *indexPath = [folder stringByAppendingPathComponent:@"index.json"];
        setenv("KEYCHAIN_SECRETS_INDEX_PATH", indexPath.UTF8String, 1);
        NSDictionary *fixture = @{
            @"ALPHA": @{@"env": @"MODEL_TOKEN", @"service": @"vendor-a", @"account": NSUserName(), @"note": @"Café 开发环境"},
            @"BETA": @{@"env": @"OTHER_TOKEN", @"service": @"vendor-b", @"account": @"build-bot", @"note": @"Production"}
        };
        [[NSJSONSerialization dataWithJSONObject:fixture options:0 error:NULL] writeToFile:indexPath atomically:YES];
        TestDelegate *app = [TestDelegate new];
        application.delegate = app;
        app.names = [NSMutableArray array];
        [app buildUI];
        [app refresh:nil];
        CHECK(app.names.count == 2);
        CHECK(app.statusView.hidden);
        [app showStatus:@"Changes saved" kind:StatusSuccess];
        CHECK(!app.statusView.hidden && !app.statusIcon.hidden && app.progress.hidden);
        PumpUntil(^BOOL { return app.statusView.hidden; }, 4);
        [app showStatus:@"Copied to clipboard" kind:StatusSuccess];
        app.dirty = YES;
        [app showStatus:@"Unsaved changes" kind:StatusUnsaved];
        __block BOOL elapsed = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ elapsed = YES; });
        PumpUntil(^BOOL { return elapsed; }, 5);
        CHECK(!app.statusView.hidden && [app.statusLabel.stringValue isEqualToString:@"Unsaved changes"]);
        [app showStatus:@"Operation failed" kind:StatusError];
        CHECK(!app.statusView.hidden && !app.statusIcon.hidden);
        CHECK([app.statusLabel.toolTip isEqualToString:@"Operation failed"]);
        app.dirty = NO;
        [app showStatus:@"" kind:StatusIdle];
        for (NSString *query in @[@"alpha", @"MODEL", @"vendor-a", NSUserName(), @"cafe", @"开发", @"model 开发"]) {
            app.searchField.stringValue = query;
            [app applySearch];
            CHECK([app.names containsObject:@"ALPHA"]);
        }
        [app loadEntry:@"ALPHA"];
        app.envField.stringValue = @"UNSAVED";
        app.dirty = YES;
        app.searchField.stringValue = @"no-such-entry";
        [app applySearch];
        CHECK(app.names.count == 0 && !app.emptyLabel.hidden);
        CHECK([app.envField.stringValue isEqualToString:@"UNSAVED"] && app.dirty);
        app.searchField.stringValue = @"";
        [app applySearch];
        CHECK(app.names.count == 2 && [app.editingName isEqualToString:@"ALPHA"]);
        CHECK([app.envField.stringValue isEqualToString:@"UNSAVED"]);
        CHECK((NSUInteger)app.table.selectedRow == [app.names indexOfObject:@"ALPHA"]);
        [app.window makeKeyAndOrderFront:nil];
        [application activateIgnoringOtherApps:YES];
        NSEvent *find = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:app.window.windowNumber context:nil characters:@"f" charactersIgnoringModifiers:@"f" isARepeat:NO keyCode:3];
        CHECK([application.mainMenu performKeyEquivalent:find]);
        CHECK(app.window.firstResponder == [app.searchField currentEditor]);
        CHECK(!app.secretVisible && app.secretField.stringValue.length == 0);
        NSTableCellView *cell = (id)[app tableView:app.table viewForTableColumn:app.table.tableColumns[0] row:0];
        CHECK([cell.textField.stringValue isEqualToString:@"ALPHA"]);
        [app setWorking:YES message:@"Testing…"];
        CHECK(!app.actionButtons[0].enabled && !app.noteView.editable);
        CHECK(!app.statusView.hidden && app.statusIcon.hidden && !app.progress.hidden);
        CHECK(![app tableView:app.table shouldSelectRow:1]);
        app.searchField.stringValue = @"vendor-b";
        [app applySearch];
        CHECK(app.names.count == 1 && [app.editingName isEqualToString:@"ALPHA"]);
        [app setWorking:NO message:@"Ready"];
        CHECK(app.actionButtons[0].enabled && app.noteView.editable);

        // A slow process must not block the main queue, and completion is delivered on it.
        __block BOOL complete = NO;
        __block BOOL mainQueueRan = NO;
        RunStore(^NSString *(NSError **error __unused) {
            [NSThread sleepForTimeInterval:0.3];
            return @"done";
        }, ^(NSString *output, NSError *error) {
            CHECK(NSThread.isMainThread && error == nil && [output isEqualToString:@"done"] && mainQueueRan);
            complete = YES;
        });
        dispatch_async(dispatch_get_main_queue(), ^{ mainQueueRan = YES; });
        PumpUntil(^BOOL { return complete; }, 5);
        // Real app save -> Foundation metadata readback, with no Python in the desktop app.
        app.searchField.stringValue = @"";
        [app applySearch];
        [app loadEntry:@"ALPHA"];
        app.envField.stringValue = @"UPDATED_TOKEN";
        app.noteView.string = @"Updated safely";
        app.dirty = YES;
        [app save:nil];
        CHECK(app.busy);
        PumpUntil(^BOOL { return !app.busy; }, 10);
        CHECK(app.lastError == nil && !app.dirty);
        NSDictionary *saved = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:indexPath] options:0 error:NULL];
        CHECK([saved[@"ALPHA"][@"env"] isEqualToString:@"UPDATED_TOKEN"]);
        CHECK([saved[@"ALPHA"][@"note"] isEqualToString:@"Updated safely"]);
        NSString *testKeychain = NSProcessInfo.processInfo.environment[@"NATIVE_TEST_KEYCHAIN"];
        if (testKeychain.length) {
            // Opt-in end-to-end path: a dedicated disposable Keychain, never the login Keychain.
            [app newEntry:nil];
            app.nameField.stringValue = @"NATIVE_E2E_SYNTHETIC";
            app.envField.stringValue = @"NATIVE_E2E_TOKEN";
            app.keychainPath = testKeychain;
            app.secretField.stringValue = @"  synthetic-value-with-spaces  ";
            [app save:nil];
            PumpUntil(^BOOL { return !app.busy; }, 10);
            CHECK(app.lastError == nil && [app.editingName isEqualToString:@"NATIVE_E2E_SYNTHETIC"]);
            [app toggleSecret:nil];
            PumpUntil(^BOOL { return !app.busy; }, 10);
            CHECK(app.secretVisible && [app.secretVisibleField.stringValue isEqualToString:@"  synthetic-value-with-spaces  "]);
            [app toggleSecret:nil];
            CHECK(!app.secretVisible && app.secretVisibleField.stringValue.length == 0);
            int status = 0;
            NSString *output = RunProcess(ToolPath(), @[@"run", @"NATIVE_E2E_SYNTHETIC", @"--", @"/usr/bin/python3", @"-c", @"import os; assert os.environ['NATIVE_E2E_TOKEN'] == '  synthetic-value-with-spaces  '"], nil, &status);
            CHECK(status == 0 && output.length == 0);
            // The unchanged CLI can update an item created by the native backend.
            output = RunProcess(ToolPath(), @[@"put", @"NATIVE_E2E_SYNTHETIC", @"--value", @"synthetic-from-cli", @"--service", @"NATIVE_E2E_SYNTHETIC", @"--keychain", testKeychain], nil, &status);
            CHECK(status == 0 && [output containsString:@"Stored"]);
            [app refresh:nil];
            [app loadEntry:@"NATIVE_E2E_SYNTHETIC"];
            [app toggleSecret:nil];
            PumpUntil(^BOOL { return !app.busy; }, 10);
            CHECK([app.secretVisibleField.stringValue isEqualToString:@"synthetic-from-cli"]);
            NSError *deleteError = nil;
            CHECK(DeleteSecretEntry(indexPath, @"NATIVE_E2E_SYNTHETIC", &deleteError) && deleteError == nil);
            [app refresh:nil];
            CHECK(app.metadata[@"NATIVE_E2E_SYNTHETIC"] == nil);
            NSError *readError = nil;
            CHECK(ReadSecretValue(@{@"service": @"NATIVE_E2E_SYNTHETIC", @"account": NSUserName(), @"keychain": testKeychain}, &readError) == nil && readError != nil);
            [app newEntry:nil];
            NSLog(@"Isolated Keychain save/reveal/inject/delete passed");
        }
        NSError *storeError = nil;
        NSData *beforeFailure = [NSData dataWithContentsOfFile:indexPath];
        CHECK(!SaveSecretEntry(indexPath, @"NEW_WITHOUT_VALUE", @{}, nil, YES, &storeError) && storeError != nil);
        CHECK([[NSData dataWithContentsOfFile:indexPath] isEqualToData:beforeFailure]);
        storeError = nil;
        CHECK(!SaveSecretEntry(indexPath, @"ALPHA", @{@"service": @"changed"}, nil, NO, &storeError) && storeError != nil);
        CHECK([[NSData dataWithContentsOfFile:indexPath] isEqualToData:beforeFailure]);
        NSDictionary *permissions = [NSFileManager.defaultManager attributesOfItemAtPath:indexPath error:NULL];
        CHECK(([permissions[NSFilePosixPermissions] unsignedIntegerValue] & 0777) == 0600);
        CHECK([app.window.title isEqualToString:@"Clinklet"]);
        NSString *invalidPath = [folder stringByAppendingPathComponent:@"invalid-index.json"];
        for (NSString *invalid in @[@"not-json", @"[]", @"{\"entry\": 7}"]) {
            [invalid writeToFile:invalidPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            NSError *invalidError = nil;
            CHECK(ReadSecretIndex(invalidPath, &invalidError) == nil && invalidError != nil);
            invalidError = nil;
            CHECK(!SaveSecretEntry(invalidPath, @"ENTRY", @{}, nil, YES, &invalidError));
            CHECK([[NSString stringWithContentsOfFile:invalidPath encoding:NSUTF8StringEncoding error:NULL] isEqualToString:invalid]);
        }
        // Build the in-memory search cache once; keystrokes never call a child process.
        NSMutableDictionary *many = [NSMutableDictionary dictionary];
        for (int i = 0; i < 10000; i++) many[[NSString stringWithFormat:@"KEY_%05d", i]] = @{@"env": @"TEST_ENV", @"note": @"Synthetic metadata"};
        [[NSJSONSerialization dataWithJSONObject:many options:0 error:NULL] writeToFile:indexPath atomically:YES];
        [app refresh:nil];
        app.searchField.stringValue = @"key_09999 synthetic";
        NSDate *start = NSDate.date;
        [app applySearch];
        CHECK(app.names.count == 1 && [app.names[0] isEqualToString:@"KEY_09999"]);
        NSLog(@"10,000-entry search: %.1f ms", -start.timeIntervalSinceNow * 1000);
        CHECK(-start.timeIntervalSinceNow < 1.0);
        // Capture only generated metadata for documentation, in both appearances.
        NSDictionary *demo = @{
            @"OpenAI · Personal": @{@"env": @"OPENAI_API_KEY", @"service": @"demo.openai", @"account": @"demo-user", @"note": @"Local coding assistant · development"},
            @"GitHub · Automation": @{@"env": @"GITHUB_TOKEN", @"service": @"demo.github", @"account": @"demo-user", @"note": @"Repository automation · read-only scope"},
            @"Staging · Service API": @{@"env": @"STAGING_API_TOKEN", @"service": @"demo.staging", @"account": @"demo-user", @"note": @"Integration tests · staging environment"}
        };
        [[NSJSONSerialization dataWithJSONObject:demo options:0 error:NULL] writeToFile:indexPath atomically:YES];
        app.searchField.stringValue = @"";
        [app refresh:nil];
        [app loadEntry:@"OpenAI · Personal"];
        [app applySearch];
        [app showStatus:@"Changes saved" kind:StatusSuccess];
        [app.window makeFirstResponder:app.table];
        for (NSString *appearance in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
            app.window.appearance = [NSAppearance appearanceNamed:appearance];
            [app.window.contentView layoutSubtreeIfNeeded];
            [app.window display];
            NSDate *settled = [NSDate dateWithTimeIntervalSinceNow:0.15];
            while (settled.timeIntervalSinceNow > 0) [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:settled];
            NSString *imagePath = [NSProcessInfo.processInfo.environment[@"NATIVE_TEST_ARTIFACTS"] stringByAppendingPathComponent:[appearance stringByAppendingString:@".png"]];
            if (imagePath) {
                int status = 0;
                RunProcess(@"/usr/sbin/screencapture", @[@"-x", @"-o", @"-l", [NSString stringWithFormat:@"%ld", (long)app.window.windowNumber], imagePath], nil, &status);
                CHECK(status == 0);
            }
        }
        [app.window orderOut:nil];
        [NSFileManager.defaultManager removeItemAtPath:folder error:NULL];
        NSLog(@"Native tests passed");
    }
    return 0;
}
