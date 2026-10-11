# 架构说明（ARCHITECTURE）

本框架把「编译某个 owrt 项目」拆成 **通用引擎 + 源注册表 + 覆盖层** 三层，使逻辑可复用于任意含 `defconfig/` 目录的项目。

## 1. 调用关系

```
CWRT-chasey.yml ─┐
CWRT-padavanonly.yml ─┤
        (手动)         ├─► CWRT-BUILD.yml ──► resolve 任务 ──► build 矩阵 ──► WRT-CORE.yml
CWRT-BUILD.yml ─┘                                           (每个 源×profile 一项)
WRT-TEST.yml ─────────────────────────────────────────────────────► WRT-CORE.yml
```

- `WRT-CORE.yml`：**唯一真正编译的核心**，完全由输入参数驱动，不含任何具体源信息。
- `CWRT-BUILD.yml`：**通用引擎**。读 `Sources.json` + `resolve_matrix.py` 生成 `(源, profile)` 矩阵，再对每项调用 `WRT-CORE`。
- `CWRT-chasey.yml` / `CWRT-padavanonly.yml`：仅做参数预设的薄封装，方便一键触发。
- `WRT-TEST.yml`：单 profile 调试，只出 `.config` 不编译。

## 2. 矩阵如何生成（resolve_matrix.py）

1. 根据触发方式决定目标源集合：
   - `schedule`：取 `Sources.json` 中 `schedule=true` 的全部源。
   - `dispatch`：`SOURCE=chasey|padavanonly` 取对应项；`SOURCE=custom` 用输入的 `REPO`/`BRANCH`（覆盖层 `_default`）。
2. 对每个目标源**浅克隆一次**，列出 `defconfig/*.config`，按 `PROFILES` 过滤（留空=全部）。
3. 输出扁平 JSON 数组，每项含 `{key, repo, branch, overlay, theme, profile}`。
4. `build` 任务用 `matrix.include` 消费该数组，每项调用 `WRT-CORE`。

> 浅克隆只为枚举目录，真正的全量克隆发生在 `WRT-CORE` 内（缓存命中时极快）。

## 3. 覆盖层解析（overlay）

`WRT-CORE` 的 `Custom Settings` 步骤：

```bash
OVERLAY_FILE="Config/overlays/${WRT_OVERLAY}.txt"
[ -f "$OVERLAY_FILE" ] || OVERLAY_FILE="Config/overlays/_default.txt"
cp "./defconfig/${WRT_CONFIG}.config" .config   # ① 上游基底（target/设备/闭源驱动全由它定）
make defconfig
Scripts/BakePkgs.sh                              # ② 烘焙包：产出离线归档 + 依赖片段
# ③ 叠加覆盖层：通用 + 源专属 + 烘焙包依赖片段（存在时）
CAT_FRAGMENTS="Config/Common.txt $OVERLAY_FILE"
[ -f Config/baked-pkgs-deps.txt ] && CAT_FRAGMENTS="$CAT_FRAGMENTS Config/baked-pkgs-deps.txt"
cat $CAT_FRAGMENTS >> .config
Scripts/Settings.sh
make defconfig
# ④ 配置漂移守卫：校验 Common.txt 生效 + 烘焙包依赖 + 断言硬需求（LuCI / 闭源 WiFi 驱动）
```

- `Common.txt`：所有源共享的**源码无关**调优（luci 应用、通用 kmod、工具、构建开关）。
- `baked-pkgs-deps.txt`：`BakePkgs.sh` 构建期生成的**烘焙包依赖片段**（内容为 `CONFIG_PACKAGE_<dep>=y`，每行一个），与 `Common.txt`/覆盖层同层并入；其依赖若上游无此包或拼写错误，会被漂移守卫显式捕获。
- `overlays/<source>.txt`：仅该源需要的**真实增量**（如某源专属包、要坚持关掉的上游默认项）。`chasey` / `padavanonly` 目前仅含各自「刻意与上游不同」的少量 delta（如关闭 `MTK_MEMORY_SHRINK`、chasey 强开 `BAND_STEERING`），闭源 MTK/WARP 驱动配置仍完全来自上游 defconfig，不应在此镜像。
- `_default.txt`：未知 / `custom` 源的兜底（通常为空，因为 `Common.txt` 已覆盖通用项）。

> 设计要点：**基底 = 上游 defconfig（单一真相源）**，覆盖层只放增量，用「断言」而非「镜像」来防御上游变化。详见 `docs/CONFIG.md`。

## 4. 缓存键

缓存键由 `源 / 分支 / 目标平台 / 提交哈希` 组成：

```
wrt-<SOURCE>-<BRANCH>-<TARGET>-<SUBTARGET>-<COMMIT>
```

`TARGET`/`SUBTARGET` 在 `Clone Code` 步骤从 `defconfig/<profile>.config` 解析，保证同平台跨 profile 复用工具链缓存；提交变化时自动失效并滚动旧缓存（见 `cache-rollover` 任务）。

## 5. 扩展点

| 需求 | 改哪里 |
|------|--------|
| 新增一个 owrt 项目 | `Sources.json` 加一项 + `Config/overlays/<key>.txt` |
| 调整全部源的公共配置 | `Config/Common.txt` |
| 调整某源特有项 | `Config/overlays/<key>.txt` |
| 新增一个第三方安装器类工具（如 adblock-lean） | `Config/baked-pkgs.json` 加一项 + `files/usr/share/cwrt-pkgs/<pkg>/activate.sh` 适配器 |
| 临时加/减包 | 手动触发填 `PACKAGE` |
| 改默认主题/IP/密码 | 各工作流 `with:` 或 `Settings.sh` |

## 6. 烘焙包（Baked Packages）

某些第三方工具**不在 opkg feed 内、自带安装脚本**（如 `adblock-lean`），无法用覆盖层 `=y` 编入固件。框架用通用「烘焙包」机制供给它们，与「配置层（§3）」「矩阵（§2）」正交，是一套独立的供给链路。

### 角色拆分
- **注册表 `Config/baked-pkgs.json`**：声明每个烘焙包的 `repo` / `branch` / `bake` / `deps`，是构建与运行期的单一事实来源。
- **构建期 `Scripts/BakePkgs.sh`**：
  - 浅克隆发行物 → 剔 `.git`/`.github` → `tar -czf` 为 `files/usr/share/cwrt-pkgs/<pkg>/src.tar.gz`（gitless 离线归档，busybox `tar -z` 原生可解）。
  - 生成 `Config/baked-pkgs-deps.txt` 依赖片段（并入 §3 配置层）与 `.cwrt-baked-deps` 校验清单。
  - **不直接改 `.config`**，依赖片段由 `WRT-CORE` 在 `cat` 阶段与 `Common.txt`/覆盖层一并并入，避免时序耦合。
- **运行期 `activate.sh` 适配器 + `99_cwrt-activate-pkgs`**：适配器自包含「在线优先安装 + 离线兜底 + WAN-up 触发 + 幂等」逻辑；通用激活器每次启动遍历执行，失败时 `logger` 持久化。

### 两种形态（由 `bake` 开关控制）
- `bake: true`（默认）：构建期烘焙离线归档作安全网，运行期先在线拿最新、失败回退离线。
- `bake: false`：纯在线，镜像不携带副本（体积最小），运行期直接从 raw 拉 installer。

### 为什么放在运行期而非编译期
- 工具可随上游滚动拿最新版；离线归档只作「GitHub 不可达」时的兜底。
- 安装需要网络与设备态（WAN 上线、按 RAM 选预设），更适合首启动后的 WAN-up 钩子执行。
- 固件镜像保持精简，第三方工具的发行物不进入 squashfs 常驻（仅在 `bake:true` 时带一份离线副本）。

详见 `docs/CONFIG.md` §8 与 `Config/baked-pkgs.json`。
