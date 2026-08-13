#!/usr/bin/env python3
"""Emit non-gating JSONL duration observations for test commands."""

import argparse
import json
import os
import subprocess
import sys
import time


SCHEMA_VERSION = 1
DEFAULT_COMMAND = ["zig", "build", "test", "--summary", "all"]


def completed_record(scenario, source, duration_ns):
    return {
        "schema_version": SCHEMA_VERSION,
        "scenario": scenario,
        "source": source,
        "status": "completed",
        "sample_count": 1,
        "gating": False,
        "duration_ms": duration_ns / 1_000_000,
    }


def unavailable_record(scenario, source):
    return {
        "schema_version": SCHEMA_VERSION,
        "scenario": scenario,
        "source": source,
        "status": "unavailable",
        "sample_count": 0,
        "gating": False,
        "unavailable_reason": "qemu_dependency_unavailable",
    }


def _silence_broken_standard_stream(stream):
    if stream is sys.stdout:
        sys.stdout = open(os.devnull, "w")
    elif stream is sys.stderr:
        sys.stderr = open(os.devnull, "w")


def _write_text_safely(stream, text):
    try:
        stream.write(text)
        stream.flush()
        return None
    except Exception as error:
        _silence_broken_standard_stream(stream)
        return error


def write_record(record, record_output, json_encoder=json.dumps):
    text = json_encoder(record, separators=(",", ":")) + "\n"
    error = _write_text_safely(record_output, text)
    if error is not None:
        raise error


def report_failure(error, diagnostic_output):
    _write_text_safely(diagnostic_output, "duration observation failed: {}\n".format(error))


def observe(
    *,
    scenario,
    source,
    command,
    runner,
    clock,
    record_output,
    diagnostic_output,
    json_encoder=json.dumps,
):
    """Run a child and return its exit code regardless of observer failures."""
    started_ns = None
    try:
        started_ns = clock()
    except Exception as error:
        report_failure(error, diagnostic_output)

    child_exit_code = runner(command)

    if started_ns is None:
        return child_exit_code

    try:
        duration_ns = clock() - started_ns
        write_record(
            completed_record(scenario, source, duration_ns), record_output, json_encoder
        )
    except Exception as error:
        report_failure(error, diagnostic_output)
    return child_exit_code


def emit_unavailable(*, scenario, source, record_output, diagnostic_output):
    try:
        write_record(unavailable_record(scenario, source), record_output)
    except Exception as error:
        report_failure(error, diagnostic_output)
    return 0


def run_child(command):
    try:
        child_exit_code = subprocess.call(command)
        return 128 + -child_exit_code if child_exit_code < 0 else child_exit_code
    except OSError as error:
        _write_text_safely(
            sys.stderr, "failed to execute observed command: {}\n".format(error)
        )
        return 127


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", help="append each JSONL record to this local file")
    parser.add_argument("--scenario", default="host-tests")
    parser.add_argument("--source", default="host")
    parser.add_argument(
        "--qemu-unavailable",
        action="store_true",
        help="emit a QEMU dependency-unavailable record without probing QEMU or Limine",
    )
    parser.add_argument("command", nargs=argparse.REMAINDER)
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    if args.qemu_unavailable:
        if args.command:
            sys.stderr.write("--qemu-unavailable does not accept a command\n")
            return 2
        scenario = args.scenario if args.scenario != "host-tests" else "qemu-smoke"
        source = args.source if args.source != "host" else "qemu"
        return emit_to_destinations(
            unavailable_record(scenario, source), args.output, sys.stdout, sys.stderr
        )

    command = args.command or DEFAULT_COMMAND
    if command[:1] == ["--"]:
        command = command[1:]
    return observe_to_destinations(command, args)


def emit_to_destinations(record, output_path, stdout, diagnostics):
    try:
        write_record(record, stdout)
        if output_path:
            output_file = open(output_path, "a", encoding="utf-8")
            try:
                write_record(record, output_file)
            finally:
                try:
                    output_file.close()
                except Exception as error:
                    report_failure(error, diagnostics)
    except Exception as error:
        report_failure(error, diagnostics)
    return 0


def observe_to_destinations(command, args):
    started_ns = None
    try:
        started_ns = time.perf_counter_ns()
    except Exception as error:
        report_failure(error, sys.stderr)

    child_exit_code = run_child(command)
    if started_ns is None:
        return child_exit_code

    try:
        record = completed_record(args.scenario, args.source, time.perf_counter_ns() - started_ns)
        emit_to_destinations(record, args.output, sys.stdout, sys.stderr)
    except Exception as error:
        report_failure(error, sys.stderr)
    return child_exit_code


if __name__ == "__main__":
    raise SystemExit(main())
