//
//  NWAppDelegate.m
//  Pusher
//
//  Copyright (c) 2012 noodlewerk. All rights reserved.
//

#import "NWAppDelegate.h"
#import "NWHub.h"
#import "NWNotification.h"
#import "NWSecTools.h"
#import "NWLCore.h"
#import "NWPushFeedback.h"
#import "NWPushService.h"
#import "NWTokensImporter.h"

@interface NWAppDelegate () <NWHubDelegate> @end

@implementation NWAppDelegate
{
    IBOutlet NSPopUpButton *_certificatePopup;
    IBOutlet NSComboBox *_tokenCombo;
    IBOutlet NSButton *_importButton;
    IBOutlet NSTextView *_payloadField;
    IBOutlet NSTextView *_logField;
    IBOutlet NSTextField *_countField;
    IBOutlet NSTextField *_infoField;
    IBOutlet NSButton *_pushButton;
    IBOutlet NSButton *_reconnectButton;
    IBOutlet NSPopUpButton *_expiryPopup;
    IBOutlet NSPopUpButton *_priorityPopup;
    IBOutlet NSLayoutConstraint *progressConstraint;
    IBOutlet NSProgressIndicator *progressIndicator;
    IBOutlet NSSlider *_delaySlider;
    IBOutlet NSTextField *_delayLabel;
    IBOutlet NSScrollView *_logScroll;

    NWHub *_hub;
    NSDictionary *_config;
    NSArray *_certificateIdentityPairs;
    NSUInteger _lastSelectedIndex;
    NWCertificateRef _selectedCertificate;
    
    NWPushService *pushService;
    NWTokensImporter *importer;
    NSMutableArray *certificateInvalidTokens;
    
    dispatch_queue_t _serial;
}


#pragma mark - Application delegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    NWLogInfo(@"Application did finish launching");
    NWLAddPrinter("NWPusher", NWPusherPrinter, 0);
    NWLPrintInfo();
    _serial = dispatch_queue_create("NWAppDelegate", DISPATCH_QUEUE_SERIAL);
    
    certificateInvalidTokens = @[].mutableCopy;
    
    [self resetTokenCombo];
    
    _certificateIdentityPairs = @[];
    [self loadCertificatesFromKeychain];
    [self migrateOldConfigurationIfNeeded];
    [self loadConfig];
    [self updateCertificatePopup];
    
    [_delaySlider setDoubleValue:0.0];
    [self delayValueChanged:_delaySlider];

    [self createPushService];
    
    NSString *payload = [_config valueForKey:@"payload"];
    _payloadField.string = payload.length ? payload : @"";
    _payloadField.font = [NSFont fontWithName:@"Monaco" size:10];
    _payloadField.enabledTextCheckingTypes = 0;
    _logField.enabledTextCheckingTypes = 0;
    [self updatePayloadCounter];
    NWLogInfo(@"");
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    [self saveConfig];
    NWLRemovePrinter("NWPusher");
    [_hub disconnect]; _hub.delegate = nil; _hub = nil;
    NWLogInfo(@"Application will terminate");
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application
{
    return YES;
}

#pragma mark - Events

- (IBAction)certificateSelected:(NSPopUpButton *)sender
{
    [self connectWithCertificateAtIndex:_certificatePopup.indexOfSelectedItem];
}

- (IBAction)tokenSelected:(NSComboBox *)sender
{
    [self selectTokenAndUpdateCombo];
}

- (void)textDidChange:(NSNotification *)notification
{
    if (notification.object == _payloadField) [self updatePayloadCounter];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
//    if (notification.object == _tokenCombo) [self something];
}

- (IBAction)push:(NSButton *)sender
{
    BOOL batchPush = importer && ([importer.availableTokens count] > 0);
    if(!batchPush)
    {
        [self addTokenAndUpdateCombo];
        [self push];
        [self upPayloadTextIndex];
    } else {
        [self pushToImported];
    }
}

- (IBAction)reconnect:(NSButton *)sender
{
    [self reconnect];
}

- (void)notification:(NWNotification *)notification didFailWithError:(NSError *)error
{
    dispatch_async(dispatch_get_main_queue(), ^{
        //NSLog(@"failed notification: %@ %@ %lu %lu %lu", notification.payload, notification.token, notification.identifier, notification.expires, notification.priority);
        NWLogWarn(@"Notification error: %@", error.localizedDescription);
    });
}

- (IBAction)selectOutput:(NSSegmentedControl *)sender {
    _logScroll.hidden = sender.selectedSegment != 1;
}

- (IBAction)readFeedback:(id)sender {
    [self feedback];
}

- (IBAction)importTokens:(NSButton*)sender
{
    if(importer)
    {
        if([importer isWorking])
        {
            return;
        }
        [self purgeTokens];
    } else {
        [self importTokens];
    }
}

- (IBAction) delayValueChanged:(NSSlider*) sender
{
    [_delayLabel setTitleWithMnemonic:[NSString stringWithFormat:@"%tums",[self pushDelayInMs]]];
}

-(NSUInteger) pushDelayInMs
{
    double span = _delaySlider.maxValue - _delaySlider.minValue;
    NSUInteger valueInMs = 2 * (NSUInteger)floor((_delaySlider.doubleValue/span * 500.0)/2.0);
    return valueInMs;
}

#pragma mark - Push service

- (void) createPushService
{
    pushService = [[NWPushService alloc] init];

    __weak typeof(self) weakSelf = self;
    __weak NWPushService *weakService = pushService;
    
    pushService.beginBlock = ^(){
        NWLogInfo(@"Push start");
        [weakSelf showSendProgress:YES];
    };
    pushService.completionBlock = ^(){
        [weakSelf purgeTokens];
        [weakSelf showSendProgress:NO];
    };
    pushService.notificationWillSend = ^(NSString *token) {
        NWLogInfo(@"Sending notification for token '%@': progress %.2f%%", token, weakService.progress);
    };
    pushService.notificationSendComplete = ^(NSString *token) {
        NWLogInfo(@"Notification send for token '%@': progress %.2f%%", token, weakService.progress);
    };
    pushService.notificationSendError = ^(NSString* token, NSError *error) {
        NWLogWarn(@"Send notification failed for token '%@' with error '%@': progress %.2f%%", token, error.localizedDescription, weakService.progress);
    };
}

- (void)showSendProgress:(BOOL) value
{
    [self showProgress:value];
    
    if(value)
    {
        _delaySlider.enabled = NO;
        _expiryPopup.enabled = NO;
        _priorityPopup.enabled = NO;
    } else {
        _delaySlider.enabled = YES;
        _expiryPopup.enabled = YES;
        _priorityPopup.enabled = YES;
    }
}

#pragma mark - Certificate and Identity

- (void)loadCertificatesFromKeychain
{
    NSError *error = nil;
    NSArray *certs = [NWSecTools keychainCertificatesWithError:&error];
    if (!certs) {
        NWLogWarn(@"Unable to access keychain: %@", error.localizedDescription);
    }
    if (!certs.count) {
        NWLogWarn(@"No push certificates in keychain.");
    }
    certs = [certs sortedArrayUsingComparator:^NSComparisonResult(NWCertificateRef a, NWCertificateRef b) {
        BOOL adev = [NWSecTools isSandboxCertificate:a];
        BOOL bdev = [NWSecTools isSandboxCertificate:b];
        if (adev != bdev) {
            return adev ? NSOrderedAscending : NSOrderedDescending;
        }
        NSString *aname = [NWSecTools summaryWithCertificate:a];
        NSString *bname = [NWSecTools summaryWithCertificate:b];
        return [aname compare:bname];
    }];
    NSMutableArray *pairs = @[].mutableCopy;
    for (NWCertificateRef c in certs) {
        [pairs addObject:@[c, NSNull.null]];
    }
    _certificateIdentityPairs = [_certificateIdentityPairs arrayByAddingObjectsFromArray:pairs];
}

- (void)updateCertificatePopup
{
    NSMutableString *suffix = @" ".mutableCopy;
    [_certificatePopup removeAllItems];
    [_certificatePopup addItemWithTitle:@"Select Push Certificate"];
    NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
    [formatter setDateStyle:NSDateFormatterShortStyle];
    [formatter setTimeStyle:NSDateFormatterShortStyle];
    for (NSArray *pair in _certificateIdentityPairs) {
        NWCertificateRef certificate = pair[0];
        BOOL hasIdentity = (pair[1] != NSNull.null);
        BOOL sandbox = [NWSecTools isSandboxCertificate:certificate];
        NSString *summary = [NWSecTools summaryWithCertificate:certificate];
        NSDate *date = [NWSecTools expirationWithCertificate:certificate];
        NSString *expire = [NSString stringWithFormat:@"  [%@]", date ? [formatter stringFromDate:date] : @"expired"];
        // summary = @"com.example.app";
        [_certificatePopup addItemWithTitle:[NSString stringWithFormat:@"%@%@%@%@%@", hasIdentity ? @"imported: " : @"", summary, sandbox ? @" (sandbox)" : @"", expire, suffix]];
        [suffix appendString:@" "];
    }
    [_certificatePopup addItemWithTitle:@"Import PKCS #12 file (.p12)..."];
}

- (void)importIdentity
{
    NWLogInfo(@"");
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = YES;
    panel.allowedFileTypes = @[@"p12"];
    [panel beginWithCompletionHandler:^(NSInteger result){
        if (result != NSFileHandlingPanelOKButton) {
            return;
        }
        NSMutableArray *pairs = @[].mutableCopy;
        for (NSURL *url in panel.URLs) {
            NSString *text = [NSString stringWithFormat:@"Enter password for %@", url.lastPathComponent];
            NSAlert *alert = [NSAlert alertWithMessageText:text defaultButton:@"OK" alternateButton:@"Cancel" otherButton:nil informativeTextWithFormat:@""];
            NSSecureTextField *input = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
            alert.accessoryView = input;
            NSInteger button = [alert runModal];
            if (button != NSAlertDefaultReturn) {
                return;
            }
            NSString *password = input.stringValue;
            NSData *data = [NSData dataWithContentsOfURL:url];
            NSError *error = nil;
            NSArray *ids = [NWSecTools identitiesWithPKCS12Data:data password:password error:&error];
            if (!ids) {
                NWLogWarn(@"Unable to read p12 file: %@", error.localizedDescription);
                return;
            }
            for (NWIdentityRef identity in ids) {
                NSError *error = nil;
                NWCertificateRef certificate = [NWSecTools certificateWithIdentity:identity error:&error];
                if (!certificate) {
                    NWLogWarn(@"Unable to import p12 file: %@", error.localizedDescription);
                    return;
                }
                [pairs addObject:@[certificate, identity]];
            }
        }
        if (!pairs.count) {
            NWLogWarn(@"Unable to import p12 file: no push certificates found");
            return;
        }
        NWLogInfo(@"Imported %i certificate%@", (int)pairs.count, pairs.count == 1 ? @"" : @"s");
        NSUInteger index = _certificateIdentityPairs.count;
        _certificateIdentityPairs = [_certificateIdentityPairs arrayByAddingObjectsFromArray:pairs];
        [self updateCertificatePopup];
        [self connectWithCertificateAtIndex:index + 1];
    }];
}

#pragma mark - Import tokens list

- (void) purgeTokens
{
    if(importer)
    {
        importer = nil;
        NWLogInfo(@"Purge imported tokens");
        _importButton.title = @"Import tokens";
        _tokenCombo.enabled = YES;
        _certificatePopup.enabled = YES;
        _pushButton.enabled = YES;
        _importButton.enabled = YES;
    }
}

- (void) importTokens
{
    NWLogInfo(@"");

    importer = [[NWTokensImporter alloc] init];
    __weak typeof(self) weakSelf = self;
    
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = YES;
    panel.allowedFileTypes = @[@"txt", @"csv"];
    [panel beginWithCompletionHandler:^(NSInteger result){
        if (result != NSFileHandlingPanelOKButton)
        {
            return;
        }

        for (NSURL *url in panel.URLs)
        {
            [importer addTokensFile:url];
        }
        
        NWLogInfo(@"Importing tokens...");
        [self showProgress:YES];
        [importer parseTokensWithBlock:nil
                            completion:^(NSArray *tokens){
                                dispatch_async(dispatch_get_main_queue(), ^(){
                                    [weakSelf tokensImported:tokens];
                                });
                            }];

    }];
}

- (void)tokensImported:(NSArray*) tokens
{
    [self showProgress:NO];
    
    if (!tokens.count)
    {
        NWLogWarn(@"Unable to tokens from file: no tokens found");
        return;
    }
    
    NWLogInfo(@"Imported %i tokens", (int)tokens.count);
}

- (void)showImportProgress:(BOOL) value
{
    [self showProgress:value];

    _tokenCombo.enabled = NO;
    _certificatePopup.enabled = NO;
    
    if(value)
    {
        _importButton.title = @"Importing ...";
    } else {
        _importButton.title = @"Purge tokens";
    }
}

#pragma mark - Mark progress

- (void)showProgress:(BOOL) value
{
    if(value)
    {
        _tokenCombo.enabled = NO;
        _certificatePopup.enabled = NO;
        _pushButton.enabled = NO;
        _importButton.enabled = NO;
        [progressIndicator startAnimation:self];
        progressConstraint.constant = 44;
    } else {
        _tokenCombo.enabled = YES;
        _certificatePopup.enabled = YES;
        _pushButton.enabled = YES;
        _importButton.enabled = YES;
        [progressIndicator stopAnimation:self];
        progressConstraint.constant = 20;
    }
}

#pragma mark - Expiry and Priority

- (NSDate *)selectedExpiry
{
    switch(_expiryPopup.indexOfSelectedItem) {
        case 1: return [NSDate dateWithTimeIntervalSince1970:0];
        case 2: return [NSDate dateWithTimeIntervalSinceNow:60];
        case 3: return [NSDate dateWithTimeIntervalSince1970:300];
        case 4: return [NSDate dateWithTimeIntervalSinceNow:3600];
        case 5: return [NSDate dateWithTimeIntervalSinceNow:86400];
        case 6: return [NSDate dateWithTimeIntervalSince1970:1];
        case 7: return [NSDate dateWithTimeIntervalSince1970:UINT32_MAX];
    }
    return nil;
}

- (NSUInteger)selectedPriority
{
    switch(_priorityPopup.indexOfSelectedItem) {
        case 1: return 5;
        case 2: return 10;
    }
    return 0;
}

#pragma mark - Payload

- (void)updatePayloadCounter
{
    NSString *payload = _payloadField.string;
    BOOL isJSON = !![NSJSONSerialization JSONObjectWithData:[payload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    _countField.stringValue = [NSString stringWithFormat:@"%@  %lu", isJSON ? @"" : @"malformed", payload.length];
    _countField.textColor = payload.length > 256 || !isJSON ? NSColor.redColor : NSColor.darkGrayColor;
}

- (void)upPayloadTextIndex
{
    NSString *payload = _payloadField.string;
    NSRange range = [payload rangeOfString:@"\\([0-9]+\\)" options:NSRegularExpressionSearch];
    if (range.location != NSNotFound) {
        range.location += 1;
        range.length -= 2;
        NSString *before = [payload substringToIndex:range.location];
        NSUInteger value = [payload substringWithRange:range].integerValue + 1;
        NSString *after = [payload substringFromIndex:range.location + range.length];
        _payloadField.string = [NSString stringWithFormat:@"%@%lu%@", before, value, after];
    }
}

#pragma mark - Connection

- (void)connectWithCertificateAtIndex:(NSUInteger)index
{
    if (index == 0) {
        [_certificatePopup selectItemAtIndex:0];
        _lastSelectedIndex = 0;
        [self selectCertificate:nil identity:nil];
        _tokenCombo.enabled = NO;
        _importButton.enabled = NO;
        [self loadSelectedToken];
    } else if (index <= _certificateIdentityPairs.count) {
        [_certificatePopup selectItemAtIndex:index];
        _lastSelectedIndex = index;
        NSArray *pair = [_certificateIdentityPairs objectAtIndex:index - 1];
        [self selectCertificate:pair[0] identity:pair[1] == NSNull.null ? nil : pair[1]];
        _tokenCombo.enabled = YES;
        _importButton.enabled = YES;
        [self loadSelectedToken];
    } else {
        [_certificatePopup selectItemAtIndex:_lastSelectedIndex];
        [self importIdentity];
    }
}

- (void)selectCertificate:(NWCertificateRef)certificate identity:(NWIdentityRef)identity
{
    if (_hub) {
        [_hub disconnect]; _hub = nil;
        _pushButton.enabled = NO;
        _reconnectButton.enabled = NO;
        NWLogInfo(@"Disconnected from APN");
    }
    
    _selectedCertificate = certificate;
    [self updateTokenCombo];
    
    if (certificate) {
        BOOL sandbox = [NWSecTools isSandboxCertificate:certificate];
        NSString *summary = [NWSecTools summaryWithCertificate:certificate];
        NWLogInfo(@"Connecting to APN..  (%@%@)", summary, sandbox ? @" sandbox" : @"");
        
        dispatch_async(_serial, ^{
            NSError *error = nil;
            NWIdentityRef ident = identity ?: [NWSecTools keychainIdentityWithCertificate:certificate error:&error];
            NWHub *hub = [NWHub connectWithDelegate:self identity:ident error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (hub) {
                    NWLogInfo(@"Connected  (%@%@)", summary, sandbox ? @" sandbox" : @"");
                    // fetch for invalids for certificate
                    _hub = hub;
                    _pushButton.enabled = YES;
                    _reconnectButton.enabled = YES;
                    
                    [self feedback];
                } else {
                    NWLogWarn(@"Unable to connect: %@", error.localizedDescription);
                    [hub disconnect];
                    [_certificatePopup selectItemAtIndex:0];
                }
            });
        });
    }
}

- (void)reconnect
{
    NWLogInfo(@"Reconnecting..");
    _pushButton.enabled = NO;
    _reconnectButton.enabled = NO;
    dispatch_async(_serial, ^{
        NSError *error =  nil;
        BOOL connected = [_hub reconnectWithError:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (connected) {
                NWLogInfo(@"Reconnected");
                _pushButton.enabled = YES;
            } else {
                NWLogWarn(@"Unable to reconnect: %@", error.localizedDescription);
            }
            _reconnectButton.enabled = YES;
        });
    });
}

- (void)push
{
    NSString *token = _tokenCombo.stringValue;
    [self pushWithTokens:@[token]];
}

- (void)pushToImported
{
    NSArray *tokens = importer.availableTokens;
    if(![tokens count])
    {
        NWLogWarn(@"No tokens available");
        return;
    }
    
    [self pushWithTokens:tokens];
}

- (void) pushWithTokens:(NSArray*) tokens
{
    NSString *payload = _payloadField.string;
    NSDate *expiry = self.selectedExpiry;
    NSUInteger priority = self.selectedPriority;
    
    pushService.queue = _serial;
    pushService.hub = _hub;
    pushService.delay = [self pushDelayInMs];
    [pushService excludeTokens:certificateInvalidTokens];
    [pushService pushWithTokens:tokens
                        payload:payload
                     expireDate:expiry
                       priority:priority];
}

- (void)feedback
{
    dispatch_async(_serial, ^{
        NWCertificateRef certificate = _selectedCertificate;
        if (!certificate)
        {
            NWLogWarn(@"Unable to connect to feedback service: no certificate selected");
            return;
        }
        BOOL sandbox = [NWSecTools isSandboxCertificate:certificate];
        NSString *summary = [NWSecTools summaryWithCertificate:certificate];
        NSString *prefix = sandbox ? @"sandbox" : @"";
        
        NWLogInfo(@"Connecting to feedback service..  (%@ %@)", summary, prefix);
        NSError *error = nil;
        NWIdentityRef identity = [NWSecTools keychainIdentityWithCertificate:_selectedCertificate error:&error];
        NWPushFeedback *feedback = [NWPushFeedback connectWithIdentity:identity error:&error];
        if (!feedback)
        {
            NWLogWarn(@"Unable to connect to feedback service: %@", error.localizedDescription);
            return;
        }
        
        NWLogInfo(@"Reading feedback service..  (%@ %@)", summary, prefix);
        NSArray *pairs = [feedback readTokenDatePairsWithMax:1000 error:&error];
        if (!pairs)
        {
            NWLogWarn(@"Unable to read feedback: %@", error.localizedDescription);
            return;
        }
        
        NSString *fileName = [NSString stringWithFormat:@"%@_%@.dat", summary, prefix];

        NSFileManager *fileManger = [NSFileManager defaultManager];
        NSURL *documentsUrl = [[fileManger URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
        NSURL *fileUrl = [documentsUrl URLByAppendingPathComponent:fileName];
        
        pairs = [NSArray arrayWithObjects:
                 @[@"1212312312312312",[NSDate date]],
                 @[@"aksjdoasdasd",[NSDate date]],
                 @[@"ajhsdiauhsiduah",[NSDate date]],
                 nil];
        
        if (pairs.count)
        {
            NSOutputStream *os = [NSOutputStream outputStreamWithURL:fileUrl append:YES];
            [os open];
            uint8_t bufferSize = 65;
            uint8_t buffer[bufferSize];
            
            // store in file
            for (NSArray *pair in pairs)
            {
                NSString *token = pair[0];
                
                NSUInteger tokenLength = MIN(bufferSize-1, [token length]);
                const uint8_t *tokenCStr = (const uint8_t *)[token UTF8String];
                memcpy(buffer, tokenCStr, tokenLength);
                buffer[tokenLength++] = '\n';
                
                NSUInteger written = [os write:buffer maxLength:tokenLength];
                if (written != tokenLength)
                {
                    NWLogWarn(@"Token %@ not written to stream", token);
                }
                
                [certificateInvalidTokens addObject:token];
                
                NWLogInfo(@"token: %@  date: %@", token, pair[1]);
            }
            
            [os close];
            
            NWLogInfo(@"Feedback service returned %i device tokens, see logs for details", (int)pairs.count);
            NWLogInfo(@"Feedback tokens saved to file '%@'", fileUrl);
        } else {
            NWLogInfo(@"Feedback service returned zero device tokens");
        }
    });
}

#pragma mark - Config

- (NSString *)identifierWithCertificate:(NWCertificateRef)certificate
{
    BOOL sandbox = [NWSecTools isSandboxCertificate:certificate];
    NSString *summary = [NWSecTools summaryWithCertificate:certificate];
    return summary ? [NSString stringWithFormat:@"%@%@", summary, sandbox ? @"-sandbox" : @""] : nil;
}

- (NSMutableArray *)tokensWithCertificate:(NWCertificateRef)certificate create:(BOOL)create
{
    NSString *identifier = [self identifierWithCertificate:certificate];
    if (!identifier) return nil;
    NSArray *result = _config[@"identifiers"][identifier];
    if (create && !result) result = (_config[@"identifiers"][identifier] = @[].mutableCopy);
    if (result && ![result isKindOfClass:NSMutableArray.class]) result = (_config[@"identifiers"][identifier] = result.mutableCopy);
    return (NSMutableArray *)result;
}

- (BOOL)addToken:(NSString *)token certificate:(NWCertificateRef)certificate
{
    NSMutableArray *tokens = [self tokensWithCertificate:certificate create:YES];
    if (token.length && ![tokens containsObject:token]) {
        [tokens addObject:token];
        return YES;
    }
    return NO;
}

- (BOOL)removeToken:(NSString *)token certificate:(NWCertificateRef)certificate
{
    NSMutableArray *tokens = [self tokensWithCertificate:certificate create:NO];
    if (token && [tokens containsObject:token]) {
        [tokens removeObject:token];
        return YES;
    }
    return NO;
}

- (BOOL)selectToken:(NSString *)token certificate:(NWCertificateRef)certificate
{
    NSMutableArray *tokens = [self tokensWithCertificate:certificate create:YES];
    if (token && [tokens containsObject:token]) {
        [tokens removeObject:token];
        [tokens addObject:token];
        return YES;
    }
    return NO;
}

- (void)resetTokenCombo
{
    [_tokenCombo removeAllItems];
}

- (void)updateTokenCombo
{
    [self resetTokenCombo];
    NSArray *tokens = [self tokensWithCertificate:_selectedCertificate create:NO];
    if (tokens.count) {
        for (NSObject *item in tokens.reverseObjectEnumerator) {
            [_tokenCombo insertItemWithObjectValue:item atIndex:0];
        }
    }
}

- (void)loadSelectedToken
{
    _tokenCombo.stringValue = [[self tokensWithCertificate:_selectedCertificate create:YES] lastObject] ?: @"";
    // _tokenCombo.stringValue = @"552fff0a65b154eb209e9dc91201025da1a4a413dd2ad6d3b51e9b33b90c977a my iphone";
}

- (void)addTokenAndUpdateCombo
{
    BOOL added = [self addToken:_tokenCombo.stringValue certificate:_selectedCertificate];
    if (added) [self updateTokenCombo];
}

- (void)selectTokenAndUpdateCombo
{
    BOOL selected = [self selectToken:_tokenCombo.stringValue certificate:_selectedCertificate];
    if (selected) [self updateTokenCombo];
}

- (NSURL *)configFileURL
{
    NSURL *libraryURL = [[NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask] lastObject];
    NSURL *configURL = [libraryURL URLByAppendingPathComponent:@"Pusher" isDirectory:YES];
    if (!configURL) return nil;
    NSError *error = nil;
    BOOL exists = [NSFileManager.defaultManager createDirectoryAtURL:configURL withIntermediateDirectories:YES attributes:nil error:&error];
    NWLogWarnIfError(error);
    if (!exists) return nil;
    NSURL *result = [configURL URLByAppendingPathComponent:@"config.plist"];
    if (![NSFileManager.defaultManager fileExistsAtPath:result.path]){
        NSURL *defaultURL = [NSBundle.mainBundle URLForResource:@"config" withExtension:@"plist"];
        [NSFileManager.defaultManager copyItemAtURL:defaultURL toURL:result error:&error];
        NWLogWarnIfError(error);
    }
    return result;
}

- (void)loadConfig
{
    NSURL *url = [self configFileURL];
    _config = [NSDictionary dictionaryWithContentsOfURL:url];
    NWLogInfo(@"Loaded config from %@", url.path);
}

- (void)saveConfig
{
    if (_config.count) [_config writeToURL:[self configFileURL] atomically:NO];
}

- (void)migrateOldConfigurationIfNeeded
{
    NSURL *libraryURL = [[NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask] lastObject];
    NSURL *configURL = [libraryURL URLByAppendingPathComponent:@"Pusher" isDirectory:YES];
    NSURL *newURL = [configURL URLByAppendingPathComponent:@"config.plist"];
    NSURL *oldURL = [configURL URLByAppendingPathComponent:@"configuration.plist"];
    if ([NSFileManager.defaultManager fileExistsAtPath:newURL.path]) return;
    if (![NSFileManager.defaultManager fileExistsAtPath:oldURL.path]) return;
    NWLogInfo(@"Migrating old configuration to new format");
    NSDictionary *old = [NSDictionary dictionaryWithContentsOfURL:oldURL];
    NSMutableDictionary *identifiers = @{}.mutableCopy;
    for (NSDictionary *d in old[@"tokens"]) {
        for (NSString *identifier in d[@"identifiers"]) {
            for (NSArray *token in d[@"development"]) {
                NSString *key = [NSString stringWithFormat:@"%@-sandbox", identifier];
                if (!identifiers[key]) identifiers[key] = @[].mutableCopy;
                [identifiers[key] addObject:token];
            }
            for (NSArray *token in d[@"production"]) {
                NSString *key = identifier;
                if (!identifiers[key]) identifiers[key] = @[].mutableCopy;
                [identifiers[key] addObject:token];
            }
        }
    }
    NSMutableDictionary *new = @{}.mutableCopy;
    new[@"payload"] = old[@"payload"];
    new[@"identifiers"] = identifiers;
    [new writeToURL:newURL atomically:NO];
    NSError *error = nil;
    [NSFileManager.defaultManager removeItemAtURL:oldURL error:&error];
    NWLogWarnIfError(error);
}

#pragma mark - Logging

- (void)log:(NSString *)message warning:(BOOL)warning
{
    dispatch_async(dispatch_get_main_queue(), ^{
        _infoField.textColor = warning ? NSColor.redColor : NSColor.blackColor;
        _infoField.stringValue = message;
        if (message.length) {
            NSDictionary *attributes = @{NSForegroundColorAttributeName: _infoField.textColor, NSFontAttributeName: [NSFont fontWithName:@"Monaco" size:10]};
            NSAttributedString *string = [[NSAttributedString alloc] initWithString:message attributes:attributes];
            [_logField.textStorage appendAttributedString:string];
            [_logField.textStorage.mutableString appendString:@"\n"];
            [_logField scrollRangeToVisible:NSMakeRange(_logField.textStorage.length - 1, 1)];
        }
    });
}

static void NWPusherPrinter(NWLContext context, CFStringRef message, void *info) {
    BOOL warning = context.tag && strncmp(context.tag, "warn", 5) == 0;
    id delegate = NSApplication.sharedApplication.delegate;
    [delegate log:(__bridge NSString *)message warning:warning];
}

@end
