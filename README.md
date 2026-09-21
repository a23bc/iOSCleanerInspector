# iOSCleanerInspector

一个**只读**的 iOS / TrollStore 文件系统审计工具：用来核实手机清理类 App 声称要清理的东西，到底是什么、在哪里、有多大。

> **安全约束（重要）**
> 本项目从头到尾不含任何删除、移动、重命名、写入被扫描路径的代码。
> 它的目的是把"被统计的内容"摊开显示出来，而不是像清理工具那样把一切都压缩成一个"可回收 1.2 GB"的数字。

---

## 一句话状态

截至 0.2.0，**尚未在真机上验证**。已确认的事实和待验证的内容都写在下面，不再用"应该没问题"糊过去。

---

## 它审计的对象：iOSCleanerPro.tipa

被审计的包在本地 `E:\Documents\Downloads\iOSCleanerPro.tipa`（arm64 切片，`cryptid=0`，未加密；401 KB，无任何私有框架依赖）。

用 `tools/decompile/extract_entitlements.py` 直接读它的代码签名，得到的**事实**是：

| 项目 | 值 |
| --- | --- |
| Bundle ID | `com.example.tweak`（占位 ID，不是真实开发者 ID） |
| UIBackgroundModes | `audio` |
| 权限用途说明 | 仅"需要访问媒体库/照片库来清理缓存"两句中式文案 |
| 链接的私有框架 | 无 |
| 二进制内硬编码路径 | `/var/mobile/Containers/Data/Application/Calculator/Library/Caches`、`.../Mail/...`、`.../Notes/...`、`.../Safari/...`、`.../Weather/...` |

最后一行值得单独说：iOS 上 app 容器的真实路径是 **UUID 目录**（`/var/mobile/Containers/Data/Application/<UUID>/Library/Caches`），并不存在 `.../Application/Calculator/...` 这种英文名路径。这些字符串吃起来更像是写死的展示项，而不是真实枚举结果。这也是本项目存在的理由：先确认"看得到什么"，再谈"清理了什么"。

它的 entitlements 全集已被完整导出，见下节。

---

## 扫描哪些位置

命中"可读"的前提下，v0.2.0 探测：

- `/tmp`
- `/var/tmp`
- `/var/mobile/Library/Caches`
- `/var/mobile/Library/Logs`
- `/var/mobile/Library/Preferences/Logs`
- `/var/mobile/Media/PhotoData/Caches`
- `/var/mobile/Media/PhotoData/Thumbnails`
- `/var/mobile/Containers/Data/Application`（逐个容器报 UUID，以及 `Library/Caches`、`tmp` 的体积和文件数）

---

## 权限设计（本次改动的核心）

### 为什么之前的版本读不到目录

上一版（0.1.0）在真机上把全局路径和容器目录报成了不可访问。逐条对照证据，找到三个原因：

**1. 漏了两个"无沙箱"开关。**
TrollStore 上游 README 明确写了，解除沙箱要用这三个键之一：

- `com.apple.private.security.container-required` = false
- `com.apple.private.security.no-container` = true
- `com.apple.private.security.no-sandbox` = true

0.1.0 只有 `no-container`，缺 `container-required=false` 和 `no-sandbox`。按官方文档，**`no-sandbox` 是推荐写法**（它还允许保留容器）。现在三个都申请了。

**2. 绝对路径例外少了尾部斜杠。**
Apple 的 *App Sandbox Temporary Exception Entitlements* 写得很清楚：

> If a path you provide specifies a directory rather a file, you must end the path with a slash character.

也就是说 `/var/mobile/Library/Caches` 只给这一个节点本身，而 `/var/mobile/Library/Caches/` 才覆盖它下面的子孙。0.1.0 的数组里**一条尾部斜杠都没有**，所以即使豁免生效，也只能 stat 到目录本身，列不出内容。被审计的 app 恰好是带斜杠写的 —— 这个差异就是对照出来的。

**3. entitlements 没有进入真正的代码签名。**
0.1.0 的产物只有 `-sectcreate,__TEXT,__entitlements` 嵌入的 section，**整个二进制没有代码签名**（用 macholib 核过：无 `LC_CODE_SIGNATURE`）。iOS 只会承认写在代码签名里的 entitlements，光有 `__TEXT` section 能不能被 TrollStore 读到并没有保证。

**更正说明（推翻自己一次）**：我一开始用手写的 Mach-O 解析器得出结论"上一版根本没嵌入 entitlements"，这个结论是**错的**，已作废。真实情况是 section 确实存在且内容正确（1290 字节，和 macholib 报的 offset 35786 / size 1290 一致）；错的是解析器 —— Apple 的 ld 在 `LC_SEGMENT_64` 里比经典布局多了一个 8 字节字段（macholib 把它叫 `filesize`），section 数组因此整体后移 8 字节。现在工具已用"依次尝试两种布局 + 校名可打印"的方式修好，并与 macholib 交叉验证通过。

### 0.2.0 的修复动作

- entitlements 按 **三份证据**重写：被审计 app 的签名导出值、TrollStore 上游 entitlements、Apple 官方文档
- 所有目录型绝对路径例外补上尾部斜杠
- 新增真ë实代码签名：`codesign -f -s - --entitlements ...`（**同时保留** `__TEXT` section，两条路都铺）
- 每个 key 为什么存在，都写在 `iOSCleanerInspector.entitlements` 的注释里

### "unrestricted accessible containers" 是哪个键

就是 **`com.apple.private.security.storage.AppDataContainers = true`**。
这不是猜的：TrollStore 的 `TSAppInfo.m` 里，App 详情页显示的

> Accessible Containers: Unrestricted, the app can access all data containers on the system.

判定条件正是这一个布尔键。0.1.0 里其实已经有它了，但因为上面三个原因，实际没起作用。

### 有意不申请的东西

- 文件例外全部用 **read-only** 变体。被审计的 app 用的是 read-write，但本工具只读，没必要要写权限。
  如果真机上出现"能列举但读不了内容"，把 `absolute-path.read-only` 换成 `read-write` 是一行改动。
- **不申请 IOKit**。被审计 app 带着 `exception.iokit-user-client-class=IOHIDLibUserClient` 和 `system.diagnostics.iokit-properties` —— 这两个是 `platform-application` 收紧 IOKit 后的补丁（TrollStore README 明确提过这个副作用），跟文件系统审计无关。
- 不申请 `persona-mgmt`（root 提权）、`skip-library-validation`、`dynamic-codesigning`、`cs.debugger`（iOS 15 A12+ 上这三个会直接崩）。

---

## 怎么判断权限到底生效了没有

App 现在会把失败原因直接摊出来，而不是笼统地报一个 "NO ACCESS"：

```
running as uid=501 euid=501 gid=501 egid=501
SYSTEM / GLOBAL PATHS ----------------------
[NO ACCESS] /var/mobile/Library/Caches
    cause: opendir() failed errno=1 (Operation not permitted)
```

读 errno 的方法：

| errno | 含义 | 说明 |
| --- | --- | --- |
| 1 EPERM | Operation not permitted | 被 Seatbelt 拦了 —— entitlement 没生效 |
| 2 ENOENT | No such file or directory | 路径根本不存在，不是权限问题 |
| 13 EACCES | Permission denied | Unix 权限位不够（进程身份问题，见 uid） |
| 20 ENOTDIR | 路径里有非目录成分 | 拼错了 |

`NSFileManager` 会把 ENOENT 和 EACCES 都吞成同一个 `NO`，所以这里直接用 `stat()` / `opendir()` 拿 errno。

另外，`unrestricted container access` 可以直接装完后在 TrollStore 的 App 详情页里看：显示 "Unrestricted" 就说明 `AppDataContainers` 被系统认了。

---

## 构建

**不在本地编译。** 推送即构建：

```sh
git push origin main
gh run watch          # 跟踪 CI
```

CI 在 `macos-14` runner 上跑，产出 `iOSCleanerInspector.tipa`。每次构建都会把**签名里实际生效的 entitlements**（`codesign --display --entitlements`）和 **`__TEXT` section 里嵌的 entitlements**（自研提取工具，独立路径重读一遍）都打到日志里，两份应当一致。

TIPA 是 ad-hoc 签名的产物，工具链里不嵌任何开发者证书；正式签名、重签交给设备上的 TrollStore。

本地有 Xcode 命令行工具的话也可以：

```sh
make            # 编译 + Info.plist
make sign       # ad-hoc 签名并写入 entitlements
make verify     # 打印并校验签名
make package    # 产出 tipa
make clean      # 把 build/ 移进 .trash/，不做 rm -rf
```

环境要求：iPhoneOS SDK + Xcode 命令行工具。依赖不需要装。

---

## 配套工具

`tools/decompile/extract_entitlements.py` —— 纯标准库，从 Mach-O 里导 entitlements，同时支持两种来源：

- `__TEXT,__entitlements` section（`-sectcreate` 嵌的）
- `LC_CODE_SIGNATURE` superblob 的 slot 5（XML）和 slot 7（DER）

```sh
# 整个压缩包：自动找出里面所有 Mach-O（含 fat 多架构切片）
python3 tools/decompile/extract_entitlements.py iOSCleanerPro.tipa

# 单个二进制
python3 tools/decompile/extract_entitlements.py build/Payload/Inspector.app/Inspector
```

> 实现上的坑：`LC_CODE_SIGNATURE` 内部的 blob **永远是大端**，跟 Mach-O 本身的字节序无关；而 `LC_SEGMENT_64` 的 section 数组在现代 Apple ld 下比经典布局多 8 字节。两个都踩过，已修。

本地做交叉验证时用过 `macholib`（装在 `tools/venv/`，只装在项目目录里，不碰全局环境）：

```sh
python -m venv tools/venv
tools/venv/Scripts/pip install macholib     # Windows
# tools/venv/bin/pip install macholib      # macOS / Linux
```

`tools/venv/` 与下载的产物都在 `.gitignore` 里，不会进仓库。

---

## 范围

这是审计/观察工具，不是清理工具。**不要往里加删除 API**，除非项目被重新设计并经过评审 —— 它的全部说服力就在于"我们只读不写"。

---

## 变更记录

### 0.2.0

- entitlements 按三份出处重写，补齐 `no-sandbox` / `container-required=false` / 绝对路径尾部斜杠
- 新增真实代码签名（`codesign`），entitlements 同时写入 `__TEXT` section 和签名
- 扫描失败时打印 POSIX errno 与进程 uid/euid，可区分"被沙箱拦"与"路径不存在"
- 修掉输出里的转义 bug：源码中换行写成了字面 `\n`，导致报告挤成一行
- 不再在 `Makefile` 里用 `rm -rf`，清理改为移入 `.trash/`

### 0.1.0

- 首个只读版本：全局路径 + app 容器扫描，最小 entitlements（真机验证不足）
