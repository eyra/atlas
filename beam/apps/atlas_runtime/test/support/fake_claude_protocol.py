"""Synthetic projections of pinned SDK fields. Never launches Claude or a model."""
import json
import sys

mode, capture = sys.argv[1:]
allowed = {"echo", "duplicate", "correlated", "uncorrelated", "batch", "wrong_uuid",
           "wrong_session", "subagent", "control", "malformed", "oversized", "eof", "partial"}
if mode not in allowed:
    sys.exit(2)
line = sys.stdin.buffer.readline(32769)
if not line.endswith(b"\n") or len(line) > 32768:
    sys.exit(2)
request = json.loads(line)
with open(capture, "xb") as output:
    output.write(line)
if mode == "eof":
    sys.exit(1)
if mode == "malformed":
    sys.stdout.write('{"type":\n')
    sys.exit(1)
if mode == "oversized":
    sys.stdout.write("x" * 65537)
    sys.exit(1)
echo = dict(request, isReplay=True)
if mode == "wrong_uuid":
    echo["uuid"] = "ffffffff-ffff-4fff-8fff-ffffffffffff"
if mode == "wrong_session":
    echo["session_id"] = "ffffffff-ffff-4fff-8fff-ffffffffffff"
if mode == "partial":
    sys.stdout.write(json.dumps(echo)[:20])
    sys.exit(1)
if mode == "control":
    print(json.dumps({"type": "control_request", "request_id": "synthetic",
                      "request": {"subtype": "can_use_tool", "tool_name": "Bash"}}))
    sys.exit(0)
if mode in {"correlated", "uncorrelated", "batch", "subagent"}:
    event = {"type": "result", "subtype": "success", "session_id": request["session_id"]}
    if mode != "uncorrelated":
        event["user_message_uuid"] = request["uuid"]
        event["user_message_uuids"] = [request["uuid"]]
    if mode == "batch":
        event["user_message_uuid"] = "ffffffff-ffff-4fff-8fff-ffffffffffff"
        event["user_message_uuids"].append(event["user_message_uuid"])
    if mode == "subagent":
        event.update(type="assistant", parent_tool_use_id="synthetic-parent")
    print(json.dumps(event))
else:
    print(json.dumps(echo, ensure_ascii=False))
    if mode == "duplicate":
        print(json.dumps(echo, ensure_ascii=False))
