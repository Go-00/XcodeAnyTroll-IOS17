#import <Foundation/Foundation.h>
#import <HBLog.h>
#import <errno.h>
#import <fcntl.h>
#import <spawn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/wait.h>

#import <libSandyXpc.h>

#import "LSApplicationProxy.h"
#import "MCMContainer.h"

/*
 * roothide 下所有越狱文件都活在一个随机命名的 jbroot 里，
 * 静态路径必须经过 jbroot() 解析：/Applications/TrollStoreLite.app/... 这种
 * 字面量在 roothide 进程里指向的是 rootfs，永远找不到。
 * 用 roothide/theos 构建时该头与函数可用；普通 theos 下退化成恒等映射。
 */
#if __has_include(<roothide.h>)
#import <roothide.h>
#define XAT_HAS_ROOTHIDE 1
#else
#define XAT_HAS_ROOTHIDE 0
#endif

#define TAG "TrollInstallerService : "

static NSString *JB(NSString *path) {
#if XAT_HAS_ROOTHIDE
    const char *resolved = jbroot(path.fileSystemRepresentation);
    return resolved ? [NSString stringWithUTF8String:resolved] : path;
#else
    return path;
#endif
}

static BOOL IsExecutable(NSString *path) {
    if (path.length == 0) return NO;
    return access(path.fileSystemRepresentation, X_OK) == 0;
}

static NSString *HelperInBundle(NSString *bundlePath) {
    if (bundlePath.length == 0) return nil;
    for (NSString *name in @[ @"trollstorehelper", @"trollstorehelper_lite" ]) {
        NSString *candidate = [bundlePath stringByAppendingPathComponent:name];
        if (IsExecutable(candidate)) return candidate;
    }
    return nil;
}

/*
 * 第一优先：jbroot 内的确定路径。
 * TrollStoreLite (roothide) 把 helper 放在 app 包里、且改名成了 trollstorehelper；
 * 上游 Makefile 的 trollstorehelper_lite + /usr/local/bin 是 rootful 布局。
 */
static NSString *HelperByKnownPaths(void) {
    NSArray<NSString *> *candidates = @[
        JB(@"/Applications/TrollStoreLite.app/trollstorehelper"),
        JB(@"/Applications/TrollStoreLite.app/trollstorehelper_lite"),
        JB(@"/Applications/TrollStore.app/trollstorehelper"),
        JB(@"/usr/local/bin/trollstorehelper_lite"),
        JB(@"/usr/local/bin/trollstorehelper"),
        @"/usr/local/bin/trollstorehelper_lite",
        @"/usr/local/bin/trollstorehelper",
    ];
    for (NSString *candidate in candidates) {
        if (IsExecutable(candidate)) return candidate;
    }
    return nil;
}

/* 第二优先：目录扫描，覆盖 app 被改名或装在别处的情况 */
static NSString *HelperByBundles(void) {
    NSArray<NSString *> *roots = @[
        JB(@"/Applications"),
        @"/Applications",
        @"/var/containers/Bundle/Application",
    ];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *root in roots) {
        NSArray<NSString *> *items = [fileManager contentsOfDirectoryAtPath:root error:nil];
        for (NSString *item in items) {
            if (![[item pathExtension] isEqualToString:@"app"]) continue;
            NSString *found = HelperInBundle([root stringByAppendingPathComponent:item]);
            if (found) return found;
        }
    }
    return nil;
}

/* 第三优先：旧逻辑，LaunchServices / MobileContainerManager 兜底 */
static NSString *HelperByLegacyLookup(void) {
    NSArray<NSString *> *identifiers = @[ @"com.opa334.TrollStoreLite", @"com.opa334.TrollStore" ];

    for (NSString *identifier in identifiers) {
        LSApplicationProxy *appProxy = [LSApplicationProxy applicationProxyForIdentifier:identifier];
        NSString *found = HelperInBundle([appProxy.bundleURL path]);
        if (found) return found;
    }

    for (NSString *identifier in identifiers) {
        NSString *bundleContainerPath =
            [[[MCMAppContainer containerWithIdentifier:identifier error:nil] url] path];
        NSArray<NSString *> *items =
            [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bundleContainerPath error:nil];
        for (NSString *item in items) {
            if (![[item pathExtension] isEqualToString:@"app"]) continue;
            NSString *found = HelperInBundle([bundleContainerPath stringByAppendingPathComponent:item]);
            if (found) return found;
        }
    }

    return nil;
}

static NSString *ResolvedHelperPath(void) {
    static NSString *cached = nil;

    if (cached && IsExecutable(cached)) return cached;

    NSString *found = HelperByKnownPaths();
    if (!found) found = HelperByBundles();
    if (!found) found = HelperByLegacyLookup();

    if (found) {
        cached = found;
        HBLogInfo(@TAG "resolved trollstore helper: %@", found);
    } else {
        cached = nil;
        HBLogError(@TAG "unable to locate trollstore helper in any known location");
    }
    return found;
}

static NSString *TailOfFile(NSString *path, NSUInteger maxLength) {
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text) return @"";
    if (text.length <= maxLength) return text;
    return [text substringFromIndex:text.length - maxLength];
}

/*
 * 跑 helper，并把它的 stdout/stderr 落到临时文件再回读。
 * 原来的实现用 posix_spawn(..., NULL) 且不重定向，失败时什么线索都留不下。
 * 返回 helper 的退出码；负值表示启动/等待失败。
 */
static int RunHelper(NSString *helperPath, NSArray<NSString *> *arguments, NSString **outputTail) {
    NSString *logPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"trollinstalld-%@.log", [NSUUID UUID].UUIDString]];
    [[NSFileManager defaultManager] createFileAtPath:logPath contents:[NSData data] attributes:nil];

    posix_spawn_file_actions_t fileActions;
    posix_spawn_file_actions_init(&fileActions);
    posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, logPath.fileSystemRepresentation,
                                    O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, logPath.fileSystemRepresentation,
                                    O_WRONLY | O_CREAT | O_TRUNC, 0644);

    NSMutableArray<NSString *> *fullArguments = [NSMutableArray arrayWithObject:helperPath];
    [fullArguments addObjectsFromArray:arguments];

    char **argv = (char **)calloc(fullArguments.count + 1, sizeof(char *));
    for (NSUInteger idx = 0; idx < fullArguments.count; idx++) {
        argv[idx] = strdup(fullArguments[idx].fileSystemRepresentation);
    }
    argv[fullArguments.count] = NULL;

    /* helper 需要 PATH 才能找到 jbroot 里的 ldid 等工具 */
    extern char **environ;
    pid_t pid = 0;
    int spawnStatus = posix_spawn(&pid, helperPath.fileSystemRepresentation, &fileActions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fileActions);

    for (NSUInteger idx = 0; idx < fullArguments.count; idx++) {
        free(argv[idx]);
    }
    free(argv);

    int result = -1;
    if (spawnStatus != 0) {
        HBLogError(@TAG "posix_spawn failed for %@: %s", helperPath, strerror(spawnStatus));
        result = -spawnStatus;
    } else {
        int status = 0;
        pid_t waited = -1;
        while ((waited = waitpid(pid, &status, 0)) < 0) {
            if (errno == EINTR) continue;
            HBLogError(@TAG "waitpid failed: %s", strerror(errno));
            break;
        }
        if (waited > 0) {
            result = WIFEXITED(status) ? WEXITSTATUS(status) : -(WTERMSIG(status));
        }
    }

    NSString *tail = TailOfFile(logPath, 3000);
    if (outputTail) *outputTail = tail;
    HBLogInfo(@TAG "helper %@ exited with %d", helperPath.lastPathComponent, result);

    if (tail.length > 0) {
        HBLogInfo(@TAG "helper output:\n%@", tail);
    }
    [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];

    return result;
}

@interface TrollInstallerService : NSObject
- (void)onOneWayMessage:(NSString *)message userInfo:(NSDictionary *)userInfo;
- (NSDictionary *)onTwoWayMessage:(NSString *)message userInfo:(NSDictionary *)userInfo;
- (NSDictionary *)onRemoteInstallPackage:(NSString *)message userInfo:(NSDictionary *)userInfo;
- (NSDictionary *)onDescribeEnvironment:(NSString *)message userInfo:(NSDictionary *)userInfo;
@end

@implementation TrollInstallerService

- (void)onOneWayMessage:(NSString *)message userInfo:(NSDictionary *)userInfo {
    HBLogDebug(@"Received one-way message %@ from %@", message, userInfo[@"name"]);
}

- (NSDictionary *)onTwoWayMessage:(NSString *)message userInfo:(NSDictionary *)userInfo {
    HBLogDebug(@"Received two-way message %@ from %@", message, userInfo[@"name"]);
    return @{
        @"reply" : [NSString
            stringWithFormat:@"Hello, %@! I am %@.", userInfo[@"name"], [[NSProcessInfo processInfo] processName]]
    };
}

/* 排障用：一行 XPC 就能看到 helper 解析结果，不用重装包 */
- (NSDictionary *)onDescribeEnvironment:(NSString *)message userInfo:(NSDictionary *)userInfo {
    NSString *helper = ResolvedHelperPath();
    NSString *ldid = JB(@"/usr/bin/ldid");
    return @{
        @"HelperPath" : helper ?: @"(none)",
        @"LdidPath" : ldid,
        @"LdidExists" : @(IsExecutable(ldid)),
        @"Uid" : @(getuid()),
    };
}

- (NSDictionary *)onRemoteInstallPackage:(NSString *)message userInfo:(NSDictionary *)userInfo {
    NSString *packagePath = userInfo[@"PackagePath"];
    HBLogInfo(@TAG "received install request for package: %@", packagePath);

    if (packagePath.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:packagePath]) {
        HBLogError(@TAG "invalid package path: %@", packagePath);
        return @{@"error" : @"Invalid package path."};
    }

    NSString *helperPath = ResolvedHelperPath();
    if (!helperPath) {
        return @{@"error" : @"TrollStore helper binary not found"};
    }

    /* 与上游 RootHelper/main.m 的 install 子命令语法一致：install [force] <ipa> */
    NSString *outputTail = nil;
    int exitStatus = RunHelper(helperPath, @[ @"install", @"force", packagePath ], &outputTail);

    if (exitStatus != 0) {
        HBLogError(@TAG "installation failed with exit code %d", exitStatus);
        /* 失败时保留 ipa，便于从 /tmp 取出复现 */
        return @{
            @"error" : [NSString stringWithFormat:@"Installation failed with exit code: %d", exitStatus],
            @"OutputTail" : outputTail ?: @"",
        };
    }

    [[NSFileManager defaultManager] removeItemAtPath:packagePath error:nil];

    /*
     * 客户端只关心成功与否，不读这里的 app 信息，
     * 真实安装结果由 installd 那侧的 LSApplicationProxy 重新构造。
     */
    return @{@"InstalledAppInfoArray" : @[ @{} ]};
}

@end

int main(int argc, const char *argv[]) {

    @autoreleasepool {
        HBLogInfo(@TAG "daemon starting, roothide=%d", XAT_HAS_ROOTHIDE);
        HBLogInfo(@TAG "jbroot = %@", JB(@"/"));
        HBLogInfo(@TAG "helper = %@", ResolvedHelperPath() ?: @"(none)");

        static TrollInstallerService *server;
        server = [[TrollInstallerService alloc] init];

        static SandyXpcMessagingCenter *messagingCenter;
        messagingCenter = [SandyXpcMessagingCenter centerNamed:@"com.82flex.xcodeanytroll"];

        [messagingCenter registerForMessageName:@"OneWayMessage"
                                         target:server
                                       selector:@selector(onOneWayMessage:userInfo:)];

        [messagingCenter registerForMessageName:@"TwoWayMessage"
                                         target:server
                                       selector:@selector(onTwoWayMessage:userInfo:)];

        [messagingCenter registerForMessageName:@"DescribeEnvironment"
                                         target:server
                                       selector:@selector(onDescribeEnvironment:userInfo:)];

        [messagingCenter registerForMessageName:@"InstallPackage"
                                         target:server
                                       selector:@selector(onRemoteInstallPackage:userInfo:)];

        [messagingCenter runServerOnCurrentThread];

        HBLogDebug(@TAG "Daemon is running...");
        CFRunLoopRun();
    }

    return EXIT_SUCCESS;
}
