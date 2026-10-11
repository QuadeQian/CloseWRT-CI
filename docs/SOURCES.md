# 如何新增一个可编译的源（SOURCES）

本框架支持**任意含 `defconfig/` 目录的 owrt 项目**。新增一个源只需两步，无需改工作流代码。

## 第 1 步：在 `Sources.json` 注册

```json
{
  "my-source": {
    "repo": "owner/repo",
    "branch": "main",
    "overlay": "my-source",
    "theme": "argon",
    "schedule": false,
    "note": "一句话说明这个源"
  }
}
```

字段含义：

| 字段 | 说明 |
|------|------|
| `repo` | `owner/repo`（脚本会自动拼 `https://github.com/...`） |
| `branch` | 要编译的分支 |
| `overlay` | 覆盖层文件名（对应 `Config/overlays/<overlay>.txt`） |
| `theme` | 默认主题（需被 `Packages.sh` 安装） |
| `schedule` | `true` 则每周自动全编；`false` 仅手动 |

## 第 2 步：提供覆盖层

创建 `Config/overlays/my-source.txt`，放该源**专属**的差异项（通用项已在 `Common.txt`）。
若没有专属差异，可让 `overlay` 指向已有的 `_default.txt`，或新建一个空文件（仅注释即可）。

```bash
# Config/overlays/my-source.txt
# owner/repo 专属调整
# CONFIG_PACKAGE_luci-app-foo=y
```

## 第 3 步：触发

- 通用引擎：`CWRT-BUILD` → `SOURCE=my-source`（或 `custom` + 手填 `REPO`/`BRANCH`）。
- 便捷封装：复制 `CWRT-chasey.yml` 改成你的源 key 即可。
- 自动编译：把 `schedule` 设为 `true`，每周一会全编该源所有 `defconfig`。

## 约定与排错

- **覆盖层只增不减**：优先在 `Common.txt` 放通用项；源专属的「禁用上游默认」项放到本源覆盖层。
- **profile 名即文件名**：`defconfig/foo.config` 对应 `WRT_CONFIG=foo`，无需在 `Sources.json` 列出机型。
- **无 `defconfig/` 目录**：`WRT-CORE` 会检测并安全退出该 profile。
- **自定义源**：`SOURCE=custom` + `REPO`/`BRANCH`，覆盖层固定 `_default`（即只用 `Common.txt`）。
- 验证配置可用 `WRT-TEST`（`SOURCE=my-source`, `PROFILE=foo`）先导出 `.config` 检查。
