# iOSCleanerInspector

一个**只读**的 iOS / TrollStore 文件系统审计工具：用来核实手机清理类 App 声称要清理的东西，到底是什么、在哪里、有多大。

> **安全约束（重要）**
> 本项目从头到尾不含任何删除、移动、重命名、写入被扫描路径的代码。
> 它的目的是把"被统计的内容"摊开显示出来，而不是像清理工具那样把一切都压缩成一个"可回收 1.2 GB"的数字。

---

## 当前状态（0.2.1）

| 环节 | 状态 | 依据 |
| --- | --- | --- |
| 解除沙箱 / 容器 unrestricted 访问 | 已验证通过 | 真机安装后权限生效 |
| 全局路径 + app 容器扫描 | 已验证通过 | 真机上扫描结果正常出现 |
| Export 按钮（把报告交给系统） | 待验证 | CI 构建通过，还没装机跑过 |
| 在文本里全选 → 复制 | 已知会闪退 | 真机复现；原因未定位，见下方"已知问题" |

## 版本号约定

**小步走**：只有权限、架构这类断点式改动才动 minor（0.1 → 0.2），其余一律 patch（0.2.0 → 0.2.1）。
本仓库每次改动都必须推远端 CI 才能拿到产物，版本号跳太快会让"哪个版本对应哪个现象"难以追溯。

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
| 自己的类 | `AppDelegate`、`RootViewController`、`CacheManager`、`CleanTaskManager` |
| `CacheManager` 的方法 | `setupCachePaths` / `scanCacheSize` / `calculateSystemCacheSize` / `calculateTempFilesSize` / `calculateAppCacheSize` / `calculatePhotosCacheSize` / `calculateSizeOfFolder:` / `cleanDirectoryAtPath:` / `removeItemAtPath:error:` |
| `RootViewController` 的按钮 | 系统缓存 / App 缓存 / 临时文件 / 照片缓存 / 全部（5 个 clean 按钮） |
| 二进制内硬编码路径 | `/var/mobile/Containers/Data/Application/Calculator/Library/Caches`、`.../Mail/...`、`.../Notes/...`、`.../Safari/...`、`.../Weather/...` |

**更正一处自己的判断。** 我上一轮看到那 5 条硬编码路径（`/Application/Calculator/...` 这种 iOS 上并不存在的英文名路径），
结合 bundle id 是 `com.example.tweak`，判断它是"写死的展示项"。**这个结论证据不足，已收回。**
把 `__objc_classname` / `__objc_methname` 完整提取后能看到：它有 `contentsOfDirectoryAtPath:error:`、
`attributesOfItemAtPath:error:`、`calculateSizeOfFolder:`、`removeItemAtPath:error:`，还有
`dictionaryWithContentsOfFile:`（用来读容器里的 `.com.apple.mobile_container_manager.metadata.plist`，
即由 UUID 反查 bundle id 的标准做法）。也就是说**它确实在枚举、确实在删**，不是摆设。

那 5 条硬编码路径更像是 `setupCachePaths` 里的默认值/兜底值。真值如何，靠下面这个对照实验来定。

它的 entitlements 全集已被完整导出，见下节。

---

## 扫描哪些位置

命中"可读"的前提下，0.2.x 探测：

- `/tmp`
- `/var/tmp`
- `/var/mobile/Library/Caches`
- `/var/mobile/Library/Logs`
- `/var/mobile/Library/Preferences/Logs`（**iOS 上已不存在**，见下）
- `/var/mobile/Media/Downloads`
- `/var/mobile/Media/PhotoData/Caches`
- `/var/mobile/Media/PhotoData/Thumbnails`
- `/var/mobile/Containers/Data/Application`（逐个容器：bundle id + `Library/Caches` + `tmp`）
- 0.2.4 起补扫（用来追系统缓存那 0.72 GiB 缺口，见下）：
  `/var/mobile/Containers/Shared/AppGroup`、`Containers/Data/TempDir`、
  `Containers/Data/InternalDaemon`、`Containers/Data/PluginKitPlugin`、`/var/containers/Data`

## 与 iOSCleanerPro 的扫描范围对照

| 位置 | iOSCleanerPro | 本工具 | 说明 |
| --- | --- | --- | --- |
| `/tmp` + `/var/tmp` | 有（`tempFilePaths`） | 有 | **两者是同一个目录**，见下一节 |
| `/var/mobile/Library/Caches` | 有（`systemCachePaths`） | 有 | 一致 |
| `/var/mobile/Library/Logs` | 有（在它申请的 entitlements 里） | 有 | 一致 |
| `/var/mobile/Library/Preferences/Logs` | 有 | 有 | **真机上 ENOENT，两者都指向一个不存在的路径** |
| `/var/mobile/Media/PhotoData/Caches`、`Thumbnails` | 有（`photoCachePaths`） | 有 | 一致 |
| `/var/mobile/Media/Downloads` | 有 | 0.2.2 起有 | 之前漏了 |
| `/var/mobile/Containers/Data/Application` | 有（`applicationsPath`） | 有 | 一致 |

结论：**扫描范围基本是同一套**，差别只有 Downloads（我们原先漏了）和每个容器是否连 `tmp` 一起算。
所以两边数字可以直接对比 —— 见下面的对照实验。

## 0.2.1 真机报告里抓到的三个东西

### 1. `/tmp` 和 `/var/tmp` 是同一个目录 —— 0.2.1 虚报了 986.82 MB

iOS 上 `/var` 是指向 `/private/var` 的符号链接，`/tmp` 指向 `/private/var/tmp`。
所以 `/tmp` 与 `/var/tmp` 落在同一个 inode 上。0.2.1 把这两个路径各遍历了一次，报出来的数字**一模一样**
（都是 1,034,757,742 bytes / 1461 files / 2019 dirs）—— 两棵不同的目录树不可能字节数和文件数全部相等，
这个"相等"本身就是它们是同一份数据的证据。

按该次报告的数据：

| 口径 | 数值 |
| --- | --- |
| 全局路径（0.2.1 原样相加） | 3.79 GB |
| 其中重复计的一次 tmp | **986.82 MB** |
| 全局路径（去重后） | 2.83 GB |
| App 容器（168 个） | 21.08 GB |
| 全量（原样相加） | 24.88 GB |
| 全量（去重后，真实） | **23.91 GB** |

~~iOSCleanerPro 的 `tempFilePaths` 同样同时含 `/tmp` 和 `/var/tmp`，它大概率也在重复计这一份。~~
**这个预测错了，已证伪**：它报的「临时文件 990.71M」= `/tmp` 986.82 MiB + `Media/Downloads` 3.89 MiB，
到小数点后两位都对得上 —— 说明它**只计了一份**，不存在重复计。顺带确认了它用的是二进制单位（MiB/GiB）。
0.2.2 起按 `dev:inode` 去重，重复路径会显式打印 `[DUPLICATE]`。

### 2. `/var/mobile/Library/Preferences/Logs` 在这台机器上不存在

真机 `stat()` 返回 `errno=2 (No such file or directory)`。这是很老的越狱插件时代的路径，
现代 iOS 上没有它。iOSCleanerPro 也把它列在扫描路径里 —— 一个声称"能清理"的位置，
目标本身并不存在。

### 3. 容器扫描里有一批"只有 tmp、没有 cache"的容器

0.2.1 的输出里能看到 `Library/Caches: 0 bytes (0 files)` 但 `tmp` 有几十 MB 的容器
（例如 28671629 的 tmp 有 424 MB / 12488 files）。只统计 `Library/Caches` 的工具会完全看不到这部分。

## 对照实验（判定 iOSCleanerPro 到底扫了多少 App）

两边扫描范围一致、两边都能真机跑，所以可以直接比：

1. 用本工具扫一遍，记下「App 容器总数」和「容器合计」（去重后）。
2. 打开 iOSCleanerPro，看它的 App 缓存分类显示多少。
3. 对得上（都是 21 GB 量级 / 168 个左右）→ 它确实全量枚举；
   只显示计算器、邮件、备忘录、Safari、天气 5 项 → 那 5 条硬编码路径就是它的全部范围。

**不要用它自带的一键清理按钮去验证**（它是真的删文件的：`removeItemAtPath:error:` 摆在那儿）。
只读我们的数字和它显示的数字就够了。

## 数字对比（第一轮，iOSCleanerPro 只有四个分类总大小）

同一台机器、相近时间：

| 分类 | iOSCleanerPro | 本工具 0.2.2 | 差 |
| --- | --- | --- | --- |
| 临时文件 | 990.71 M | `/tmp` 986.82 MiB + Downloads 3.89 MiB = **990.71 MiB** | **完全一致** |
| 照片缓存 | 335.59 M | PhotoData/Caches + Thumbnails = 355.59 MiB；只算 Thumbnails = 335.19 MiB | ≈0（只算缩略图） |
| 系统缓存 | 2.24 G | `Library/Caches` = 1.50 GiB；+Apple 容器 = 2.06 GiB | **+0.72 GiB 未对上** |
| 应用缓存 | 17.92 G | 168 个容器 **仅 `Library/Caches`** = **17.93 GiB** | ≈0（差 0.01） |

「临时文件」两项完全对上，是很硬的证据：**我们的遍历方式和它是一致的**
（同一批文件、同样的字节数、同样的单位），所以上面的差异不是"算法不同"，而是**分桶边界不同**。

剩下的差异有两个候选解释，0.2.3 的分类小计就是用来二选一的：

0.2.3 的分类小计出来后，**假设 B 成立，假设 A 不成立**：

- **应用缓存 = 所有容器（含 com.apple.*）的 `Library/Caches`，不含 `tmp`** —— 17.93 vs 17.92 GiB，差 0.01。
  所以它**不区分 Apple / 第三方**，也**不统计容器里的 tmp**（我们 0.2.2 才加的那 3.20 GiB tmp，它看不到）。
- **照片缓存 ≈ 只算 `PhotoData/Thumbnails`**（335.19 vs 335.59 MiB，差 0.4 MiB 属扫描间隔的自然变动）。
  `PhotoData/Caches` 那 20.44 MiB 它没算进照片桶。

**只剩「系统缓存」对不上 0.72 GiB**：它显示 2.24 G，0.2.3 时我们最大口径只有 2.06 GiB
（Caches 1.50 + Logs 0.02 + Apple 容器 0.56）。差的这部分大概率在我们没扫的位置上 ——
候选是 `/var/mobile/Containers/Shared/`（App Group 共享容器）和 `/var/containers/` 下的系统容器。

0.2.4 已经把这批路径加进去扫了，并在分类小计里单列一行「+ 共享/系统容器」以及上面四项的合计。

### 重启后的第二轮对账（推翻了两条旧判断）

重启手机后两边各扫一次（iOSCleanerPro：系统 449.56M / 应用 18.16G / 临时 70.77M / 照片 358.29M）：

| 分类 | iOSCleanerPro | 本工具 | 结论 |
| --- | --- | --- | --- |
| 临时文件 | 70.77 M | 70.57 MiB（/tmp 67.67 + Downloads 2.90） | ✓ 差 0.2 MiB |
| 照片缓存 | 358.29 M | 358.29 MiB（Caches + Thumbnails） | ✓ **逐位一致** |
| 应用缓存 | 18.16 G | 18.16 GiB（167 个容器，仅 `Library/Caches`） | ✓ **逐位一致** |
| 系统缓存 | 449.56 M | 867.98 MiB（`Library/Caches` 全量） | ✗ **反过来变成我们更大** |

有两条旧判断因此作废：

- ~~照片缓存只算 `PhotoData/Thumbnails`~~ —— 错，这次 Caches + Thumbnails 两项加起来与它**完全一致**（358.29 对 358.29）。
  上一轮差的那 20.00 MiB 就是两次扫描之间的自然变动。
- ~~系统缓存是它比我们多 0.72 GiB~~ —— 方向不是固定的。重启前它多、重启后我们多，
  说明「系统缓存」这个桶的口径不是 `Library/Caches` 全量，两次扫描的先后也掺在里面。

三个桶能逐位对上（照片、应用、临时），说明**两个 App 看到的是同一份文件系统**；
系统缓存这 418 MiB 的差，剩下就是两个可能：
（a）两次扫描之间 `Library/Caches` 涨了（重启后 App 会迅速回填缓存）；
（b）它的系统桶只覆盖 `Library/Caches` 的一部分。

0.2.5 加了两个东西来二选一：**扫描开始/结束时间戳**（能看出漂移量）和
**`Library/Caches` 的一级子项明细**（能看出有没有某个子集正好等于它的 449.56 MiB）。

### 它根本没碰的部分（约 9.3 GiB）

它的四个桶加起来约 **19.01 GiB**，我们整体合计 **28.35 GiB**，差 ~9.34 GiB：

| 位置 | 大小 | 在它的四个桶里吗 |
| --- | --- | --- |
| 各容器 `tmp` | 3.90 GiB | 否（应用桶只算 `Library/Caches`） |
| `Containers/Shared/AppGroup` | 3.09 GiB | 否 |
| `Containers/Data/PluginKitPlugin` | 1.91 GiB | 否 |
| 其余（Logs、`/var/containers/Data` 等） | ~0.03 GiB | 否 |

也就是说：App Group 共享缓存、插件缓存、以及每个 App 的 `tmp`，它一类都不碰。

### 顺带：重启本身清掉了多少

| 路径 | 重启前 | 重启后 |
| --- | --- | --- |
| `/tmp` | 1.03 GB | 71 MB（少 963 MB） |
| `Library/Caches` | 1.61 GB | 910 MB |

另外有几个容器的 UUID 换了（clue、Tweetie2、pinduoduo、alipay、doubao 等），
说明 UUID 不是稳定的标识 —— 这也是报告里带 bundle id 的原因。

0.2.3 起报告末尾会打印这几个桶的**多种组合**（Caches 单独、含 tmp、Apple/第三方拆分），
并且用二进制单位显示，直接跟它界面上的数字对。

## 反编译：它到底扫哪些目录（已确认）

用 `tools/decompile/objc_method_strings.py` 做了真正的静态还原（走
`__objc_classlist → class_ro_t → method_list_t → 反汇编 → CFString / @[] 字面量`，
注意 iOS 15+ 的 `__DATA*` 里是指针是 **dyld chained fixup**，要取低 36 位才是真地址）。

`-[CacheManager setupCachePaths]`（imp `0x100009adc`，`init` 里同样一份）引用的全部路径字面量：

```text
@[ /var/tmp, /tmp, /var/mobile/Library/Caches, /var/mobile/Library/Logs ]   ← 4 元素数组字面量
   /var/mobile/Library/Preferences/Logs
   /var/mobile/Media/Downloads
@[ /var/mobile/Media/PhotoData/Caches, /var/mobile/Media/PhotoData/Thumbnails ]
   /var/mobile/Containers/Data/Application
```

所以它的真实扫描面和我们的扫描面是**同一套**（0.2.2 补 Downloads 之后）：

| 路径 | 它 | 我们 |
| --- | --- | --- |
| `/tmp`、`/var/tmp` | 有（在同一个 4 元素数组里） | 有（去重后只计一次） |
| `Library/Caches`、`Library/Logs`、`Preferences/Logs` | 有 | 有 |
| `Media/Downloads`、`PhotoData/Caches`、`PhotoData/Thumbnails` | 有 | 有 |
| `Containers/Data/Application` | 有 | 有 |

`-[CacheManager getAllApplicationsInfo]`（imp `0x10000b968`）证实它读的是
`Library/Preferences/.com.apple.mobile_container_manager.metadata.plist` 里的 `MCMMetadataIdentifier`
（由 UUID 反查 bundle id），再拼 `Library/Caches` 算体积 —— 与我们 0.2.2 起的做法一致。

### 顺带挖到：5 条写死的假数据

`__objc_arraydata` 里有 5 份硬编码字典，字段是 `bundleIdentifier` / `cachePath` / `cacheSize` / `cacheSizeFormatted`：

| bundle id | cachePath | cacheSizeFormatted（写死） |
| --- | --- | --- |
| com.apple.mobilesafari | `.../Application/Safari/Library/Caches` | **150.00 MB** |
| com.apple.mobilemail | `.../Application/Mail/Library/Caches` | **85.00 MB** |
| com.apple.mobilenotes | `.../Application/Notes/Library/Caches` | **45.00 MB** |
| com.apple.weather | `.../Application/Weather/Library/Caches` | **30.00 MB** |
| com.apple.calculator | `.../Application/Calculator/Library/Caches` | **5.00 MB** |

我已经把上一轮"写死展示项"的判断收回过一次（它确实有真实枚举），现在证据更细：
**两套都在** —— 真实枚举（`getAllApplicationsInfo`）+ 一份写死的整数大小兜底数据。
真机的「应用缓存 17.92G」等于我们 168 个容器 `Library/Caches` 的 17.93 GiB，
说明展示用的是真实枚举结果；这份兜底数据大概是枚举出结果前/失败时的占位。
（我没法证明它一定不会显示，只是它显示的数字与真实值吻合。）

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
- 新增真实代码签名：`codesign -f -s - --entitlements ...`（**同时保留** `__TEXT` section，两条路都铺）
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

## 导出报告：Export 按钮

屏幕上联排两个按钮：`Scan (READ ONLY)` 和 `Export…`。扫描完成后 `Export…` 才可用。

点它会弹出系统的分享/保存面板（`UIActivityViewController`）。关键点是**递给它的是报告原文字符串，不是文件 URL**：

```objc
UIActivityViewController *activity =
    [[UIActivityViewController alloc] initWithActivityItems:@[report]
                                      applicationActivities:nil];
```

这样做的结果：

- 我们**不预先写任何文件**，也不会把任何临时文件路径交出去
- 因此**不会直接跳到文件 App 的目录里**去"真的保存"——只有在面板里自己点了目标（保存到"文件"、存到备忘录、发给别的 App 等），系统才在那个时刻生成文件
- 面板里出现哪些选项由系统依据内容类型决定，不需要我们声明

另外补了一处在 iPad 上的必要处理：`Info.plist` 里 `UIDeviceFamily` 包含 2（iPad），而 iPad 上以 popover 形式呈现分享面板**必须**指定 `popoverPresentationController.sourceView`，否则直接崩。iPhone 上这行无害。

### 已知问题：全选 → 复制会闪退

在文本区域里全选再点"复制"，0.2.1 会直接闪退。成因还没定位（没有崩溃日志，不猜）。Export 按钮是绕过它的办法。

需要留意的是：如果崩溃跟粘贴板本身有关，那么分享面板里的那个 "Copy" 也可能同样崩——那就先选面板里的其他目标。真机上跑一遍把现象（以及能不能拿到崩溃日志）带回来，再决定下一步是继续绕还是正面修。

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

### 0.2.5

- 报告头尾打出**扫描开始/结束时间戳**：缓存变动很快，没有时间戳就分不清
  「两次扫描之间的漂移」和「口径真的不一样」
- 新增 `/var/mobile/Library/Caches` 的**一级子项明细**（按大小排序），
  用来判断它的 449.56 MiB 是不是其中某个子集

### 0.2.4

- 补扫 5 个此前没覆盖的容器路径（Shared/AppGroup、Data/TempDir、Data/InternalDaemon、
  Data/PluginKitPlugin、`/var/containers/Data`），追「系统缓存」那 0.72 GiB 的缺口
- 分类小计里单列「+ 共享/系统容器」一行和四项合计，直接对它的 2.24 G
- 整体合计现在也把这批路径算进去

### 0.2.3

- 报告末尾新增 **CATEGORY TOTALS**：按对方界面的四个分桶给出多种组合
  （系统缓存：Caches / +Logs / +Apple 容器；应用缓存：仅 Caches / 含 tmp / Apple / 第三方），
  并用二进制单位显示 —— 上一轮已确认对方界面用的是 MiB/GiB
- 修正上一轮的预测：对方的「临时文件」与我们的 `/tmp` + Downloads **到小数点后两位一致**，
  说明它并没有重复计 `/tmp`，猜测作废
- `SystemScanner` / `AppScanner` 现在把结果留在属性里（`sizesByPath`、各项分类合计），
  便于组合出别的分桶口径

### 0.2.2

- 修掉重复统计：`/tmp` 与 `/var/tmp` 在 iOS 上是同一个目录（`/var` → `/private/var`），
  0.2.1 各遍历一次，虚报 986.82 MB。现在按 `dev:inode` 去重，并对重复路径显式打印 `[DUPLICATE]`
- 容器扫描补上 bundle id（读容器里的 `.com.apple.mobile_container_manager.metadata.plist` 的
  `MCMMetadataIdentifier`），168 个匿名 UUID 变成可核对的 App 列表
- 补上 `/var/mobile/Media/Downloads`（与 iOSCleanerPro 对齐，0.2.1 漏了）
- 更正对 iOSCleanerPro 的判断：它有真实枚举与删除实现，上一轮"写死展示项"的说法证据不足，已收回

### 0.2.1

- 新增 `Export…` 按钮：把报告**原文字符串**交给系统分享面板（不预写文件、不传文件 URL，
  因此不会直接跳进目录去保存，只有用户选中目标时系统才生成文件）
- 补 iPad 上必需的 `popoverPresentationController.sourceView`（`UIDeviceFamily` 含 iPad，
  不设的话 popover 形式呈现会崩）
- 导出用扫描器产出的原文而非 `UITextView` 的文本，避免被排版层影响
- 版本号改为小步走：权限/架构类断点改动才动 minor，其余 patch

### 0.2.0

- entitlements 按三份出处重写，补齐 `no-sandbox` / `container-required=false` / 绝对路径尾部斜杠
- 新增真实代码签名（`codesign`），entitlements 同时写入 `__TEXT` section 和签名
- 扫描失败时打印 POSIX errno 与进程 uid/euid，可区分"被沙箱拦"与"路径不存在"
- 修掉输出里的转义 bug：源码中换行写成了字面 `\n`，导致报告挤成一行
- 不再在 `Makefile` 里用 `rm -rf`，清理改为移入 `.trash/`

### 0.1.0

- 首个只读版本：全局路径 + app 容器扫描，最小 entitlements（真机验证不足）
