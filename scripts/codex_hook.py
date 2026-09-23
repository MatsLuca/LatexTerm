#!/usr/bin/env python3
"""Forward Codex lifecycle hooks to LatexTerm's local socket, never to the TTY.

No transcript reads, persistent state, model calls, or prompt output. Missing LatexTerm
or an older app is a quiet no-op. Hook input: https://learn.chatgpt.com/docs/hooks
"""
import json
import os
from pathlib import Path
import re
import socket
import sys
import subprocess

EVENTS = ("SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
          "PostToolUse", "Stop", "Interrupt", "SessionEnd")
ID = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")
PANE = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")


def clean(value, limit=150):
    if not isinstance(value, str):
        return ""
    return " ".join(re.sub(r"[\x00-\x1f\x7f;]", " ", value).split())[:limit]


def request_for(event, pane):
    if not isinstance(event, dict) or not PANE.fullmatch(pane or "") or event.get("agent_id"):
        return None
    session = event.get("session_id")
    turn = event.get("turn_id")
    if not isinstance(session, str) or not ID.fullmatch(session):
        return None
    if turn is not None and (not isinstance(turn, str) or not ID.fullmatch(turn)):
        return None
    name = event.get("hook_event_name")
    tool = clean(event.get("tool_name"), 60)
    if name == "SessionStart":
        text = "ready"
    elif name == "UserPromptSubmit":
        text = "working;t=0;n=0;p=" + clean(event.get("prompt"), 80)
    elif name == "PermissionRequest":
        text = "input;Freigabe: " + tool
    elif name == "PreToolUse":
        asks_user = "request_user_input" in tool
        text = "input;Frage beantworten" if asks_user else "working;" + tool + ";inc=1"
    elif name == "PostToolUse":
        text = "working;" + tool
    elif name == "Stop":
        text = "done;r=answer;a=" + clean(event.get("last_assistant_message"), 190)
    elif name == "Interrupt":
        text = "done;r=aborted"
    elif name == "SessionEnd":
        text = "closed"
    else:
        return None
    request = {"cmd": "status", "pane": pane, "agent": "codex", "sessionID": session, "text": text}
    if turn is not None:
        request["turnID"] = turn
    return request


def exchange(path, request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(0.35)
        client.connect(str(path))
        client.sendall(json.dumps(request).encode() + b"\n")
        data = bytearray()
        while b"\n" not in data and len(data) < 1_048_576:
            chunk = client.recv(4096)
            if not chunk:
                break
            data.extend(chunk)
        return json.loads(data.split(b"\n", 1)[0])


def forward(event, pane, path, source_group=None):
    request = request_for(event, pane)
    if request is None:
        return False
    if source_group is not None:
        request["sourceGroup"] = source_group
    # An old app ignores the new identity fields and would label Codex as Claude.
    # Negotiate first so installing the hook before an app restart is harmless.
    info = exchange(path, {"cmd": "list-panes"})
    if not info.get("ok") or "agent-sessions" not in (info.get("capabilities") or []):
        return False
    if not any(p.get("id", "").lower() == pane.lower() for p in info.get("panes", [])):
        return False
    return exchange(path, request).get("ok", False)


def codex_process_group():
    """Locate the emitting Codex process, not the hook shell's potentially separate job.

    A shared/background daemon must not claim a pane whose foreground job it doesn't own.
    No command-line arguments, environment dumps, or transcript heuristics are read.
    """
    pid = os.getppid()
    for _ in range(8):
        if pid <= 1:
            return None
        result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "ppid=,comm="],
                                capture_output=True, text=True, timeout=0.15)
        fields = result.stdout.strip().split(None, 1)
        if len(fields) != 2:
            return None
        if Path(fields[1]).name == "codex":
            return os.getpgid(pid)
        pid = int(fields[0])
    return None


def main():
    pane = os.environ.get("LATEXTERM_PANE_ID", "")
    if not PANE.fullmatch(pane):
        return
    try:
        raw = sys.stdin.buffer.read(1_048_577)
        if len(raw) > 1_048_576:
            return
        event = json.loads(raw)
        path = Path.home() / "Library/Application Support/LatexTerm/control.sock"
        group = codex_process_group()
        if group is not None:
            forward(event, pane, path, group)
    except (OSError, ValueError, TypeError, AttributeError, subprocess.TimeoutExpired):
        pass  # Status delivery never blocks or changes the agent's work.


if __name__ == "__main__":
    main()
