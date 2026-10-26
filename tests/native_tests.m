#define main KeychainSecretsApplicationMain
#import "../macos/KeychainSecretsApp.m"
#undef main

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
        CHECK(![app tableView:app.table shouldSelectRow:1]);
        app.searchField.stringValue = @"vendor-b";
        [app applySearch];
        CHECK(app.names.count == 1 && [app.editingName isEqualToString:@"ALPHA"]);
        [app setWorking:NO message:@"Ready"];
        CHECK(app.actionButtons[0].enabled && app.noteView.editable);

        // A slow process must not block the main queue, and completion is delivered on it.
        __block BOOL complete = NO;
        __block BOOL mainQueueRan = NO;
        RunAsync(@"/bin/sleep", @[@"0.3"], nil, ^(NSString *output, int status) {
            CHECK(NSThread.isMainThread && status == 0 && output.length == 0 && mainQueueRan);
            complete = YES;
        });
        dispatch_async(dispatch_get_main_queue(), ^{ mainQueueRan = YES; });
        PumpUntil(^BOOL { return complete; }, 5);
        // More than a pipe buffer on stdout and stderr, including a large stdin payload.
        NSString *largeInput = [@"payload" stringByPaddingToLength:300000 withString:@"x" startingAtIndex:0];
        complete = NO;
        RunAsync(@"/usr/bin/python3", @[@"-c", @"import sys; sys.stdout.write('o'*300000); sys.stderr.write('e'*300000); assert len(sys.stdin.read()) == 300000"], largeInput, ^(NSString *output, int status) {
            CHECK(status == 0 && output.length == 300000); complete = YES;
        });
        PumpUntil(^BOOL { return complete; }, 10);
        complete = NO;
        RunAsync(@"/does/not/exist", @[], nil, ^(NSString *output, int status) {
            CHECK(status != 0 && output.length > 0); complete = YES;
        });
        PumpUntil(^BOOL { return complete; }, 5);
        // Real app save -> bundled, unchanged CLI -> metadata readback; no Keychain access.
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
            output = RunProcess(ToolPath(), @[@"delete", @"NATIVE_E2E_SYNTHETIC"], nil, &status);
            CHECK(status == 0 && [output containsString:@"Deleted"]);
            [app refresh:nil];
            CHECK(app.metadata[@"NATIVE_E2E_SYNTHETIC"] == nil);
            [app newEntry:nil];
            NSLog(@"Isolated Keychain save/reveal/inject/delete passed");
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
        [[NSJSONSerialization dataWithJSONObject:fixture options:0 error:NULL] writeToFile:indexPath atomically:YES];
        app.searchField.stringValue = @"";
        [app refresh:nil];
        [app loadEntry:@"ALPHA"];
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
