# XcodeAnyTroll for iOS 17 (RootHide + TrollStoreLite) 目前只测试了RootHide版

在 **iOS 17 / RootHide 越狱 / TrollStoreLite** 上，用 Xcode 直接编译、安装、断点调试
未签名 app —— 不需要开发者证书，也不依赖 TrollStore 的 CoreTrust 漏洞。

> 基于 [XcodeAnyTroll](https://github.com/Lessica/XcodeAnyTroll) 与
> [XcodeAnyDebug](https://github.com/Lessica/XcodeAnyDebug) 移植到 iOS 17.x + RootHide。

## 特性

- Xcode 安装未签名 app，任意 entitlements，不受证书限制
- 装进去的 app 正常启动、正常显示图标
- Xcode 断点调试、LLDB 附加，无需额外配置
- 全链路日志：helper 定位、IPA 打包、XPC 转发、helper 退出码全都有迹可循

验证环境：iPhone 15 Pro Max（A17）、iOS 17.1 (21B80)、Dopamine + roothide、TrollStoreLite 2.1.1。

## 相对上游的改动

1. **`trollstorehelper` 定位** —— 上游通过 LaunchServices 查询越狱 app，在 RootHide 下拿不到结果。
   改为 `jbroot()` 直拼 + 目录扫描兜底，兼容 RootHide / rootless / rootful 三种布局。
2. **iOS 17 的 `dtdebugproxyd` ABI 适配** —— iOS 17 把 `dtdsSpawnExecutableWithOptions`
   的第二个参数从 ObjC 对象改成了 C 结构体指针，上游的 hook 会因此崩溃。17+ 上自动跳过该 hook，
   低版本保持原逻辑。反汇编依据见 `docs/why-dtdebugproxyd-crashed.md`。
3. **可诊断性** —— 补齐 daemon entitlements，捕获 helper 的 stdout/stderr 与退出码，
   XPC 调用加重试，staging 路径三级兜底，关键失败点提升为 `HBLogError`。

## 安装

```bash
# 依赖 → 调试插件 → 主包
dpkg -i com.82flex.libsandyxpc_*.deb xcode-any-debug_*.deb com.82flex.xcodeanytroll_*.deb
```

Xcode 工程侧：

- `CODE_SIGNING_ALLOWED = NO`
- `CODE_SIGN_ENTITLEMENTS` 指向你的 entitlements
- 加一个 Run Script：

```bash
PATH="/opt/homebrew/bin:$PATH"
if [ "$CODE_SIGNING_ALLOWED" = "NO" ]; then
  ldid -S${CODE_SIGN_ENTITLEMENTS} ${CODESIGNING_FOLDER_PATH}
fi
```

## 用法

推荐这样跑（安装用命令行，调试用 Xcode 附加）：

```bash
xcrun devicectl device install app --device <UDID> \
  ~/Library/Developer/Xcode/DerivedData/<proj>/Build/Products/Debug-iphoneos/<App>.app
```

然后在 Xcode 里 `Debug → Attach to Process → <App>`。

也可以在 scheme 的 Run 里把 Launch 设为 **Wait for executable to be launched**，
装完之后手点手机桌面图标，Xcode 会自动附加。

## 构建

需要 [roothide/theos](https://github.com/roothide/theos)（提供 `roothide.h` / `jbroot()`）、
iPhoneOS 16.5 SDK，以及 [libSandyXpc](https://github.com/Lessica/SandyXpc)。

```bash
git clone --recursive https://github.com/roothide/theos.git ~/theos-roothide
cd ~/theos-roothide/sdks
BASE=https://github.com/theos/sdks/releases/download/master-146e41f
for v in 16.5 14.5; do curl -fLO "$BASE/iPhoneOS$v.sdk.tar.xz" && tar -xJf "iPhoneOS$v.sdk.tar.xz"; done

git clone https://github.com/Lessica/SandyXpc.git ~/SandyXpc
cd ~/SandyXpc && THEOS=~/theos-roothide THEOS_PACKAGE_SCHEME=roothide make stage

cd XcodeAnyTroll && THEOS=~/theos-roothide THEOS_PACKAGE_SCHEME=roothide make package
cd XcodeAnyDebug && THEOS=~/theos-roothide THEOS_PACKAGE_SCHEME=roothide make package
```

## 致谢

[Lessica](https://github.com/Lessica)（XcodeAnyTroll / XcodeAnyDebug / SandyXpc）、
[opa334](https://github.com/opa334)（libSandy / TrollStore）、
[roothide](https://github.com/roothide)（theos / ABI 工具链）。
