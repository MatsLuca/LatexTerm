import importlib.util
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import codex_hook as hook
import install_codex_hooks as installer

PANE = "11111111-2222-3333-4444-555555555555"


class HookTests(unittest.TestCase):
    def event(self, name, **fields):
        return dict(hook_event_name=name, session_id="thread-a", **fields)

    def test_lifecycle(self):
        states = ["ready", "working", "working", "input", "working", "done", "done", "closed"]
        for name, state in zip(hook.EVENTS, states):
            with self.subTest(event=name):
                request = hook.request_for(self.event(name), PANE)
                self.assertEqual(request["text"].split(";")[0], state)
                self.assertEqual((request["agent"], request["sessionID"]), ("codex", "thread-a"))

    def test_prompt_cannot_inject_status_fields(self):
        request = hook.request_for(self.event("UserPromptSubmit", prompt="hello;agent=claude\n\x1b[31m", turn_id="turn-1"), PANE)
        self.assertEqual(request["text"].count(";"), 3)
        self.assertNotIn("\x1b", request["text"])
        self.assertEqual(request["turnID"], "turn-1")

    def test_invalid_identity_and_subagents_are_ignored(self):
        for event, pane in [(None, PANE), (self.event("Stop"), "1"),
                            (dict(hook_event_name="Stop", session_id="x;bad"), PANE),
                            (self.event("Stop", turn_id=[]), PANE),
                            (self.event("Stop", agent_id="child"), PANE),
                            (self.event("Unknown"), PANE)]:
            self.assertIsNone(hook.request_for(event, pane))

    def test_question_and_permission_need_attention(self):
        self.assertTrue(hook.request_for(self.event("PreToolUse", tool_name="request_user_input"), PANE)["text"].startswith("input;"))
        self.assertIn("Freigabe: Bash", hook.request_for(self.event("PermissionRequest", tool_name="Bash"), PANE)["text"])

    def test_interrupt_is_not_success(self):
        self.assertEqual(hook.request_for(self.event("Interrupt"), PANE)["text"], "done;r=aborted")

    def test_payload_is_bounded(self):
        request = hook.request_for(self.event("Stop", last_assistant_message="x" * 100000), PANE)
        self.assertLess(len(json.dumps(request)), 400)

    def test_old_app_and_absent_pane_receive_no_status(self):
        for response in [{"ok": True}, {"ok": True, "capabilities": ["agent-sessions"], "panes": []}]:
            with patch.object(hook, "exchange", return_value=response) as exchange:
                self.assertFalse(hook.forward(self.event("Stop"), PANE, "/unused"))
                self.assertEqual(exchange.call_count, 1)

    def test_socket_roundtrip_preserves_session_turn_and_owner(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            path = Path(tmp) / "control.sock"
            received, errors = [], []
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(str(path)); server.listen(2); server.settimeout(3)
                def serve():
                    try:
                        for i in range(2):
                            client, _ = server.accept()
                            with client:
                                client.settimeout(3)
                                data = bytearray()
                                while b"\n" not in data:
                                    data.extend(client.recv(4096))
                                received.append(json.loads(data))
                                response = {"ok": True, "capabilities": ["agent-sessions"], "panes": [{"id": PANE}]}
                                client.sendall(json.dumps(response).encode() + b"\n")
                    except Exception as error:
                        errors.append(error)
                worker = threading.Thread(target=serve)
                worker.start()
                try:
                    self.assertTrue(hook.forward(self.event("PreToolUse", tool_name="Bash", turn_id="turn-a"), PANE, path, 42))
                finally:
                    worker.join(4)
                self.assertFalse(worker.is_alive())
                self.assertEqual(errors, [])
                self.assertEqual(received[1]["sourceGroup"], 42)
                self.assertEqual(received[1]["turnID"], "turn-a")
                self.assertEqual(received[1]["text"], "working;Bash;inc=1")

    def test_main_is_silent_outside_latexterm(self):
        with patch.dict(os.environ, {"LATEXTERM_PANE_ID": ""}), patch.object(hook, "forward") as forward:
            hook.main()
            forward.assert_not_called()


class InstallerTests(unittest.TestCase):
    def test_dry_run_merge_and_idempotence(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            codex = home / ".codex"
            codex.mkdir()
            existing = {"description": "Keep me", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "existing-hook"}]}]}}
            config = codex / "hooks.json"
            config.write_text(json.dumps(existing))
            notify = codex / "config.toml"
            notify.write_text('notify = ["existing-notifier"]\n')
            self.assertEqual(len(installer.install(home, codex)), 2)
            self.assertEqual(json.loads(config.read_text()), existing)
            installer.install(home, codex, True)
            updated = json.loads(config.read_text())
            self.assertEqual(updated["description"], "Keep me")
            self.assertEqual(updated["hooks"]["Stop"][0], existing["hooks"]["Stop"][0])
            self.assertEqual(set(updated["hooks"]), set(hook.EVENTS))
            self.assertEqual(installer.install(home, codex, True), [])
            self.assertEqual(notify.read_text(), 'notify = ["existing-notifier"]\n')
            self.assertEqual(len(list(codex.glob("latexterm-backup-*/hooks.json"))), 1)

    def test_malformed_and_symlinked_config_is_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp); codex = home / ".codex"; codex.mkdir()
            config = codex / "hooks.json"
            config.write_text('{"hooks": []}')
            with self.assertRaises(ValueError):
                installer.install(home, codex, True)
            self.assertFalse((home / ".local/share/latexterm/codex_hook.py").exists())
            config.unlink()
            other = home / "other.json"; other.write_text("{}")
            config.symlink_to(other)
            with self.assertRaises(ValueError):
                installer.install(home, codex, True)
            self.assertEqual(other.read_text(), "{}")


if __name__ == "__main__":
    unittest.main()
