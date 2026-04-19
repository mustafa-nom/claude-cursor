//
//  ObjCExceptionBridge.h
//  claude-cursor
//
//  Swift has no native NSException catch. This header exposes a single
//  function that runs a block under `@try`/`@catch` so Swift callers can
//  recover from AppKit / Foundation NSException paths (e.g. NSHostingView
//  "Update Constraints pass recursion", NSWindow setFrame asserts) without
//  killing the whole process.
//
//  Use sparingly — NSExceptions indicate programmer error and should be
//  prevented first. This exists so a single bug at an AppKit boundary
//  doesn't terminate the app via +[NSApplication _crashOnException:].
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and catches any `NSException` it throws. Returns `nil` if
/// the block completed normally, or the captured exception otherwise.
NSException * _Nullable runBlockCatchingNSException(
    __attribute__((noescape)) void (^block)(void)
);

NS_ASSUME_NONNULL_END
