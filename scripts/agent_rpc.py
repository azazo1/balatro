"""调用 mod 版的 agent 接口: 一次调用, 或轮询等游戏进入某个状态.

    python3 scripts/agent_rpc.py call <方法> '<参数 JSON>' [--port 12346]
    python3 scripts/agent_rpc.py wait [状态] [--timeout 60] [--port 12346]

只依赖标准库的 urllib: Windows 上没有 curl 也能用, 也省掉各平台不同的引号规则.
接口说明见 docs/agent-api.md.
"""
import argparse
import json
import sys
import time
import urllib.error
import urllib.request

DEFAULT_PORT = 12346


def rpc(port, method, params, timeout=10.0):
    """发一次 JSON-RPC 请求, 返回解析后的响应 (dict). 网络错误向上抛."""
    body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode("utf-8")
    request = urllib.request.Request(
        "http://127.0.0.1:%d" % port,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def do_call(args):
    try:
        params = json.loads(args.params)
    except json.JSONDecodeError as exc:
        print("参数不是合法 JSON: %s" % exc, file=sys.stderr)
        return 1
    if not isinstance(params, dict):
        print("参数必须是 JSON 对象", file=sys.stderr)
        return 1
    try:
        result = rpc(args.port, args.method, params)
    except (urllib.error.URLError, OSError) as exc:
        print("连不上 http://127.0.0.1:%d: %s" % (args.port, exc), file=sys.stderr)
        print("游戏是否在运行, 且 agent 已开启?", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    # 端点的错误放在 error 字段里; 仍然以 0 退出, 让调用方自己判断, 与 curl 版本一致.
    return 0


def do_wait(args):
    """轮询 gamestate 直到状态匹配. 超时返回非 0, 并把最后的状态打到 stderr."""
    deadline = time.monotonic() + args.timeout
    last = None
    seen_any = False
    while time.monotonic() < deadline:
        try:
            result = rpc(args.port, "gamestate", {}, timeout=5.0)
            state = (result.get("result") or {}).get("state")
        except (urllib.error.URLError, OSError, json.JSONDecodeError, ValueError):
            state = None
        if state == args.state:
            print("游戏已进入 %s" % args.state)
            return 0
        if state and state != last:
            print("当前状态: %s" % state)  # 状态变化时打一行, 便于看进度
            last = state
            seen_any = True
        time.sleep(0.5)
    detail = last if seen_any else "无响应"
    print("等待 %s 超时 (%ds), 最后状态: %s" % (args.state, args.timeout, detail), file=sys.stderr)
    return 1


def main():
    parser = argparse.ArgumentParser(description="调用 agent 接口")
    sub = parser.add_subparsers(dest="command", required=True)

    call = sub.add_parser("call", help="调用一次方法并打印 JSON-RPC 响应")
    call.add_argument("method")
    call.add_argument("params", nargs="?", default="{}", help="参数 JSON, 默认 {}")
    call.add_argument("--port", type=int, default=DEFAULT_PORT)

    wait = sub.add_parser("wait", help="轮询直到游戏进入指定状态 (默认 MENU)")
    wait.add_argument("state", nargs="?", default="MENU")
    wait.add_argument("--timeout", type=int, default=60)
    wait.add_argument("--port", type=int, default=DEFAULT_PORT)

    args = parser.parse_args()
    return do_call(args) if args.command == "call" else do_wait(args)


if __name__ == "__main__":
    sys.exit(main())
