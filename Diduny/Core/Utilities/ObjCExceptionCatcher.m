#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (BOOL)catchException:(void(NS_NOESCAPE ^)(void))tryBlock error:(__autoreleasing NSError **)error {
    @try {
        tryBlock();
        return YES;
    }
    @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:exception.name code:0 userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: @"Unknown Objective-C exception"
            }];
        }
        return NO;
    }
}

@end
