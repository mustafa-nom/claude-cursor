//
//  ObjCExceptionBridge.m
//  claude-cursor
//

#import "ObjCExceptionBridge.h"

NSException * _Nullable runBlockCatchingNSException(void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
