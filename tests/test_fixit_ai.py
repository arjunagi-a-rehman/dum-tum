#!/usr/bin/env python3
"""Unit tests for src/fixit-ai.py (stdlib only — run: python3 -m unittest)."""

import importlib.util
import json
import os
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parent.parent / "src" / "fixit-ai.py"
spec = importlib.util.spec_from_file_location("fixit_ai", MODULE_PATH)
fixit_ai = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixit_ai)


class TestHeadOf(unittest.TestCase):
    def test_plain_command(self):
        self.assertEqual(fixit_ai.head_of("ls -la"), "ls")

    def test_sudo_stripped(self):
        self.assertEqual(fixit_ai.head_of("sudo rm -rf /tmp/x"), "rm")

    def test_path_stripped(self):
        self.assertEqual(fixit_ai.head_of("/usr/bin/find ."), "find")

    def test_empty(self):
        self.assertEqual(fixit_ai.head_of(""), "")
        self.assertEqual(fixit_ai.head_of("   "), "")


class TestExtract(unittest.TestCase):
    def test_simple_command(self):
        self.assertEqual(fixit_ai.extract("ls -la"), "ls -la")

    def test_strips_markdown_fence(self):
        self.assertEqual(fixit_ai.extract("```bash\nls -la\n```"), "ls -la")

    def test_backtick_candidate(self):
        out = fixit_ai.extract("You can use `find . -name reno` to locate it.")
        self.assertEqual(out, "find . -name reno")

    def test_prose_lines_skipped(self):
        out = fixit_ai.extract("Here is the command you need\nls -la")
        self.assertEqual(out, "ls -la")

    def test_danger_prefix_preserved(self):
        out = fixit_ai.extract("# DANGER: deletes files\nrm -rf ./build")
        self.assertEqual(out, "# DANGER: deletes files\nrm -rf ./build")

    def test_comment_only_returns_empty(self):
        self.assertEqual(fixit_ai.extract("# just a comment"), "")

    def test_empty_input(self):
        self.assertEqual(fixit_ai.extract(""), "")

    def test_url_in_backticks_ignored(self):
        out = fixit_ai.extract("`https://example.com/docs`")
        self.assertEqual(out, "")


class TestParsePayload(unittest.TestCase):
    def test_plain_text_passthrough(self):
        self.assertEqual(fixit_ai.parse_payload("ls -la"), "ls -la")

    def test_empty(self):
        self.assertEqual(fixit_ai.parse_payload(""), "")
        self.assertEqual(fixit_ai.parse_payload("   \n  "), "")

    def test_openrouter_chat_completion(self):
        body = json.dumps({
            "choices": [{"message": {"role": "assistant", "content": "ls -la"}}]
        })
        self.assertEqual(fixit_ai.parse_payload(body), "ls -la")

    def test_error_payload_reports_and_returns_empty(self):
        body = json.dumps({"error": {"message": "invalid api key"}})
        self.assertEqual(fixit_ai.parse_payload(body), "")

    def test_jsonl_stream_concatenated(self):
        lines = "\n".join([
            json.dumps({"text": "ls"}),
            json.dumps({"text": " -la"}),
        ])
        self.assertEqual(fixit_ai.parse_payload(lines), "ls\n -la")

    def test_single_json_line(self):
        line = json.dumps({"part": {"text": "pwd"}})
        self.assertEqual(fixit_ai.parse_payload(line), "pwd")

    def test_invalid_json_returned_raw(self):
        raw = "{not valid json"
        self.assertEqual(fixit_ai.parse_payload(raw), raw)


class TestBodyCommand(unittest.TestCase):
    def test_body_json_structure(self):
        os.environ.update({
            "FX_MODEL": "test/model",
            "FX_SYS": "sys prompt",
            "FX_USER": "user prompt",
        })
        import io
        from contextlib import redirect_stdout
        buf = io.StringIO()
        with redirect_stdout(buf):
            fixit_ai.cmd_body()
        body = json.loads(buf.getvalue())
        self.assertEqual(body["model"], "test/model")
        self.assertEqual(body["max_tokens"], 800)
        self.assertEqual(body["messages"][0], {"role": "system", "content": "sys prompt"})
        self.assertEqual(body["messages"][1], {"role": "user", "content": "user prompt"})


if __name__ == "__main__":
    unittest.main()
