#import <Foundation/Foundation.h>
#import <SSZipArchive/SSZipArchive.h>
#import <HBLog.h>

#import <dlfcn.h>
#import <libSandy.h>
#import <libSandyXpc.h>

#import "LSApplicationProxy.h"
#import "LSRecordPromise.h"
#import "MCMContainer.h"

#define TAG "[XcodeAnyTroll] "

/*
 * roothide 下越狱侧文件全在随机命名的 jbroot 里，静态路径必须过 jbroot()。
 * 用 roothide/theos 构建时该头与函数可用；普通 theos 下退化成恒等映射。
 */
#if __has_include(<roothide.h>)
#import <roothide.h>
#define XAT_HAS_ROOTHIDE 1
#else
#define XAT_HAS_ROOTHIDE 0
static inline const char *jbroot(const char *path) { return path; }
#endif

static NSString *gPackageIdentifier = nil;
static NSString *gPackagePath = nil;
static LSRecordPromise *gRecordPromise = nil;

/* 防递归：万一哪天走了 helper 的 installd 分支，会把安装打回我们自己的 hook */
static BOOL gInstallingViaTrollStore = NO;

static SandyXpcMessagingCenter *GetXpcMessagingCenter(void) {
    static SandyXpcMessagingCenter *messagingCenter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        messagingCenter = [SandyXpcMessagingCenter centerNamed:@"com.82flex.xcodeanytroll"];
    });
    return messagingCenter;
}

/*
 * installd 的 Xcode 安装流程里，待安装的 .app 位于 /var/installd/.../staging 下，
 * 但它落在哪个子目录、错误描述里是否带上路径，各系统版本并不一致。
 * 依次尝试：url.path → 错误文本里的路径 → staging 目录扫描。
 */
static NSString *ResolveStagedAppPath(NSURL *url, NSString *errorDescription) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];

    if (url.isFileURL && url.path.length > 0) {
        [candidates addObject:url.path];
    }

    if (errorDescription.length > 0) {
        NSRegularExpression *regex =
            [NSRegularExpression regularExpressionWithPattern:@"(/private)?/var/installd/[^:\\s\"']+"
                                                     options:0
                                                       error:nil];
        NSArray<NSTextCheckingResult *> *matches =
            [regex matchesInString:errorDescription options:0 range:NSMakeRange(0, errorDescription.length)];
        for (NSTextCheckingResult *match in matches) {
            NSString *path = [[errorDescription substringWithRange:match.range]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (path.length > 0) [candidates addObject:path];
        }
    }

    for (NSString *candidate in candidates) {
        NSString *infoPlistPath = [candidate stringByAppendingPathComponent:@"Info.plist"];
        if ([fileManager fileExistsAtPath:infoPlistPath]) return candidate;
    }

    /* 最后兜底：扫 staging 根目录下两层找 .app */
    NSArray<NSString *> *stagingRoots = @[
        @"/private/var/installd/Library/Caches/com.apple.mobile.installd.staging",
        @"/var/installd/Library/Caches/com.apple.mobile.installd.staging",
    ];
    for (NSString *root in stagingRoots) {
        for (NSString *first in [fileManager contentsOfDirectoryAtPath:root error:nil]) {
            NSString *firstPath = [root stringByAppendingPathComponent:first];
            for (NSString *second in [fileManager contentsOfDirectoryAtPath:firstPath error:nil]) {
                NSString *secondPath = [firstPath stringByAppendingPathComponent:second];
                if ([[secondPath pathExtension] isEqualToString:@"app"] &&
                    [fileManager fileExistsAtPath:[secondPath stringByAppendingPathComponent:@"Info.plist"]]) {
                    return secondPath;
                }
            }
        }
    }

    return nil;
}

/*
 * daemon 刚被 launchd 拉起时 mach service 可能还没就绪，首次连接会失败，
 * 所以重试一次再放弃。返回值保留原始 error 供上层拼进 Xcode 的报错。
 */
static NSDictionary *InstallPackageViaTrollStore(NSString *packagePath, NSString *packageIdentifier,
                                                 NSError **errorPtr) {
    if (gInstallingViaTrollStore) {
        HBLogError(@TAG "recursive install attempt blocked");
        if (errorPtr) {
            *errorPtr = [NSError errorWithDomain:@"XcodeAnyTroll"
                                            code:-1
                                        userInfo:@{NSLocalizedDescriptionKey : @"Recursive install blocked"}];
        }
        return nil;
    }

    gInstallingViaTrollStore = YES;

    NSDictionary *retVal = nil;
    NSError *lastError = nil;

    for (int attempt = 0; attempt < 2; attempt++) {
        NSError *xpcError = nil;
        retVal = [GetXpcMessagingCenter() sendMessageAndReceiveReplyName:@"InstallPackage"
                                                                userInfo:@{
                                                                    @"PackagePath" : packagePath,
                                                                    @"PackageIdentifier" : packageIdentifier,
                                                                }
                                                                   error:&xpcError];
        lastError = xpcError;
        if (retVal && !xpcError) break;
        HBLogDebug(@TAG "XPC attempt %d failed: %@", attempt + 1, xpcError);
        usleep(200 * 1000);
    }

    gInstallingViaTrollStore = NO;

    if (errorPtr) *errorPtr = lastError;
    return retVal;
}

/* 安装结束后清掉全局状态，避免下一次安装串味 */
static void ResetPackageState(void) {
    gPackageIdentifier = nil;
    gPackagePath = nil;
    gRecordPromise = nil;
}


#import <Foundation/Foundation.h>

struct BlockDescriptor {
    unsigned long reserved;
    unsigned long size;
    void *rest[1];
};

struct Block {
    void *isa;
    int flags;
    int reserved;
    void *invoke;
    struct BlockDescriptor *descriptor;
};

__used
static const char *BlockSig(id blockObj)
{
    struct Block *block = (__bridge struct Block *)blockObj;
    struct BlockDescriptor *descriptor = block->descriptor;

    int copyDisposeFlag = 1 << 25;
    int signatureFlag = 1 << 30;

    assert(block->flags & signatureFlag);

    int index = 0;
    if (block->flags & copyDisposeFlag)
        index += 2;

    return (const char *)descriptor->rest[index];
}

@interface MIInstaller : NSObject

@property (readonly, nonatomic) LSRecordPromise *recordPromise;

@end

@interface MIInstallOptions : NSObject

@property (getter=isDeveloperInstall, nonatomic) bool developerInstall;

@end

%hook MICodeSigningVerifier

+ (id)_validateSignatureAndCopyInfoForURL:(NSURL *)url withOptions:(id)options error:(NSError **)errorPtr {
    id result = %orig(url, options, errorPtr);

    if (errorPtr && *errorPtr) {
        NSError *error = *errorPtr;
        if (![[error description] containsString:@"0xe800801c"] && ![[error description] containsString:@"0xe8008001"]) {
            return result;
        }

        // 待安装的 .app 在 staging 下的确切位置各版本不一致，走三级兜底解析
        NSString *errorDescription = [error description];
        HBLogInfo(@TAG "signature error captured: %@", errorDescription);

        NSString *sourceDirectory = ResolveStagedAppPath(url, errorDescription);
        if (sourceDirectory.length == 0) {
            HBLogError(@TAG "unable to resolve staged app path, url=%@", url);
            return result;
        }
        HBLogInfo(@TAG "staged app resolved: %@", sourceDirectory);

        // Ensure sourceDirectory is valid
        NSString *infoPlistPath = [sourceDirectory stringByAppendingPathComponent:@"Info.plist"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:infoPlistPath]) {
            HBLogError(@TAG "Info.plist not found at path: %@", infoPlistPath);
            return result;
        }

        // Read Info.plist to get package identifier
        NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
        if (!infoPlist) {
            HBLogError(@TAG "Failed to read Info.plist at path: %@", infoPlistPath);
            return result;
        }

        gPackageIdentifier = infoPlist[@"CFBundleIdentifier"];
        if (!gPackageIdentifier) {
            HBLogError(@TAG "CFBundleIdentifier not found in Info.plist");
            return result;
        }

        HBLogInfo(@TAG "package identifier: %@", gPackageIdentifier);
        
        NSString *tempDir = NSTemporaryDirectory();
        NSString *workDir = [tempDir stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        NSString *payloadDir = [workDir stringByAppendingPathComponent:@"Payload"];
        NSString *ipaFileName = [NSString stringWithFormat:@"XcodeAnyTroll_%@.ipa", [[NSUUID UUID] UUIDString]];
        NSString *ipaFilePath = [tempDir stringByAppendingPathComponent:ipaFileName];
        
        // Create directory structure
        NSFileManager *fileManager = [NSFileManager defaultManager];
        [fileManager createDirectoryAtPath:payloadDir withIntermediateDirectories:YES attributes:nil error:nil];
        
        // Get app name (last path component)
        NSString *appName = [sourceDirectory lastPathComponent];
        NSString *destAppPath = [payloadDir stringByAppendingPathComponent:appName];
        
        HBLogDebug(@TAG "Starting to copy app to Payload directory: %@", sourceDirectory);
        
        // Copy the app to Payload directory
        NSError *copyError;
        BOOL copySuccess = [fileManager copyItemAtPath:sourceDirectory toPath:destAppPath error:&copyError];
        
        if (!copySuccess) {
            HBLogError(@TAG "failed to copy app into Payload: %@", copyError);
        } else {
            HBLogInfo(@TAG "app copied into Payload: %@", destAppPath);

            // Create zip file (IPA)
            HBLogDebug(@TAG "Creating IPA file from Payload directory");
            BOOL success = [SSZipArchive createZipFileAtPath:ipaFilePath withContentsOfDirectory:workDir keepParentDirectory:NO compressionLevel:0 password:nil AES:NO progressHandler:nil];
            
            if (success) {
                HBLogInfo(@TAG "ipa created: %@", ipaFilePath);
            } else {
                HBLogError(@TAG "failed to create ipa from %@", workDir);
            }
            
            // Clean up temporary directory
            [fileManager removeItemAtPath:workDir error:nil];

            // Assign the IPA file path to the global variable
            gPackagePath = ipaFilePath;
        }
    }

    return result;
}

%end

%hook MIInstaller

- (BOOL)performInstallationWithError:(NSError **)errorPtr {
    BOOL result = %orig;
    if ([self respondsToSelector:@selector(recordPromise)] && self.recordPromise) {
        gRecordPromise = self.recordPromise;
    }
    return result;
}

%end

%hook MIClientConnection

/* iOS 18.2 */
- (void)_installURL:(NSURL *)url identity:(id)identity targetingDomain:(NSUInteger)domain options:(MIInstallOptions *)options operationType:(NSUInteger)operationType completion:(void (^)(BOOL, NSArray *, id, NSError *))completion {
    HBLogDebug(@TAG "installURL:%@ withOptions:%@", url, options);

    if (![options isKindOfClass:%c(MIInstallOptions)] || ![options respondsToSelector:@selector(isDeveloperInstall)] || ![options isDeveloperInstall]) {
        HBLogDebug(@TAG "Not a developer install, skipping custom handling");
        %orig;
        return;
    }

    void (^replCompletion)(BOOL, NSArray *, id, NSError *) = ^(BOOL succeed, NSArray *appList, id recordPromise, NSError *error) {
        HBLogDebug(@TAG "completion called with recordPromise:%@ error:%@", recordPromise, error);
        if (!completion) {
            return;
        }

        if (gPackagePath && gPackageIdentifier && ([[error description] containsString:@"0xe800801c"] || [[error description] containsString:@"0xe8008001"])) {
            NSError *installError = nil;
            NSDictionary *retVal = InstallPackageViaTrollStore(gPackagePath, gPackageIdentifier, &installError);
            if (!retVal || installError) {
                HBLogError(@TAG "install via trollstore failed: %@ / %@", installError, retVal[@"OutputTail"]);
                completion(succeed, appList, recordPromise, installError);
                ResetPackageState();
                return;
            }

            HBLogInfo(@TAG "trollstore install succeeded: %@", retVal);

            LSApplicationProxy *appProxy = [LSApplicationProxy applicationProxyForIdentifier:gPackageIdentifier];
            LSRecordPromise *promise = [[%c(LSRecordPromise) alloc] initWithRecord:appProxy.correspondingApplicationRecord error:nil];

            /* LSRecordPromise 在部分系统版本上构造不完整，优先用 installd 自己产出的那个 */
            completion(YES, retVal[@"InstalledAppInfoArray"], gRecordPromise ?: promise, nil);
            ResetPackageState();
            return;
        }

        completion(succeed, appList, recordPromise, error);
    };

    %orig(url, identity, domain, options, operationType, replCompletion);
}

/* iOS 16.2 */
- (void)_installURL:(NSURL *)url identity:(id)identity targetingDomain:(NSUInteger)domain options:(MIInstallOptions *)options completion:(void (^)(BOOL, NSArray *, id, NSError *))completion {
    HBLogDebug(@TAG "installURL:%@ withOptions:%@", url, options);

    if (![options isKindOfClass:%c(MIInstallOptions)] || ![options respondsToSelector:@selector(isDeveloperInstall)] || ![options isDeveloperInstall]) {
        HBLogDebug(@TAG "Not a developer install, skipping custom handling");
        %orig;
        return;
    }

    void (^replCompletion)(BOOL, NSArray *, id, NSError *) = ^(BOOL succeed, NSArray *appList, id recordPromise, NSError *error) {
        HBLogDebug(@TAG "completion called with recordPromise:%@ error:%@", recordPromise, error);
        if (!completion) {
            return;
        }

        if (gPackagePath && gPackageIdentifier && ([[error description] containsString:@"0xe800801c"] || [[error description] containsString:@"0xe8008001"])) {
            NSError *installError = nil;
            NSDictionary *retVal = InstallPackageViaTrollStore(gPackagePath, gPackageIdentifier, &installError);
            if (!retVal || installError) {
                HBLogError(@TAG "install via trollstore failed: %@ / %@", installError, retVal[@"OutputTail"]);
                completion(succeed, appList, recordPromise, installError);
                ResetPackageState();
                return;
            }

            HBLogInfo(@TAG "trollstore install succeeded: %@", retVal);

            LSApplicationProxy *appProxy = [LSApplicationProxy applicationProxyForIdentifier:gPackageIdentifier];
            LSRecordPromise *promise = [[%c(LSRecordPromise) alloc] initWithRecord:appProxy.correspondingApplicationRecord error:nil];

            /* LSRecordPromise 在部分系统版本上构造不完整，优先用 installd 自己产出的那个 */
            completion(YES, retVal[@"InstalledAppInfoArray"], gRecordPromise ?: promise, nil);
            ResetPackageState();
            return;
        }

        completion(succeed, appList, recordPromise, error);
    };

    %orig(url, identity, domain, options, replCompletion);
}

/* iOS 15 */
- (void)installURL:(NSURL *)url withOptions:(NSDictionary *)options completion:(void (^)(id, NSError *))completion {
    HBLogDebug(@TAG "installURL:%@ withOptions:%@", url, options);

    if (![options[@"PackageType"] isEqualToString:@"Developer"]) {
        HBLogDebug(@TAG "Not a developer install, skipping custom handling");
        %orig;
        return;
    }

    void (^replCompletion)(NSDictionary *, NSError *) = ^(NSDictionary *userInfo, NSError *error) {
        HBLogDebug(@TAG "completion called with userInfo:%@ error:%@", [userInfo[@"InstalledAppInfoArray"] firstObject], error);
        if (!completion) {
            return;
        }

        if (gPackagePath && gPackageIdentifier && ([[error description] containsString:@"0xe800801c"] || [[error description] containsString:@"0xe8008001"])) {
            NSError *installError = nil;
            NSDictionary *retVal = InstallPackageViaTrollStore(gPackagePath, gPackageIdentifier, &installError);
            if (!retVal || installError) {
                HBLogError(@TAG "install via trollstore failed: %@ / %@", installError, retVal[@"OutputTail"]);
                completion(userInfo, installError);
                ResetPackageState();
                return;
            }

            HBLogInfo(@TAG "trollstore install succeeded: %@", retVal);
            completion(retVal, nil);
            ResetPackageState();
            return;
        }

        completion(userInfo, error);
    };

    %orig(url, options, replCompletion);
}

%end

#if DEBUG
static void TestConnection(void) {
    SandyXpcMessagingCenter *messagingCenter = GetXpcMessagingCenter();

    NSDictionary *msgBody = @{@"name" : [[NSBundle mainBundle] bundleIdentifier] ?: @"Sandy"};
    [messagingCenter sendMessageName:@"OneWayMessage" userInfo:msgBody];

    NSError *error = nil;
    NSDictionary *retVal = nil;

    retVal = [messagingCenter sendMessageAndReceiveReplyName:@"TwoWayMessage"
                                                    userInfo:msgBody
                                                       error:&error];

    if (error) {
        HBLogDebug(@TAG "Error occurred: %@", error);
        return;
    }

    if (!retVal[@"reply"]) {
        HBLogDebug(@TAG "No reply received");
        return;
    }

    HBLogDebug(@TAG "Received reply: %@", retVal[@"reply"]);
}
#endif

%ctor {
    @autoreleasepool {
        /* roothide 下 libSandy 在 jbroot 里，用 jbroot() 解析，不再靠 @loader_path 猜 */
        const char *sandyPath = jbroot("/usr/lib/libsandy.dylib");
        HBLogInfo(@TAG "loading libSandy from %s", sandyPath);

        void *sandyHandle = dlopen(sandyPath, RTLD_LAZY);
        if (!sandyHandle) {
            sandyHandle = dlopen("/usr/lib/libsandy.dylib", RTLD_LAZY);
        }
        if (sandyHandle) {
            int (*__dyn_libSandy_applyProfile)(const char *profileName) =
                (int (*)(const char *))dlsym(sandyHandle, "libSandy_applyProfile");
            if (__dyn_libSandy_applyProfile) {
                int sandyStatus = __dyn_libSandy_applyProfile("XcodeAnyTroll");
                if (sandyStatus == kLibSandyErrorXPCFailure) {
                    HBLogDebug(@TAG "Failed to apply profile");
                } else {
                    HBLogDebug(@TAG "Profile applied");
                }
            }
        }

#if DEBUG
        TestConnection();
#endif
    }
}
