#import "../ChromiumBridge.h"
@interface PopupChecks : NSObject
@property NSWindow *window;
@property WBChromiumView *parent;
@property WBChromiumView *child;
@property WBChromiumView *pendingPage;
@property NSString *base;
@property NSString *root;
@property BOOL submitted;
@property BOOL passedPost;
@end
@implementation PopupChecks
- (void)fail:(NSString *)message { fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1); }
- (void)start {
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,800,600) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    self.window.releasedWhenClosed=NO;
    if(!WBChromiumInitialize(self.root)) [self fail:@"CEF init"];
    [self checkQueuedNavigationSuperseded:NO then:^{
        [self checkQueuedNavigationSuperseded:YES then:^{ [self startPopup]; }];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC),dispatch_get_main_queue(),^{[self fail:@"Chromium navigation/popup regression deadline"];});
}
- (void)checkQueuedNavigationSuperseded:(BOOL)superseded then:(void (^)(void))next {
    WBChromiumView *page = [[WBChromiumView alloc] initWithFrame:NSMakeRect(0,0,400,600)];
    self.pendingPage = page;
    [self.window.contentView addSubview:page];
    NSString *queued = [self.base stringByAppendingString:@"/queued-navigation"];
    NSString *latest = [self.base stringByAppendingString:@"/latest-navigation"];
    __weak PopupChecks *weakSelf = self;
    __weak WBChromiumView *weakPage = page;
    __block BOOL sawExpected = NO;
    page.eventHandler = ^(NSString *event, NSString *value) {
        PopupChecks *self = weakSelf;
        WBChromiumView *page = weakPage;
        if ([event isEqual:@"error"]) [self fail:value];
        if (superseded && [event isEqual:@"created"]) [page navigate:latest];
        if (![event isEqual:@"title"]) return;
        if (superseded && [value hasPrefix:@"queued-navigation|"]) [self fail:@"Old queued destination overwrote newer navigation"];
        NSString *expected = superseded ? @"latest-navigation|empty" : @"queued-navigation|empty";
        if (sawExpected || ![value isEqual:expected]) return;
        sawExpected = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            if (![page.pageTitle isEqual:expected]) [self fail:[@"Queued navigation was replaced: " stringByAppendingString:page.pageTitle]];
            [page closePage]; [page removeFromSuperview]; self.pendingPage = nil;
            puts(superseded ? "PASS: Chromium newest explicit navigation wins during creation." : "PASS: Chromium opening preserves its queued navigation.");
            next();
        });
    };
    if (![page openURL:[self.base stringByAppendingString:@"/first"] profile:[self.root stringByAppendingPathComponent:@"profile"]])
        [self fail:@"Unable to create queued-navigation tab"];
    [page navigate:queued];
}
- (void)startPopup {
    self.parent=[[WBChromiumView alloc]initWithFrame:NSMakeRect(0,0,400,600)];[self.window.contentView addSubview:self.parent];
    __weak PopupChecks *weakSelf=self;
    self.parent.popupHandler=^WBChromiumView *(NSString *address, BOOL background) {
        PopupChecks *s=weakSelf;
        fprintf(stderr,"popup request: %s\n",address.UTF8String);
        s.child=[[WBChromiumView alloc]initWithFrame:NSMakeRect(400,0,400,600)]; [s.window.contentView addSubview:s.child];
        s.child.eventHandler=^(NSString *event,NSString *value) {
            PopupChecks *s=weakSelf;
            fprintf(stderr,"popup %s %s\n",event.UTF8String,value.UTF8String);
            if([event isEqual:@"error"] || [event isEqual:@"popupAborted"]) [s fail:[@"Popup failure: " stringByAppendingString:value]];
            if(!s.passedPost && [event isEqual:@"title"] && [value isEqual:@"POST preserved: token=popup-payload"]) {
                s.passedPost=YES;
                [s.child automationMethod:@"Runtime.evaluate" parameters:@{@"expression":@"window.opener.postMessage('popup-ok','*');window.close()"} completion:^(NSDictionary *,NSString *){}];
            }
            if([event isEqual:@"close"]) {
                if(!s.passedPost)[s fail:@"Popup closed before POST payload verified"];
                puts("PASS: Chromium native popup preserves POST body, window.opener, and window.close.");fflush(stdout);
                dispatch_async(dispatch_get_main_queue(),^{[s.parent closePage];[s.parent removeFromSuperview];[s awaitClosed];});
            }
        };
        return s.child;
    };
    self.parent.eventHandler=^(NSString *event,NSString *value) {
        PopupChecks *s=weakSelf;
        if([event isEqual:@"error"]) [s fail:value];
        if([event isEqual:@"loading"] && [value isEqual:@"0"] && !s.submitted) {
            fprintf(stderr,"opener submitting form\n");
            s.submitted=YES;
            [s.parent automationMethod:@"Runtime.evaluate" parameters:@{@"expression":@"document.querySelector('form').submit()",@"userGesture":@YES} completion:^(NSDictionary *,NSString *error){if(error)[s fail:error];}];
        }
    };
    if(![self.parent openURL:[self.base stringByAppendingString:@"/popup-form"] profile:[self.root stringByAppendingPathComponent:@"profile"]])[self fail:@"CEF create"];
}
- (void)awaitClosed {
    if(WBChromiumHasBrowsers()) {dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self awaitClosed];});return;}
    WBChromiumShutdown();exit(0);
}
@end
int main(int argc,char **argv){@autoreleasepool{
    if(argc<3)return 2;WBPrepareApplication();[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    PopupChecks *check=[PopupChecks new];check.base=[NSString stringWithUTF8String:argv[1]];check.root=[NSString stringWithUTF8String:argv[2]];
    dispatch_async(dispatch_get_main_queue(),^{[check start];});[NSApp run];
}}
