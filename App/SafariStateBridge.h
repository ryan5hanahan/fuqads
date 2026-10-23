#import <Foundation/Foundation.h>
#import <SafariServices/SafariServices.h>

#ifdef __cplusplus
extern "C" {
#endif

/// State queries bridged with a plain (nonisolated) completion delivered on
/// the main queue.
///
/// Why: SafariServices annotates both completions `NS_SWIFT_UI_ACTOR`, so
/// the direct Swift import is a `@MainActor` closure — but Safari delivers
/// the XPC reply on the connection's user queue (`com.apple.NSXPCConnection
/// .user.com.apple.SafariServices.ExtensionHelper`). Under Swift 6 the
/// runtime isolation check traps on entry ("Block was expected to execute
/// on queue [com.apple.main-thread]"), and `Task { @MainActor in }` created
/// from that context is equally fragile in debug builds. Bouncing the
/// reply through `dispatch_async(main_queue)` in ObjC hands the caller a
/// plain block on the main thread; the caller hops isolation with
/// `MainActor.assumeIsolated`.
FOUNDATION_EXPORT void bl0cksh1t_getContentBlockerState(
    NSString *identifier,
    void (^completion)(SFContentBlockerState * _Nullable state,
                       NSError * _Nullable error));
FOUNDATION_EXPORT void bl0cksh1t_getWebExtensionState(
    NSString *identifier,
    void (^completion)(SFSafariExtensionState * _Nullable state,
                       NSError * _Nullable error));

#ifdef __cplusplus
}
#endif
