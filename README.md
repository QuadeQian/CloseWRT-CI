# CloseWRT-CI

一个可复用的 OpenWrt 固件云编译框架，专注于**带 `defconfig` 目录的 MTK 798x 闭源 SDK 项目**。核心特性：

- **多源支持**：任意含 `defconfig/` 目录的 owrt 项目都能编译，只需在 `Sources.json` 注册。
- **defconfig 基底 + 覆盖层**：每个机型 profile 以上游 `defconfig/<profile>.config` 为基底，再叠加自定义覆盖层（源码无关 `Common.txt` + 各源专属 `overlays/<source>.txt`），不重复定义闭源驱动。
- **动态全编**：自动枚举所选源 `defconfig/` 下所有机型并矩阵构建。
- **按源优化**：各上游的 MTK/WARP 闭源驱动与默认配置由上游维护，我们只在覆盖层做增量调优。

## 快速开始

- 想编译某个已注册源：手动触发 `CWRT-chasey` 或 `CWRT-padavanonly`（留空 `PROFILES` 即全编，也可限定某几个 profile）。
- 想编译任意其它 owrt 项目：手动触发 `CWRT-BUILD`，`SOURCE` 选 `custom` 并填 `REPO`/`BRANCH`。
- 只想要配置不编译：触发 `WRT-TEST`，选 `SOURCE` + `PROFILE`，产物为 `.config`。
- 每周一早 5 点：`CWRT-BUILD` 自动全编 `Sources.json` 中 `schedule=true` 的源。

## 目录结构

```
CloseWRT-CI/
├── Sources.json                 # 已知可编译源注册表（增删源只改这里）
├── Config/
│   ├── Common.txt              # 源码无关通用覆盖层（公共调优）
│   ├── baked-pkgs.json         # 烘焙包注册表（第三方安装器类工具，如 adblock-lean）
│   ├── baked-pkgs-deps.txt     # 由 BakePkgs.sh 生成的依赖片段（构建期派生，已 gitignore）
│   └── overlays/
│       ├── chasey.txt          # chasey 源专属覆盖层
│       ├── padavanonly.txt     # padavanonly 源专属覆盖层
│       └── _default.txt        # 兜底覆盖层（自定义/未知源）
├── Scripts/
│   ├── Settings.sh             # 主题/IP/SSID 注入 + 私有扩展
│   ├── Handles.sh              # 源码树补丁
│   ├── Packages.sh             # 第三方包安装/更新
│   └── BakePkgs.sh             # 构建期准备烘焙包（离线归档 + 依赖片段）
├── files/
│   ├── etc/uci-defaults/99_cwrt-activate-pkgs   # 首启动/每次启动发现并执行各烘焙包适配器
│   └── usr/share/cwrt-pkgs/<pkg>/
│       ├── activate.sh         # 该包适配器（在线优先安装 + 离线兜底 + WAN-up 触发）
│       └── src.tar.gz          # 构建期烘焙的 gitless 压缩归档（离线回退，bake:true 时）
├── .github/
│   ├── scripts/resolve_matrix.py  # 解析 (源,profile) 构建矩阵
│   └── workflows/
│       ├── WRT-CORE.yml        # 公用编译核心（基底+覆盖层逻辑）
│       ├── CWRT-BUILD.yml      # 通用引擎（读取 Sources.json，支持 custom）
│       ├── CWRT-chasey.yml     # chasey 便捷封装
│       ├── CWRT-padavanonly.yml# padavanonly 便捷封装
│       ├── WRT-TEST.yml        # 单 profile 调试
│       └── Cache-Clean.yml     # 清理缓存
└── docs/
    ├── ARCHITECTURE.md         # 框架工作原理
    ├── CONFIG.md               # 默认配置方案评估与优化
    └── SOURCES.md              # 如何新增一个源
```

## 构建原理（简述）

```
clone 上游 → 以 defconfig/<profile>.config 为基底
  → make defconfig
  → Scripts/BakePkgs.sh（烘焙包：产出离线归档 + 依赖片段 baked-pkgs-deps.txt）
  → 叠加 Config/Common.txt + Config/overlays/<source>.txt + Config/baked-pkgs-deps.txt
  → Scripts/Settings.sh（主题/IP/SSID/私有扩展）
  → make defconfig → 配置漂移守卫 → 编译
```

因两上游的 `defconfig` 已内置完整 MTK/WARP 闭源驱动，覆盖层只做**增量叠加**。

## 烘焙包（Baked Packages）

部分第三方工具不在 opkg feed 内、自带安装脚本（如 `adblock-lean`）。本框架用通用「烘焙包」机制供给它们：

- **构建期**（`BakePkgs.sh`）：把发行物浅克隆、剔 `.git` 后压缩为 `src.tar.gz` 作离线回退，并生成依赖片段并入配置。
- **运行期**（`activate.sh` + `99_cwrt-activate-pkgs`）：首启动植入 WAN-up hotplug，WAN 上线后在线优先安装（拿最新版）、失败回退离线归档，全程幂等、可重试。

详见 `docs/ARCHITECTURE.md` §6 与 `Config/baked-pkgs.json`。

## 已知源

| key | repo | branch | 说明 |
|-----|------|--------|------|
| `chasey` | chasey-dev/immortalwrt-mt798x-rebase | `25.12` | 新版 rebase，子目标 `mediatek/filogic` |
| `padavanonly` | Yuzhii0718/immortalwrt-mt798x-6.6-padavanonly | `openwrt-24.10-6.6` | 6.6 内核 padavanonly 闭源 WiFi |

## 自定义

- 公共插件/组件/内核模块/驱动调优 → 编辑 `Config/Common.txt`
- 某源专属差异 → 编辑对应 `Config/overlays/<source>.txt`
- 私有配置 → 放 `Config/PRIVATE.txt`（若存在自动生效）
- 临时增删包 → 手动触发时填 `PACKAGE`（`\n` 分隔）

## 相关链接

- 本地编译器：https://github.com/VIKINGYFY/OWRT-Tools.git
- 自用修改版插件：https://github.com/VIKINGYFY/packages.git
- UBOOT：https://github.com/VIKINGYFY/UBOOT-CI/releases

#
[![Stargazers over time](https://starchart.cc/VIKINGYFY/CloseWRT-CI.svg?variant=adaptive)](https://starchart.cc/VIKINGYFY/CloseWRT-CI)
