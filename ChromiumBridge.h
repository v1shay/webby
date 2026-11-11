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
void WBChromiumForgetPrivateSession(NSString *identifier);
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
@property(nonatomic, readonly) BOOL hasActiveDownloads;
@property(nonatomic, copy, nullable) BOOL (^allowsDownload)(void);
@property(nonatomic, copy, nullable) BOOL (^routeLink)(NSString *address);
// Return a newly configured empty native page; CEF supplies its browser and
// preserves window.opener, named targets, and the original popup navigation.
@property(nonatomic, copy, nullable) WBChromiumView * _Nullable (^popupHandler)(NSString *address, BOOL background);
- (BOOL)openURL:(NSString *)url profile:(NSString *)profile;
// A private profile uses a session identifier prefixed with "private:".
- (void)navigate:(NSString *)url;
- (void)setAudioMuted:(BOOL)muted;
- (BOOL)isAudioMuted;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)findText:(NSString *)text backwards:(BOOL)backwards;
- (void)stopFinding;
- (BOOL)runScript:(NSString *)script expectedOrigin:(NSString *)origin;
- (void)automationMethod:(NSString *)method parameters:(NSDictionary *)parameters
              completion:(void (^)(NSDictionary * _Nullable result, NSString * _Nullable error))completion
    NS_SWIFT_NAME(automation(method:parameters:completion:));
@property(nonatomic, copy, nullable) void (^automationDownloadDestination)(NSString *identifier, NSString *filename, void (^reply)(NSString * _Nullable path));
@property(nonatomic, copy, nullable) void (^automationDownloadFinished)(NSString *identifier, NSString *status);
- (BOOL)startAutomationDownload:(NSString *)address identifier:(NSString *)identifier
    NS_SWIFT_NAME(startAutomationDownload(_:identifier:));
- (void)cancelAutomationDownload:(NSString *)identifier NS_SWIFT_NAME(cancelAutomationDownload(_:));
- (void)focusPage;
- (void)closePage;
@end
NS_ASSUME_NONNULL_END
