# Changelog

本文件记录 CloseWRT-CI 的显著变更。日期以本地提交/评审时间为准。

## 2026-10-11

### 新增：烘焙包（Baked Packages）子系统
面向「不在 opkg feed 内、自带安装脚本的第三方工具」的通用供给机制，首个落地包为 `adblock-lean`（去广告，走 dnsmasq 黑名单）。

- **`Config/baked-pkgs.json`**：烘焙包注册表，每项含 `repo` / `branch` / `bake` / `deps`。
- **`Scripts/BakePkgs.sh`**：
  - 构建期浅克隆发行物 → 剔 `.git`/`.github` → `tar -czf` 为 `files/usr/share/cwrt-pkgs/<pkg>/src.tar.gz`（gitless 离线归档）。
  - 生成 `Config/baked-pkgs-deps.txt`（运行时依赖片段，并入统一配置层）与 `.cwrt-baked-deps`（供漂移守卫校验）。
  - **不再直接改 `.config`**，依赖片段由 `WRT-CORE.yml` 在 `cat` 阶段与 `Common.txt`/覆盖层一并并入，消除与 `Settings.sh`/最终 `make defconfig` 的时序耦合。
- **`files/usr/share/cwrt-pkgs/<pkg>/activate.sh`** 适配器（在线优先 + 离线兜底）：
  - 首启动仅植入 WAN-up hotplug（`install` 阶段不装任何东西，此时无网络）。
  - WAN 上线执行 `activate`：优先在线安装（重试 3 次拿最新版）→ 失败回退镜像内归档（离线 `-s`）→ 都失败则打日志、下次 WAN-up 再试。
  - 首启动若 WAN 已上线（`ubus` 探测），直接补触发 `activate`，避免错过 `ifup` 事件。
  - `start` 阶段用 `init status` 探测，**已运行则跳过** `start`，避免 WAN 抖动时反复重拉 blocklist；进程崩溃后由 `status` 检测自动重启。
- **`bake` 开关**：`true`（默认）= 烘焙归档作离线安全网；`false` = 纯在线（运行时从 raw 拉 installer，镜像不带副本）。
- **`files/etc/uci-defaults/99_cwrt-activate-pkgs`**：每次启动遍历 `<pkg>/activate.sh` 执行（适配器自身幂等），失败时 `logger` 持久化便于排查。**刻意不自我删除**（sysupgrade 保留 `/etc` 时自我删除会导致新烘焙包 hotplug 不被植入）。
- **配置漂移守卫**扩展：在最终 `make defconfig` 之后，除校验 `Common.txt` 与硬需求外，额外校验 `.cwrt-baked-deps` 中全部烘焙包依赖均生效。

### 调整：默认包配置（Common.txt）
- `luci-app-homeproxy`：**默认关闭**（不进固件）；需用时在对应 overlay 覆盖 `=y`。
- `smartdns` + `luci-app-smartdns`：**默认启用**（DNS 加速/防污染）；运行期链路配置（接上游解析器、与 dnsmasq 联动）交由运行期处理。
- 去广告统一由烘焙包 `adblock-lean` 负责，**移除** `luci-app-adblock`（避免与 adblock-lean 在 dnsmasq 层重复）。

### 工程
- 新增根 `.gitignore`，忽略 `BakePkgs.sh` 生成的派生文件（`.cwrt-baked-deps`、`Config/baked-pkgs-deps.txt`）。
- 烘焙包注册表移除 `min_ram_mb` / `min_rom_kb` / `needs_network_at_start` / `preset` 等早期门控字段——当前包体积都很小，不做安装期资源门控，失败处理交给「在线优先 + 离线兜底 + 重试」。

### 文档
- `README.md` / `ARCHITECTURE.md` / `CONFIG.md` 补充烘焙包子系统说明与更新后的构建拼装流程。
