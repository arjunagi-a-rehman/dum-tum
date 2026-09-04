#!/usr/bin/env python3
"""Unit tests for src/fixit-ai.py (stdlib only — run: python3 -m unittest)."""

import importlib.util
import json
import os
import sys
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

    def test_sudo_multiple_spaces(self):
        self.assertEqual(fixit_ai.head_of("sudo    apt update"), "apt")

    def test_sudo_with_path(self):
        self.assertEqual(fixit_ai.head_of("sudo /bin/rm -f x"), "rm")

    def test_leading_whitespace_and_tabs(self):
        self.assertEqual(fixit_ai.head_of("\t  git\tstatus"), "git")

    def test_sudo_only(self):
        self.assertEqual(fixit_ai.head_of("sudo"), "sudo")

    def test_sudo_no_args(self):
        self.assertEqual(fixit_ai.head_of("sudo "), "sudo")


class TestRepairFailedLine(unittest.TestCase):
    def test_preserves_shell_syntax_around_repaired_span(self):
        raw = 'cat "dcoument.txt" | wc -c > "$OUT" && printf "$KEEP"'
        repaired = fixit_ai.repair_failed_line(raw, ["cat"], ["document.txt"])
        self.assertEqual(
            repaired,
            (
                "run",
                "dcoument.txt",
                "document.txt",
                'cat "document.txt" | wc -c > "$OUT" && printf "$KEEP"',
            ),
        )

    def test_preserves_single_quotes(self):
        raw = "cat 'dcoument.txt' || printf failed"
        repaired = fixit_ai.repair_failed_line(raw, ["cat"], ["document.txt"])
        self.assertEqual(repaired[3], "cat 'document.txt' || printf failed")

    def test_simple_line_uses_argv_execution(self):
        repaired = fixit_ai.repair_failed_line("cat dcoument.txt", ["cat"], ["document.txt"])
        self.assertEqual(repaired, ("argv", "dcoument.txt", "document.txt", "cat document.txt"))

    def test_assignment_and_tilde_keep_shell_execution(self):
        raw = "MODE=test cat dcoument.txt ~/archive"
        repaired = fixit_ai.repair_failed_line(raw, ["cat"], ["document.txt"])
        self.assertEqual(repaired, ("run", "dcoument.txt", "document.txt", "MODE=test cat document.txt ~/archive"))

    def test_escaped_word_requires_editing(self):
        raw = r"cat dcoument\ file.txt"
        repaired = fixit_ai.repair_failed_line(raw, ["cat"], ["document file.txt"])
        self.assertEqual(repaired, ("edit", "dcoument file.txt", "document file.txt", raw))

    def test_complex_repair_does_not_insert_untrusted_filename_syntax(self):
        candidates = (
            ("target", "tar;get"),
            ("tar(x)get", "tar$(x)get"),
            ("target", "tar`get"),
            ("target", "tar get"),
            ("target", "tar'get"),
            ("target", 'tar"get'),
            ("target", "tar*get"),
            ("target", "tar?get"),
            ("target", "tar[get"),
        )
        for operator in ("| wc -c", "> output"):
            for typo, candidate in candidates:
                raw = f"cat '{typo}' {operator}"
                with self.subTest(operator=operator, candidate=candidate):
                    self.assertEqual(
                        fixit_ai.repair_failed_line(raw, ["cat"], [candidate]),
                        ("edit", typo, candidate, raw),
                    )

    def test_does_not_repair_inside_expansion(self):
        raw = 'cat "$DIR/dcoument.txt"'
        self.assertIsNone(fixit_ai.repair_failed_line(raw, ["cat"], ["document.txt"]))

    def test_rejects_non_safe_command(self):
        self.assertIsNone(fixit_ai.repair_failed_line("rm dcoument.txt", ["cat"], ["document.txt"]))


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

    def test_fence_with_language_and_surrounding_prose(self):
        out = fixit_ai.extract("Sure! Here you go:\n```sh\ngit status\n```\nHope that helps")
        self.assertEqual(out, "git status")

    def test_last_backtick_candidate_wins(self):
        out = fixit_ai.extract("Run `ls -la` or better `git status`")
        self.assertEqual(out, "git status")

    def test_backtick_unknown_head_with_space_accepted(self):
        out = fixit_ai.extract("try `gcloud compute instances list` now")
        self.assertEqual(out, "gcloud compute instances list")

    def test_backtick_single_word_unknown_head_rejected(self):
        out = fixit_ai.extract("the `foobar` command")
        self.assertEqual(out, "")

    def test_backtick_quotes_stripped(self):
        out = fixit_ai.extract('use `"ls -la"` here')
        self.assertEqual(out, "ls -la")

    def test_unknown_head_multiline_fallback(self):
        out = fixit_ai.extract("gcloud compute instances list")
        self.assertEqual(out, "gcloud compute instances list")

    def test_single_word_unknown_head_returns_empty(self):
        self.assertEqual(fixit_ai.extract("blahblah"), "")

    def test_prose_variants_skipped(self):
        out = fixit_ai.extract("We can fix this\nUse the following\nls -la")
        self.assertEqual(out, "ls -la")

    def test_prose_case_insensitive(self):
        out = fixit_ai.extract("THE answer is\nls -la")
        self.assertEqual(out, "ls -la")

    def test_danger_without_following_command(self):
        out = fixit_ai.extract("# DANGER: deletes everything")
        self.assertEqual(out, "# DANGER: deletes everything")

    def test_danger_not_first_line(self):
        out = fixit_ai.extract("Here is the fix\n# DANGER: wipes data\nrm -rf /tmp/x")
        self.assertEqual(out, "# DANGER: wipes data\nrm -rf /tmp/x")

    def test_whitespace_only_input(self):
        self.assertEqual(fixit_ai.extract("   \n\t\n  "), "")

    def test_unclosed_fence(self):
        self.assertEqual(fixit_ai.extract("```bash\nls -la"), "ls -la")

    def test_lines_with_backticks_stripped(self):
        self.assertEqual(fixit_ai.extract("`git status`"), "git status")


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

    def test_error_string_payload(self):
        body = json.dumps({"error": "rate limited"})
        self.assertEqual(fixit_ai.parse_payload(body), "")

    def test_error_with_choices_not_treated_as_error(self):
        body = json.dumps({
            "error": {"message": "partial"},
            "choices": [{"message": {"content": "ls -la"}}],
        })
        self.assertEqual(fixit_ai.parse_payload(body), "ls -la")

    def test_jsonl_error_midstream_aborts(self):
        lines = "\n".join([
            json.dumps({"text": "ls"}),
            json.dumps({"error": {"message": "boom"}}),
        ])
        self.assertEqual(fixit_ai.parse_payload(lines), "")

    def test_jsonl_multiple_json_no_text_returns_empty(self):
        lines = "\n".join([
            json.dumps({"id": 1}),
            json.dumps({"id": 2}),
        ])
        self.assertEqual(fixit_ai.parse_payload(lines), "")

    def test_json_array_payload(self):
        body = json.dumps([{"text": "git"}, {"text": " status"}])
        self.assertEqual(fixit_ai.parse_payload(body), "git\n status")

    def test_choices_empty_content_falls_back_to_collect(self):
        body = json.dumps({
            "choices": [{"message": {"content": "  ", "reasoning": "ls -la"}}]
        })
        self.assertEqual(fixit_ai.parse_payload(body), "ls -la")

    def test_choices_missing_message(self):
        body = json.dumps({"choices": [{}]})
        self.assertEqual(fixit_ai.parse_payload(body), "")

    def test_empty_choices_array(self):
        body = json.dumps({"choices": []})
        self.assertEqual(fixit_ai.parse_payload(body), "")

    def test_nested_content_dict(self):
        body = json.dumps({"message": {"content": {"text": "pwd"}}})
        self.assertEqual(fixit_ai.parse_payload(body), "pwd")

    def test_reasoning_details_collected(self):
        body = json.dumps({"reasoning_details": [{"text": "ls -la"}]})
        self.assertEqual(fixit_ai.parse_payload(body), "ls -la")

    def test_part_content_key(self):
        line = json.dumps({"part": {"content": "mkdir foo"}})
        self.assertEqual(fixit_ai.parse_payload(line), "mkdir foo")

    def test_claude_result_shape(self):
        body = json.dumps({
            "type": "result",
            "subtype": "success",
            "is_error": False,
            "result": "ls -la",
            "session_id": "abc123",
        })
        self.assertEqual(fixit_ai.parse_payload(body), "ls -la")

    def test_antigravity_stream_result_shape(self):
        body = json.dumps({
            "event": "result",
            "result": {"status": "SUCCESS", "response": "ls -la\n"},
        })
        self.assertEqual(fixit_ai.parse_payload(body), "ls -la\n")

    def test_non_json_mixed_lines_passthrough(self):
        raw = "some prose\nls -la"
        self.assertEqual(fixit_ai.parse_payload(raw), raw)

    def test_scalar_json_returned_raw(self):
        raw = "123"
        self.assertEqual(fixit_ai.parse_payload(raw), raw)

    def test_anthropic_messages_response(self):
        body = json.dumps({
            "content": [{"type": "text", "text": "ls -la"}],
            "stop_reason": "end_turn",
        })
        self.assertEqual(fixit_ai.parse_payload(body), "ls -la")

    def test_gemini_generate_content_response(self):
        body = json.dumps({
            "candidates": [{"content": {"parts": [{"text": "ls -la"}]}}]
        })
        self.assertEqual(fixit_ai.parse_payload(body), "ls -la")


class TestCollectText(unittest.TestCase):
    def test_plain_string(self):
        parts = []
        fixit_ai.collect_text("hello", parts)
        self.assertEqual(parts, ["hello"])

    def test_blank_strings_ignored(self):
        parts = []
        fixit_ai.collect_text("   ", parts)
        self.assertEqual(parts, [])

    def test_nested_list(self):
        parts = []
        fixit_ai.collect_text([{"text": "a"}, ["b", {"content": "c"}]], parts)
        self.assertEqual(parts, ["a", "b", "c"])

    def test_non_string_scalars_ignored(self):
        parts = []
        fixit_ai.collect_text({"text": 42, "content": None, "ok": True}, parts)
        self.assertEqual(parts, [])

    def test_delta_streaming_shape(self):
        parts = []
        fixit_ai.collect_text({"delta": {"content": "ls"}}, parts)
        self.assertEqual(parts, ["ls"])


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

    def test_body_anthropic_structure(self):
        os.environ.update({
            "FX_MODEL": "claude-sonnet-4-5",
            "FX_SYS": "sys prompt",
            "FX_USER": "user prompt",
        })
        import io
        from contextlib import redirect_stdout
        buf = io.StringIO()
        with redirect_stdout(buf):
            fixit_ai.cmd_body_anthropic()
        body = json.loads(buf.getvalue())
        self.assertEqual(body["model"], "claude-sonnet-4-5")
        self.assertEqual(body["max_tokens"], 800)
        self.assertEqual(body["system"], "sys prompt")
        self.assertEqual(body["messages"], [{"role": "user", "content": "user prompt"}])

    def test_body_gemini_structure(self):
        os.environ.update({
            "FX_SYS": "sys prompt",
            "FX_USER": "user prompt",
        })
        import io
        from contextlib import redirect_stdout
        buf = io.StringIO()
        with redirect_stdout(buf):
            fixit_ai.cmd_body_gemini()
        body = json.loads(buf.getvalue())
        self.assertEqual(body["system_instruction"], {"parts": [{"text": "sys prompt"}]})
        self.assertEqual(
            body["contents"],
            [{"role": "user", "parts": [{"text": "user prompt"}]}],
        )

    def test_body_antigravity_structure(self):
        import io
        from contextlib import redirect_stdout
        old_stdin = sys.stdin
        sys.stdin = io.StringIO("user prompt")
        buf = io.StringIO()
        try:
            with redirect_stdout(buf):
                fixit_ai.cmd_body_antigravity()
        finally:
            sys.stdin = old_stdin
        body = json.loads(buf.getvalue())
        self.assertEqual(body, {
            "event": "user",
            "message": {"content": "user prompt"},
        })


class TestExtractCommand(unittest.TestCase):
    def _run_extract(self, stdin_text):
        import io
        from contextlib import redirect_stdout
        old_stdin = sys.stdin
        sys.stdin = io.StringIO(stdin_text)
        buf = io.StringIO()
        try:
            with redirect_stdout(buf):
                fixit_ai.cmd_extract()
        finally:
            sys.stdin = old_stdin
        return buf.getvalue()

    def test_extract_plain(self):
        self.assertEqual(self._run_extract("ls -la\n"), "ls -la\n")

    def test_extract_json_payload(self):
        body = json.dumps({"choices": [{"message": {"content": "git status"}}]})
        self.assertEqual(self._run_extract(body), "git status\n")

    def test_extract_no_command_prints_nothing(self):
        self.assertEqual(self._run_extract("just some prose"), "")

    def test_extract_empty_stdin(self):
        self.assertEqual(self._run_extract(""), "")


class TestProjHints(unittest.TestCase):
    def test_empty_dir_no_hints(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(fixit_ai.proj_hints(d), [])

    def test_package_json_scripts(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            Path(d, "package.json").write_text(
                json.dumps({"name": "app", "scripts": {"start": "node s.js", "dev": "vite"}}))
            hints = fixit_ai.proj_hints(d)
            self.assertEqual(hints, ["package.json scripts: start, dev"])

    def test_invalid_package_json_ignored(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            Path(d, "package.json").write_text("{broken")
            self.assertEqual(fixit_ai.proj_hints(d), [])

    def test_makefile_targets(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            Path(d, "Makefile").write_text("build:\n\tcc x.c\n\n.PHONY: test\ntest:\n\tpytest\n")
            hints = fixit_ai.proj_hints(d)
            self.assertEqual(hints, ["make targets: build, test"])

    def test_marker_files(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            Path(d, "docker-compose.yml").write_text("services: {}")
            Path(d, "go.mod").write_text("module x")
            hints = fixit_ai.proj_hints(d)
            self.assertEqual(hints, ["project files: docker-compose.yml, go.mod"])


class TestMain(unittest.TestCase):
    def test_main_defaults_to_extract(self):
        import io
        from contextlib import redirect_stdout
        old_argv, old_stdin = sys.argv, sys.stdin
        sys.argv = ["fixit-ai.py"]
        sys.stdin = io.StringIO("pwd\n")
        buf = io.StringIO()
        try:
            with redirect_stdout(buf):
                fixit_ai.main()
        finally:
            sys.argv, sys.stdin = old_argv, old_stdin
        self.assertEqual(buf.getvalue(), "pwd\n")

    def test_main_body_mode(self):
        import io
        from contextlib import redirect_stdout
        os.environ.update({"FX_MODEL": "m", "FX_SYS": "s", "FX_USER": "u"})
        old_argv = sys.argv
        sys.argv = ["fixit-ai.py", "body"]
        buf = io.StringIO()
        try:
            with redirect_stdout(buf):
                fixit_ai.main()
        finally:
            sys.argv = old_argv
        self.assertEqual(json.loads(buf.getvalue())["model"], "m")


if __name__ == "__main__":
    unittest.main()
