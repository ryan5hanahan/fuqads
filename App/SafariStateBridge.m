#import "SafariStateBridge.h"

void bl0cksh1t_getContentBlockerState(
    NSString *identifier,
    void (^completion)(SFContentBlockerState *state, NSError *error)) {
    [SFContentBlockerManager
        getStateOfContentBlockerWithIdentifier:identifier
                              completionHandler:^(SFContentBlockerState *state,
                                                 NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(state, error);
        });
    }];
}

void bl0cksh1t_getWebExtensionState(
    NSString *identifier,
    void (^completion)(SFSafariExtensionState *state, NSError *error)) {
    [SFSafariExtensionManager
        getStateOfSafariExtensionWithIdentifier:identifier
                              completionHandler:^(SFSafariExtensionState *state,
                                                 NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(state, error);
        });
    }];
}
