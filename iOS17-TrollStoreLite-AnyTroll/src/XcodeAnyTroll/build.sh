#!/bin/bash

set -e

# 三个 scheme 全部用 roothide/theos 构建：
# 它的 SDK 提供 roothide.h / jbroot()，并对 rootful、rootless 输出保持兼容。
# 用普通 theos 构建时源码里的 jbroot() 会退化成恒等映射，无法定位 jbroot 内文件。
THEOS_DIR="${THEOS_DIR:-$HOME/theos-roothide}"

if [ ! -d "$THEOS_DIR" ]; then
  echo "缺少 roothide theos: $THEOS_DIR" >&2
  echo "安装: git clone --recursive https://github.com/roothide/theos.git ~/theos-roothide" >&2
  exit 1
fi

# macOS 上没有 gmake，退回到 make
MAKE_BIN="${MAKE_BIN:-$(command -v gmake || command -v make)}"

# 只出需要的 scheme：SCHEMES="roothide" ./build.sh
SCHEMES="${SCHEMES:-rootful rootless roothide}"

for scheme in $SCHEMES; do
  if [ "$scheme" = "rootful" ]; then
    SCHEME_ARG=""
  else
    SCHEME_ARG="$scheme"
  fi
  echo "==> building scheme: ${SCHEME_ARG:-rootful}"
  FINALPACKAGE=1 THEOS="$THEOS_DIR" THEOS_PACKAGE_SCHEME="$SCHEME_ARG" "$MAKE_BIN" clean package
done

echo
echo "==> 产物:"
ls -1 "$(cd "$(dirname "$0")" && pwd)"/packages/*.deb 2>/dev/null || echo "  (无)"
