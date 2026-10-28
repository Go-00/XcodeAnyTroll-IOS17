#!/bin/sh
# XcodeAnyTroll 诊断脚本 — 在越狱设备上以 root 运行，输出一份环境快照
# 用法: ssh root@DEVICE 'sh -s' < devkit/diag-device.sh > diag.txt
#      或 NewTerm3: sh /var/.../diag-device.sh

line() { echo; echo "===== $* ====="; }

line "0. 身份"
id
uname -a
echo "OS: $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
echo "MODEL: $(sysctl -n hw.model 2>/dev/null)  CPU: $(sysctl -n hw.ncpu 2>/dev/null)"

line "1. 越狱形态 / jbroot"
ls -d /var/jb 2>/dev/null && echo "ROOTLESS(/var/jb) = yes"
for d in /var/containers/Bundle/Application/.jbroot-*; do
    [ -d "$d" ] && echo "ROOTHIDE jbroot = $d"
done
ls -d /var/lib/dpkg 2>/dev/null
echo "launchctl(getuid=$(id -u)):"
launchctl list 2>/dev/null | grep -iE "jailbreakd|dopamine|roothide|ellekit|troll|82flex|sandy" || echo "  (launchctl list 需要 root)"

line "2. 越狱 / 依赖包版本"
DPKG_DB=/var/lib/dpkg/status
[ -f /var/jb/var/lib/dpkg/status ] && DPKG_DB=/var/jb/var/lib/dpkg/status
for j in /var/containers/Bundle/Application/.jbroot-*/var/lib/dpkg/status; do [ -f "$j" ] && DPKG_DB="$j"; done
echo "status db: $DPKG_DB"
awk '/^Package:/{p=$2} /^Version:/{print p" "$2}' "$DPKG_DB" 2>/dev/null | grep -iE "dopamine|roothide|bootstrap|ellekit|substrate|troll|ldid|sandy|apps?sync|xcode" 

line "3. TrollStore / TrollStoreLite"
for p in /Applications /var/jb/Applications /var/containers/Bundle/Application/*/ /var/containers/Bundle/Application/.jbroot-*/Applications; do
    for a in "$p"/*Troll*.app; do [ -d "$a" ] && echo "APP: $a"; done 2>/dev/null
done
echo "--- 找 helper 二进制"
find / -maxdepth 7 \( -name 'trollstorehelper' -o -name 'trollstorehelper_lite' \) -type f 2>/dev/null
echo "--- /usr/local/bin"
ls -l /var/jb/usr/local/bin /usr/local/bin 2>/dev/null
for d in /var/containers/Bundle/Application/.jbroot-*/usr/local/bin; do ls -l "$d" 2>/dev/null; done
echo "--- ldid"
for l in /var/jb/usr/bin/ldid /usr/bin/ldid; do [ -x "$l" ] && { echo "$l:"; "$l" -v 2>&1 | head -4; }; done

line "4. libSandy"
find / -maxdepth 6 -name 'libsandy*' 2>/dev/null | head -20
echo "--- profiles"
for d in /Library/libSandy /var/jb/Library/libSandy /var/containers/Bundle/Application/.jbroot-*/Library/libSandy; do ls -l "$d" 2>/dev/null; done

line "5. 本项目已安装情况"
for d in /Library/LaunchDaemons /var/jb/Library/LaunchDaemons /var/containers/Bundle/Application/.jbroot-*/Library/LaunchDaemons; do ls -l "$d"/com.82flex.* 2>/dev/null; done
find / -maxdepth 7 -name 'XcodeAnyTroll.dylib' 2>/dev/null
find / -maxdepth 7 -name 'trollinstalld' 2>/dev/null
echo "--- 进程"
ps ax 2>/dev/null | grep -iE "trollinstalld|installd" | grep -v grep

line "6. 最近的安装 / 签名错误 (syslog 尾)"
( log show --last 10m --predicate 'process == "installd" OR process == "appinstalld"' 2>/dev/null \
  || cat /var/log/syslog 2>/dev/null ) | grep -iE "XcodeAnyTroll|0xe8008|signature|TrollInstaller|installURL" | tail -40

line "7. 结束"
echo "把上面全部内容贴回来即可"
