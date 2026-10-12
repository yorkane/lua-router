#!/usr/bin/env python3
"""README〈文档索引〉表的完整性检查（双向）。

用法：python3 script/check_docs_index.py [仓库根目录]（缺省 = 脚本所在目录的上一级）

口径：README.md 的「## 文档索引」小节里那张表是本仓**唯一完整**的文档索引，
doc/ 下每一份文件各占一行。检查是双向的，刻意不写「表内行数 == ls doc/ 计数」
这种计数对计数的判据——漏收一份同时多收一份会互相抵消，那样检不出来。

  盘上有、表内没有 -> 漏收，退出 1
  表内有、盘上没有 -> 断链（已删除/改名的文档还留在索引里），退出 1

新增/移动文档只改 README 那张表，然后跑本脚本确认两边对齐。
"""
import os
import re
import sys

root = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
readme = os.path.join(root, "README.md")
docdir = os.path.join(root, "doc")


def die(msg, items):
    print("FAIL: " + msg)
    for x in sorted(items):
        print("  - " + x)
    sys.exit(1)


if not os.path.isfile(readme):
    die("找不到 README.md: " + readme, [])
if not os.path.isdir(docdir):
    die("找不到 doc/ 目录: " + docdir, [])

LINK = re.compile(r"\[([^\]]*)\]\(([^)]+)\)")

rows = []
inside = False
for line in open(readme, encoding="utf-8").read().splitlines():
    if line.startswith("## "):
        inside = line.startswith("## 文档索引")
        continue
    if not inside or not line.startswith("|"):
        continue
    for m in LINK.finditer(line):
        tgt = m.group(2).strip().split("#")[0]
        if tgt:
            rows.append(tgt)

if not rows:
    die("README〈文档索引〉表里一条链接都没解析到（表被改坏，或小标题改了名）", [])

listed = set()
for tgt in rows:
    if tgt.startswith(("http://", "https://", "mailto:", "codex://")):
        continue
    full = os.path.normpath(os.path.join(root, tgt))
    listed.add(os.path.relpath(full, root).replace(os.sep, "/"))

on_disk = set()
for base, _dirs, files in os.walk(docdir):
    for f in files:
        rel = os.path.relpath(os.path.join(base, f), root).replace(os.sep, "/")
        on_disk.add(rel)

missing = on_disk - listed
broken = set(p for p in listed if not os.path.isfile(os.path.join(root, p)))

if missing:
    die("doc/ 里有 " + str(len(missing)) + " 份文件没进 README〈文档索引〉表（漏收）", missing)
if broken:
    die("README〈文档索引〉表里有 " + str(len(broken)) + " 条链接指向盘上不存在的文件（断链）", broken)

print("ok: doc/ 的 " + str(len(on_disk)) + " 份文件与 README〈文档索引〉表逐份对齐；表内 " + str(len(listed)) + " 条目标全部存在")

