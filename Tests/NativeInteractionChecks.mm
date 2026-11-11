#import "../ChromiumBridge.h"
#import <WebKit/WebKit.h>

@interface InteractionCheck : NSObject <WKNavigationDelegate>
@property NSWindow *window;
@property WKWebView *webkit;
@property WBChromiumView *chromium;
@property NSArray<NSDictionary<NSString *, NSData *> *> *clipboard;
@property NSString *base;
@property NSString *root;
@property BOOL started;
@end
@implementation InteractionCheck
- (void)restoreClipboard {
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    [board clearContents];
    NSMutableArray *items = [NSMutableArray new];
    for (NSDictionary *saved in self.clipboard) {
        NSPasteboardItem *item = [NSPasteboardItem new];
        for (NSString *type in saved) [item setData:saved[type] forType:type];
        [items addObject:item];
    }
    [board writeObjects:items];
}
- (void)fail:(NSString *)message { [self restoreClipboard]; fprintf(stderr,"FAIL: %s\n", message.UTF8String); exit(1); }
- (void)evaluate:(NSString *)source chromium:(BOOL)cef then:(void (^)(id))next {
    if (cef) {
        [self.chromium automationMethod:@"Runtime.evaluate" parameters:@{@"expression":source,@"returnByValue":@YES}
            completion:^(NSDictionary *result, NSString *error) {
                if (error || result[@"exceptionDetails"]) [self fail:[NSString stringWithFormat:@"Script: %@ %@",error,result]];
                next(result[@"result"][@"value"]);
            }];
    } else [self.webkit evaluateJavaScript:source completionHandler:^(id result, NSError *error) {
        if (error) [self fail:error.description]; next(result);
    }];
}
- (void)mouse:(NSEventType)type at:(NSPoint)point {
    NSEvent *event = [NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
        windowNumber:self.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:type==NSEventTypeLeftMouseUp?0:1];
    [self.window sendEvent:event];
}
- (void)command:(NSString *)key code:(unsigned short)code {
    NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:self.window.windowNumber context:nil characters:key
        charactersIgnoringModifiers:key isARepeat:NO keyCode:code];
    [NSApp sendEvent:event];
}
- (void)later:(void (^)(void))next { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250*NSEC_PER_MSEC), dispatch_get_main_queue(), next); }
- (void)check:(BOOL)cef {
    NSView *view = cef ? self.chromium : self.webkit;
    [self.window orderFrontRegardless]; [self.window makeKeyWindow]; [NSApp activateIgnoringOtherApps:YES];
    [self evaluate:@"(()=>{const r=document.querySelector('#selection').getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}})()" chromium:cef then:^(id result) {
        NSDictionary *r = result;
        if (!self.window.isKeyWindow || !NSApp.isActive) {
            [self restoreClipboard];
            fprintf(stderr,"SKIP: native selection/keyboard test requires an active key window; this session denied activation.\n");
            exit(77);
        }
        NSPoint start = [view convertPoint:NSMakePoint([r[@"x"] doubleValue]+1, (view.isFlipped ? [r[@"y"] doubleValue]+[r[@"height"] doubleValue]/2 : view.bounds.size.height-[r[@"y"] doubleValue]-[r[@"height"] doubleValue]/2)) toView:nil];
        NSPoint end = NSMakePoint(start.x+[r[@"width"] doubleValue]-2,start.y);
        fprintf(stderr,"DRAG engine=%s flipped=%d key=%d active=%d start=%s end=%s rect=%s\n",cef?"CEF":"WK",view.isFlipped,self.window.isKeyWindow,NSApp.isActive,NSStringFromPoint(start).UTF8String,NSStringFromPoint(end).UTF8String,r.description.UTF8String);
        [self mouse:NSEventTypeLeftMouseDown at:start];
        for (int i=1;i<=8;i++) [self mouse:NSEventTypeLeftMouseDragged at:NSMakePoint(start.x+(end.x-start.x)*i/8,end.y)];
        [self mouse:NSEventTypeLeftMouseUp at:end];
        [self later:^{
            [self evaluate:@"getSelection().toString()" chromium:cef then:^(id selection) {
                if (![selection isEqual:@"Selection fixture text"]) [self fail:[NSString stringWithFormat:@"%@ native drag selection: %@",cef?@"Chromium":@"WebKit",selection]];
                [NSPasteboard.generalPasteboard clearContents];
                [NSPasteboard.generalPasteboard setString:@"Copy has not run" forType:NSPasteboardTypeString];
                [self command:@"c" code:8];
                [self later:^{
                    NSString *copied = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
                    if (![copied isEqualToString:@"Selection fixture text"]) [self fail:[NSString stringWithFormat:@"%@ Cmd+C failed: %@",cef?@"Chromium":@"WebKit",copied]];
                    [self evaluate:@"(()=>{const r=document.querySelector('#edit').getBoundingClientRect();return {x:r.x,y:r.y,height:r.height}})()" chromium:cef then:^(NSDictionary *input) {
                        NSPoint p=[view convertPoint:NSMakePoint([input[@"x"] doubleValue]+20,(view.isFlipped ? [input[@"y"] doubleValue]+[input[@"height"] doubleValue]/2 : view.bounds.size.height-[input[@"y"] doubleValue]-[input[@"height"] doubleValue]/2)) toView:nil];
                        [self mouse:NSEventTypeLeftMouseDown at:p]; [self mouse:NSEventTypeLeftMouseUp at:p];
                        [self command:@"a" code:0]; [self command:@"v" code:9];
                        [self later:^{ [self evaluate:@"document.querySelector('#edit').value" chromium:cef then:^(id value) {
                            if (![value isEqual:@"Selection fixture text"]) [self fail:[NSString stringWithFormat:@"%@ Cmd+A/V failed: %@",cef?@"Chromium":@"WebKit",value]];
                            [NSPasteboard.generalPasteboard clearContents];
                            [NSPasteboard.generalPasteboard setString:@"Cut has not run" forType:NSPasteboardTypeString];
                            [self command:@"a" code:0]; [self command:@"x" code:7];
                            [self later:^{ [self evaluate:@"document.querySelector('#edit').value" chromium:cef then:^(id finalValue) {
                                NSString *cut = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
                                if (![finalValue isEqual:@""] || ![cut isEqualToString:@"Selection fixture text"])
                                    [self fail:[NSString stringWithFormat:@"%@ Cmd+X failed",cef?@"Chromium":@"WebKit"]];
                                printf("PASS: %s native mouse-drag selection, Cmd+C, Cmd+A, Cmd+V, Cmd+X.\n",cef?"Chromium":"WebKit"); fflush(stdout);
                                if (!cef) [self check:YES]; else [self finish];
                            }]; }];
                        }]; }];
                    }];
                }];
            }];
        }];
    }];
}
- (void)finish {
    [self restoreClipboard]; [self.chromium closePage]; [self.chromium removeFromSuperview];
    [self shutdown];
}
- (void)shutdown {
    if (WBChromiumHasBrowsers()) { [self later:^{ [self shutdown]; }]; return; }
    WBChromiumShutdown(); exit(0);
}
- (void)webView:(WKWebView *)view didFinishNavigation:(WKNavigation *)navigation {
    self.started = YES;
}
- (void)start {
    NSMutableArray *saved = [NSMutableArray new];
    for (NSPasteboardItem *item in NSPasteboard.generalPasteboard.pasteboardItems) {
        NSMutableDictionary *types=[NSMutableDictionary new];
        for (NSString *type in item.types) { NSData *data=[item dataForType:type]; if(data) types[type]=data; }
        [saved addObject:types];
    }
    self.clipboard=saved;
    NSMenu *menu=[NSMenu new]; NSMenuItem *edit=[NSMenuItem new]; [menu addItem:edit]; edit.submenu=[NSMenu new];
    for (NSArray *entry in @[@[@"Copy",@"copy:",@"c"],@[@"Cut",@"cut:",@"x"],@[@"Paste",@"paste:",@"v"],@[@"Select All",@"selectAll:",@"a"]]) {
        [edit.submenu addItemWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:entry[2]];
    }
    NSApp.mainMenu=menu;
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,1000,550) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    self.window.releasedWhenClosed=NO;
    WKWebViewConfiguration *config=[WKWebViewConfiguration new]; config.websiteDataStore=WKWebsiteDataStore.nonPersistentDataStore;
    self.webkit=[[WKWebView alloc] initWithFrame:NSMakeRect(0,0,500,550) configuration:config]; self.webkit.navigationDelegate=self;
    self.chromium=[[WBChromiumView alloc] initWithFrame:NSMakeRect(500,0,500,550)];
    [self.window.contentView addSubview:self.webkit]; [self.window.contentView addSubview:self.chromium];
    [self.window orderFrontRegardless]; [self.window makeKeyWindow]; [NSApp activateIgnoringOtherApps:YES];
    NSString *address=[self.base stringByAppendingString:@"/native-interaction"];
    [self.webkit loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:address]]];
    if(!WBChromiumInitialize(self.root)) [self fail:@"CEF initialize"];
    __weak InteractionCheck *weakSelf=self;
    self.chromium.eventHandler=^(NSString *event, NSString *value) {
        InteractionCheck *s=weakSelf;
        if([event isEqualToString:@"error"]) [s fail:value];
        if([event isEqualToString:@"loading"] && [value isEqualToString:@"0"]) [s awaitReady];
    };
    if(![self.chromium openURL:address profile:[self.root stringByAppendingPathComponent:@"profile"]]) [self fail:@"CEF create"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40*NSEC_PER_SEC),dispatch_get_main_queue(),^{[self fail:@"Native interaction timeout"];});
}
- (void)awaitReady {
    if(!self.started) { [self later:^{[self awaitReady];}]; return; }
    self.chromium.eventHandler=nil;
    [self check:NO];
}
@end
int main(int argc,char **argv) { @autoreleasepool {
    if(argc<3)return 2;
    WBPrepareApplication(); [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular]; [NSApp finishLaunching];
    InteractionCheck *check=[InteractionCheck new]; check.base=[NSString stringWithUTF8String:argv[1]];check.root=[NSString stringWithUTF8String:argv[2]];
    dispatch_async(dispatch_get_main_queue(),^{[check start];}); [NSApp run];
} }
