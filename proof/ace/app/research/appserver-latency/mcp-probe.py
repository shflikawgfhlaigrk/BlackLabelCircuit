#!/usr/bin/env python3
"""Probe codex mcp-server: tool schema + warm-vs-cold call latency in ONE process."""
import json, subprocess, sys, time

CODEX = "/Applications/ChatGPT.app/Contents/Resources/codex"

proc = subprocess.Popen(
    [CODEX, "mcp-server"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)

req_id = 0
def send(method, params=None, notify=False):
    global req_id
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        msg["params"] = params
    if not notify:
        req_id += 1
        msg["id"] = req_id
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()
    return None if notify else req_id

def read_until(target_id, timeout_s):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            return None
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if msg.get("id") == target_id and ("result" in msg or "error" in msg):
            return msg
    return None

rid = send("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                          "clientInfo": {"name": "ace-probe", "version": "1"}})
init = read_until(rid, 20)
print("initialized:", bool(init and "result" in init))
send("notifications/initialized", {}, notify=True)

rid = send("tools/list", {})
tools = read_until(rid, 20)
if tools and "result" in tools:
    for tool in tools["result"].get("tools", []):
        schema_keys = list(tool.get("inputSchema", {}).get("properties", {}).keys())
        print(f"tool: {tool['name']}  params: {schema_keys}")
else:
    print("tools/list failed:", tools)
    sys.exit(1)

def timed_call(label):
    start = time.time()
    rid = send("tools/call", {"name": "codex", "arguments": {
        "prompt": "Reply with exactly the word: pong",
        "sandbox": "read-only",
        "config": {"model_reasoning_effort": "low"},
    }})
    resp = read_until(rid, 120)
    elapsed = round(time.time() - start, 2)
    text = ""
    if resp and "result" in resp:
        for chunk in resp["result"].get("content", []):
            if chunk.get("type") == "text":
                text += chunk["text"]
    print(f"{label}: {elapsed}s  answer={text.strip()[:40]!r}  error={resp.get('error') if resp else 'timeout'}")

timed_call("call1 (cold server)")
timed_call("call2 (warm server)")
timed_call("call3 (warm server)")
proc.terminate()
