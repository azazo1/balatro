#!/usr/bin/env python3
"""把录像的 .replay.json 转成对拍用的 fixture.

用法 (在仓库根目录):

```shell
for f in recordings/*/*.replay.json; do
  d=$(echo "$f" | sed 's|recordings/||;s|/.*||')
  python3 scripts/recording-to-fixture.py "$f" "engine/tests/data/rec-$d.jsonl"
done
```

生成结果是 `engine/tests/data/rec-*.jsonl`, 由 `engine/tests/dump_replay.rs` 的
`every_recorded_run_replays_step_by_step` 逐步对拍. 录像本身不入库 (二进制与体积原因),
所以要靠这个脚本重新生成 —— 换了新的录像之后照上面那样跑一遍即可.


格式 (每行一个 JSON):
- 第一行是头部: {"seed", "deck", "stake", "source"}
- 之后每行是一个动作: {"method", "params"?, "digest"?, "ok"}

# `ok` 为什么必须留着

一份真实录像里**本来就包含失败的尝试** —— bot 试了一下, 游戏拒绝了 (选中张数不对, 槽位满了,
状态不允许...). 这些步骤在录像里 `ok: false` 且**没有 digest**.

少了这个字段, 对拍器会要求每一步都成功, 于是把"引擎正确地拒绝了"当成差异 ——
第一版就是这样: 18 份里报了 5 宗, 其中 4 宗全是这种假警报 (游戏自己也没成功).

# `press` 要按 `area` 折算

`press` 是"按了某个按钮", 同一个 `fn` 在不同 `area` 上可能是完全不同的事:
`use_card` 在 `pack_cards` 上是"从包里取出来用掉", 在 `consumeables` 上是"用掉手上那张".
第一版只按 `fn` 折, 就把后者也当成了取包.
"""
import json
import sys


def translate(params):
    """按 (fn, area) 折算成对拍器认的方法名与参数."""
    fn = params.get("fn")
    area = params.get("area")
    if fn == "use_card" and area == "pack_cards":
        # **`targets` 一定要带上**: 塔罗要指定手牌目标, 少了它引擎会按"空目标"处理 ——
        # 于是要么报错, 要么把效果落到别的牌上 (第一版就是这么丢的).
        out = {"card": params.get("index", 0)}
        if params.get("targets"):
            out["targets"] = params["targets"]
        return "pack", out
    if fn == "use_card" and area == "consumeables":
        out = {"consumable": params.get("index", 0)}
        if params.get("targets"):
            out["targets"] = params["targets"]
        return "use", out
    if fn == "buy_from_shop":
        # 商店那一格买东西: 对拍器认的是 `buy {card: 下标}`.
        # 但那一格若是"买并使用"按钮 (`buy_and_use`), 走的是另一条规矩 ——
        # 买下来当场用掉, 不占消耗牌格子. 折成 `buy` 会去槽位检查, 于是"槽满买不成".
        if params.get("id") == "buy_and_use":
            return "buy_and_use", {"card": params.get("index", 0)}
        return "buy", {"card": params.get("index", 0)}
    if fn in ("sort_hand_value", "sort_hand_suit"):
        return fn, None
    return None, None


def main(src, dst, *, limit=None):
    j = json.load(open(src))
    run = j.get("run") or {}
    header = {
        "seed": run.get("seed"),
        "deck": run.get("deck"),
        "stake": run.get("stake"),
        "source": src.split("/")[-1],
    }
    out = [json.dumps(header, ensure_ascii=False)]
    skipped = []
    for a in j.get("actions") or []:
        method = a.get("method")
        params = dict(a.get("params") or {})
        if method == "press":
            method, params = translate(params)
            if method is None:
                skipped.append(("press", a.get("params", {}).get("fn")))
                continue
            params = params or {}
        if method == "menu":
            # 回主菜单只是结束录像, 与对局本身无关.
            skipped.append(("menu", None))
            continue
        rec = {"method": method}
        if params:
            rec["params"] = params
        if a.get("digest"):
            rec["digest"] = a["digest"]
        # 游戏自己没成功的步骤要标出来: 它们没有 digest, 而且**引擎也该拒绝**.
        rec["ok"] = bool(a.get("ok"))
        out.append(json.dumps(rec, ensure_ascii=False))
        if limit and len(out) > limit:
            break
    open(dst, "w").write("\n".join(out) + "\n")
    print(f"{dst}: {len(out)-1} 步 (跳过 {len(skipped)} 步: {sorted(set(skipped))})")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
