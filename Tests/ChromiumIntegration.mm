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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self fail:@"Timed out waiting for browser engines"]; });
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
        self.phase = 5; [self checkContext:@"A" expected:@"second|alpha" then:^{ [self checkContext:@"B" expected:@"second|empty" then:^{ self.phase = 6; [self.chromium navigate:[self.base stringByAppendingString:@"/edit"]]; }]; }];
    }
}
- (void)checkContext:(NSString *)profile expected:(NSString *)title then:(void (^)(void))next {
    WBChromiumView *page = [[WBChromiumView alloc] initWithFrame:NSMakeRect(0,0,450,600)];
    [self.window.contentView addSubview:page]; [self.extra addObject:page];
    __weak WBChromiumView *weakPage = page;
    page.eventHandler = ^(NSString *event, NSString *value) {
        if ([event isEqualToString:@"error"]) [self fail:value];
        if ([event isEqualToString:@"loading"] && [value isEqualToString:@"0"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                WBChromiumView *current = weakPage;
                if (![current.pageTitle isEqualToString:title]) [self fail:[NSString stringWithFormat:@"Profile %@ isolation failed: %@",profile,current.pageTitle]];
                current.eventHandler = nil; next();
            });
        }
    };
    if (![page openURL:[self.base stringByAppendingString:@"/second"] profile:[self.root stringByAppendingPathComponent:profile]]) [self fail:@"Additional Chromium tab failed"];
}
- (void)finish {
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
