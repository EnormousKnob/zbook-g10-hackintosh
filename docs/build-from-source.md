# 从源码构建 WhateverXe（edp-keep 版）

本文记录本仓库使用的 WhateverXe 修改版是如何从上游源码构建出来的，供同机型用户复现。

> 成品驱动**不在本仓库分发**（尊重上游 License 与 Lilu 插件惯例），请按本文自行编译。

## 1. 前置条件

- 一台能进系统的 Mac（黑苹果本机即可），已安装 Xcode Command Line Tools：

```bash
xcode-select --install
xcrun clang++ --version   # 确认 clang 可用
```

- 源码树是**自包含**的，clone 后无需另外下载 SDK：

```
~/wex070/
├── WhateverXe/          # 主驱动源码（Lilu 插件）
├── AppleIntelTGLCompat/ # donor 符号提供者（0xA720 必需）
├── Lilu.kext/           # 构建时取其 Resources 头文件
├── MacKernelSDK/        # 内核 SDK
└── tools/build.py       # 一键构建脚本
```

## 2. 获取上游源码

```bash
git clone https://github.com/b00t0x/WhateverXe ~/wex070
cd ~/wex070
git checkout d0b7fb6        # 0.7.0 tag 对应的 commit
```

## 3. 应用 eDP keep 补丁（内屏修复的核心）

上游 issue [#43](https://github.com/b00t0x/WhateverXe/issues/43) 中 nickk19 的 fork
添加了 `-wex-edp-keep`：驱动检测到固件已训练好的 eDP 链路时回答 *Partial modeset*，
不再断链重训。共 3 个 commit：

| commit | 内容 | 应用方式 |
|---|---|---|
| `5f4aab9` | eDP 启动端口准入 | `git apply` 干净套用 |
| `3aad38c` | VBT panel type 0xFF（按 EDID 选面板）兼容 | 手工移植（本地 VBT 已有 HP 机型改动） |
| `7aef3d0` | keep-link 决策钩子 + ReadAUX 链路能力采集 | `patch -p1 --fuzz=3` 应用 5/6 hunk，剩余 1 个手工移植 |

```bash
curl -sLO https://github.com/nickk19/WhateverXe/commit/5f4aab95e8b55d54848ea4329fc602cbce6623f4.patch
curl -sLO https://github.com/nickk19/WhateverXe/commit/3aad38c0f38069398ed60465a5fb2c54a2ea150b.patch
curl -sLO https://github.com/nickk19/WhateverXe/commit/7aef3d04f2f98f60df630799424d019c40d5c8db.patch

git apply 5f4aab9*.patch
# 3aad38c / 7aef3d0 与本机改动冲突时，按 hunk 手工移植（见下文"本机改动"）
```

补丁效果（部署后可在 ioreg 验证）：

```
"WEXEDPKeep" = <01000000 04000000 04000000 ...>
#  version=1  call=4  kept=4   ← 4 次 modeset 全部被拦为 Partial，固件链路从未断开
```

## 4. 本机专属改动

在上游基础上另有约 700 行本地修改，与本机相关的关键项：

- **VBT 解析**：HP 出厂 VBT 含重复面板条目，`kern_vbt.hpp` 中加入去重 workaround
  （这也是上游 issue #35 卡住的点）；
- **CPU 拓扑**：配合 `CpuTopologyRebuild` 修正 6P/8E 拓扑；
- **DVMT / 显存**：Stolen Memory 64MB → 传参修正；
- 若你的机器同为我这类 ADL-P / RPL-H 移动端，建议先在上游干净树上试
  `3aad38c` + `7aef3d0`，跑通后再叠加自己的机器专属修改。

## 5. 构建

```bash
cd ~/wex070
python3 tools/build.py --output out-edpkeep
```

- 同时产出 `out-edpkeep/WhateverXe.kext` 和 `out-edpkeep/AppleIntelTGLCompat.kext`；
- Debug 版（默认，`-DDEBUG=1`）会往 ioreg 发布诊断属性（`WEX*`），便于排错；
  加 `--release` 则关闭；
- 产物二进制 UUID：

```bash
dwarfdump --uuid out-edpkeep/WhateverXe.kext/Contents/MacOS/WhateverXe
```

## 6. 部署

```bash
diskutil mount disk0s1                      # 挂载 EFI
DST=/Volumes/EFI/EFI/OC/Kexts/WhateverXe.kext/Contents/MacOS/WhateverXe
sudo cp "$DST" "$DST.bak-$(date +%H%M%S)"   # 先备份
sudo cp ~/wex070/out-edpkeep/WhateverXe.kext/Contents/MacOS/WhateverXe "$DST"
sudo chown root:wheel "$DST" && sudo chmod 755 "$DST" && sudo xattr -cr "$DST"
```

同时确认 `config.plist` 的 boot-args 包含 `-wex-edp-keep`（内屏），
触摸板顺滑另需 `-vi2c-force-polling`。

## 7. 验证（重启后）

```bash
# 1. 运行中的驱动 UUID 必须等于刚部署文件的 UUID（防止改错引导盘！）
kextstat | grep WhateverXe
dwarfdump --uuid /Volumes/EFI/EFI/OC/Kexts/WhateverXe.kext/Contents/MacOS/WhateverXe

# 2. edp-keep 生效
ioreg -l | grep -o '"WEXEDPKeepReady" = [A-Za-z]*'

# 3. 无 modeset 失败
log show --last 5m --predicate 'process == "kernel"' | grep -c "Hardware mode set failed"
```

## 8. 血泪教训（务必读）

1. **多引导介质**：本机有内置 ESP + 两个 USB 救援盘共三套 OC。改 EFI 前先确认
   固件实际从哪个盘引导（比对运行中 kext 的 UUID 和磁盘文件 UUID），否则会出现
   “改动随机失效”的假象；
2. **不要在 processKext 阶段做 vtable 钩子**：我们试过在驱动加载早期替换
   AUX worker 的 vtable，两个版本都稳定卡死启动（dpcd10/dpcd11 事故），
   最终方案是上游补丁式的行为修改；
3. **edp-keep 的代价**：显示关闭 / 分辨率切换 / 睡眠会触发 complete modeset，
   内屏会黑到下次重启。本仓库的 config 主动禁用了睡眠。
