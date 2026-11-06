# CPU 睿频：为什么只有 3.8GHz，以及做到了哪一步

> 机型：HP ZBook Power G10 · i7-13700H（6P + 8E / 20 线程）
> 系统：macOS 26.7.1 · OpenCore + SMBIOS `MacBookPro16,2`
> 结论先说：**macOS 侧的上限已经从 3.8GHz 打开到 5.0GHz，但实测持续频率仍在 3.7–3.9GHz，
> 根因在伪装 CPUID 与 HWP 的协同层，未彻底解决。**

---

## 1. 症状

「关于本机」显示 `2.92 GHz`（这个数字本身不可信），但真正的问题是满载也上不去。
空闲时频率在 600–1100MHz 之间跳动（说明 XCPM 变频本身是工作的），一旦压满：

| 场景 | 修复前实测 |
|---|---|
| 20 线程全核压满 | P 核 ~3.80GHz |
| 单核 / 双核压满 | 峰值 ~3.81GHz，不再上升 |

i7-13700H 的规格是 **P 核单核睿频 5.0GHz、E 核 4.7GHz、全核 P 核约 4.3–4.6GHz**。

## 2. 根因：频率表是「借」来的

macOS 的 `X86PlatformPlugin` 按 **board-id** 从自身资源里挑一份电源管理 plist：

```
/System/Library/Extensions/IOPlatformPluginFamily.kext/Contents/PlugIns/
    X86PlatformPlugin.kext/Contents/Resources/<board-id>.plist
```

本机 board-id = `Mac-5F9802EFE386AA28`（即 `MacBookPro16,2`），该机型真实 CPU 是
**Ice Lake i7-1068NG7**，规格恰好是 **全核 3.8GHz / 单核 4.1GHz**——和实测封顶 3.8GHz 精确吻合。

```bash
plutil -p .../Resources/Mac-5F9802EFE386AA28.plist | grep -A3 Frequencies
#   "Frequencies" => { "3800" => 1, "4100" => 1 }
```

也就是说：**macOS 根本没认出这颗 CPU，只是照抄了一颗低它两代的 U 的频率表。**

对应的内核侧硬限制：

```bash
sysctl machdep.xcpm.hard_plimit_max_100mhz_ratio    # 修复前：38（=3.8GHz）
```

## 3. 方案：CPUFriend + 换频率表

`CPUFriend` 的工作方式是 hook `X86PlatformPlugin` 的 `configResourceCallback()`，
在系统请求电源管理数据时喂入自定义数据（不修改系统文件，可随时撤回）。
数据由官方的 `ResourceConverter.sh` 从一份完整资源 plist 转成 `CPUFriendDataProvider.kext`。

选表原则：**找一颗 P 核基频/睿频与你最接近的机型**。候选：

| board-id | 机型 | 真实 CPU | Frequencies 档位 |
|---|---|---|---|
| `Mac-5F9802EFE386AA28` | MacBookPro16,2 | i7-1068NG7（Ice Lake，4C） | 3800 / 4100 |
| `Mac-AA95B1DDAB278B95` | MacBookPro16,1 | i9-9980HK（CFL-H，8C） | 4100 / 4300 / 4600 / **5000** |

i9-9980HK 是「基频 2.4GHz、单核 5.0GHz」——与 13700H 的 P 核规格几乎一模一样，故选它。

```bash
# CPUFriend 官方 release 自带 Tools/ResourceConverter.sh
sh Tools/ResourceConverter.sh --kext Mac-AA95B1DDAB278B95.plist
# → 当前目录产出 CPUFriendDataProvider.kext
```

部署：

1. `CPUFriend.kext`、`CPUFriendDataProvider.kext` 放进 `EFI/OC/Kexts`
2. `config.plist` → `Kernel → Add` 两条，位置排在 `Lilu.kext` **之后**（本机插在 index 1、2）
3. `boot-args` 追加 **`-cpufbeta`**

## 4. 最大的坑：`-cpufbeta`

CPUFriend 的 RELEASE 二进制带内核版本白名单，**macOS 26 不在白名单里**。
不加 `-cpufbeta` 时它不报错、不进日志，只是**静默不注入**——现象极难判断：

- `kextstat` 里 `CPUFriend` 明明已加载
- `machdep.xcpm.vectors_loaded_count = 1` 看起来也正常
- 但频率表一个字都没变

判定注入是否真的生效，看运行时资源（不是磁盘上的 plist）：

```bash
ioreg -l -n X86PlatformPlugin | grep -o '"Frequencies"={[^}]*}'
# 未生效：{"4100"=1,"3800"=1}
# 已生效：{"4300"=1,"4600"=2,"5000"=3,"4100"=0}

sysctl machdep.xcpm.hard_plimit_max_100mhz_ratio
# 38 → 50（=5.0GHz）
```

> 官方文档在 `Instructions.md` 里写了这条：
> `Add -cpufbeta to enable CPUFriend on unsupported OS versions.`

## 5. 效果：上限打开了，持续频率没有

修复后 macOS 侧一切绿灯：

| 检查项 | 结果 |
|---|---|
| `hard_plimit_max_100mhz_ratio` | 50（5.0GHz） |
| `bootpst`（启动性能档） | 50 |
| 电源 | AC 供电，`lowpowermode 0` |
| 热状态 | `pmset -g therm` 无任何警告，`CPU_Speed_Limit 100` |
| 封装功耗（单核满载） | 仅 13–15W（PL1 45W，余量巨大） |
| 运行时频率表 | 4300 / 4600 / 5000 三档已注入 |

但实测仍然上不去。用两种**独立**方法交叉验证（powermetrics 的平均值会被 C-state 拉低，不可单独采信）：

**方法 A：powermetrics**

```bash
sudo powermetrics -n 3 -i 1500 --samplers cpu_power | grep 'CPU Average frequency'
# 峰值 ~3.92GHz（修复前 ~3.81GHz，略有提升）
```

**方法 B：自写 AVX2+FMA 峰值算力基准（不依赖任何系统频率标定）**

```c
// 8 条独立 FMA 链跑满 P 核的 2 个 256-bit FMA 端口 = 32 FLOP/cycle
// 实测 GFLOPS ÷ 32 ÷ 0.95 ≈ 真实核心频率
```

| 轮次 | GFLOPS | 换算频率 |
|---|---|---|
| 1 | 59.05 | ~1.9GHz（落到了 E 核） |
| 2 | 79.23 | ~2.6GHz（被调度/降频影响） |
| 3 | 110.96 | **~3.65GHz** |

若真有 5.0GHz，此基准应给出 ~149 GFLOPS。**结论：3.7–3.9GHz 是真实频率，不是显示误差。**

## 6. 剩下的瓶颈（未解决）

已排除：XCPM 硬限制、电源模式、温度墙、功耗墙、调度限制、频率表缺档。

最可能的解释：`config.plist → PlatformInfo → Generic → Emulate → Cpuid1Data`
把 CPUID 伪装成 **`0x000A0655`（Comet Lake）**——这是让 macOS 26 接受这颗 CPU + 核显补丁的前提。
伪装之后，macOS 的 HWP/EPP 调频策略仍按「一颗 Comet Lake」来跑，
真实 Raptor Lake 的 HWP 能力表（最高 5.0GHz）没有被完整驱动。

想继续逼近，可尝试（均未验证、风险自担）：

- DEBUG 版 CPUFriend + `-cpufdbg`，确认数据是否被后续流程覆盖
- 换 `Cpuid1Data` 目标（会影响核显补丁，可能直接黑屏）
- 注入 EPP / HWP 相关 SSDT（收益不确定）

对日常使用而言，3.7–3.9GHz 的单核性能与 20 线程并行能力已经够用，
且该配置**两次完整重启验证稳定**，故保持现状。

## 7. 复现清单

```bash
# 1) 确认当前 board-id 与频率表
ioreg -l | grep -m1 board-id
plutil -p .../Resources/$(ioreg -l | grep -m1 board-id | grep -o 'Mac-[A-F0-9]*').plist | grep -A3 Frequencies

# 2) 下载 CPUFriend release，转换选定的资源表
curl -L -o cf.zip https://github.com/acidanthera/CPUFriend/releases/download/1.2.9/CPUFriend-1.2.9-RELEASE.zip
unzip -q cf.zip && sh Tools/ResourceConverter.sh --kext Mac-AA95B1DDAB278B95.plist

# 3) 两个 kext 进 EFI，config 加两条 Kernel→Add（Lilu 之后），boot-args 加 -cpufbeta

# 4) 重启后验证
ioreg -l -n X86PlatformPlugin | grep -o '"Frequencies"={[^}]*}'
sysctl machdep.xcpm.hard_plimit_max_100mhz_ratio
```
