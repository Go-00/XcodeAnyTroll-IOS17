#import <Foundation/Foundation.h>

#import <dlfcn.h>
#import <roothide.h>

#define TAG "[XcodeAnyDebug] "

@interface DTDSLaunchTargetID : NSObject
- (instancetype)initWithUser:(uid_t)user group:(gid_t)group;
@end

@interface DTDSSpawnOptions : NSObject
@property (nonatomic, strong) DTDSLaunchTargetID *targetUserAndGroup;
@end

%group SMJob

static void* _SMJobSubmit;

%hookf(Boolean, _SMJobSubmit, CFStringRef domain, CFDictionaryRef job, CFTypeID auth, CFErrorRef *outError)
{
    NSMutableDictionary* mjob = [(__bridge NSDictionary*)job mutableCopy];
    if (job != nil && mjob[@"ProgramArguments"] != nil)
    {
        NSArray* argv = mjob[@"ProgramArguments"];

        NSLog(@TAG "_SMJobSubmit argv=%@", argv);

        if ([argv[0] hasSuffix:@"/debugserver"])
        {
            NSMutableArray* new_argv = [argv mutableCopy];

            new_argv[0] = jbroot(@"/usr/bin/xcodeanydebug/debugserver");

            mjob[@"UserName"] = @"root";
            mjob[@"ProgramArguments"] = new_argv;
        }

        job = (__bridge_retained CFDictionaryRef)mjob;     
    }
    return %orig;
}

%end

%group Dtds

static void* _dtdsSpawnExecutableWithOptions;

/*
 * 仅适用于 iOS 16 及更早：那时 dtdsSpawnExecutableWithOptions 的第二个参数
 * 是 ObjC 对象（DTDSSpawnOptions），可以直接 setTargetUserAndGroup:。
 *
 * iOS 17 起该参数变成了 C 结构体指针（调用点把参数打包到栈上再传 x1），
 * DTDSLaunchTargetID / DTDSSpawnOptions 两个类也已经从 DTDeviceServices 里移除。
 * 继续沿用这段会对着结构体发 objc_msgSend，在 lookUpImpOrForward 里 SIGBUS。
 * 因此在 17+ 上我们完全不注入这个 hook，让 dtdebugproxyd 保持原生行为。
 */
%hookf(Boolean, _dtdsSpawnExecutableWithOptions, const char *path, DTDSSpawnOptions *options, pid_t *pid, NSError **error)
{
    NSLog(@TAG "_dtdsSpawnExecutableWithOptions path=%s", path);

    if ([[NSString stringWithUTF8String:path] hasSuffix:@"/debugserver"])
    {
        DTDSLaunchTargetID *target = [[%c(DTDSLaunchTargetID) alloc] initWithUser:0 group:0];
        [options setTargetUserAndGroup:target];

        NSString *newPath = jbroot(@"/usr/bin/xcodeanydebug/debugserver");
        return %orig([newPath UTF8String], options, pid, error);
    }

    return %orig;
}

%end

%ctor {
    BOOL isDtds = NO;
    for (NSString* arg in [[NSProcessInfo processInfo] arguments]) {
        if ([arg hasSuffix:@"dtdebugproxyd"]) {
            isDtds = YES;
            break;
        }
    }
    NSLog(@TAG "isDtds=%@", isDtds ? @"YES" : @"NO");

    if (isDtds) {
        if (@available(iOS 17, *)) {
            NSLog(@TAG "iOS 17+ detected: skipping dtds hook (ABI changed to C struct), dtdebugproxyd left untouched");
            return;
        }

        _dtdsSpawnExecutableWithOptions = dlsym(RTLD_DEFAULT, "dtdsSpawnExecutableWithOptions");
        if (_dtdsSpawnExecutableWithOptions) {
            %init(Dtds);
        } else {
            NSLog(@TAG "dtdsSpawnExecutableWithOptions not found, nothing to hook");
        }
    } else {
        _SMJobSubmit = dlsym(RTLD_DEFAULT, "SMJobSubmit");
        if (_SMJobSubmit) {
            %init(SMJob);
        } else {
            NSLog(@TAG "SMJobSubmit not found, nothing to hook");
        }
    }
}
