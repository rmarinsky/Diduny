#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCExceptionCatcher : NSObject
+ (BOOL)catchException:(void(NS_NOESCAPE ^)(void))tryBlock error:(__autoreleasing NSError **)error;
@end

NS_ASSUME_NONNULL_END
