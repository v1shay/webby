#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
#ifdef __cplusplus
extern "C" {
#endif
// Loaded only when the first Chromium page is opened. No Chromium event pump
// or helper process is started for a WebKit-only session.
void WBPrepareApplication(void);
BOOL WBChromiumAvailable(void);
BOOL WBChromiumInitialize(NSString *rootPath);
BOOL WBChromiumHasBrowsers(void);
void WBChromiumShutdown(void);
#ifdef __cplusplus
}
#endif

@interface WBChromiumView : NSView
@property(nonatomic, copy, nullable) void (^eventHandler)(NSString *event, NSString *value);
@property(nonatomic, readonly, copy) NSString *pageURL;
@property(nonatomic, readonly, copy) NSString *pageTitle;
@property(nonatomic, readonly) BOOL loading;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL canGoForward;
@property(nonatomic, readonly) BOOL protectsFromDiscard;
- (BOOL)openURL:(NSString *)url profile:(NSString *)profile;
- (void)navigate:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)findText:(NSString *)text backwards:(BOOL)backwards;
- (BOOL)runScript:(NSString *)script expectedOrigin:(NSString *)origin;
- (void)focusPage;
- (void)closePage;
@end
NS_ASSUME_NONNULL_END
