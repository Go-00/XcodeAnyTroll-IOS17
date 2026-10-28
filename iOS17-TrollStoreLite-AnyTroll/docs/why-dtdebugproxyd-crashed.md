# 为什么 `dtdebugproxyd` 会 SIGBUS —— 反汇编级根因

崩溃报告：`dtdebugproxyd-2026-10-28-100453.ips`（iOS 17.1 / 21B80 / iPhone16,2）

## 1. 崩溃现场

```
exception  : EXC_BAD_ACCESS (SIGBUS)
subtype    : KERN_PROTECTION_FAILURE at 0x0000000500000000
termination: Bus error: 10

队列 com.apple.main-thread（callee 在下）：
  lookUpImpOrForward
  _objc_msgSend_uncached
  XcodeAnyDebug.dylib + 17024                     ← 注入的 tweak
  dtdsSpawnExecutableWithFileActions              ← DTDeviceServices
  -[DebugServerConnectionHandler initWithDebugServerPath:target_ids:]
  +[DebugServerConnectionHandler debugServerConnectionWithPath:root:]
  __main_block_invoke → dtdebugproxyd main
```

镜像索引核对：

```
image[1]  XcodeAnyDebug.dylib   /private/var/…/.jbroot-DCA85E24412F3151/usr/lib/TweakInject/XcodeAnyDebug.dylib
image[7]  DTDeviceServices      /System/Developer/Library/Frameworks/DTDeviceServices.framework/DTDeviceServices
image[17] libobjc.A.dylib
```

因此崩溃点在 tweak 里那一句 `objc_msgSend` —— 对应源码 `main.x` 的
`[options setTargetUserAndGroup:target]`。

## 2. 为什么这一句会崩

原始 hook 声明（`main.x`，第 50 行）：

```objc
%hookf(Boolean, _dtdsSpawnExecutableWithOptions,
       const char *path, DTDSSpawnOptions *options, pid_t *pid, NSError **error)
```

假设第 2 个参数是 **ObjC 对象**，于是对它发消息。

### iOS 17.1 的调用点（DTDeviceServices 反汇编）

```asm
_dtdsSpawnExecutableWithFileActions:
    sub   sp, sp, #0x40
    movi.16b v0, #0x0
    stur  q0, [sp, #0x8]
    stur  q0, [sp, #0x18]
    stp   x5, xzr, [sp, #0x20]      ; 把参数打包到栈上的结构体
    str   x1, [sp]                  ;   [+0x00] = x1
    strb  w2, [sp, #0x8]            ;   [+0x08] = (bool)w2
    stp   x3, x4, [sp, #0x10]       ;   [+0x10] = x3, [+0x18] = x4
    mov   x1, sp                    ; ← 第 2 个参数 = 结构体指针
    mov   x2, x6
    mov   x3, x7
    bl    _dtdsSpawnExecutableWithOptions
```

### 被调函数自己的读法

```asm
_dtdsSpawnExecutableWithOptions:
    mov   x21, x3
    mov   x28, x2
    mov   x27, x1                   ; x1 当结构体基址
    mov   x23, x0                   ; x0 = path
    …
    ldr   x26, [x1]                 ; [+0x00] 取一个对象
    ldrb  w20, [x1, #0x8]           ; [+0x08] bool
    ldr   x8,  [x1, #0x10]
    bl    _objc_retain_x8
    ldr   x8,  [x27, #0x18]         ; [+0x18] 另一个对象
    bl    _objc_retain_x8
```

结论：**第 2 个参数在 17.1 上是 C 结构体指针**，内部含两个会被 `objc_retain` 的对象字段。

tweak 却把它当对象发消息 → `objc_msgSend` 从结构体头 8 字节取 "isa"（是个普通指针），
`lookUpImpOrForward` 顺着假 isa 读 `0x5000000000` → 不可读 → SIGBUS。

## 3. 附加证据：相关类已被移除

```
$ strings -a DTDeviceServices | grep -E "DTDSLaunchTargetID|DTDSSpawnOptions"
（无输出）

$ nm -gU -arch arm64 DTDeviceServices | grep -i "DTDS"
_OBJC_CLASS_$_DTDSCPUType        ← 只剩这个
_dtdsSpawnExecutable
_dtdsSpawnExecutableWithFileActions
_dtdsSpawnExecutableWithOptions
_dtdsSpawnOneShotLaunchdJob
```

也就是说"给 debugserver 指定 root 身份"这套 ObjC API 在 17.1 被整体换成了结构体字段，
光把参数类型改对也不足以复刻原意。

## 4. 本次采用的修法（方案 1）

`%ctor` 里加版本闸门，iOS 17+ 上**完全不注入**该 hook：

```objc
if (isDtds) {
    if (@available(iOS 17, *)) {
        NSLog(@TAG "iOS 17+ detected: skipping dtds hook (ABI changed to C struct)…");
        return;                       // dtdebugproxyd 持续保持原生行为
    }
    _dtdsSpawnExecutableWithOptions = dlsym(RTLD_DEFAULT, "dtdsSpawnExecutableWithOptions");
    if (_dtdsSpawnExecutableWithOptions) %init(Dtds);
}
```

实测结果：`dtdebugproxyd` 不再崩溃，Xcode 用系统自带的 `/usr/libexec/debugserver`
成功附加。

## 5. 若将来需要"任意进程调试"（方案 2 的起点）

按真 ABI 重写，且**不碰**结构体内容，只换可执行文件路径：

```c
Boolean dtdsSpawnExecutableWithOptions(const char *path, const void *opts, id a2, id a3);
```

要进一步把身份改成 root，得逆出结构体里 `+0x08` bool 与 `+0x10` / `+0x18` 两个对象字段的语义
（可能是 persona / uid-gid 描述对象），目前未验证。
