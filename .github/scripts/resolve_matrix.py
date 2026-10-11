#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# 读取 Sources.json，根据触发方式解析出需要构建的 (源, profile) 矩阵。
# 每个源会浅克隆一次以枚举其 defconfig/ 目录，输出扁平的 JSON 数组供 GitHub Actions matrix.include 使用。
import json
import os
import sys
import shutil
import subprocess
import tempfile
import argparse


def run(cmd, cwd=None):
    r = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, text=True)
    if r.returncode != 0:
        raise RuntimeError("cmd failed: %s\n%s" % (" ".join(cmd), r.stderr))
    return r.stdout


def list_defconfigs(repo, branch, profiles_filter):
    tmp = tempfile.mkdtemp(prefix="cwrt-")
    try:
        run(["git", "clone", "--depth=1", "--single-branch",
             "--branch", branch, "https://github.com/%s.git" % repo, tmp])
        d = os.path.join(tmp, "defconfig")
        if not os.path.isdir(d):
            return []
        files = sorted(
            f[:-len(".config")] for f in os.listdir(d) if f.endswith(".config")
        )
        if profiles_filter and profiles_filter.strip() not in ("*", ""):
            wanted = {p.strip() for p in profiles_filter.replace(",", " ").split() if p.strip()}
            files = [f for f in files if f in wanted]
        return files
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sources-file", required=True)
    ap.add_argument("--mode", required=True, choices=["schedule", "dispatch"])
    ap.add_argument("--source", default="")
    ap.add_argument("--repo", default="")
    ap.add_argument("--branch", default="")
    ap.add_argument("--profiles", default="")
    args = ap.parse_args()

    with open(args.sources_file) as f:
        sources = json.load(f)

    if args.mode == "schedule":
        targets = {k: v for k, v in sources.items()
                   if isinstance(v, dict) and v.get("schedule", False)}
    else:
        if args.source == "custom":
            if not args.repo or not args.branch:
                print("custom requires --repo and --branch", file=sys.stderr)
                sys.exit(1)
            targets = {"custom": {
                "repo": args.repo, "branch": args.branch,
                "overlay": "_default", "theme": "aurora"}}
        else:
            if args.source not in sources:
                print("unknown source: %s" % args.source, file=sys.stderr)
                sys.exit(1)
            targets = {args.source: sources[args.source]}

    entries = []
    for key, meta in targets.items():
        profiles = list_defconfigs(meta["repo"], meta["branch"], args.profiles)
        for p in profiles:
            entries.append({
                "key": key,
                "repo": meta["repo"],
                "branch": meta["branch"],
                "overlay": meta.get("overlay", "_default"),
                "theme": meta.get("theme", "aurora"),
                "profile": p,
            })

    print(json.dumps(entries))


if __name__ == "__main__":
    main()
