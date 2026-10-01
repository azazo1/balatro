"""调用 mod 版的 agent 接口: 一次调用, 或轮询等游戏进入某个状态. 接口说明见 docs/agent-api.md.

    python3 scripts/agent_rpc.py call <方法> ['<参数 JSON>'] [端口]
    python3 scripts/agent_rpc.py wait [状态] [超时秒数] [端口]

只用标准库的 urllib, Windows 上没有 curl 也能用.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib import log  # noqa: E402


def post(port, method, params, timeout=None):
    """发一次 JSON-RPC 请求, 返回响应正文 (bytes). 连不上时抛 OSError.

    端点报错时 HTTP 状态码是 4xx/5xx, 但正文仍是 JSON-RPC 响应, 照常返回.
    """
    body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode("utf-8")
    request = urllib.request.Request(
        "http://127.0.0.1:%d" % port, data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        return exc.read()


def do_call(args):
    try:
        params = json.loads(args.params)
    except json.JSONDecodeError as exc:
        log.die("参数不是合法 JSON: %s" % exc)
    # 操作类方法要等动画和结算结束才返回, 不设超时, 由调用方决定等多久.
    try:
        body = post(args.port, args.method, params)
    except OSError as exc:
        log.die("连不上 http://127.0.0.1:%d: %s (游戏是否在运行, 且 agent 已开启?)" % (args.port, exc))
    # 原样输出响应; 端点的错误在 error 字段里, 仍以 0 退出, 由调用方判断.
    sys.stdout.buffer.write(body + b"\n")


def do_wait(args):
    """轮询 gamestate 直到状态匹配, 超时以非 0 退出."""
    deadline = time.monotonic() + args.timeout
    last = None
    while time.monotonic() < deadline:
        try:
            state = json.loads(post(args.port, "gamestate", {}, timeout=5)).get("result", {}).get("state")
        except (OSError, ValueError, AttributeError):
            state = None
        if state == args.state:
            log.info("游戏已进入 %s" % args.state)
            return
        if state and state != last:
            log.info("当前状态: %s" % state)
            last = state
        time.sleep(0.5)
    log.die("等待 %s 超时 (%ds), 最后状态: %s" % (args.state, args.timeout, last or "无响应"))


def main():
    parser = argparse.ArgumentParser(description="调用 agent 接口")
    sub = parser.add_subparsers(dest="command", required=True)

    call = sub.add_parser("call", help="调用一次方法并打印 JSON-RPC 响应")
    call.add_argument("method")
    call.add_argument("params", nargs="?", default="{}", help="参数 JSON, 默认 {}")
    call.add_argument("port", nargs="?", type=int, default=12346)
    call.set_defaults(run=do_call)

    wait = sub.add_parser("wait", help="轮询直到游戏进入指定状态")
    wait.add_argument("state", nargs="?", default="MENU")
    wait.add_argument("timeout", nargs="?", type=int, default=60)
    wait.add_argument("port", nargs="?", type=int, default=12346)
    wait.set_defaults(run=do_wait)

    log.set_prefix("agent")
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
