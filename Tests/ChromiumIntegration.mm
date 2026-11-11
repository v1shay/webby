#import "../ChromiumBridge.h"
#import <WebKit/WebKit.h>

@interface EngineCheck : NSObject <WKNavigationDelegate, NSWindowDelegate>
@property NSWindow *window;
@property WKWebView *webkit;
@property WBChromiumView *chromium;
@property NSMutableArray<WBChromiumView *> *extra;
@property NSString *base;
@property NSString *root;
@property int phase;
@property int findStep;
@property int closeNotifications;
@property BOOL webkitLoaded;
@end

@implementation EngineCheck
- (BOOL)windowShouldClose:(NSWindow *)sender { self.closeNotifications++; return NO; }
- (void)fail:(NSString *)message { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [webView evaluateJavaScript:@"document.title" completionHandler:^(id title, NSError *error) {
        if (![title isEqualToString:@"first|empty"]) [self fail:[NSString stringWithFormat:@"WebKit title/storage check failed: %@ %@", title, error]];
        self.webkitLoaded = YES;
    }];
}
- (void)start {
    self.extra = [NSMutableArray new];
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,900,600) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    self.window.releasedWhenClosed = NO; self.window.delegate = self;
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new]; configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    self.webkit = [[WKWebView alloc] initWithFrame:NSMakeRect(0,0,450,600) configuration:configuration];
    self.webkit.navigationDelegate = self; [self.window.contentView addSubview:self.webkit];
    [self.webkit loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[self.base stringByAppendingString:@"/first"]]]];
    if (!WBChromiumInitialize(self.root)) [self fail:@"Chromium initialization returned false"];
    self.chromium = [[WBChromiumView alloc] initWithFrame:NSMakeRect(450,0,450,600)];
    [self.window.contentView addSubview:self.chromium];
    __weak EngineCheck *weakSelf = self;
    self.chromium.eventHandler = ^(NSString *event, NSString *value) {
        EngineCheck *s = weakSelf;
        if ([event isEqualToString:@"error"]) [s fail:value];
        if ([event isEqualToString:@"find"] && s.phase == 5 && value.length) {
            NSString *expected = s.findStep == 1 ? @"No match" : @"Found";
            if (![value isEqualToString:expected]) [s fail:[NSString stringWithFormat:@"Find step %d: %@", s.findStep, value]];
            s.findStep++;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (s.findStep == 1) [s.chromium findText:@"fixture-does-not-contain-this" backwards:NO];
                else if (s.findStep == 2) [s.chromium findText:@"second" backwards:YES];
                else if (s.findStep == 3) {
                    [s.chromium stopFinding];
                    [s.chromium findText:@"" backwards:NO];
                    puts("PASS: Chromium find, changed query, missing query, backwards search, clear selection.");
                    [s checkDownloadCancellation];
                }
            });
        }
        if ([event isEqualToString:@"title"]) fprintf(stderr,"title phase %d: %s\n",s.phase,value.UTF8String);
        if ([event isEqualToString:@"activity"] && s.phase == 6) {
            NSDictionary *state = [NSJSONSerialization JSONObjectWithData:[value dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if ([state[@"edited"] boolValue]) {
                if (!s.chromium.protectsFromDiscard) [s fail:@"Unsaved edits were not protected"];
                s.phase = 7; dispatch_async(dispatch_get_main_queue(), ^{ [s finish]; });
            }
        }
        if (![event isEqualToString:@"loading"] || ![value isEqualToString:@"0"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [s advance]; });
    };
    NSString *profile = [self.root stringByAppendingPathComponent:@"A"];
    if (![self.chromium openURL:[self.base stringByAppendingString:@"/first?set=alpha"] profile:profile]) [self fail:@"Chromium creation failed"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self fail:[NSString stringWithFormat:@"Timed out waiting for browser engines in phase %d (find step %d, title %@)",self.phase,self.findStep,self.chromium.pageTitle]]; });
}
- (void)advance {
    NSString *title = self.chromium.pageTitle;
    if (self.phase == 0) {
        if (![title isEqualToString:@"first|empty"]) { [self fail:[@"Initial Chromium title: " stringByAppendingString:title]]; return; }
        self.phase = 1; [self.chromium navigate:[self.base stringByAppendingString:@"/second"]];
    } else if (self.phase == 1) {
        if (![title isEqualToString:@"second|alpha"]) [self fail:@"Chromium cookie/localStorage continuity failed"];
        if (!self.chromium.canGoBack) [self fail:@"Back history unavailable"];
        self.phase = 2; [self.chromium goBack];
    } else if (self.phase == 2) {
        if (![title hasPrefix:@"first|"]) [self fail:@"Back navigation failed"];
        if (!self.chromium.canGoForward) [self fail:@"Forward history unavailable"];
        self.phase = 3; [self.chromium goForward];
    } else if (self.phase == 3) {
        if (![title isEqualToString:@"second|alpha"]) [self fail:@"Forward navigation failed"];
        self.phase = 4; [self.chromium reload];
    } else if (self.phase == 4) {
        if (![title isEqualToString:@"second|alpha"]) [self fail:@"Reload failed"];
        self.phase = 5; [self.chromium findText:@"second" backwards:NO];
    }
}
- (void)checkDownloadCancellation {
    NSString *path = [self.root stringByAppendingPathComponent:@"cancel-download.bin"];
    NSString *address = [self.base stringByAppendingString:@"/slow-download"];
    __weak EngineCheck *weakSelf = self;
    self.chromium.automationDownloadDestination = ^(NSString *identifier, NSString *filename, void (^reply)(NSString *)) {
        EngineCheck *self = weakSelf;
        if (![identifier isEqualToString:@"active-cancel"]) [self fail:@"A canceled pending request reached destination selection"];
        reply(path);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [self.chromium cancelAutomationDownload:identifier];
        });
    };
    self.chromium.automationDownloadFinished = ^(NSString *identifier, NSString *status) {
        EngineCheck *self = weakSelf;
        if (![status isEqualToString:@"Canceled"]) [self fail:[@"Download cancellation status: " stringByAppendingString:status]];
        if ([identifier isEqualToString:@"active-cancel"]) [self awaitDownloadDisconnect:30];
    };
    if (![self.chromium startAutomationDownload:address identifier:@"pending-cancel"]) [self fail:@"Pending cancel request rejected"];
    [self.chromium cancelAutomationDownload:@"pending-cancel"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (![self.chromium startAutomationDownload:[address stringByAppendingString:@"?active=1"] identifier:@"active-cancel"]) [self fail:@"Active cancel request rejected"];
    });
}
- (void)awaitDownloadDisconnect:(int)attempts {
    NSURL *url = [NSURL URLWithString:[self.base stringByAppendingString:@"/download-status?active=1"]];
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *, NSError *error) {
        NSString *status = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([status isEqualToString:@"disconnected"]) {
                self.chromium.automationDownloadDestination = nil;
                self.chromium.automationDownloadFinished = nil;
                puts("PASS: Chromium canceled pending destination and interrupted the active network transfer.");
                [self checkContext:@"A" expected:@"second|alpha" then:^{ [self checkContext:@"B" expected:@"second|empty" then:^{ self.phase = 6; [self.chromium navigate:[self.base stringByAppendingString:@"/edit"]]; }]; }];
            } else if (!attempts || [status isEqualToString:@"finished"]) {
                [self fail:[NSString stringWithFormat:@"Chromium transport kept downloading after Cancel: %@ %@",status,error]];
            } else {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self awaitDownloadDisconnect:attempts-1]; });
            }
        });
    }] resume];
}
- (void)checkContext:(NSString *)profile expected:(NSString *)title then:(void (^)(void))next {
    fprintf(stderr,"checking Chromium profile %s\n",profile.UTF8String);
    WBChromiumView *page = [[WBChromiumView alloc] initWithFrame:NSMakeRect(0,0,450,600)];
    [self.window.contentView addSubview:page]; [self.extra addObject:page];
    __weak WBChromiumView *weakPage = page;
    page.eventHandler = ^(NSString *event, NSString *value) {
        if ([event isEqualToString:@"error"]) [self fail:value];
        if ([event isEqualToString:@"loading"] && [value isEqualToString:@"0"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                WBChromiumView *current = weakPage;
                if (![current.pageTitle isEqualToString:title]) [self fail:[NSString stringWithFormat:@"Profile %@ isolation failed: %@",profile,current.pageTitle]];
                fprintf(stderr,"Chromium profile %s ready\n",profile.UTF8String);
                current.eventHandler = nil; next();
            });
        }
    };
    if (![page openURL:[self.base stringByAppendingString:@"/second"] profile:[self.root stringByAppendingPathComponent:profile]]) [self fail:@"Additional Chromium tab failed"];
}
- (void)finish {
    if (self.phase == 7 && getenv("WEBBY_REQUIRE_CHROMIUM_MP4")) {
        self.phase = 8;
        __weak EngineCheck *weakSelf = self;
        self.chromium.eventHandler = ^(NSString *event, NSString *value) {
            if ([event isEqualToString:@"loading"] && [value isEqualToString:@"0"]) {
                dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf checkMP4]; });
            }
        };
        [self.chromium navigate:[self.base stringByAppendingString:@"/chromium-media"]];
        return;
    }
    if (!self.webkitLoaded) {
        // Chromium can reach this point before WebKit's process finishes launching.
        // The existing overall deadline still catches a stalled WebKit load.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{ [self finish]; });
        return;
    }
    [self.chromium closePage]; [self.chromium removeFromSuperview];
    for (WBChromiumView *page in self.extra) { [page closePage]; [page removeFromSuperview]; }
    [self.extra removeAllObjects];
    for (int i=0;i<12;i++) {
        @autoreleasepool {
            WBChromiumView *page = [[WBChromiumView alloc] initWithFrame:NSMakeRect(0,0,450,600)];
            [self.window.contentView addSubview:page];
            if (![page openURL:@"about:blank" profile:[self.root stringByAppendingPathComponent:@"A"]]) [self fail:@"Rapid tab creation failed"];
            [page closePage]; [page closePage]; [page removeFromSuperview];
        }
    }
    [self awaitClose];
}
- (void)checkMP4 {
    self.chromium.eventHandler = nil;
    NSString *expression = @R"JS((async () => {
        const v = document.querySelector('video');
        if (!v) return 'missing video';
        if (!v.canPlayType('video/mp4; codecs="avc1.42E01E, mp4a.40.2"')) return 'H.264/AAC unsupported';
        await v.play();
        const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
        await wait(350);
        if (!v.videoWidth || v.currentTime <= 0 || v.paused) return 'MP4 did not advance';
        const bounds = v.getBoundingClientRect();
        document.dispatchEvent(new PointerEvent('pointermove', {clientX: bounds.left + 20, clientY: bounds.top + 20}));
        await new Promise(requestAnimationFrame);
        const button = document.querySelector('[data-webby-video-action=pip]');
        if (!button) return 'missing Webby Picture in Picture control';
        button.click();
        for (let i = 0; i < 40 && document.pictureInPictureElement !== v; i++) await wait(100);
        if (document.pictureInPictureElement !== v) return button.title;
        const start = v.currentTime;
        await wait(350);
        if (v.paused || v.currentTime <= start) return 'MP4 stopped during Picture in Picture';
        await document.exitPictureInPicture();
        return document.pictureInPictureElement === null && !v.paused ? 'pass' : 'failed to return inline';
    })())JS";
    [self.chromium automationMethod:@"Runtime.evaluate"
        parameters:@{@"expression":expression, @"returnByValue":@YES, @"awaitPromise":@YES, @"userGesture":@YES}
        completion:^(NSDictionary *result, NSString *error) {
            id value = result[@"result"][@"value"];
            if (![value isEqual:@"pass"]) {
                [self fail:[NSString stringWithFormat:@"Embedded Chromium MP4/PiP: %@",
                    value ?: error ?: result[@"exceptionDetails"] ?: @"no result"]];
            }
            puts("PASS: embedded Chromium H.264/AAC MP4 playback, Picture in Picture, and inline return.");
            dispatch_async(dispatch_get_main_queue(), ^{ [self finish]; });
        }];
}
- (void)awaitClose {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (WBChromiumHasBrowsers()) { [self awaitClose]; return; }
        if (self.closeNotifications) [self fail:@"Closing a tab attempted to close its parent window"];
        WBChromiumShutdown();
        puts("PASS: embedded WebKit + Chromium; navigation, reload, shared/isolated profiles, 12 rapid create/close cycles, idempotent close, parent-window preservation, clean shutdown.");
        exit(0);
    });
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        WBPrepareApplication(); [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        EngineCheck *check = [EngineCheck new];
        check.base = [NSString stringWithUTF8String:argv[1]]; check.root = [NSString stringWithUTF8String:argv[2]];
        dispatch_async(dispatch_get_main_queue(), ^{ [check start]; });
        [NSApp run];
    }
}
