#import <Foundation/Foundation.h>

@interface ReleaseUpdater : NSObject
@property (readonly, copy) NSString *status;
@property (readonly, copy) NSString *availableVersion;
@property (readonly) BOOL checking;
@property (readonly) BOOL installing;
@property (copy) void (^changed)(void);
- (void)check;
- (void)install;
@end
