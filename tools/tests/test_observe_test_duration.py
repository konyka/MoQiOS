"""Deterministic contract tests for the non-gating duration observer."""

import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import unittest


OBSERVER_PATH = Path(__file__).parents[1] / "observe_test_duration.py"
DOCS_PATH = Path(__file__).parents[2] / "docs" / "build-and-toolchain.md"
SPEC = importlib.util.spec_from_file_location("observe_test_duration", OBSERVER_PATH)
assert SPEC is not None and SPEC.loader is not None
observer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(observer)


class ObserveTestDurationTests(unittest.TestCase):
    def run_cli(self, *args, stdout=None, stderr=None):
        return subprocess.run(
            [sys.executable, str(OBSERVER_PATH), *args],
            stdout=stdout,
            stderr=stderr,
            check=False,
        )

    def run_observer(
        self, *, runner, clock, output=None, diagnostic=None, json_encoder=json.dumps
    ):
        stream = output if output is not None else io.StringIO()
        diagnostics = diagnostic if diagnostic is not None else io.StringIO()
        result = observer.observe(
            scenario="host-tests",
            source="host",
            command=["zig", "build", "test", "--summary", "all"],
            runner=runner,
            clock=clock,
            record_output=stream,
            diagnostic_output=diagnostics,
            json_encoder=json_encoder,
        )
        return result, stream, diagnostics

    def test_host_success_emits_exact_completed_json_record(self):
        result, stream, diagnostics = self.run_observer(
            runner=lambda command: 0,
            clock=iter([1_000_000, 3_500_000]).__next__,
        )

        self.assertEqual(0, result)
        self.assertEqual("", diagnostics.getvalue())
        self.assertEqual(
            '{"schema_version":1,"scenario":"host-tests","source":"host",'
            '"status":"completed","sample_count":1,"gating":false,'
            '"duration_ms":2.5}\n',
            stream.getvalue(),
        )

    def test_default_command_is_the_canonical_host_test_command(self):
        args = observer.parse_args([])

        self.assertEqual([], args.command)
        self.assertEqual(
            ["zig", "build", "test", "--summary", "all"], observer.DEFAULT_COMMAND
        )

    def test_child_nonzero_exit_is_preserved(self):
        result, stream, diagnostics = self.run_observer(
            runner=lambda command: 37,
            clock=iter([10, 1_000_010]).__next__,
        )

        self.assertEqual(37, result)
        self.assertEqual("", diagnostics.getvalue())
        self.assertEqual(1.0, json.loads(stream.getvalue())["duration_ms"])

    def test_stdout_failure_preserves_child_exit(self):
        with open("/dev/full", "w") as output:
            result = self.run_cli("--", "sh", "-c", "exit 7", stdout=output)

        self.assertEqual(7, result.returncode)

    def test_output_file_failure_preserves_child_exit(self):
        result = self.run_cli(
            "--output", "/dev/full", "--", "sh", "-c", "exit 7", stdout=subprocess.DEVNULL
        )

        self.assertEqual(7, result.returncode)

    def test_diagnostic_failure_preserves_child_exit(self):
        with open("/dev/full", "w") as diagnostics:
            result = self.run_cli(
                "--", "sh", "-c", "exit 7", stdout=diagnostics, stderr=diagnostics
            )

        self.assertEqual(7, result.returncode)

    def test_signal_exit_uses_shell_status(self):
        result = self.run_cli(
            "--", "sh", "-c", "kill -TERM $$", stdout=subprocess.DEVNULL
        )

        self.assertEqual(143, result.returncode)

    def test_docs_do_not_promise_qemu_runtime_sampling(self):
        docs = DOCS_PATH.read_text(encoding="utf-8")

        self.assertIn("P1 emits an unavailable record without probing QEMU or Limine", docs)
        self.assertNotIn("until a pin-compliant Limine checkout permits runtime samples", docs)

    def test_qemu_unavailable_is_declarative_without_duration(self):
        stream = io.StringIO()
        diagnostics = io.StringIO()

        result = observer.emit_unavailable(
            scenario="qemu-smoke",
            source="qemu",
            record_output=stream,
            diagnostic_output=diagnostics,
        )

        self.assertEqual(0, result)
        self.assertEqual("", diagnostics.getvalue())
        self.assertEqual(
            {
                "schema_version": 1,
                "scenario": "qemu-smoke",
                "source": "qemu",
                "status": "unavailable",
                "sample_count": 0,
                "gating": False,
                "unavailable_reason": "qemu_dependency_unavailable",
            },
            json.loads(stream.getvalue()),
        )

    def test_timer_failure_retains_child_exit_without_duration(self):
        result, stream, diagnostics = self.run_observer(
            runner=lambda command: 23,
            clock=lambda: (_ for _ in ()).throw(RuntimeError("clock failed")),
        )

        self.assertEqual(23, result)
        self.assertEqual("", stream.getvalue())
        self.assertIn("duration observation failed: clock failed", diagnostics.getvalue())

    def test_record_output_failure_retains_child_exit(self):
        class FailingOutput:
            def write(self, value):
                raise OSError("disk full")

            def flush(self):
                raise OSError("disk full")

        result, stream, diagnostics = self.run_observer(
            runner=lambda command: 41,
            clock=iter([0, 1_000_000]).__next__,
            output=FailingOutput(),
        )

        self.assertEqual(41, result)
        self.assertIn("duration observation failed: disk full", diagnostics.getvalue())

    def test_json_failure_retains_child_exit(self):
        result, stream, diagnostics = self.run_observer(
            runner=lambda command: 53,
            clock=iter([0, 1_000_000]).__next__,
            json_encoder=lambda record, separators: (_ for _ in ()).throw(
                TypeError("encoding failed")
            ),
        )

        self.assertEqual(53, result)
        self.assertEqual("", stream.getvalue())
        self.assertIn("duration observation failed: encoding failed", diagnostics.getvalue())


if __name__ == "__main__":
    unittest.main()
