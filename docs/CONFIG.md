# 配置分层约定（CONFIG）

本框架对「固件默认配置」的核心策略是：**信任上游 `defconfig` 作为权威基底，覆盖层只放真实增量，用断言而非镜像来防御上游变化。**

## 0. 一句话原则

| 层级 | 负责什么 | 谁来定 |
|------|----------|--------|
| 基底（上游 defconfig） | 目标平台 / 子目标 / 设备 / 闭源驱动（MTK·WARP） | **上游**，我们不碰 |
| 通用覆盖层 `Config/Common.txt` | 源码无关的增项：luci 应用、通用 kmod、工具、构建开关 | 我们 |
| 源专属覆盖层 `Config/overlays/<source>.txt` | 仅该源需要的真实增量（加包 / 关项） | 我们 |
| 兜底 `Config/overlays/_default.txt` | 未知 / `custom` 源的兜底（通常空） | 我们 |

> ⚠️ **绝不在覆盖层里镜像上游的驱动配置**。镜像只会在上游改动时产生「静默分歧」或「被覆盖」，是与上游脱节的根源。

## 1. 构建时配置如何拼装

`WRT-CORE.yml` 的 `Custom Settings` 步骤：

```bash
cp "./defconfig/${WRT_CONFIG}.config" .config   # ① 上游基底
make defconfig
Scripts/BakePkgs.sh                              # ② 烘焙包：产出离线归档 + 依赖片段 baked-pkgs-deps.txt
# ③ 叠加覆盖层（通用 + 源专属 + 烘焙包依赖片段，存在时）
CAT_FRAGMENTS="$GITHUB_WORKSPACE/Config/Common.txt $OVERLAY_FILE"
[ -f "$GITHUB_WORKSPACE/Config/baked-pkgs-deps.txt" ] && \
  CAT_FRAGMENTS="$CAT_FRAGMENTS $GITHUB_WORKSPACE/Config/baked-pkgs-deps.txt"
cat $CAT_FRAGMENTS >> .config
Scripts/Settings.sh
make defconfig                                   # ④ 解析 + 清理
# ⑤ 配置漂移守卫（见 §4）
```

- `OVERLAY_FILE` 解析自 `WRT_OVERLAY`（由 `Sources.json` 的 `overlay` 字段提供），缺失时回退 `_default.txt`。
- `Config/baked-pkgs-deps.txt` 由 `BakePkgs.sh` 构建期生成（内容为 `CONFIG_PACKAGE_<dep>=y` 每行一个），与 `Common.txt`/覆盖层处于**同一配置层**，避免 `BakePkgs` 直接改 `.config` 带来的时序耦合。
- `make defconfig` 会丢弃未知符号、把依赖自动拉满，因此「上游已配好的驱动」无需我们重复声明。

## 2. 什么该放哪里

| 你想做的事 | 放哪里 |
|------------|--------|
| 换机型 / 改子目标 / 调闭源 WiFi 驱动行为 | **改上游 defconfig**（或提 PR 给上游），不要在我们仓库动 |
| 给所有源加一个 luci 应用 / 工具 / 通用 kmod | `Config/Common.txt`（`=y`） |
| 给某个源**专属**加包，或坚持关掉某上游默认项 | `Config/overlays/<source>.txt` |
| `custom` 源的特殊调整 | `Config/overlays/_default.txt` |
| 临时加 / 减包（不入库） | 手动触发填 `PACKAGE` 输入 |

## 3. 关键认知：MTK / WARP 驱动块是上游的地盘

实测对比（以 `mt7981-ax3000` 为样本）：

- **padavanonly**：overlay 228 项中有 218 项（95%）与上游 `defconfig` **完全一致**；其余多为 `kmod-ipt-*` 等会被防火墙依赖自动选入的包。
- **chasey**：多数项也与上游一致，未列出的 `kmod-ipt-*` / `iptables-mod-*` 同样是依赖自动拉入，MTK 特性开关在驱动 Kconfig 里 `default y`。

结论：闭源 MTK/WARP 驱动调优属于上游 defconfig，**我们不应复制它**。因此这两个 overlay 不再镜像 MTK/WARP 驱动块，只保留历史上「刻意与上游不同」的少量源专属 delta（其余驱动来自上游）：

- `overlays/chasey.txt`：关闭上游默认开启的 `MTK_MEMORY_SHRINK` / `MTK_MEMORY_SHRINK_AGGRESS` / `l1util`；强开上游默认关闭的 `MTK_BAND_STEERING`。
- `overlays/padavanonly.txt`：关闭上游在 mt7981 profile 默认开启的 `MTK_MEMORY_SHRINK` / `MTK_MEMORY_SHRINK_AGGRESS`（mt7986 该符号不存在，`is not set` 无害）。

> 其余 15 个「`# CONFIG_* is not set`」原本就在上游本身就是 `is not set`，属冗余，已正确删除。若未来确有一项仅某源需要的差异，再往对应 overlay 追加。

## 4. 如何应对上游变化（自动跟进 + 显式失败）

### 机制：自动跟进
- `resolve_matrix.py` 每次浅克隆枚举 `defconfig/*.config` → 上游**新增 / 删除机型**自动纳入或退出。
- `WRT-CORE` 按浮动分支克隆 → defconfig **内容变动**自动拿到最新。
- 缓存键含源码 commit 哈希 → 上游一推送新提交，缓存自动失效并滚动旧缓存重建。

### 风险：静态覆盖层不会跟变
- 上游把某包改名 → 我们 `=y` 被 `make defconfig` **静默丢弃**（不报错，只是功能消失）。
- 上游改了某个默认值，而我们用 `# CONFIG_X is not set` 写死关掉 → 一直被压着，你很难察觉。
- 上游 MTK 符号改名 / 改值 → 我们的强制值要么被忽略，要么覆盖上游意图。

### 防护：用断言而非镜像（WRT-CORE 守卫）
构建末尾执行两段检查，任何硬需求缺失都 **`::error::` + `exit 1`**，让构建显式失败，而非产出缺组件的异常固件：

1. **校验 Common.txt**：`Common.txt` 中每个 `CONFIG_*=y` 必须出现在最终 `.config`；否则说明该包上游已改名 / 移除 / 不在该源 feed 中。
2. **断言硬需求**：
   - 始终要求 `CONFIG_PACKAGE_luci=y`（LuCI 框架）。
   - 非 `nowifi` 的 profile 要求 `kmod-mt_wifi` / `kmod-warp` 存在（`=y` 或 `=m`）——上游若移除闭源 WiFi 支持会立即报错。
3. **校验烘焙包依赖**：`BakePkgs.sh` 生成的 `.cwrt-baked-deps` 中每个依赖（`CONFIG_PACKAGE_<dep>=y`）必须出现在最终 `.config`；拼写错误或该源 feed 无此包会立即报错，避免运行期缺失 `uclient-fetch` / `jsonfilter` 等导致安装静默失败。

> 守卫只校验源码无关的 `Common.txt` 与少量硬需求，**不会**因 `nowifi` 等无 WiFi profile 误伤驱动包。

## 5. 验证清单

- [ ] 跑 `WRT-TEST`（仅出 `.config` 不编译）对两个源各取一份 `.config` **存档**。
- [ ] 日后上游有变时 `diff` 历史 `.config`，一眼看出动了什么（机型 / 驱动 / 包）。
- [ ] 闭源加速 `kmod-mt_wifi` / `kmod-warp` 已编入——守卫已自动断言。
- [ ] 若守卫报错某包缺失：先确认是该源 feed 真没有（查 feeds），还是它只存在于某源 → 若是后者，把它从 `Common.txt` 移入对应 `overlays/<source>.txt`，保持 `Common` 真正源码无关。

## 6. 如何加一个真实增量（示例）

要给 `padavanonly` 专属加 `luci-app-xxx`：

1. 编辑 `Config/overlays/padavanonly.txt`，追加：
   ```bash
   CONFIG_PACKAGE_luci-app-xxx=y
   ```
2. **不要动**上游 defconfig，也**不要**放进 `Common.txt`（它不是全源通用）。
3. 跑 `WRT-TEST` 确认最终 `.config` 含该项；守卫会校验它通过。

## 7. 保留的全局评估（历史优化结论）

### 构建与全局

| 选项 | 取值 | 评估 |
|------|------|------|
| `CONFIG_CCACHE` | `y` | ✅ 大幅加速增量编译，必开 |
| `CONFIG_DEVEL` | `y` | ✅ 便于调试 / 符号，CI 可接受 |
| `CONFIG_TARGET_OPTIMIZE_ACFLAGS` | `y` | ✅ 针对目标架构优化编译参数，体积/性能双赢 |
| `CONFIG_TARGET_MULTI_PROFILE` | `y` | ✅ 单镜像多机型，符合「一包多设备」 |
| `CONFIG_TARGET_PER_DEVICE_ROOTFS` | `y` | ✅ 每设备独立 rootfs，避免功能膨胀 |
| `CONFIG_TARGET_ROOTFS_INITRAMFS` | `n` | ✅ MTK 路由无需 initramfs，关掉省空间 |
| `CONFIG_FEED_video` / `pon_*` | `n` | ✅ 路由不需要视频 / 光猫驱动，禁用加速 feeds |

### 代理 / 科学上网
- `luci-app-homeproxy` 在 `Common.txt` 中默认**关闭**（家庭主路由暂不需要，且 sing-box 核心体积庞大）；如需启用，在对应 overlay 覆盖为 `=y` 即可。

### 增值 luci 应用
默认启用：`autoreboot`、`gecoosac`、`mini-diskmanager`、`natmapt`、`partexp`、`samba4`、`upnp`、`wolultra`，以及 DNS 增强 `smartdns`（核心包 `smartdns` + `luci-app-smartdns`）。去广告由烘焙包 `adblock-lean` 负责（见 BakePkgs 机制），不再内置 `luci-app-adblock`。
默认移除：`attendedsysupgrade`、`wol`（避免与 `wolultra` 冲突 / 冗余）。

> 优化建议：插件越多体积越大。在嵌入式小闪存设备（如 256M / 128M 版）上，建议在该源的 `overlays/<source>.txt` 中对非必需插件显式 `=n`，配合 `PER_DEVICE_ROOTFS` 让每设备只装所需。

### 内核模块与通用组件
- 网络相关 `kmod-*`（nft / ipt / usb / storage / nvme 等）与工具类（`htop`、`smartmontools`、`iperf3`、`openssh-*` 等）为通用可维护性项，置于 `Common.txt`。

### 针对不同闪存容量的优化建议

| 场景 | 建议 |
|------|------|
| ≥1G NAND | 全量插件，体验优先 |
| 256M | `homeproxy` 已在 `Common.txt` 默认关闭；仍可 `=n` 掉其它大体积包，保留核心 |
| 128M / 小设备 | 仅保留 `PER_DEVICE_ROOTFS` + 必要 luci，禁用视频 / 多余 kmod |

## 8. 烘焙包机制（Baked Packages）

部分第三方工具不在 opkg feed 内、自带安装脚本（首个落地包：`adblock-lean`，dnsmasq 黑名单去广告）。它们无法用覆盖层 `=y` 直接编入，因此走通用「烘焙包」供给链路：

### 注册（`Config/baked-pkgs.json`）
每项含 `repo` / `branch` / `bake` / `deps`：
- `bake: true`（默认）：构建期把发行物浅克隆、剔 `.git`/`.github` 后压缩为 `files/usr/share/cwrt-pkgs/<pkg>/src.tar.gz`，作离线安全网。
- `bake: false`：纯在线，镜像不携带副本（体积最小），运行期直接从 raw 拉 installer。
- `deps`：运行时依赖（如 `uclient-fetch` / `jsonfilter` / `ca-bundle`），由 `BakePkgs.sh` 生成 `baked-pkgs-deps.txt` 并入配置层，并被漂移守卫校验。

### 构建期（`Scripts/BakePkgs.sh`）
浅克隆 → 剔 `.git`/`.github` → `tar -czf` 离线归档；同时生成 `Config/baked-pkgs-deps.txt`（依赖片段）与 `.cwrt-baked-deps`（校验清单）。**不**直接改 `.config`。

### 运行期（`files/usr/share/cwrt-pkgs/<pkg>/activate.sh` + `99_cwrt-activate-pkgs`）
- 首启动（`install`）：仅植入 WAN-up hotplug，真正安装留给 WAN 上线（此时才有网络）。
- WAN 上线（`activate`）：**在线优先**安装（重试 3 次拿最新版）→ 失败回退离线归档 → 都失败则打日志、下次 WAN-up 再试。
- 首启动若 WAN 已上线，直接补触发 `activate`，避免错过 `ifup` 事件。
- `start` 阶段用 `init status` 探测，已运行则跳过 `start`，避免 WAN 抖动时反复重拉 blocklist。
- `99_cwrt-activate-pkgs` 每次启动遍历执行各适配器（适配器自身幂等），失败时 `logger` 持久化。

> 新增一个烘焙包只需：在 `baked-pkgs.json` 加一项 + 提供 `activate.sh` 适配器；构建与激活由通用框架自动完成。
