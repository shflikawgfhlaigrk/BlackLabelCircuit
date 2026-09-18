#!/usr/bin/env python3
"""A/B the codex app-server: warm-thread VISION latency vs the exec baseline.
Speaks JSON-RPC over stdio: thread/start once, then repeated turn/start with
text+localImage input; answer text is collected from item/turn notifications."""
import json, subprocess, sys, time

CODEX = "/Applications/ChatGPT.app/Contents/Resources/codex"
IMG = "/private/tmp/claude-501/-Users-michaelbarber/7f8a8c9f-8f26-4c52-9e8b-8452b0537cb0/scratchpad/probe-word.png"

proc = subprocess.Popen([CODEX, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL, text=True, bufsize=1)
rid = 0
def send(method, params=None, notify=False):
    global rid
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None: msg["params"] = params
    if not notify:
        rid += 1; msg["id"] = rid
    proc.stdin.write(json.dumps(msg) + "\n"); proc.stdin.flush()
    return None if notify else rid

def read_msg(timeout_s):
    # line-based read with deadline via poll on the fd would be nicer; keep simple
    line = proc.stdout.readline()
    if not line: return None
    try: return json.loads(line)
    except: return {"_raw": line[:200]}

def wait_response(tid, timeout_s=60, collect=None):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        m = read_msg(timeout_s)
        if m is None: return None
        if collect is not None: collect.append(m)
        if m.get("id") == tid and ("result" in m or "error" in m):
            return m
    return None

# Optional initialize — try it; ignore a method-not-found error.
i = send("initialize", {"clientInfo": {"name": "ace-probe", "version": "1"}})
r = wait_response(i, 10)
print("initialize:", ("result" in r) if r else "none", flush=True)

t = send("thread/start", {})
r = wait_response(t, 30)
if not r or "error" in r:
    print("thread/start failed:", json.dumps(r)[:300]); sys.exit(1)
thread_id = (r.get("result") or {}).get("thread", {}).get("id") or (r.get("result") or {}).get("threadId")
print("threadId:", thread_id, flush=True)

def vision_turn(label):
    start = time.time()
    msgs = []
    tid = send("turn/start", {
        "threadId": thread_id,
        "input": [
            {"type": "text", "text": "Look at the attached image and reply with EXACTLY the text shown in it, nothing else."},
            {"type": "localImage", "path": IMG},
        ],
        "effort": "low",
        "approvalPolicy": "never",
        "sandboxPolicy": {"type": "readOnly"},
    })
    # turn/start's response may arrive before generation completes; keep reading
    # until turn/completed for this thread.
    got_response = False
    answer = ""
    deadline = time.time() + 120
    while time.time() < deadline:
        m = read_msg(120)
        if m is None: break
        if m.get("id") == tid and ("result" in m or "error" in m):
            got_response = True
            if "error" in m:
                print(f"{label}: turn/start error {json.dumps(m['error'])[:200]}"); return
            continue
        if m.get("method") == "turn/completed":
            turn = (m.get("params") or {}).get("turn", {})
            items = turn.get("items") or []
            for item in items:
                if item.get("type") in ("agentMessage", "assistantMessage", "message"):
                    answer += str(item.get("text") or item.get("content") or "")
            break
        if m.get("method") in ("item/completed", "item/started"):
            item = (m.get("params") or {}).get("item", {})
            if item.get("type") in ("agentMessage", "assistantMessage") and m["method"] == "item/completed":
                answer += str(item.get("text") or "")
    print(f"{label}: {round(time.time()-start,2)}s  answer={answer.strip()[:50]!r}", flush=True)

vision_turn("turn1 (thread cold)")
vision_turn("turn2 (thread warm)")
vision_turn("turn3 (thread warm)")
proc.terminate()
