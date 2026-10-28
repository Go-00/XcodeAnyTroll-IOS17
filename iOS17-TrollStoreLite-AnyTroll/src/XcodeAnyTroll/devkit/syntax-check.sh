#!/bin/bash
# 在 macOS 上不做真机链接、只做语法检查：
#   - logos.pl 预处理 .xm（校验 %hook / %orig / %c 用法）
#   - clang -fsyntax-only 过一遍 tweak 与 daemon
# 桩头文件用于替代 iOS SDK 里缺失的部分（UIKit / CydiaSubstrate / roothide.h / SandyXpc）。
# 真正的编译、链接、签名仍然是 `./build.sh`（需要 roothide theos + iPhoneOS SDK）。

set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STUBS="$(mktemp -d)"
trap 'rm -rf "$STUBS"' EXIT

SDK="$(xcrun --show-sdk-path)"
THEOS_INC="${THEOS_INC:-/opt/theos/vendor/include}"

mkdir -p "$STUBS/UIKit" "$STUBS/CydiaSubstrate" "$STUBS/SSZipArchive"
printf '#import <Foundation/Foundation.h>\n' > "$STUBS/UIKit/UIKit.h"
printf '#ifndef ROOTHIDE_STUB_H\n#define ROOTHIDE_STUB_H\n#ifdef __cplusplus\nextern "C" {\n#endif\nconst char *jbroot(const char *path);\n#ifdef __cplusplus\n}\n#endif\n#endif\n' > "$STUBS/roothide.h"
printf '#ifndef STUB_SUBSTRATE_H\n#define STUB_SUBSTRATE_H\n#import <objc/runtime.h>\nstatic inline void MSHookMessageEx(Class c, SEL s, IMP i, IMP *r) {}\n#endif\n' > "$STUBS/CydiaSubstrate/CydiaSubstrate.h"
cp "$ROOT"/Frameworks/SSZipArchive.framework/Headers/SSZipArchive.h \
   "$ROOT"/Frameworks/SSZipArchive.framework/Headers/SSZipCommon.h "$STUBS/SSZipArchive/"

# SandyXpc 的头文件由它的包提供，这里临时取一份
SANDYXPC="$(mktemp -d)"
trap 'rm -rf "$STUBS" "$SANDYXPC"' EXIT
git clone --depth 1 -q https://github.com/Lessica/SandyXpc.git "$SANDYXPC"
cp "$SANDYXPC"/libSandyXpc.h "$SANDYXPC"/SandyXpc*.h "$STUBS/"

CFLAGS=(-fsyntax-only -fobjc-arc -x objective-c++ -isysroot "$SDK"
        -I"$STUBS" -I"$ROOT/Headers" -I"$ROOT/Frameworks" -I"$THEOS_INC")

check() {
  local label="$1" source="$2"
  printf '==> %s\n' "$label"
  if clang++ "${CFLAGS[@]}" -DTHEOS_INSTANCE_NAME='"XcodeAnyTroll"' -DDEBUG=0 "$source"; then
    printf '    OK\n'
  else
    printf '    FAILED\n' >&2
    exit 1
  fi
}

LOGOS_OUT="$STUBS/XcodeAnyTroll.mm"
perl /opt/theos/bin/logos.pl "$ROOT/XcodeAnyTroll.xm" > "$LOGOS_OUT"

check "tweak (roothide 分支)"      "$LOGOS_OUT"
check "daemon (roothide 分支)"     "$ROOT/trollinstalld.mm"

# 去掉 roothide.h 再验一次 rootful/rootless 分支
rm -f "$STUBS/roothide.h"
perl /opt/theos/bin/logos.pl "$ROOT/XcodeAnyTroll.xm" > "$LOGOS_OUT"
check "tweak (rootful/rootless 分支)"  "$LOGOS_OUT"
check "daemon (rootful/rootless 分支)" "$ROOT/trollinstalld.mm"

echo "全部通过。"
