#import <Cocoa/Cocoa.h>

#import "SecretStore.h"

static void RunStore(NSString *(^work)(NSError **), void (^completion)(NSString *, NSError *)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSError *error = nil;
            NSString *value = work(&error);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(value, error); });
        }
    });
}

static NSString *DefaultKeychainPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Keychains/login.keychain-db"];
}

static NSString *IndexPath(void) {
    const char *overridePath = getenv("KEYCHAIN_SECRETS_INDEX_PATH");
    if (overridePath != NULL && strlen(overridePath) > 0) {
        return [NSString stringWithUTF8String:overridePath];
    }
    NSString *modern = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/KeychainSecrets/index.json"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:modern]) {
        return modern;
    }
    NSString *legacy = [NSHomeDirectory() stringByAppendingPathComponent:@".codex/keychain-secrets/index.json"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:legacy]) {
        NSError *err = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:[modern stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&err];
        if (err == nil && [[NSFileManager defaultManager] copyItemAtPath:legacy toPath:modern error:&err]) {
            return modern;
        }
        return legacy;
    }
    return modern;
}

static NSScreen *PreferredScreen(void) {
    NSPoint primaryPoint = NSMakePoint(100, 100);
    for (NSScreen *screen in NSScreen.screens) {
        if (NSPointInRect(primaryPoint, screen.frame)) {
            return screen;
        }
    }
    return NSScreen.mainScreen ?: NSScreen.screens.firstObject;
}

static NSString *Trim(NSString *value) {
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSMenu *TextEditingMenu(void) {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [menu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@""];
    return menu;
}

static void InstallMainMenu(void) {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"Main Menu"];

    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appMenuItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Clinklet"];
    [appMenu addItemWithTitle:@"Quit Clinklet" action:@selector(terminate:) keyEquivalent:@"q"];
    appMenuItem.submenu = appMenu;

    NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:editMenuItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Find Secret…" action:@selector(focusSearch:) keyEquivalent:@"f"];
    editMenuItem.submenu = editMenu;

    NSMenuItem *fileItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"New Secret" action:@selector(newEntry:) keyEquivalent:@"n"];
    [fileMenu addItemWithTitle:@"Save Changes" action:@selector(save:) keyEquivalent:@"s"];
    [fileMenu addItemWithTitle:@"Refresh" action:@selector(refresh:) keyEquivalent:@"r"];
    fileItem.submenu = fileMenu;

    NSApp.mainMenu = mainMenu;
}

typedef NS_ENUM(NSInteger, StatusKind) { StatusIdle, StatusUnsaved, StatusWorking, StatusSuccess, StatusError };

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property NSWindow *window;
@property NSTableView *table;
@property NSMutableArray<NSString *> *names;
@property NSDictionary<NSString *, NSDictionary *> *metadata;
@property NSTextField *nameField;
@property NSTextField *envField;
@property NSTextField *serviceField;
@property NSTextField *accountField;
@property NSSecureTextField *secretField;
@property NSTextField *secretVisibleField;
@property NSButton *secretToggleButton;
@property NSButton *secretCopyButton;
@property NSTextView *noteView;
@property NSTextField *statusLabel;
@property NSTextField *hintLabel;
@property NSString *keychainPath;
@property BOOL secretVisible;
@property NSSearchField *searchField;
@property NSTextField *countLabel;
@property NSTextField *emptyLabel;
@property NSTextField *detailTitle;
@property NSProgressIndicator *progress;
@property NSImageView *statusIcon;
@property NSStackView *statusView;
@property NSUInteger statusGeneration;
@property NSArray<NSButton *> *actionButtons;
@property NSArray<NSString *> *allNames;
@property NSDictionary<NSString *, NSString *> *searchIndex;
@property NSString *editingName;
@property BOOL busy;
@property BOOL filtering;
@property BOOL dirty;
@property BOOL loading;
@property NSUInteger selectionGeneration;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.names = [NSMutableArray array];
    [self buildUI];
    [self refresh:nil];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (NSTextField *)label:(NSString *)text size:(CGFloat)size weight:(NSFontWeight)weight {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    return label;
}

- (NSStackView *)stack:(NSArray<NSView *> *)views vertical:(BOOL)vertical spacing:(CGFloat)spacing {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = vertical ? NSUserInterfaceLayoutOrientationVertical : NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = vertical ? NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
    stack.spacing = spacing;
    return stack;
}

- (void)buildUI {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1160, 760)
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Clinklet";
    self.window.delegate = (id<NSWindowDelegate>)self;
    self.window.minSize = NSMakeSize(1080, 740);
    self.window.titlebarAppearsTransparent = YES;
    self.window.backgroundColor = NSColor.windowBackgroundColor;
    NSScreen *screen = PreferredScreen();
    if (screen) {
        NSRect frame = self.window.frame;
        frame.origin = NSMakePoint(NSMidX(screen.visibleFrame) - frame.size.width / 2, NSMidY(screen.visibleFrame) - frame.size.height / 2);
        [self.window setFrame:frame display:NO];
    }

    NSTextField *libraryTitle = [self label:@"Your secrets" size:24 weight:NSFontWeightBold];
    NSTextField *subtitle = [self label:@"Local storage · macOS Keychain" size:12 weight:NSFontWeightRegular];
    subtitle.textColor = NSColor.secondaryLabelColor;
    self.searchField = [[NSSearchField alloc] init];
    self.searchField.placeholderString = @"Search names, variables, notes…";
    self.searchField.delegate = (id<NSSearchFieldDelegate>)self;
    self.searchField.sendsSearchStringImmediately = YES;
    self.searchField.accessibilityLabel = @"Search secrets";
    self.countLabel = [self label:@"" size:11 weight:NSFontWeightMedium];
    self.countLabel.textColor = NSColor.secondaryLabelColor;
    NSButton *newButton = [self button:@"New Secret" action:@selector(newEntry:)];
    newButton.imagePosition = NSImageLeading;
    newButton.image = [NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:nil];
    NSButton *refreshButton = [self button:@"Refresh" action:@selector(refresh:)];
    refreshButton.imagePosition = NSImageLeading;
    refreshButton.image = [NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:nil];
    NSStackView *libraryActions = [self stack:@[newButton, refreshButton] vertical:NO spacing:8];

    self.table = [[NSTableView alloc] init];
    self.table.delegate = self;
    self.table.dataSource = self;
    self.table.headerView = nil;
    self.table.rowHeight = 68;
    self.table.style = NSTableViewStyleFullWidth;
    self.table.backgroundColor = NSColor.controlBackgroundColor;
    self.table.allowsEmptySelection = YES;
    self.table.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    self.table.accessibilityLabel = @"Secrets";
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"entry"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    [self.table addTableColumn:column];
    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    scroll.documentView = self.table;
    self.emptyLabel = [NSTextField wrappingLabelWithString:@""];
    self.emptyLabel.textColor = NSColor.secondaryLabelColor;
    self.emptyLabel.font = [NSFont systemFontOfSize:13];
    NSStackView *library = [self stack:@[libraryTitle, subtitle, libraryActions, self.searchField, self.countLabel, self.emptyLabel, scroll] vertical:YES spacing:12];
    library.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *view in @[self.searchField, self.emptyLabel, scroll]) {
        [view.widthAnchor constraintEqualToAnchor:library.widthAnchor].active = YES;
    }
    [library.widthAnchor constraintEqualToConstant:380].active = YES;
    [self.searchField.heightAnchor constraintEqualToConstant:30].active = YES;
    [scroll.heightAnchor constraintGreaterThanOrEqualToConstant:100].active = YES;

    self.detailTitle = [self label:@"New secret" size:24 weight:NSFontWeightBold];
    NSTextField *detailSubtitle = [self label:@"Configure a credential for your apps and agents." size:12 weight:NSFontWeightRegular];
    detailSubtitle.textColor = NSColor.secondaryLabelColor;
    self.nameField = [NSTextField textFieldWithString:@""];
    self.envField = [NSTextField textFieldWithString:@""];
    self.serviceField = [NSTextField textFieldWithString:@""];
    self.accountField = [NSTextField textFieldWithString:NSUserName()];
    self.secretField = [NSSecureTextField textFieldWithString:@""];
    self.secretVisibleField = [NSTextField textFieldWithString:@""];
    self.secretVisibleField.hidden = YES;
    self.secretToggleButton = [self button:@"Show" action:@selector(toggleSecret:)];
    self.secretCopyButton = [self button:@"Copy" action:@selector(copySecret:)];
    for (NSTextField *field in @[self.nameField, self.envField, self.serviceField, self.accountField, self.secretField, self.secretVisibleField]) {
        field.menu = TextEditingMenu();
        field.delegate = (id<NSTextFieldDelegate>)self;
        field.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
        field.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    self.nameField.placeholderString = @"e.g. OPENAI_API_KEY";
    self.envField.placeholderString = @"Defaults to the secret name";
    self.serviceField.placeholderString = @"Defaults to the secret name";
    self.accountField.placeholderString = @"Keychain account";
    self.secretField.placeholderString = @"Leave blank to keep the stored value";
    self.secretVisibleField.placeholderString = self.secretField.placeholderString;
    NSStackView *secretInput = [self stack:@[self.secretField, self.secretVisibleField, self.secretCopyButton, self.secretToggleButton] vertical:NO spacing:6];
    [self.secretField.widthAnchor constraintEqualToAnchor:self.secretVisibleField.widthAnchor].active = YES;
    [self.secretField.widthAnchor constraintGreaterThanOrEqualToConstant:160].active = YES;
    [self.secretField setContentHuggingPriority:200 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.secretVisibleField setContentHuggingPriority:200 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *fields = [self stack:@[
        [self row:@"Name" input:self.nameField],
        [self row:@"Environment" input:self.envField],
        [self row:@"Secret value" input:secretInput],
        [self row:@"Service" input:self.serviceField],
        [self row:@"Account" input:self.accountField]
    ] vertical:YES spacing:14];
    for (NSView *row in fields.arrangedSubviews) [row.widthAnchor constraintEqualToAnchor:fields.widthAnchor].active = YES;

    NSTextField *noteLabel = [self label:@"NOTES" size:11 weight:NSFontWeightSemibold];
    noteLabel.textColor = NSColor.secondaryLabelColor;
    self.noteView = [[NSTextView alloc] init];
    self.noteView.font = [NSFont systemFontOfSize:13];
    self.noteView.richText = NO;
    self.noteView.textContainerInset = NSMakeSize(10, 10);
    self.noteView.delegate = (id<NSTextViewDelegate>)self;
    self.noteView.menu = TextEditingMenu();
    NSScrollView *noteScroll = [[NSScrollView alloc] init];
    noteScroll.hasVerticalScroller = YES;
    noteScroll.borderType = NSBezelBorder;
    noteScroll.documentView = self.noteView;
    [noteScroll.heightAnchor constraintEqualToConstant:112].active = YES;
    self.hintLabel = [NSTextField wrappingLabelWithString:@"Values stay in macOS Keychain. Search uses names and metadata only."];
    self.hintLabel.textColor = NSColor.secondaryLabelColor;
    self.hintLabel.font = [NSFont systemFontOfSize:12];
    self.statusLabel = [self label:@"" size:12 weight:NSFontWeightMedium];
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.progress = [[NSProgressIndicator alloc] init];
    self.progress.style = NSProgressIndicatorStyleSpinning;
    self.progress.controlSize = NSControlSizeSmall;
    self.progress.displayedWhenStopped = NO;
    self.statusIcon = [[NSImageView alloc] init];
    self.statusIcon.imageScaling = NSImageScaleProportionallyDown;
    [self.statusIcon.widthAnchor constraintEqualToConstant:14].active = YES;
    [self.statusIcon.heightAnchor constraintEqualToConstant:14].active = YES;
    [self.progress.widthAnchor constraintEqualToConstant:14].active = YES;
    [self.progress.heightAnchor constraintEqualToConstant:14].active = YES;
    self.statusView = [self stack:@[self.progress, self.statusIcon, self.statusLabel] vertical:NO spacing:6];
    self.statusView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.statusLabel.widthAnchor constraintLessThanOrEqualToConstant:420].active = YES;
    NSButton *saveButton = [self button:@"Save Changes" action:@selector(save:)];
    saveButton.bezelColor = NSColor.controlAccentColor;
    NSButton *deleteButton = [self button:@"Delete…" action:@selector(deleteEntry:)];
    deleteButton.contentTintColor = NSColor.systemRedColor;
    NSStackView *actions = [self stack:@[saveButton, deleteButton] vertical:NO spacing:10];
    self.actionButtons = @[newButton, saveButton, deleteButton, refreshButton, self.secretCopyButton, self.secretToggleButton];

    NSStackView *detail = [self stack:@[self.detailTitle, detailSubtitle, fields, noteLabel, noteScroll, self.hintLabel, actions] vertical:YES spacing:18];
    detail.edgeInsets = NSEdgeInsetsMake(26, 26, 26, 26);
    detail.wantsLayer = YES;
    detail.layer.cornerRadius = 16;

    detail.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *view in @[fields, noteScroll, self.hintLabel]) {
        [view.widthAnchor constraintEqualToAnchor:detail.widthAnchor constant:-52].active = YES;
    }
    NSView *content = self.window.contentView;
    NSVisualEffectView *card = [[NSVisualEffectView alloc] init];
    card.material = NSVisualEffectMaterialContentBackground;
    card.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    card.state = NSVisualEffectStateActive;
    card.wantsLayer = YES;
    card.layer.cornerRadius = 16;
    card.layer.masksToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:library];
    [content addSubview:card];
    [content addSubview:detail];
    [content addSubview:self.statusView];
    [NSLayoutConstraint activateConstraints:@[
        [self.statusView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [self.statusView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
        [self.statusView.leadingAnchor constraintGreaterThanOrEqualToAnchor:content.leadingAnchor constant:24],
        [self.statusView.heightAnchor constraintEqualToConstant:18],
    ]];
    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:detail.leadingAnchor],
        [card.trailingAnchor constraintEqualToAnchor:detail.trailingAnchor],
        [card.topAnchor constraintEqualToAnchor:detail.topAnchor],
        [card.bottomAnchor constraintEqualToAnchor:detail.bottomAnchor],
    ]];
    [NSLayoutConstraint activateConstraints:@[
        [library.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [library.topAnchor constraintEqualToAnchor:content.topAnchor constant:24],
        [library.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-48],
        [detail.leadingAnchor constraintEqualToAnchor:library.trailingAnchor constant:24],
        [detail.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [detail.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
        [detail.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-48],
    ]];
    [self newEntry:nil];
}

- (NSView *)row:(NSString *)label input:(NSView *)input {
    NSTextField *caption = [self label:label size:12 weight:NSFontWeightMedium];
    caption.textColor = NSColor.secondaryLabelColor;
    [caption.widthAnchor constraintEqualToConstant:100].active = YES;
    NSStackView *row = [self stack:@[caption, input] vertical:NO spacing:12];
    [input setContentHuggingPriority:200 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [input.widthAnchor constraintEqualToAnchor:row.widthAnchor constant:-112].active = YES;
    return row;
}

- (NSButton *)button:(NSString *)title action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.bezelStyle = NSBezelStyleRounded;
    return button;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.names.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSString *name = self.names[row];
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"entry" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] init];
        cell.identifier = @"entry";
        NSTextField *title = [self label:@"" size:13 weight:NSFontWeightSemibold];
        NSTextField *subtitle = [self label:@"" size:11 weight:NSFontWeightRegular];
        subtitle.textColor = NSColor.secondaryLabelColor;
        title.tag = 1;
        subtitle.tag = 2;
        for (NSTextField *label in @[title, subtitle]) {
            label.lineBreakMode = NSLineBreakByTruncatingTail;
            label.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:label];
            [label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:10].active = YES;
            [label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-10].active = YES;
        }
        [title.topAnchor constraintEqualToAnchor:cell.topAnchor constant:12].active = YES;
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:5].active = YES;
        NSBox *separator = [[NSBox alloc] init];
        separator.boxType = NSBoxSeparator;
        separator.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:separator];
        [NSLayoutConstraint activateConstraints:@[
            [separator.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:10],
            [separator.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-10],
            [separator.bottomAnchor constraintEqualToAnchor:cell.bottomAnchor],
            [separator.heightAnchor constraintEqualToConstant:1],
        ]];
        cell.textField = title;
    }
    cell.textField.stringValue = name;
    NSString *env = [self field:@"env" forName:name fallback:name];
    NSString *note = [self field:@"note" forName:name fallback:@""];
    ((NSTextField *)[cell viewWithTag:2]).stringValue = note.length ? [NSString stringWithFormat:@"%@ · %@", env, note] : env;
    cell.toolTip = [NSString stringWithFormat:@"%@\n%@\n%@", name, env, note];
    return cell;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    return !self.busy && [self confirmDiscard];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (self.filtering || self.busy) return;
    NSInteger row = self.table.selectedRow;
    if (row >= 0 && (NSUInteger)row < self.names.count) [self loadEntry:self.names[row]];
}

- (BOOL)confirmDiscard {
    if (!self.dirty) return YES;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Discard unsaved changes?";
    alert.informativeText = @"Your changes have not been saved to Keychain.";
    [alert addButtonWithTitle:@"Keep Editing"];
    [alert addButtonWithTitle:@"Discard Changes"];
    return [alert runModal] == NSAlertSecondButtonReturn;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (self.busy) {
        [self showStatus:@"Wait for the current operation before quitting." kind:StatusWorking];
        return NSTerminateCancel;
    }
    return [self confirmDiscard] ? NSTerminateNow : NSTerminateCancel;
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (self.busy || ![self confirmDiscard]) return NO;
    self.dirty = NO;
    return YES;
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == self.searchField) {
        [self applySearch];
    } else if (!self.loading) {
        self.dirty = YES;
        [self showStatus:@"Unsaved changes" kind:StatusUnsaved];
    }
}

- (void)textDidChange:(NSNotification *)notification {
    if (!self.loading) {
        self.dirty = YES;
        [self showStatus:@"Unsaved changes" kind:StatusUnsaved];
    }
}

- (IBAction)focusSearch:(id)sender {
    [self.window makeFirstResponder:self.searchField];
    [self.searchField selectText:nil];
}

- (void)applySearch {
    NSArray<NSString *> *tokens = [Trim(self.searchField.stringValue) componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.filtering = YES;
    [self.names removeAllObjects];
    for (NSString *name in self.allNames) {
        NSString *text = self.searchIndex[name];
        BOOL matches = YES;
        for (NSString *token in tokens) {
            if (token.length && [text rangeOfString:token options:(NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch)].location == NSNotFound) {
                matches = NO;
                break;
            }
        }
        if (matches) [self.names addObject:name];
    }
    [self.table deselectAll:nil];
    [self.table reloadData];
    NSUInteger selected = self.editingName ? [self.names indexOfObject:self.editingName] : NSNotFound;
    if (selected != NSNotFound) [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:selected] byExtendingSelection:NO];
    self.filtering = NO;
    self.countLabel.stringValue = [NSString stringWithFormat:@"%lu of %lu secrets", (unsigned long)self.names.count, (unsigned long)self.allNames.count];
    self.emptyLabel.hidden = self.names.count > 0;
    self.emptyLabel.stringValue = self.allNames.count ? @"No matching secrets. Try another name, variable, or note." : @"Your vault is ready. Add your first secret to get started.";
}

- (BOOL)loadMetadata {
    NSData *data = [NSData dataWithContentsOfFile:IndexPath()];
    if (data == nil) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:IndexPath()]) {
            [self showError:@"Unable to read the metadata index. Check the file permissions and refresh."];
            return NO;
        }
        self.metadata = @{};
        return YES;
    }

    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![object isKindOfClass:[NSDictionary class]]) {
        [self showError:@"The metadata index is invalid. Restore a valid JSON index and refresh."];
        return NO;
    }

    NSMutableDictionary<NSString *, NSDictionary *> *metadata = [NSMutableDictionary dictionary];
    NSDictionary *rawMetadata = (NSDictionary *)object;
    for (id key in rawMetadata) {
        id value = rawMetadata[key];
        if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSDictionary class]]) {
            metadata[key] = value;
        }
    }
    self.metadata = metadata;
    return YES;
}

- (NSString *)field:(NSString *)field forName:(NSString *)name fallback:(NSString *)fallback {
    id value = self.metadata[name][field];
    if (![value isKindOfClass:[NSString class]]) {
        return fallback;
    }
    NSString *trimmed = Trim(value);
    return trimmed.length > 0 ? trimmed : fallback;
}

- (void)loadEntry:(NSString *)name {
    self.loading = YES;
    self.selectionGeneration++;
    self.editingName = name;
    self.detailTitle.stringValue = @"Secret details";
    self.nameField.stringValue = name;
    self.nameField.editable = NO;
    self.envField.stringValue = [self field:@"env" forName:name fallback:name];
    self.serviceField.stringValue = [self field:@"service" forName:name fallback:name];
    self.accountField.stringValue = [self field:@"account" forName:name fallback:NSUserName()];
    self.keychainPath = [self field:@"keychain" forName:name fallback:DefaultKeychainPath()];
    [self resetSecretFields];
    self.noteView.string = [self field:@"note" forName:name fallback:@""];
    [self showStatus:@"" kind:StatusIdle];
    self.loading = NO;
    self.dirty = NO;
}

- (IBAction)newEntry:(id)sender {
    if (self.busy || ![self confirmDiscard]) return;
    self.loading = YES;
    self.selectionGeneration++;
    self.editingName = nil;
    self.detailTitle.stringValue = @"New secret";
    [self.table deselectAll:nil];
    self.nameField.editable = YES;
    self.nameField.stringValue = @"";
    self.envField.stringValue = @"";
    self.serviceField.stringValue = @"";
    self.accountField.stringValue = NSUserName();
    self.keychainPath = DefaultKeychainPath();
    [self resetSecretFields];
    self.noteView.string = @"";
    [self showStatus:@"" kind:StatusIdle];
    self.loading = NO;
    self.dirty = NO;
    [self.window makeFirstResponder:self.nameField];
}

- (IBAction)refresh:(id)sender {
    if (self.busy || (sender && ![self confirmDiscard])) return;
    if (![self loadMetadata]) return;
    if (sender) {
        if (self.editingName && self.metadata[self.editingName]) [self loadEntry:self.editingName];
        else { self.dirty = NO; [self newEntry:nil]; }
    }
    self.allNames = [self.metadata.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableDictionary *index = [NSMutableDictionary dictionary];
    for (NSString *name in self.allNames) {
        NSMutableArray *parts = [NSMutableArray arrayWithObject:name];
        for (NSString *field in @[@"env", @"service", @"account", @"note"]) [parts addObject:[self field:field forName:name fallback:@""]];
        index[name] = [parts componentsJoinedByString:@"\n"];
    }
    self.searchIndex = index;
    [self applySearch];
    if (sender) [self showStatus:@"Refreshed" kind:StatusSuccess];
}

- (void)showStatus:(NSString *)message kind:(StatusKind)kind {
    NSUInteger generation = ++self.statusGeneration;
    self.statusView.hidden = kind == StatusIdle;
    self.statusLabel.stringValue = message;
    self.statusLabel.toolTip = message;
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusIcon.hidden = kind == StatusWorking || kind == StatusIdle;
    self.progress.hidden = kind != StatusWorking;
    if (kind == StatusWorking) [self.progress startAnimation:nil]; else [self.progress stopAnimation:nil];
    NSString *symbol = kind == StatusSuccess ? @"checkmark.circle" : kind == StatusError ? @"exclamationmark.circle" : @"circle.inset.filled";
    NSColor *color = kind == StatusSuccess ? NSColor.systemGreenColor : kind == StatusError ? NSColor.systemRedColor : NSColor.systemOrangeColor;
    self.statusIcon.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:message];
    self.statusIcon.contentTintColor = color;
    if (kind == StatusError) self.statusLabel.textColor = NSColor.systemRedColor;
    if (kind == StatusSuccess) {
        __weak AppDelegate *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            AppDelegate *owner = weakSelf;
            if (owner && owner.statusGeneration == generation) {
                [owner showStatus:owner.dirty ? @"Unsaved changes" : @"" kind:owner.dirty ? StatusUnsaved : StatusIdle];
            }
        });
    }
}

- (void)setWorking:(BOOL)working message:(NSString *)message {
    self.busy = working;
    for (NSButton *button in self.actionButtons) button.enabled = !working;
    for (NSTextField *field in @[self.nameField, self.envField, self.serviceField, self.accountField, self.secretField, self.secretVisibleField]) field.enabled = !working;
    self.noteView.editable = !working;
    [self showStatus:working ? message : (self.dirty ? @"Unsaved changes" : @"")
                kind:working ? StatusWorking : (self.dirty ? StatusUnsaved : StatusIdle)];
}

- (IBAction)save:(id)sender {
    if (self.busy) return;
    NSString *name = Trim(self.nameField.stringValue);
    if (name.length == 0) {
        [self showError:@"Name is required."];
        return;
    }
    NSString *envName = Trim(self.envField.stringValue);
    NSString *service = Trim(self.serviceField.stringValue);
    NSString *account = Trim(self.accountField.stringValue);
    NSString *secret = self.secretVisible ? self.secretVisibleField.stringValue : self.secretField.stringValue;
    NSString *note = self.noteView.string ?: @"";
    if (envName.length == 0) envName = name;
    if (service.length == 0) service = name;
    if (account.length == 0) account = NSUserName();

    if (!self.editingName && self.metadata[name]) {
        [self showError:@"This name already exists. Select the existing entry to edit it."];
        return;
    }
    if (!self.editingName && secret.length == 0) {
        [self showError:@"A secret value is required for a new entry."];
        return;
    }
    NSDictionary *entry = @{@"env": envName, @"service": service, @"account": account,
                            @"note": note, @"keychain": self.keychainPath ?: DefaultKeychainPath()};
    NSString *indexPath = IndexPath();
    BOOL creating = self.editingName == nil;
    [self setWorking:YES message:@"Saving to Keychain…"];
    RunStore(^NSString *(NSError **error) {
        SaveSecretEntry(indexPath, name, entry, secret.length ? secret : nil, creating, error);
        return nil;
    }, ^(NSString *value __unused, NSError *error) {
        [self setWorking:NO message:@""];
        if (error) { [self showError:error.localizedDescription]; return; }
        self.dirty = NO;
        self.editingName = name;
        [self refresh:nil];
        [self loadEntry:name];
        [self showStatus:@"Changes saved" kind:StatusSuccess];
    });
}

- (IBAction)deleteEntry:(id)sender {
    if (self.busy) return;
    NSString *name = self.editingName;
    if (!name) { [self showError:@"Select a saved entry to delete."]; return; }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Delete %@?", name];
    alert.informativeText = @"This permanently removes the Keychain value and its metadata, including any unsaved changes.";
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:@"Delete Secret"];
    if ([alert runModal] != NSAlertSecondButtonReturn) return;
    [self setWorking:YES message:@"Deleting from Keychain…"];
    NSString *indexPath = IndexPath();
    RunStore(^NSString *(NSError **error) {
        DeleteSecretEntry(indexPath, name, error);
        return nil;
    }, ^(NSString *value __unused, NSError *error) {
        [self setWorking:NO message:@""];
        if (error) { [self showError:error.localizedDescription]; return; }
        self.dirty = NO;
        [self newEntry:nil];
        [self refresh:nil];
        [self showStatus:@"Secret deleted" kind:StatusSuccess];
    });
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(focusSearch:)) return YES;
    if (item.action == @selector(save:) || item.action == @selector(newEntry:) || item.action == @selector(refresh:)) return !self.busy;
    return YES;
}

- (void)showError:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Clinklet";
    alert.informativeText = message ?: @"Unknown error";
    [self showStatus:message ?: @"Unknown error" kind:StatusError];
    [alert runModal];
}

- (void)resetSecretFields {
    self.secretVisible = NO;
    self.secretField.hidden = NO;
    self.secretVisibleField.hidden = YES;
    self.secretField.stringValue = @"";
    self.secretVisibleField.stringValue = @"";
    self.secretToggleButton.title = @"Show";
}

- (void)readCurrentSecret:(void (^)(NSString *))completion {
    if (self.busy) return;
    NSString *typed = self.secretVisible ? self.secretVisibleField.stringValue : self.secretField.stringValue;
    if (typed.length > 0) { completion(typed); return; }
    NSString *name = self.editingName;
    if (!name) { [self showError:@"Enter a secret value first."]; return; }
    // Read the persisted identity, even if the form contains unsaved service/account edits.
    NSString *service = [self field:@"service" forName:name fallback:name];
    NSString *account = [self field:@"account" forName:name fallback:NSUserName()];
    NSString *keychain = [self field:@"keychain" forName:name fallback:DefaultKeychainPath()];
    NSUInteger generation = self.selectionGeneration;
    [self setWorking:YES message:@"Waiting for Keychain…"];
    NSDictionary *entry = @{@"service": service, @"account": account, @"keychain": keychain};
    RunStore(^NSString *(NSError **error) { return ReadSecretValue(entry, error); }, ^(NSString *output, NSError *error) {
        [self setWorking:NO message:@""];
        if (generation != self.selectionGeneration) return;
        if (error) { [self showError:error.localizedDescription]; return; }
        completion(output);
    });
}

- (IBAction)toggleSecret:(id)sender {
    if (self.busy) return;
    if (self.secretVisible) {
        self.secretField.stringValue = self.secretVisibleField.stringValue;
        self.secretVisibleField.stringValue = @"";
        self.secretVisibleField.hidden = YES;
        self.secretField.hidden = NO;
        self.secretVisible = NO;
        self.secretToggleButton.title = @"Show";
        return;
    }
    [self readCurrentSecret:^(NSString *value) {
        self.secretVisibleField.stringValue = value;
        self.secretField.hidden = YES;
        self.secretVisibleField.hidden = NO;
        self.secretVisible = YES;
        self.secretToggleButton.title = @"Hide";
    }];
}

- (IBAction)copySecret:(id)sender {
    [self readCurrentSecret:^(NSString *value) {
        NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
        [pasteboard clearContents];
        [pasteboard setString:value forType:NSPasteboardTypeString];
        [self showStatus:@"Copied to clipboard" kind:StatusSuccess];
    }];
}

@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        InstallMainMenu();
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
