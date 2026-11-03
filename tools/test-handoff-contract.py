#!/usr/bin/env python3
"""Offline parser/case contract checks. No host mutations or network access."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TIP = "cd1c951cb0a2b8d33971b8cf2f87907dfa100221"


class HandoffContract(unittest.TestCase):
    def parse(self, directory, since):
        env = dict(os.environ, HT_STATE_DIR=str(directory))
        return subprocess.check_output(
            [os.environ.get("HWTEST_BASH", "bash"), "-c",
             'source "$1/macos/common.sh"; HT_STATE_DIR="$2"; parse_agent_events "$3"',
             "test", str(ROOT), str(directory), str(since)], env=env, text=True)

    def test_shared_fixture_and_rotation(self):
        expected = json.loads((ROOT / "tests/event-expectations.json").read_text())
        with tempfile.TemporaryDirectory() as directory:
            for name in ("agent.1.log", "agent.2.log"):
                (Path(directory) / name).write_bytes((ROOT / "tests/agent-events.log").read_bytes())
            output = self.parse(directory, expected.pop("since_ms"))
        summary = next(line.split("\t", 1)[1] for line in output.splitlines() if line.startswith("SUMMARY\t"))
        self.assertEqual({k: int(v) for k, v in (x.split("=") for x in summary.split())}, expected)
        self.assertNotIn("transfer_id=999", output)
        self.assertIn("peer=Mac mini", output)
        self.assertIn("(Partial)", output)
        self.assertIn("(Timeout)", output)
        self.assertIn("(Cancelled)", output)
        self.assertNotIn("CROSSING DURATION", output)
        self.assertIn("UNAVAILABLE: sender edge->handoff completed", output)

    def test_empty_log_is_not_success(self):
        with tempfile.TemporaryDirectory() as directory:
            output = self.parse(directory, 0)
        self.assertIn("outgoing_arrived=0 incoming_arrived=0 other_terminal=0 diagnostics=0", output)

    def test_duplicate_transfer_not_duplicate_success(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "agent.1.log").write_text(
                '2026-11-03T08:00:00Z INFO f: Flow handoff completed peer="Mac mini" transfer_id=7 outcome=1\n'
                '2026-11-03T08:00:01Z INFO f: Flow handoff completed peer="Mac mini" transfer_id=7 outcome=1\n')
            output = self.parse(directory, 0)
        self.assertIn("outgoing_arrived=1 incoming_arrived=0", output)

    def test_case_manifest_and_gates(self):
        manifest = json.loads((ROOT / "handoff-cases.json").read_text())
        self.assertEqual(manifest["source_tip"], TIP)
        self.assertEqual([c["id"] for c in manifest["cases"]], [f"H{i:02}" for i in range(1, 9)])
        runbook = (ROOT / "RUNBOOK-Jay.md").read_text()
        coverage = (ROOT / "COVERAGE-tip-cd1c951c.md").read_text()
        for case in manifest["cases"]:
            self.assertIn(case["id"], runbook)
            self.assertIn(case["id"], coverage)
            for key in ("id", "title", "instructions"):
                self.assertTrue(case[key])
                self.assertNotRegex(case[key], r"[\r\n\t]")
        for name in ("windows/Invoke-OpenLogiFlowTest.ps1", "macos/run-openlogi-flow-test.sh"):
            script = (ROOT / name).read_text(encoding="utf-8-sig")
            for token in ("handoff-cases.json", "HWCASE", "PASS-MANUAL", "BLOCKED", "FAIL", "NOT AUTOMATICALLY PASSED"):
                self.assertIn(token, script)
            self.assertNotIn("CROSSING DURATION", script)
        self.assertIn("$WithInjection -and -not $SkipInjection", (ROOT / "windows/Invoke-OpenLogiFlowTest.ps1").read_text(encoding="utf-8-sig"))

    def test_preserve_allowlist_exactly(self):
        # Intentionally pinned to the reviewed safety branch. Adding mutation targets needs a separate review.
        self.assertEqual(hashlib.sha256((ROOT / "allowlist.json").read_bytes()).hexdigest(),
                         "a7d51fd3d73dce69dc2b0c86cbd2a49e0017518fb7ac60356d63185b72a7d1ee")

    def test_no_fabricated_edge_start(self):
        for name in ("macos/common.sh", "windows/Invoke-OpenLogiFlowTest.ps1"):
            script = (ROOT / name).read_text(encoding="utf-8-sig")
            self.assertNotIn("pendingSwitch", script)
            self.assertNotIn('if "edge" in ev.lower()', script)

    @unittest.skipUnless(os.environ.get("OPENLOGI_SOURCE_TREE"), "set OPENLOGI_SOURCE_TREE for optional pinned source drift guard")
    def test_pinned_source_contract(self):
        source = Path(os.environ["OPENLOGI_SOURCE_TREE"])
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
        self.assertEqual(head, TIP, "Re-audit case manifest before testing another source tip")
        flow = source / "crates/openlogi-agent-core/src/flow"
        sender = (flow / "handoff/sender.rs").read_text()
        handoff = (flow / "handoff.rs").read_text()
        for constant, seconds in (("REQUEST_TIMEOUT", 2), ("NETWORK_SLACK", 2), ("MAX_PEER_ARM_TIMEOUT", 40)):
            self.assertRegex(sender, rf"const {constant}: Duration = Duration::from_secs\({seconds}\)")
        self.assertRegex(handoff, r"const ARM_TIMEOUT: Duration = Duration::from_secs\(30\)")
        self.assertIn("accept_then_switch(", sender)
        for event in ("Flow handoff completed", "Flow handoff rejected", "Flow handoff request timed out",
                      "Flow host switch failed after receiver acceptance", "Flow arrival acknowledgment timed out",
                      "Flow peer returned an invalid handoff acceptance", "Flow handoff cancelled by peer"):
            self.assertIn('"' + event + '"', sender)
            self.assertIn(event, (ROOT / "macos/common.sh").read_text())
            self.assertIn(event, (ROOT / "windows/HwTest.Common.ps1").read_text(encoding="utf-8-sig"))
        self.assertIn('"Flow incoming handoff finished"', handoff)
        # This is a drift guard, not a substitute for the Rust behavior tests or hardware.


if __name__ == "__main__":
    unittest.main(verbosity=2)
