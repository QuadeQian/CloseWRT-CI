#!/bin/bash
# SPDX-License-Identifier: MIT
#
# BakePkgs.sh — 构建期准备“烘焙”包。
#
# 烘焙包指自带安装脚本、不在 opkg feed 里的第三方工具。本脚本在构建时：
#   1. 浅克隆发行物 → 剔 .git/CI → 压缩为 files/usr/share/cwrt-pkgs/<pkg>/src.tar.gz（离线回退）
#   2. 生成 Config/baked-pkgs-deps.txt（运行时依赖片段，由 WRT-CORE 并入 .config）与 .cwrt-baked-deps（供漂移守卫校验）
# 运行时由 activate.sh 适配器优先在线安装（拿最新版），失败回退离线副本。
#
# 必须在 immortalwrt 构建树根目录（./wrt）下运行，依赖 $GITHUB_WORKSPACE 定位仓库。
set -euo pipefail

WS="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.." && pwd)}"
PKG_JSON="$WS/Config/baked-pkgs.json"
FILES_DIR="$WS/files"

[ -f "$PKG_JSON" ] || { echo "::notice::No baked-pkgs.json, skipping."; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "::error::python3 is required by BakePkgs.sh"; exit 1; }

mkdir -p "$FILES_DIR/usr/share/cwrt-pkgs"

python3 - "$PKG_JSON" "$FILES_DIR" <<'PY'
import json, os, subprocess, sys

pkg_json, files_dir = sys.argv[1:3]
with open(pkg_json) as f:
    data = json.load(f)

def run(cmd):
    print("+ " + " ".join(cmd))
    subprocess.run(cmd, check=True)

all_deps = []

for pkg, spec in data.items():
    if pkg.startswith("_"):
        continue
    repo = spec["repo"]
    branch = spec.get("branch", "master")

    adapter = os.path.join(files_dir, "usr/share/cwrt-pkgs", pkg, "activate.sh")
    if not os.path.exists(adapter):
        print(f"::error::Missing activate.sh adapter for baked pkg '{pkg}'")
        sys.exit(1)

    # bake: 是否把发行物克隆进镜像作为离线回退（默认 true）
    bake = bool(spec.get("bake", True))
    if bake:
        # 构建期：浅克隆 → 剔除 .git/CI → gzip 压缩成 gitless 归档存镜像，作离线回退
        # 运行时由 activate.sh 临时解压安装：镜像不带 .git、体积更小
        pkg_dir = os.path.join(files_dir, "usr/share/cwrt-pkgs", pkg)
        archive = os.path.join(pkg_dir, "src.tar.gz")
        work = os.path.join(pkg_dir, ".clone")
        old_src = os.path.join(pkg_dir, "src")
        for old in (work, old_src):  # 清理旧产物，避免混淆
            if os.path.exists(old):
                run(["rm", "-rf", old])
        run(["git", "clone", "--depth=1", "--single-branch", "--branch", branch,
             f"https://github.com/{repo}.git", work])
        for junk in (".git", ".github"):  # 剔除运行时无用的元数据/CI 目录
            jp = os.path.join(work, junk)
            if os.path.exists(jp):
                run(["rm", "-rf", jp])
        if os.path.exists(archive):
            os.remove(archive)
        run(["tar", "-czf", archive, "-C", work, "."])  # gzip：busybox tar 原生支持 -z 解压
        run(["rm", "-rf", work])
        print(f"Baked pkg '{pkg}': dist archived (gitless, compressed) -> {archive}")
    else:
        print(f"Baked pkg '{pkg}': bake disabled, online-only install at runtime.")

    # 收集运行时依赖；统一在循环结束后写入依赖片段（Config/baked-pkgs-deps.txt），
    # 由 WRT-CORE 在 cat 阶段并入 .config（与 Common.txt/覆盖层同一配置层），
    # 不再直接改 .config，避免与 Settings.sh / 最终 make defconfig 的时序耦合。
    all_deps.extend(spec.get("deps", []))
    print(f"Baked pkg '{pkg}' prepared (deps: {' '.join(spec.get('deps', [])) or 'none'}).")

# 依赖片段：写入 Config/baked-pkgs-deps.txt（每行一个 CONFIG_PACKAGE_<dep>=y），
# 作为统一配置层的一部分由 WRT-CORE 并入 .config；同时写 .cwrt-baked-deps 供漂移守卫校验。
config_dir = os.path.dirname(files_dir)  # $WS
frag = os.path.join(config_dir, "Config", "baked-pkgs-deps.txt")
if all_deps:
    with open(frag, "w") as f:
        for dep in all_deps:
            f.write(f"CONFIG_PACKAGE_{dep}=y\n")
    with open(".cwrt-baked-deps", "w") as d:
        for dep in all_deps:
            d.write(dep + "\n")
    print(f"Baked deps fragment written: {len(all_deps)} entries -> {frag}")
else:
    if os.path.exists(frag):
        os.remove(frag)

print("BakePkgs done.")
PY
