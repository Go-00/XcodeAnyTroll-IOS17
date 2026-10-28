# iOS 17.1 + TrollStoreLite（RootHide）适配包

把 [XcodeAnyTroll](https://github.com/Lessica/XcodeAnyTroll) 和 [XcodeAnyDebug](https://github.com/Lessica/XcodeAnyDebug)
在 **iOS 17.1 / iPhone 15 Pro Max / Dopamine(RootHide) / TrollStoreLite** 这套组合上跑通，
并留下可复现的源码、补丁、deb 与现场证据。

归档日期：2026-10-28

---

## 一、结论

| 环节 | 结果 |
|---|---|
| Xcode 把 app 装进设备（绕过代码签名） | ✅ 打通，两次验证成功 |
| 装进去的 app 在桌面启动 | ✅ 正常（TrollStoreLite 管理的系统级安装） |
| Xcode 连上调试（LLDB attach） | ✅ 打通（修掉 XcodeAnyDebug 在 17.1 上的崩溃后） |
| 重复安装（第二次 Run） | ⚠️ 会撞 Apple 的增量更新校验，见「已知问题」 |

## 二、环境

| 项 | 值 |
|---|---|
| 设备 | iPhone 15 Pro Max `iPhone16,2` / `D84AP` / A17 arm64e |
| 系统 | iOS 17.1 (21B80) |
| 越狱 | Dopamine + roothide（jbroot = `/var/containers/Bundle/Application/.jbroot-DCA85E24412F3151`） |
| 注入 | ellekit 1.2-3，`installd` 带 `DYLD_INSERT_LIBRARIES=/usr/lib/systemhook-*.dylib` |
| 容器 | TrollStoreLite 2.1.1-2（helper 在 `jbroot/Applications/TrollStoreLite.app/trollstorehelper`） |
| 桌面 | Xcode 15.0 / macOS 14.5，DDI 15A240d |

## 三、改了什么（三处根因）

### 1. `trollstorehelper` 找不到 → 安装永远失败

原始 `trollinstalld.mm` 靠 `LSApplicationProxy` + `MCMAppContainer` 去定位 helper。
RootHide 把越狱 app 放在 `jbroot/Applications`，既不在 LaunchServices 正常索引里，
也没有 MCM 容器，查询必然返回 nil，最终拼成 `(null)/trollstorehelper`。

**改法**：`jbroot()` 直拼 + 目录扫描兜底，按命中率排序：

```
jbroot("/Applications/TrollStoreLite.app/trollstorehelper")   ← 本机命中
jbroot("/Applications/TrollStoreLite.app/trollstorehelper_lite")
jbroot("/Applications/TrollStore.app/trollstorehelper")
jbroot("/usr/local/bin/trollstorehelper_lite")
jbroot("/usr/local/bin/trollstorehelper")
→ 扫 jbroot("/Applications") 下所有 *.app
→ 旧的 LS / MCM 逻辑留作最后兜底
```

### 2. 链路黑盒，失败无信息

- `trollinstalld` 的 `posix_spawn` 传 `envp = NULL`，且不重定向输出 → 失败时拿不到任何线索
- entitlements 只有 `platform-application` + `container-required=false`

**改法**：
- spawn 改传 `environ`，stdout/stderr 落到临时文件后回读，退出码原样回传
- 补 `no-sandbox` / `storage.AppBundles` / `storage.AppDataContainers`
- XPC 调用加一次重试 + 递归保护 + 用后清状态
- staged 路径解析加三级兜底（`url.path` → 错误文本正则含 `/private` 前缀 → staging 目录扫描）
- 关键失败点从 `HBLogDebug` 提到 `HBLogError`（release 构建里 Debug 是被编译掉的）
- 新增 `DescribeEnvironment` XPC 消息，一条消息即可打印 helper 解析结果

### 3. `dtdebugproxyd` 被 hook 打成 SIGBUS → 调试连接被掐

`xcode-any-debug` 把 `dtdsSpawnExecutableWithOptions` 的第二个参数当作 ObjC 对象并发消息
（`[options setTargetUserAndGroup:]`）。iOS 17.1 把这个参数改成了 **C 结构体指针**，
且 `DTDSLaunchTargetID` / `DTDSSpawnOptions` 两个类已从 `DTDeviceServices` 移除。
对结构体发 `objc_msgSend` → 拿结构体头 8 字节当类指针 → `lookUpImpOrForward` 踩空 → SIGBUS。

**改法**：iOS 17+ 上完全不注入这段 hook，让 `dtdebugproxyd` 保持原生行为；
iOS 16 及更早保持原逻辑不变。详细反汇编证据见 `docs/why-dtdebugproxyd-crashed.md`。

## 四、目录结构

```
iOS17-TrollStoreLite-port/
├── README.md                        ← 本文
├── src/
│   ├── XcodeAnyTroll/               ← 改好的主包源码（1.1.4）
│   │   ├── XcodeAnyTroll.xm
│   │   ├── trollinstalld.mm
│   │   ├── entitlements.plist
│   │   ├── build.sh
│   │   └── devkit/syntax-check.sh   ← 语法闸门（无需 iOS SDK 即可跑）
│   └── XcodeAnyDebug/               ← 改好的调试插件源码（1.0.1）
│       └── main.x                   ← 加了 iOS 17 版本闸门
├── dist/                            ← 直接装机用
│   ├── com.82flex.xcodeanytroll_1.1.4_iphoneos-arm64e.deb
│   ├── xcode-any-debug_1.0.1_iphoneos-arm64e.deb
│   ├── com.82flex.libsandyxpc_1.1.2_iphoneos-arm64e.deb
│   └── legacy-crashing/             ← 会崩的旧版，仅存档
├── patches/                         ← 相对上游的 unified diff
│   ├── 0001-xcodeanytroll-trollstorelite-roothide.patch
│   └── 0002-xcodeanydebug-ios17-abi-gate.patch
└── docs/
    └── why-dtdebugproxyd-crashed.md ← 反汇编级根因分析
```

## 五、怎么构建

```bash
# 1. roothide 版 theos（提供 roothide.h / jbroot()）
git clone --recursive https://github.com/roothide/theos.git ~/theos-roothide

# 2. iOS SDK（theos/sdks 的 release 资产是 .tar.xz）
cd ~/theos-roothide/sdks
BASE=https://github.com/theos/sdks/releases/download/master-146e41f
for v in 16.5 14.5; do curl -fLO "$BASE/iPhoneOS$v.sdk.tar.xz" && tar -xJf "iPhoneOS$v.sdk.tar.xz"; done

# 3. 依赖库 libSandyXpc（会 stage 进 theos）
git clone https://github.com/Lessica/SandyXpc.git ~/SandyXpc && cd ~/SandyXpc
THEOS=~/theos-roothide THEOS_PACKAGE_SCHEME=roothide make stage

# 4. 出包
cd src/XcodeAnyTroll && THEOS=~/theos-roothide THEOS_PACKAGE_SCHEME=roothide make package
cd ../XcodeAnyDebug && THEOS=~/theos-roothide THEOS_PACKAGE_SCHEME=roothide make package
```

> 注意：本机没有 `gmake`，用 `make`。三个 scheme 全部用 roothide theos 构建，
> 否则源码里的 `jbroot()` 会退化成恒等映射，定位不到 jbroot 内文件。

## 六、怎么装

```bash
# 顺序：依赖 → 调试插件 → 主包
scp -P 2222 dist/*.deb root@127.0.0.1:/var/mobile/Documents/
ssh -p 2222 root@127.0.0.1
cd /var/mobile/Documents
dpkg -i com.82flex.libsandyxpc_*.deb xcode-any-debug_1.0.1_*.deb com.82flex.xcodeanytroll_*.deb
```

`postinst` 会自动加载 launchd 服务并 `killall installd`。

Xcode 工程侧仍需按下述配置（见上游 README）：
`CODE_SIGNING_ALLOWED=NO`、`CODE_SIGN_ENTITLEMENTS` 指向 entitlements、
Run Script 里 `ldid -S${CODE_SIGN_ENTITLEMENTS} ${CODESIGNING_FOLDER_PATH}`。

## 七、验收证据（2026-10-28 实测）

```
# helper 定位成功、daemon 存活
launchctl list | grep 82flex        → 6713  0  com.82flex.trollinstalld

# app 确实由 TrollStoreLite 装进去的
/var/containers/Bundle/Application/EA634C88-…/_TrollStoreLite    ← 标记文件存在

# debug 链路恢复
10:14:14 dtdebugproxyd(XcodeAnyDebug.dylib)[7340] [XcodeAnyDebug] isDtds=YES
10:14:14 dtdebugproxyd(XcodeAnyDebug.dylib)[7340] [XcodeAnyDebug] iOS 17+ detected:
         skipping dtds hook (ABI changed to C struct), dtdebugproxyd left untouched

# 崩溃报告时间线：最后一次是 10:04:53，修复后无新增
```

## 八、已知问题

**Xcode IDE 点 Run 会撞增量更新校验（已定论：不是我们的代码导致，也没有开关可关）**

```
Could not hardlink copy …/Kexploit.app … Compare of info plist hash failed
MIInstallerErrorDomain 8 / MIInstallerDeltaErrorDomain 1
```

机制（三步实测确认）：

1. Xcode 只要发现"同 bundle id 的 app 已安装"，就**只发差分包**，与设备上的版本无关
2. 差分清单里记的是 Xcode 自己构建产物的 `Info.plist` 哈希与版本
3. 设备上那份是 TrollStoreLite 装的，TrollStore 在安装前改写过 `Info.plist`
   （加了 `SBAppUsesLocalNotifications`、剥掉了系统 URL scheme）→ 哈希必然不符 → 中止

**被证伪的方案（别再试）**：把设备上那份的 `CFBundleVersion` 改掉，指望 Xcode 因此发全量包。
实测报错变成 `Got manifest for version "1 1.0", but expected version "1-tsl 1.0"`，
说明判据不是版本，而是"同 id 是否已安装"。改版本只会让失败点提前。

**实测可用的两条工作流**

A. 命令行装（全量，一次成功，走的就是本补丁修好的链路）

```bash
xcrun devicectl device install app --device <UDID>   ~/Library/Developer/Xcode/DerivedData/<proj>/Build/Products/Debug-iphoneos/<App>.app
# 然后 Xcode: Debug → Attach to Process → <App>
# 或 scheme 的 Launch 设为 "Wait for executable to be launched"，装完手点桌面图标
```

B. 每次 Run 前删掉 app，逼 Xcode 走全量

```bash
ssh -p 2222 root@127.0.0.1 'trollstorehelper uninstall <bundle id>'
```

补充：`xcrun devicectl device install app` 这条路同时验证了整条链路——
装完后容器里 `_TrollStoreLite` 标记在、`Info.plist` 被 TrollStore 改写，说明
"签名失败 → hook → TrollStoreLite 安装"确实跑通了。

## 九、回滚

```bash
dpkg -r com.82flex.xcodeanytroll xcode-any-debug com.82flex.libsandyxpc
killall -9 installd
```

或从 `dist/legacy-crashing/xcode-any-debug_1.0_*.deb` 装回会崩的旧版（不建议）。

## 十、致谢

上游作者 Lessica（XcodeAnyTroll / XcodeAnyDebug / SandyXpc）、opa334（libSandy / TrollStore）、
roothide 团队（theos 与 ABI 工具链）。
