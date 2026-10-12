#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# 读取 Sources.json，根据触发方式解析出需要构建的 (源, profile) 矩阵。
# 每个源会浅克隆一次以枚举其 defconfig/ 目录，输出扁平的 JSON 数组供 GitHub Actions matrix.include 使用。
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile


def run(cmd, cwd=None):
    r = subprocess.run(
        cmd,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if r.returncode != 0:
        raise RuntimeError("cmd failed: %s\n%s" % (" ".join(cmd), r.stderr))
    return r.stdout


def parse_profiles_filter(raw):
    if raw is None:
        return []
    raw = raw.strip()
    if raw in ("", "*"):
        return []
    return [p.strip() for p in raw.replace(",", " ").split() if p.strip()]


def normalize_meta_defconfigs(defs):
    """规范化 Sources.json 中定义的 defconfig 列表。接受字符串、列表或元组。"""
    if defs is None:
        return []
    if isinstance(defs, str):
        items = defs.replace(",", " ").split()
    else:
        items = list(defs)

    out = []
    seen = set()
    for item in items:
        p = str(item).strip()
        if not p or p in seen:
            continue
        if p.endswith(".config"):
            p = p[:-len(".config")]
        seen.add(p)
        out.append(p)
    return out


def filter_profiles(profiles, cli_filter):
    if not profiles:
        return []
    wanted = set(parse_profiles_filter(cli_filter))
    if not wanted:
        return profiles
    return [p for p in profiles if p in wanted]


def list_defconfigs(repo, branch, profiles_filter):
    if not repo or not branch:
        return []
    tmp = tempfile.mkdtemp(prefix="cwrt-")
    try:
        run(
            [
                "git",
                "clone",
                "--depth=1",
                "--single-branch",
                "--branch",
                branch,
                "https://github.com/%s.git" % repo,
                tmp,
            ]
        )
        d = os.path.join(tmp, "defconfig")
        if not os.path.isdir(d):
            return []
        files = sorted(
            f[:-len(".config")] for f in os.listdir(d) if f.endswith(".config")
        )
        return filter_profiles(files, profiles_filter)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def resolve_profiles(meta, cli_profiles):
    if isinstance(meta, dict) and "defconfig" in meta and meta["defconfig"] not in (None, "", [], {}):
        profiles = normalize_meta_defconfigs(meta["defconfig"])
        return filter_profiles(profiles, cli_profiles)

    repo = meta.get("repo") if isinstance(meta, dict) else ""
    branch = meta.get("branch") if isinstance(meta, dict) else ""
    return list_defconfigs(repo, branch, cli_profiles)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sources-file", required=True)
    ap.add_argument("--mode", required=True, choices=["schedule", "dispatch"])
    ap.add_argument("--source", default="")
    ap.add_argument("--repo", default="")
    ap.add_argument("--branch", default="")
    ap.add_argument("--profiles", default="")
    args = ap.parse_args()

    with open(args.sources_file, encoding="utf-8") as f:
        sources = json.load(f)

    if args.mode == "schedule":
        targets = {
            k: v
            for k, v in sources.items()
            if isinstance(v, dict) and v.get("schedule", False)
        }
    else:
        if args.source == "custom":
            if not args.repo or not args.branch:
                print("custom requires --repo and --branch", file=sys.stderr)
                sys.exit(1)
            targets = {
                "custom": {
                    "repo": args.repo,
                    "branch": args.branch,
                    "overlay": "_default",
                    "theme": "aurora",
                }
            }
        else:
            if args.source not in sources:
                print("unknown source: %s" % args.source, file=sys.stderr)
                sys.exit(1)
            targets = {args.source: sources[args.source]}

    entries = []
    for key, meta in targets.items():
        profiles = resolve_profiles(meta, args.profiles)
        for profile in profiles:
            entries.append(
                {
                    "key": key,
                    "repo": meta.get("repo", ""),
                    "branch": meta.get("branch", ""),
                    "overlay": meta.get("overlay", "_default"),
                    "theme": meta.get("theme", "aurora"),
                    "profile": profile,
                }
            )

    print(json.dumps(entries, separators=(",", ":")))


if __name__ == "__main__":
    main()
