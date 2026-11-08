#import "ChromiumBridge.h"
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/cef_api_hash.h"
#include "include/cef_application_mac.h"
#include <dlfcn.h>
#include <atomic>
#include <map>
#include <string>
#include <set>
#include <memory>

// CEF must be able to detect nested Cocoa event dispatch. Install this class
// before the first use of NSApplication.shared, including in WebKit-only mode.
@interface WebbyApplication : NSApplication <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@end
@implementation WebbyApplication
- (BOOL)isHandlingSendEvent { return self.handlingSendEvent; }
- (void)sendEvent:(NSEvent *)event {
    BOOL previous = self.handlingSendEvent;
    self.handlingSendEvent = YES;
    @try { [super sendEvent:event]; }
    @finally { self.handlingSendEvent = previous; }
}
@end
void WBPrepareApplication(void) { [WebbyApplication sharedApplication]; }

static void *library;
static bool initialized, shuttingDown, pumpRunning;
static bool isolatedTestKeychain;
static NSTimer *pump;
@class WebbyCEFEventPump;
static WebbyCEFEventPump *pumpHandler;
static double pumpDeadline = DBL_MAX;
static std::map<std::string, cef_request_context_t *> contexts;
static std::map<int, cef_browser_t *> browsers;
static NSMutableSet<WBChromiumView *> *pendingViews;
static cef_app_t *applicationHandler;
static cef_browser_process_handler_t *processHandler;
#define CEF_FUNCTION(name) static decltype(&name) p_##name
CEF_FUNCTION(cef_initialize);
CEF_FUNCTION(cef_shutdown);
CEF_FUNCTION(cef_do_message_loop_work);
CEF_FUNCTION(cef_api_hash);
CEF_FUNCTION(cef_browser_host_create_browser);
CEF_FUNCTION(cef_request_context_create_context);
CEF_FUNCTION(cef_string_userfree_utf16_free);

template<class T> static void release(T *value) { if (value) { auto *base = reinterpret_cast<cef_base_ref_counted_t *>(value); base->release(base); } }
template<class T> static T *retain(T *value) { if (value) { auto *base = reinterpret_cast<cef_base_ref_counted_t *>(value); base->add_ref(base); } return value; }
// CEF transfers one reference for every ref-counted argument crossing the C
// API boundary. Adopt callback arguments and explicitly retain outbound ones.
template<class T> struct Incoming {
    T *value;
    explicit Incoming(T *v) : value(v) {}
    ~Incoming() { release(value); }
};

// Each C API handler owns its reference count and only a weak reference to the
// native page. CEF can finish asynchronous close without accessing a freed tab.
template<class T> struct Handler {
    T api{};
    std::atomic<int> refs{1};
    __weak WBChromiumView *view;
    std::shared_ptr<void> state;
    Handler(WBChromiumView *owner = nil) : view(owner) {
        api.base.size = sizeof(T);
        api.base.add_ref = [](cef_base_ref_counted_t *s) { ++reinterpret_cast<Handler *>(s)->refs; };
        api.base.release = [](cef_base_ref_counted_t *s) -> int {
            auto *h = reinterpret_cast<Handler *>(s);
            if (--h->refs == 0) { delete h; return 1; } return 0;
        };
        api.base.has_one_ref = [](cef_base_ref_counted_t *s) -> int { return reinterpret_cast<Handler *>(s)->refs == 1; };
        api.base.has_at_least_one_ref = [](cef_base_ref_counted_t *s) -> int { return reinterpret_cast<Handler *>(s)->refs > 0; };
    }
};
template<class T> static WBChromiumView *owner(T *api) { return reinterpret_cast<Handler<T> *>(api)->view; }

static NSString *string(const cef_string_t *s) {
    return s && s->str ? [[NSString alloc] initWithCharacters:reinterpret_cast<const unichar *>(s->str) length:s->length] : @"";
}
struct Text {
    cef_string_t value{};
    Text(NSString *s) {
        value.length = s.length;
        value.str = static_cast<char16_t *>(calloc(s.length + 1, sizeof(char16_t)));
        [s getCharacters:reinterpret_cast<unichar *>(value.str) range:NSMakeRange(0, s.length)];
    }
    ~Text() { free(value.str); }
};

// Network-free HTTPS login fixtures exist only in the diagnostic process and
// its temporary profile. No certificate checks or production traffic change.
static cef_scheme_handler_factory_t *passwordFixtureFactory() {
    auto *factory = new Handler<cef_scheme_handler_factory_t>();
    factory->api.create = [](cef_scheme_handler_factory_t *, cef_browser_t *browser, cef_frame_t *frame,
        const cef_string_t *, cef_request_t *request) -> cef_resource_handler_t * {
        Incoming incomingBrowser(browser); Incoming incomingFrame(frame); Incoming incomingRequest(request);
        struct Body { std::string html; size_t offset = 0; };
        auto body = std::make_shared<Body>();
        body->html = R"HTML(<!doctype html><html><head><title>Secure password fixture</title></head><body>
        <input id="user" autocomplete="username"><input id="pass" type="password">
        <script>const user=document.querySelector('#user'),pass=document.querySelector('#pass');
        const report=()=>console.debug('__webby_password_check:'+JSON.stringify({
          username:user.value==='fixture-user',password:pass.value==='fixture-password',
          empty:!user.value&&!pass.value,origin:location.origin}));
        addEventListener('input',report,true);addEventListener('change',report,true);report();
        </script></body></html>)HTML";
        auto *resource = new Handler<cef_resource_handler_t>(); resource->state = body;
        resource->api.open = [](cef_resource_handler_t *, cef_request_t *r, int *handle, cef_callback_t *callback) -> int {
            Incoming incomingRequest(r); Incoming incomingCallback(callback); *handle = 1; return 1;
        };
        resource->api.get_response_headers = [](cef_resource_handler_t *s, cef_response_t *response, int64_t *length, cef_string_t *) {
            Incoming incoming(response);
            auto body = std::static_pointer_cast<Body>(reinterpret_cast<Handler<cef_resource_handler_t> *>(s)->state);
            response->set_status(response, 200); Text mime(@"text/html"); response->set_mime_type(response, &mime.value);
            *length = body->html.size();
        };
        resource->api.read = [](cef_resource_handler_t *s, void *out, int requested, int *read, cef_resource_read_callback_t *callback) -> int {
            Incoming incoming(callback);
            auto body = std::static_pointer_cast<Body>(reinterpret_cast<Handler<cef_resource_handler_t> *>(s)->state);
            size_t count = std::min<size_t>(MAX(0, requested), body->html.size() - body->offset);
            if (count) memcpy(out, body->html.data() + body->offset, count);
            body->offset += count; *read = (int)count; return count > 0;
        };
        resource->api.cancel = [](cef_resource_handler_t *) {};
        return &resource->api;
    };
    return &factory->api;
}

static NSString *frameworkPath(void) {
    return [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework"];
}
static NSString *canonicalPath(NSString *path) {
    // NSString path normalization can reintroduce /tmp or /var aliases. CEF
    // compares against realpath(root_cache_path), so use POSIX canonical paths.
    char *resolved = realpath(path.fileSystemRepresentation, nullptr);
    if (!resolved) return path;
    NSString *result = [NSString stringWithUTF8String:resolved]; free(resolved);
    return result;
}
BOOL WBChromiumAvailable(void) { return [NSFileManager.defaultManager fileExistsAtPath:frameworkPath()]; }

static void schedulePump(int64_t delay);

// Cocoa timers/performSelector keep CEF work outside the serial GCD main
// queue. This matters when AppKit enters tracking, dialogs, or quit handling.
@interface WebbyCEFEventPump : NSObject
- (void)scheduleWork:(NSNumber *)delay;
- (void)fire:(NSTimer *)timer;
@end
@implementation WebbyCEFEventPump
- (void)scheduleWork:(NSNumber *)delay {
    if (shuttingDown || !pumpHandler) return;
    int64_t milliseconds = MAX(1, MIN((int64_t)33, delay.longLongValue));
    double deadline = CFAbsoluteTimeGetCurrent() + milliseconds / 1000.0;
    if (pump && deadline >= pumpDeadline) return;
    [pump invalidate];
    pumpDeadline = deadline;
    pump = [NSTimer timerWithTimeInterval:milliseconds / 1000.0 target:self selector:@selector(fire:) userInfo:nil repeats:NO];
    [NSRunLoop.mainRunLoop addTimer:pump forMode:NSRunLoopCommonModes];
    [NSRunLoop.mainRunLoop addTimer:pump forMode:NSEventTrackingRunLoopMode];
}
- (void)fire:(NSTimer *)timer {
    if (timer != pump) return;
    pump = nil; pumpDeadline = DBL_MAX;
    if (!initialized || shuttingDown) return;
    if (pumpRunning) { schedulePump(33); return; }
    pumpRunning = true;
    p_cef_do_message_loop_work();
    pumpRunning = false;
    if (!browsers.empty() || pendingViews.count > 0) schedulePump(33);
}
@end
static void schedulePump(int64_t delay) {
    [pumpHandler performSelector:@selector(scheduleWork:)
                      onThread:NSThread.mainThread
                    withObject:@(MAX((int64_t)0, delay))
                 waitUntilDone:NO
                         modes:@[NSRunLoopCommonModes, NSEventTrackingRunLoopMode]];
}

BOOL WBChromiumInitialize(NSString *rootPath) {
    NSCAssert(NSThread.isMainThread, @"Chromium must start on the main thread");
    if (initialized) return YES;
    if (![NSFileManager.defaultManager createDirectoryAtPath:rootPath withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    rootPath = canonicalPath(rootPath);
    // Hermetic diagnostics never access the user's keychain. This switch is
    // restricted to our diagnostic entry points AND their temporary profiles.
    BOOL diagnosticProcess = [NSProcessInfo.processInfo.processName isEqualToString:@"WebbyEngineChecks"]
        || [NSProcessInfo.processInfo.arguments containsObject:@"--check-engine-ui"];
    BOOL diagnosticPath = [rootPath hasPrefix:@"/private/tmp/webby-engine-checks."]
        || ([rootPath hasPrefix:canonicalPath(NSTemporaryDirectory())]
            && [rootPath.lastPathComponent hasPrefix:@"webby-engine-ui-"]);
    isolatedTestKeychain = getenv("WEBBY_ENGINE_TEST_KEYCHAIN") && diagnosticProcess && diagnosticPath;
    if (shuttingDown || !WBChromiumAvailable()) return NO;
    library = dlopen(frameworkPath().fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!library) { NSLog(@"Chromium could not load: %s", dlerror()); return NO; }
#define LOAD(name) p_##name = reinterpret_cast<decltype(p_##name)>(dlsym(library, #name)); if (!p_##name) return NO
    LOAD(cef_api_hash);
    const char *actualHash = p_cef_api_hash(CEF_API_VERSION, 0);
    if (!actualHash || strcmp(actualHash, CEF_API_HASH_PLATFORM) != 0) return NO;
    LOAD(cef_initialize); LOAD(cef_shutdown); LOAD(cef_do_message_loop_work);
    LOAD(cef_browser_host_create_browser); LOAD(cef_request_context_create_context);
    LOAD(cef_string_userfree_utf16_free);
#undef LOAD
    pumpHandler = [WebbyCEFEventPump new];
    auto *process = new Handler<cef_browser_process_handler_t>();
    process->api.on_context_initialized = [](cef_browser_process_handler_t *) {
        if (getenv("WEBBY_ENGINE_DIAGNOSTICS")) fprintf(stderr, "CEF: global context initialized\n");
    };
    process->api.on_schedule_message_pump_work = [](cef_browser_process_handler_t *, int64_t delay) { schedulePump(delay); };
    auto *app = new Handler<cef_app_t>();
    app->api.on_before_command_line_processing = [](cef_app_t *, const cef_string_t *, cef_command_line_t *command) {
        Incoming incoming(command);
        if (isolatedTestKeychain) {
            Text option(@"use-mock-keychain"); command->append_switch(command, &option.value);
        }
    };
    // Application and process handlers are intentionally held until shutdown.
    processHandler = &process->api;
    applicationHandler = &app->api;
    app->api.get_browser_process_handler = [](cef_app_t *) { return retain(processHandler); };
    cef_settings_t settings{}; settings.size = sizeof(settings);
    settings.external_message_pump = 1;
    settings.command_line_args_disabled = 1;
    settings.log_severity = LOGSEVERITY_WARNING;
    settings.persist_session_cookies = 1;
    settings.background_color = 0xff17191e;
    Text root(rootPath), cache([rootPath stringByAppendingPathComponent:@"Default"]);
    Text helper([NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Frameworks/Webby Helper.app/Contents/MacOS/Webby Helper"]);
    Text log([rootPath stringByAppendingPathComponent:@"chromium.log"]);
    settings.root_cache_path = root.value; settings.cache_path = cache.value;
    settings.browser_subprocess_path = helper.value; settings.log_file = log.value;
    int argc = 1; char *argv[] = {const_cast<char *>(NSBundle.mainBundle.executablePath.fileSystemRepresentation), nullptr};
    cef_main_args_t args{argc, argv};
    if (!p_cef_initialize(&args, &settings, retain(&app->api), nullptr)) {
        // CEF explicitly prohibits continuing after failed initialization.
        NSLog(@"Chromium initialization failed; exiting without touching browser data.");
        exit(1);
    }
    initialized = true;
    schedulePump(0);
    return YES;
}
// Quit must also wait for an in-flight pump callback to unwind before CEF
// shutdown; a nested Cocoa run loop can otherwise reach shutdown mid-callback.
BOOL WBChromiumHasBrowsers(void) { return pumpRunning || !browsers.empty() || pendingViews.count > 0; }
void WBChromiumShutdown(void) {
    if (!initialized || WBChromiumHasBrowsers()) return;
    shuttingDown = true;
    for (auto &entry : contexts) release(entry.second);
    contexts.clear();
    [pump invalidate]; pump = nil; pumpHandler = nil;
    p_cef_shutdown(); initialized = false;
    release(applicationHandler); applicationHandler = nullptr;
    release(processHandler); processHandler = nullptr;
    // Do not dlclose Chromium: Objective-C classes remain registered until exit.
}

@interface WBChromiumView () {
    cef_browser_t *_browser;
    BOOL _closed, _creating, _loading, _canGoBack, _canGoForward, _protectsFromDiscard, _captureGranted, _fullscreen;
    NSMutableSet<NSNumber *> *_downloads;
    NSString *_pageURL, *_pageTitle, *_pendingNavigation;
}
- (void)emit:(NSString *)event value:(NSString *)value;
- (void)updateLoading:(BOOL)loading back:(BOOL)back forward:(BOOL)forward;
- (void)updateURL:(NSString *)url;
- (void)updateTitle:(NSString *)title;
- (void)updateActivity:(NSString *)state;
- (void)setCapturing;
- (void)setFullscreen:(BOOL)fullscreen;
- (void)download:(int)identifier active:(BOOL)active;
- (void)createdBrowser:(cef_browser_t *)browser;
@end

static cef_client_t *makeClient(WBChromiumView *view) {
    auto *client = new Handler<cef_client_t>(view);
    client->api.get_life_span_handler = [](cef_client_t *s) {
        auto *h = new Handler<cef_life_span_handler_t>(owner(s));
        h->api.on_after_created = [](cef_life_span_handler_t *s, cef_browser_t *b) {
            Incoming incoming(b);
            browsers.emplace(b->get_identifier(b), retain(b));
            WBChromiumView *page = owner(s);
            [page createdBrowser:b];
            [pendingViews removeObject:page];
        };
        // A tab must never send performClose: to Webby's containing NSWindow.
        // Removing its native child view completes destruction on macOS.
        h->api.do_close = [](cef_life_span_handler_t *, cef_browser_t *b) -> int { Incoming incoming(b); return 1; };
        h->api.on_before_close = [](cef_life_span_handler_t *, cef_browser_t *b) {
            Incoming incoming(b);
            auto it = browsers.find(b->get_identifier(b)); if (it != browsers.end()) { release(it->second); browsers.erase(it); }
        };
        h->api.on_before_popup = [](cef_life_span_handler_t *s, cef_browser_t *b, cef_frame_t *f, int,
            const cef_string_t *url, const cef_string_t *, cef_window_open_disposition_t, int,
            const cef_popup_features_t *, cef_window_info_t *, cef_client_t **, cef_browser_settings_t *, cef_dictionary_value_t **, int *) -> int {
            Incoming incomingBrowser(b); Incoming incomingFrame(f);
            [owner(s) emit:@"popup" value:string(url)]; return 1;
        };
        return &h->api;
    };
    client->api.get_display_handler = [](cef_client_t *s) {
        auto *h = new Handler<cef_display_handler_t>(owner(s));
        h->api.on_address_change = [](cef_display_handler_t *s, cef_browser_t *b, cef_frame_t *f, const cef_string_t *url) {
            Incoming incomingBrowser(b); Incoming incomingFrame(f);
            if (f->is_main(f)) [owner(s) updateURL:string(url)];
        };
        h->api.on_title_change = [](cef_display_handler_t *s, cef_browser_t *b, const cef_string_t *title) { Incoming incoming(b); [owner(s) updateTitle:string(title)]; };
        h->api.on_fullscreen_mode_change = [](cef_display_handler_t *s, cef_browser_t *b, int fullscreen) { Incoming incoming(b); [owner(s) setFullscreen:fullscreen]; };
        h->api.on_console_message = [](cef_display_handler_t *s, cef_browser_t *b, cef_log_severity_t,
            const cef_string_t *message, const cef_string_t *, int) -> int {
            Incoming incoming(b); NSString *text = string(message);
            if ([text hasPrefix:@"__webby_activity:"]) { [owner(s) updateActivity:[text substringFromIndex:17]]; return 1; }
            if ([text isEqualToString:@"__webby_password_field"]) { [owner(s) emit:@"passwordField" value:@""]; return 1; }
            if (isolatedTestKeychain && [text hasPrefix:@"__webby_password_check:"]) {
                [owner(s) emit:@"passwordCheck" value:[text substringFromIndex:23]]; return 1;
            }
            return 0;
        };
        return &h->api;
    };
    client->api.get_load_handler = [](cef_client_t *s) {
        auto *h = new Handler<cef_load_handler_t>(owner(s));
        h->api.on_loading_state_change = [](cef_load_handler_t *s, cef_browser_t *b, int loading, int back, int forward) {
            Incoming incoming(b);
            [owner(s) updateLoading:loading back:back forward:forward];
        };
        h->api.on_load_end = [](cef_load_handler_t *, cef_browser_t *b, cef_frame_t *f, int) {
            Incoming incomingBrowser(b); Incoming incomingFrame(f);
            if (!f->is_main(f)) return;
            // Event-driven activity tracking; no repeating JavaScript timer.
            Text js(@"(()=>{if(window.__webbyActivityInstalled)return;window.__webbyActivityInstalled=true;let edited=false;const report=()=>console.debug('__webby_activity:'+JSON.stringify({edited,embedded:!!document.querySelector('iframe,object,embed'),media:[...document.querySelectorAll('video,audio')].some(m=>!m.paused&&!m.ended),x:scrollX,y:scrollY}));let queued=false;const schedule=()=>{if(queued)return;queued=true;setTimeout(()=>{queued=false;report()},150)};addEventListener('input',()=>{edited=true;report()},true);addEventListener('submit',()=>{edited=false;report()},true);['play','pause','ended','visibilitychange'].forEach(e=>addEventListener(e,report,true));addEventListener('scroll',schedule,{passive:true});new MutationObserver(records=>{if(records.some(r=>[...r.addedNodes,...r.removedNodes].some(n=>n.nodeType===1&&(n.matches('iframe,object,embed,video,audio')||n.querySelector('iframe,object,embed,video,audio')))))schedule()}).observe(document.documentElement,{childList:true,subtree:true});report()})()");
            Text source(@"webby://activity"); f->execute_java_script(f, &js.value, &source.value, 1);
            // Only a field-available signal crosses this bridge. Credentials
            // stay in Webby's profile vault and fill only the trusted main frame.
            Text probe(@"(()=>{if(location.protocol!=='https:'||window.__webbyPasswordProbe)return;window.__webbyPasswordProbe=true;const seen=new WeakSet();let queued=false;const selector='input[type=password],input[autocomplete=username],input[type=email][name=identifier]';const check=()=>{const field=document.querySelector('input[type=password]')||document.querySelector(selector);if(!field||seen.has(field))return;seen.add(field);console.debug('__webby_password_field');if(field.type==='password')observer.disconnect()};const observer=new MutationObserver(()=>{if(queued)return;queued=true;setTimeout(()=>{queued=false;check()},120)});observer.observe(document,{childList:true,subtree:true});document.addEventListener('focusin',e=>{if(e.target instanceof Element&&e.target.matches(selector))check()},true);addEventListener('pageshow',check);check()})()");
            Text probeSource(@"webby://password-probe"); f->execute_java_script(f, &probe.value, &probeSource.value, 1);
        };
        h->api.on_load_error = [](cef_load_handler_t *s, cef_browser_t *b, cef_frame_t *f, cef_errorcode_t code, const cef_string_t *error, const cef_string_t *) {
            Incoming incomingBrowser(b); Incoming incomingFrame(f);
            if (f->is_main(f) && code != ERR_ABORTED) [owner(s) emit:@"error" value:string(error)];
        };
        return &h->api;
    };
    client->api.get_request_handler = [](cef_client_t *s) {
        auto *h = new Handler<cef_request_handler_t>(owner(s));
        h->api.on_render_process_terminated = [](cef_request_handler_t *s, cef_browser_t *b, cef_termination_status_t, int, const cef_string_t *) {
            Incoming incoming(b);
            [owner(s) emit:@"error" value:@"This Chromium page stopped responding. Reload to try again."];
        };
        return &h->api;
    };
    client->api.get_download_handler = [](cef_client_t *s) {
        auto *h = new Handler<cef_download_handler_t>(owner(s));
        h->api.can_download = [](cef_download_handler_t *, cef_browser_t *b, const cef_string_t *, const cef_string_t *) -> int { Incoming incoming(b); return 1; };
        h->api.on_before_download = [](cef_download_handler_t *s, cef_browser_t *b, cef_download_item_t *item, const cef_string_t *, cef_before_download_callback_t *callback) -> int {
            Incoming incomingBrowser(b); Incoming incomingItem(item); Incoming incomingCallback(callback);
            [owner(s) download:item->get_id(item) active:YES];
            Text path(@""); callback->cont(callback, &path.value, 1); return 1;
        };
        h->api.on_download_updated = [](cef_download_handler_t *s, cef_browser_t *b, cef_download_item_t *item, cef_download_item_callback_t *callback) {
            Incoming incomingBrowser(b); Incoming incomingItem(item); Incoming incomingCallback(callback);
            [owner(s) download:item->get_id(item) active:item->is_in_progress(item)];
        };
        return &h->api;
    };
    client->api.get_permission_handler = [](cef_client_t *s) {
        auto *h = new Handler<cef_permission_handler_t>(owner(s));
        h->api.on_request_media_access_permission = [](cef_permission_handler_t *s, cef_browser_t *b, cef_frame_t *f, const cef_string_t *origin, uint32_t requested, cef_media_access_callback_t *callback) -> int {
            Incoming incomingBrowser(b); Incoming incomingFrame(f); Incoming incomingCallback(callback);
            WBChromiumView *page = owner(s);
            if (!page.window || page.isHidden) { callback->cancel(callback); return 1; }
            retain(callback);
            NSAlert *alert = [NSAlert new]; alert.messageText = @"Allow camera or microphone access?";
            alert.informativeText = [NSString stringWithFormat:@"%@ wants to use media capture in this Chromium tab.", string(origin)];
            [alert addButtonWithTitle:@"Don't Allow"]; [alert addButtonWithTitle:@"Allow"];
            __weak WBChromiumView *weakPage = page;
            [alert beginSheetModalForWindow:page.window completionHandler:^(NSModalResponse response) {
                WBChromiumView *current = weakPage;
                if (current && response == NSAlertSecondButtonReturn) { [current setCapturing]; callback->cont(callback, requested); }
                else callback->cancel(callback);
                release(callback);
            }];
            return 1;
        };
        return &h->api;
    };
    return &client->api;
}

@implementation WBChromiumView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) { _pageURL = @""; _pageTitle = @""; _downloads = [NSMutableSet new]; _protectsFromDiscard = YES; self.wantsLayer = YES; }
    return self;
}
- (NSString *)pageURL { return _pageURL; }
- (NSString *)pageTitle { return _pageTitle; }
- (BOOL)loading { return _loading; }
- (BOOL)canGoBack { return _canGoBack; }
- (BOOL)canGoForward { return _canGoForward; }
- (BOOL)protectsFromDiscard { return _protectsFromDiscard || _captureGranted || _fullscreen || _downloads.count > 0; }
- (void)setCapturing { _captureGranted = YES; }
- (void)setFullscreen:(BOOL)fullscreen { _fullscreen = fullscreen; }
- (void)download:(int)identifier active:(BOOL)active {
    if (active) [_downloads addObject:@(identifier)]; else [_downloads removeObject:@(identifier)];
}
- (void)emit:(NSString *)event value:(NSString *)value { if (!_closed && self.eventHandler) self.eventHandler(event, value); }
- (void)updateURL:(NSString *)url { _pageURL = [url copy]; _protectsFromDiscard = YES; [self emit:@"url" value:url]; }
- (void)updateTitle:(NSString *)title { _pageTitle = [title copy]; [self emit:@"title" value:title]; }
- (void)updateLoading:(BOOL)loading back:(BOOL)back forward:(BOOL)forward {
    _loading = loading; _canGoBack = back; _canGoForward = forward;
    [self emit:@"loading" value:loading ? @"1" : @"0"];
}
- (void)updateActivity:(NSString *)state {
    NSDictionary *value = [NSJSONSerialization JSONObjectWithData:[state dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if ([value isKindOfClass:NSDictionary.class]) {
        _protectsFromDiscard = [value[@"edited"] boolValue] || [value[@"media"] boolValue] || [value[@"embedded"] boolValue];
        [self emit:@"activity" value:state];
    }
}
- (BOOL)openURL:(NSString *)url profile:(NSString *)profile {
    if (_closed || !initialized) return NO;
    if (_browser || _creating) { [self navigate:url]; return YES; }
    if (![NSFileManager.defaultManager createDirectoryAtPath:profile withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    profile = canonicalPath(profile);
    auto key = std::string(profile.UTF8String);
    cef_request_context_t *context;
    auto found = contexts.find(key);
    if (found == contexts.end()) {
        cef_request_context_settings_t settings{}; settings.size = sizeof(settings);
        Text path(profile); settings.cache_path = path.value; settings.persist_session_cookies = 1;
        auto *handler = new Handler<cef_request_context_handler_t>();
        handler->api.on_request_context_initialized = [](cef_request_context_handler_t *, cef_request_context_t *context) {
            Incoming incoming(context);
            if (isolatedTestKeychain) {
                Text scheme(@"https"), host(@"webby-password.test"), other(@"other.webby-password.test");
                context->register_scheme_handler_factory(context, &scheme.value, &host.value, passwordFixtureFactory());
                context->register_scheme_handler_factory(context, &scheme.value, &other.value, passwordFixtureFactory());
            }
            if (getenv("WEBBY_ENGINE_DIAGNOSTICS")) fprintf(stderr, "CEF: page profile initialized\n");
        };
        context = p_cef_request_context_create_context(&settings, &handler->api);
        if (!context) return NO;
        contexts[key] = context;
    } else context = found->second;
    cef_window_info_t window{}; window.size = sizeof(window);
    window.parent_view = (__bridge void *)self;
    window.bounds = {0, 0, MAX(1, (int)self.bounds.size.width), MAX(1, (int)self.bounds.size.height)};
    window.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    cef_browser_settings_t settings{}; settings.size = sizeof(settings);
    settings.background_color = 0xff17191e;
    auto *client = makeClient(self); Text address(url);
    _creating = YES; _pageURL = [url copy];
    if (!pendingViews) pendingViews = [NSMutableSet new];
    [pendingViews addObject:self];
    int accepted = p_cef_browser_host_create_browser(&window, client, &address.value, &settings, nullptr, retain(context));
    if (!accepted) { _creating = NO; [pendingViews removeObject:self]; return NO; }
    schedulePump(0);
    return YES;
}
- (void)createdBrowser:(cef_browser_t *)browser {
    if (getenv("WEBBY_ENGINE_DIAGNOSTICS")) fprintf(stderr, "CEF: browser created\n");
    _creating = NO; _browser = retain(browser);
    auto *host = _browser->get_host(_browser);
    NSView *view = (__bridge NSView *)host->get_window_handle(host);
    view.frame = self.bounds; view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    release(host);
    if (_closed) {
        // The tab was closed while CEF was initializing its request context.
        _closed = NO; [self closePage]; return;
    }
    if (_pendingNavigation) {
        NSString *url = _pendingNavigation; _pendingNavigation = nil;
        __weak WBChromiumView *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf navigate:url]; });
    }
    [self emit:@"created" value:@""];
}
- (void)navigate:(NSString *)url {
    if (_closed) return;
    _pageURL = [url copy];
    if (!_browser) { _pendingNavigation = [url copy]; return; }
    auto *f = _browser->get_main_frame(_browser);
    if (f) { Text value(url); f->load_url(f, &value.value); release(f); }
}
- (void)goBack { if (_browser && !_closed) _browser->go_back(_browser); }
- (void)goForward { if (_browser && !_closed) _browser->go_forward(_browser); }
- (void)reload { if (_browser && !_closed) _browser->reload(_browser); }
- (void)findText:(NSString *)text backwards:(BOOL)backwards {
    if (!_browser || _closed) return;
    auto *h = _browser->get_host(_browser); Text value(text); h->find(h, &value.value, !backwards, 0, 1); release(h);
}
- (BOOL)runScript:(NSString *)script expectedOrigin:(NSString *)origin {
    if (!_browser || _closed || _loading) return NO;
    auto *frame = _browser->get_main_frame(_browser);
    if (!frame) return NO;
    cef_string_userfree_t rawURL = frame->get_url(frame);
    NSString *address = string(rawURL);
    if (rawURL) p_cef_string_userfree_utf16_free(rawURL);
    NSURLComponents *actual = [NSURLComponents componentsWithString:address];
    NSURLComponents *expected = [NSURLComponents componentsWithString:origin];
    BOOL allowed = [actual.scheme.lowercaseString isEqualToString:@"https"]
        && [expected.scheme.lowercaseString isEqualToString:@"https"]
        && [actual.host.lowercaseString isEqualToString:expected.host.lowercaseString]
        && (actual.port.intValue ?: 443) == (expected.port.intValue ?: 443);
    if (allowed) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:@[origin] options:0 error:nil];
        NSString *originJSON = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSString *guarded = [NSString stringWithFormat:@"if(location.origin === (%@)[0]) { %@ }", originJSON, script];
        Text code(guarded), source(@"webby://password-fill");
        frame->execute_java_script(frame, &code.value, &source.value, 1);
    }
    release(frame);
    return allowed;
}
- (void)focusPage {
    if (!_browser || _closed) return;
    auto *h = _browser->get_host(_browser); h->set_focus(h, 1); release(h);
}
- (void)closePage {
    if (_closed) return;
    _closed = YES; self.eventHandler = nil;
    if (_browser) {
        auto *h = _browser->get_host(_browser);
        NSView *native = (__bridge NSView *)h->get_window_handle(h);
        h->close_browser(h, 1);
        [native removeFromSuperview];
        release(h);
        release(_browser); _browser = nullptr;
    }
}
- (void)dealloc { [self closePage]; }
@end
