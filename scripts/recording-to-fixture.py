#!/usr/bin/env python3
"""将游戏回放转换为可入库的离线 fixture.

只保留开局参数, 解锁快照和规则动作, 不复制 profile, 设置, 解说或其它代理数据.
手动 press/reorder 保持原样, 统一交给 engine 的回放适配器解释.
不丢弃未知规则动作, 不改写 digest, 不忽略金钱差异.
"""

import argparse
import json
from pathlib import Path


def main(src, dst, *, limit=None):
    source = Path(src)
    with source.open(encoding="utf-8") as stream:
        recording = json.load(stream)
    run = recording.get("run") or {}
    if run.get("resumed") or run.get("tutorial"):
        raise ValueError("教程局和中途读档局无法从普通开局重建")
    snapshot = recording.get("snapshot") or {}
    if not isinstance(snapshot.get("uda"), dict):
        raise ValueError("缺少原局 snapshot.uda, 不能猜测解锁进度")
    header = {
        "seed": run["seed"],
        "deck": run["deck"],
        "stake": run["stake"],
        "uda": snapshot["uda"],
        "source": source.name,
    }
    output = [json.dumps(header, ensure_ascii=False)]
    skipped = 0
    for index, action in enumerate(recording.get("actions") or [], 1):
        if action.get("method") in ("notify", "menu", "continue", "endless"):
            skipped += 1
            continue
        record = {"method": action["method"], "source_index": index}
        params = {key: value for key, value in (action.get("params") or {}).items() if key != "reason"}
        if params:
            record["params"] = params
        if action.get("digest"):
            record["digest"] = action["digest"]
        if "ok" in action:
            record["ok"] = action["ok"]
        output.append(json.dumps(record, ensure_ascii=False))
        if limit is not None and len(output) - 1 >= limit:
            break
    destination = Path(dst)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text("\n".join(output) + "\n", encoding="utf-8")
    print(f"{destination.name}: {len(output) - 1} 个规则动作, 跳过 {skipped} 个观察或界面动作")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", help="游戏 .replay.json")
    parser.add_argument("destination", help="输出 fixture.jsonl")
    parser.add_argument("--limit", type=int, help="仅截取明确数量的规则动作")
    arguments = parser.parse_args()
    if arguments.limit is not None and arguments.limit < 1:
        parser.error("--limit 必须为正整数")
    main(arguments.source, arguments.destination, limit=arguments.limit)
