#!/usr/bin/env python3
"""Checks a Purser audit export (JSONL) for the write-safety invariants used in M3.

Input (contract K3, AuditLog.exportJSONL): one ChainLine JSON object per line with the keys
  seq (number), ts, type, actor, refs, payload, prevHash, hash
where refs and payload are JSON objects encoded as STRINGS; this tool decodes them again.
A line in any other shape (for example a payloadJSON key or refs as a JSON object) makes the input unreadable (exit 2).

Checks (any failure -> exit code 1):
  - seq grows by exactly 1 and prevHash equals the previous event's hash (genesis prevHash = 64 x "0" for seq 1);
  - no line contains "Bearer ", "-----BEGIN" or an "authorization" JSON key (also inside the encoded strings);
  - every httpSent and httpReceived payload names its method and path;
  - every httpReceived has an earlier, still unanswered httpSent with the same request key.
Request key (K3 refs keys):
  Executor item:   ("plan", refs.plan, refs.seq)
  ApprovedProbe:   ("probe", refs.probe, method, path)
  SpikeProbe:      ("spike", refs.spike, refs.step, method, path)
  anything else:   ("other", refs)
Received events are counted by payload.status when it is set, otherwise by payload.outcome
(after a successful write the Executor stores status null or omits it, with outcome "ok").
An httpSent without a later httpReceived is only a warning (possible after a crash or a timeout, e.g. the S8
drills of M2; the item must then have been resolved by a fresh read, which the run log has to explain).
With --plan, the summary and the warnings are limited to that plan; warnings of other groups are only counted.
Problems are never filtered: any problem anywhere in the export gives exit code 1.
The hash values themselves are verified by Purser (History -> Verify chain), not here.
"""
import argparse
import json
import re
import sys
from collections import Counter, defaultdict

GENESIS = "0" * 64
REQUIRED_KEYS = ("seq", "ts", "type", "actor", "refs", "payload", "prevHash", "hash")
SECRET_PATTERNS = (
    re.compile(r"Bearer "),
    re.compile(r"-----BEGIN"),
    re.compile(r'authorization\\*"\s*:', re.IGNORECASE),
)


class AuditReportError(Exception):
    pass


def decode_object(event, key, number):
    """refs and payload are JSON objects encoded as strings (K3)."""
    raw = event[key]
    if not isinstance(raw, str):
        raise AuditReportError(f"line {number}: '{key}' must be a JSON-encoded string (contract K3)")
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise AuditReportError(f"line {number}: '{key}' is not valid JSON ({error})")
    if not isinstance(value, dict):
        raise AuditReportError(f"line {number}: '{key}' must encode a JSON object")
    return value


def parse_lines(lines):
    """[(line number, raw line, event, refs, payload)] for every non-empty line."""
    events = []
    for number, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError as error:
            raise AuditReportError(f"line {number}: not valid JSON ({error})")
        if not isinstance(event, dict):
            raise AuditReportError(f"line {number}: not a JSON object")
        for key in REQUIRED_KEYS:
            if key not in event:
                raise AuditReportError(f"line {number}: missing key '{key}' (contract K3 ChainLine)")
        if not isinstance(event["seq"], int) or isinstance(event["seq"], bool):
            raise AuditReportError(f"line {number}: 'seq' must be a number")
        refs = decode_object(event, "refs", number)
        payload = decode_object(event, "payload", number)
        events.append((number, line, event, refs, payload))
    return events


def request_key(refs, payload):
    method, path = payload.get("method"), payload.get("path")
    if "plan" in refs:
        return ("plan", refs["plan"], refs.get("seq", "?")), f"plan {refs['plan']}"
    if "probe" in refs:
        return ("probe", refs["probe"], method, path), f"probe {refs['probe']}"
    if "spike" in refs:
        return ("spike", refs["spike"], refs.get("step", "?"), method, path), f"spike {refs['spike']}"
    return ("other", json.dumps(refs, sort_keys=True)), "other"


def received_label(payload):
    status = payload.get("status")
    if isinstance(status, int) and not isinstance(status, bool):
        return str(status)
    if isinstance(status, str) and status:
        return status
    outcome = payload.get("outcome")
    if isinstance(outcome, str) and outcome:
        return outcome
    return "error" if payload.get("error") is not None else "?"


def check(events):
    problems, warnings = [], []
    sent, received = defaultdict(Counter), defaultdict(Counter)
    pending = defaultdict(list)
    previous = None
    for number, line, event, refs, payload in events:
        for pattern in SECRET_PATTERNS:
            if pattern.search(line):
                problems.append(f"line {number}: forbidden pattern {pattern.pattern!r}")
        seq = event["seq"]
        if previous is None:
            if seq == 1 and event["prevHash"] != GENESIS:
                problems.append("seq 1: prevHash is not the genesis hash")
        else:
            if seq != previous["seq"] + 1:
                problems.append(f"seq {seq}: expected {previous['seq'] + 1}")
            if event["prevHash"] != previous["hash"]:
                problems.append(f"seq {seq}: prevHash does not match hash of seq {previous['seq']}")
        previous = event
        kind = event["type"]
        if kind not in ("httpSent", "httpReceived"):
            continue
        for field in ("method", "path"):
            if not payload.get(field):
                problems.append(f"seq {seq}: {kind} without {field} in payload")
        key, group = request_key(refs, payload)
        if kind == "httpSent":
            pending[key].append((seq, group))
            sent[group][payload.get("method") or "?"] += 1
        else:
            if pending[key]:
                pending[key].pop(0)
            else:
                problems.append(f"seq {seq}: httpReceived without an earlier httpSent ({group})")
            received[group][received_label(payload)] += 1
    for entries in pending.values():
        for seq, group in entries:
            warnings.append((group, f"seq {seq}: httpSent without httpReceived ({group})"))
    warnings.sort(key=lambda warning: warning[1])
    return problems, warnings, sent, received


def render(events, problems, warnings, sent, received, plan=None):
    out = []
    if events:
        out.append(f"events: {len(events)} (seq {events[0][2]['seq']}..{events[-1][2]['seq']})")
    else:
        out.append("events: 0")
    for group in sorted(set(sent) | set(received)):
        if plan and group != f"plan {plan}":
            continue
        sent_text = " ".join(f"{method}={count}" for method, count in sorted(sent[group].items()))
        received_text = " ".join(f"{label}={count}" for label, count in sorted(received[group].items()))
        out.append(f"{group}: sent {sent_text or '-'}; received {received_text or '-'}")
    out.append(f"problems: {len(problems)}")
    out.extend(f"  {problem}" for problem in problems)
    shown = [text for group, text in warnings if not plan or group == f"plan {plan}"]
    out.append(f"warnings: {len(shown)}")
    out.extend(f"  {warning}" for warning in shown)
    if plan and len(shown) != len(warnings):
        out.append(f"warnings outside plan {plan}: {len(warnings) - len(shown)}")
    return "\n".join(out)


def run(lines, plan=None):
    events = parse_lines(lines)
    problems, warnings, sent, received = check(events)
    return (1 if problems else 0), render(events, problems, warnings, sent, received, plan)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Check a Purser audit export (JSONL, contract K3).")
    parser.add_argument("export")
    parser.add_argument("--plan", help="limit the per-group summary to one plan id")
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)
    try:
        with open(args.export, encoding="utf-8") as f:
            code, text = run(f.readlines(), args.plan)
    except (OSError, UnicodeDecodeError, AuditReportError) as error:
        print(f"audit-report: {error}", file=sys.stderr)
        return 2
    print(text)
    return code


if __name__ == "__main__":
    sys.exit(main())
