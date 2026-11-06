import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "sandbox-promote.py"
AGENT = "agent-1"


class SandboxPromoteTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.agent = self.root / AGENT
        self.scratch = self.agent / "scratch"
        self.artifacts = self.agent / "artifacts"
        self.scratch.mkdir(parents=True)

    def tearDown(self):
        self._tmp.cleanup()

    def run_promote(self, *files, agent=AGENT, max_total=1_000_000):
        env = dict(os.environ, SANDBOX_AGENTS_ROOT=str(self.root), SANDBOX_REQUIRE_DOCKER="0")
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--agent", agent, "--max-total", str(max_total), *files],
            env=env,
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )

    def result(self, proc, code):
        self.assertEqual(proc.returncode, code, proc.stderr)
        self.assertNotIn("Traceback", proc.stderr)
        return json.loads(proc.stdout)

    def write_scratch(self, rel, data):
        path = self.scratch / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def assert_rejected_only(self, proc, rel):
        out = self.result(proc, 1)
        self.assertEqual(out["promoted"], [])
        self.assertEqual([item["path"] for item in out["rejected"]], [rel])
        return out["rejected"][0]["reason"]

    def assert_rejected(self, proc, rel):
        reason = self.assert_rejected_only(proc, rel)
        self.assertFalse(os.path.lexists(self.artifacts / rel))
        return reason

    def test_regular_file_promoted(self):
        self.write_scratch("out.txt", b"hello\n")
        out = self.result(self.run_promote("out.txt:100"), 0)
        self.assertEqual(out, {"promoted": [f"agents/{AGENT}/artifacts/out.txt"], "rejected": []})
        self.assertEqual((self.artifacts / "out.txt").read_bytes(), b"hello\n")

    def test_nested_path_creates_directories(self):
        data = bytes(range(256)) * 300
        self.write_scratch("a/b/out.txt", data)
        out = self.result(self.run_promote(f"a/b/out.txt:{len(data)}"), 0)
        self.assertEqual(out["promoted"], [f"agents/{AGENT}/artifacts/a/b/out.txt"])
        self.assertTrue((self.artifacts / "a" / "b").is_dir())
        self.assertEqual((self.artifacts / "a/b/out.txt").read_bytes(), data)

    def test_symlink_leaf_rejected(self):
        target = self.write_scratch("real.txt", b"secret")
        os.symlink(target, self.scratch / "link.txt")
        self.assert_rejected(self.run_promote("link.txt:100"), "link.txt")

    def test_symlink_to_outside_rejected(self):
        outside = self.root / "outside.txt"
        outside.write_bytes(b"secret")
        os.symlink(outside, self.scratch / "link.txt")
        self.assert_rejected(self.run_promote("link.txt:100"), "link.txt")

    def test_symlinked_parent_component_rejected(self):
        self.write_scratch("real/out.txt", b"data")
        os.symlink("real", self.scratch / "linkdir")
        self.assert_rejected(self.run_promote("linkdir/out.txt:100"), "linkdir/out.txt")
        self.assertFalse((self.artifacts / "linkdir").exists())

    def test_hard_link_rejected(self):
        source = self.write_scratch("out.txt", b"data")
        os.link(source, self.root / "elsewhere.txt")
        reason = self.assert_rejected(self.run_promote("out.txt:100"), "out.txt")
        self.assertIn("link count", reason)

    def test_fifo_rejected_without_hanging(self):
        os.mkfifo(self.scratch / "pipe")
        reason = self.assert_rejected(self.run_promote("pipe:100"), "pipe")
        self.assertIn("not a regular file", reason)

    def test_directory_leaf_rejected(self):
        (self.scratch / "dir").mkdir()
        self.assert_rejected(self.run_promote("dir:100"), "dir")

    def test_file_over_per_file_limit_rejected(self):
        self.write_scratch("big.txt", b"x" * 11)
        reason = self.assert_rejected(self.run_promote("big.txt:10"), "big.txt")
        self.assertIn("exceeds limit", reason)

    def test_file_at_per_file_limit_promoted(self):
        self.write_scratch("exact.txt", b"x" * 10)
        self.result(self.run_promote("exact.txt:10"), 0)
        self.assertEqual((self.artifacts / "exact.txt").read_bytes(), b"x" * 10)

    def test_cumulative_limit_rejects_second_file(self):
        self.write_scratch("one.txt", b"1" * 6)
        self.write_scratch("two.txt", b"2" * 6)
        out = self.result(self.run_promote("one.txt:100", "two.txt:100", max_total=10), 1)
        self.assertEqual(out["promoted"], [f"agents/{AGENT}/artifacts/one.txt"])
        self.assertEqual([item["path"] for item in out["rejected"]], ["two.txt"])
        self.assertIn("exceeds limit 4", out["rejected"][0]["reason"])
        self.assertEqual((self.artifacts / "one.txt").read_bytes(), b"1" * 6)
        self.assertFalse((self.artifacts / "two.txt").exists())

    def test_unsafe_paths_rejected(self):
        self.write_scratch("a/out.txt", b"data")
        outside = self.root / "outside.txt"
        outside.write_bytes(b"secret")
        for rel in ("../outside.txt", "a/../a/out.txt", "./a/out.txt", str(outside), "/etc/passwd", "a//out.txt", "a/out.txt/", ""):
            with self.subTest(rel=rel):
                out = self.result(self.run_promote(f"{rel}:100"), 1)
                self.assertEqual(out["promoted"], [])
                self.assertEqual([item["path"] for item in out["rejected"]], [rel])
        self.assertEqual(list(self.artifacts.rglob("*")), [])

    def test_existing_destination_not_overwritten(self):
        self.write_scratch("out.txt", b"new")
        self.artifacts.mkdir()
        (self.artifacts / "out.txt").write_bytes(b"old")
        reason = self.assert_rejected_only(self.run_promote("out.txt:100"), "out.txt")
        self.assertIn("exclusively", reason)
        self.assertEqual((self.artifacts / "out.txt").read_bytes(), b"old")

    def test_symlink_destination_not_followed(self):
        self.write_scratch("out.txt", b"new")
        self.artifacts.mkdir()
        victim = self.root / "victim.txt"
        victim.write_bytes(b"old")
        os.symlink(victim, self.artifacts / "out.txt")
        self.assert_rejected_only(self.run_promote("out.txt:100"), "out.txt")
        self.assertTrue(os.path.islink(self.artifacts / "out.txt"))
        self.assertEqual(victim.read_bytes(), b"old")

    def test_bad_agent_ids_exit_2(self):
        self.write_scratch("out.txt", b"data")
        for agent in ("Upper", "con", "../x", "", "_x", "a" * 65):
            with self.subTest(agent=agent):
                proc = self.run_promote("out.txt:100", agent=agent)
                self.assertEqual(proc.returncode, 2, proc.stderr)
                self.assertEqual(proc.stdout, "")
                self.assertIn("agent ID", proc.stderr)
        self.assertFalse(self.artifacts.exists())

    def test_missing_scratch_dir_rejected_as_json(self):
        (self.agent / "other").mkdir()
        self.scratch.rmdir()
        out = self.result(self.run_promote("out.txt:100"), 1)
        self.assertEqual(out["promoted"], [])
        self.assertEqual(len(out["rejected"]), 1)
        self.assertEqual(out["rejected"][0]["path"], "*")
        self.assertIn("scratch", out["rejected"][0]["reason"])
        self.assertFalse(self.artifacts.exists())

    def test_missing_agent_dir_rejected_as_json(self):
        out = self.result(self.run_promote("out.txt:100", agent="nobody"), 1)
        self.assertEqual(out["promoted"], [])
        self.assertEqual(out["rejected"][0]["path"], "*")
        self.assertIn("nobody", out["rejected"][0]["reason"])

    def test_symlinked_scratch_root_rejected_as_json(self):
        real = self.root / "real-scratch"
        real.mkdir()
        (real / "out.txt").write_bytes(b"data")
        self.scratch.rmdir()
        os.symlink(real, self.scratch)
        out = self.result(self.run_promote("out.txt:100"), 1)
        self.assertEqual(out["promoted"], [])
        self.assertEqual(out["rejected"][0]["path"], "*")
        self.assertFalse(self.artifacts.exists())

    def test_symlinked_agent_root_rejected_as_json(self):
        real = self.root / "real-agent"
        (real / "scratch").mkdir(parents=True)
        (real / "scratch" / "out.txt").write_bytes(b"data")
        os.symlink(real, self.root / "linked")
        out = self.result(self.run_promote("out.txt:100", agent="linked"), 1)
        self.assertEqual(out["promoted"], [])
        self.assertEqual(out["rejected"][0]["path"], "*")
        self.assertFalse((real / "artifacts").exists())

    def test_mixed_batch(self):
        self.write_scratch("good.txt", b"good")
        os.symlink("good.txt", self.scratch / "bad.txt")
        out = self.result(self.run_promote("good.txt:100", "bad.txt:100"), 1)
        self.assertEqual(out["promoted"], [f"agents/{AGENT}/artifacts/good.txt"])
        self.assertEqual([item["path"] for item in out["rejected"]], ["bad.txt"])
        self.assertEqual((self.artifacts / "good.txt").read_bytes(), b"good")
        self.assertFalse(os.path.lexists(self.artifacts / "bad.txt"))

    def test_docker_required_without_docker_refuses(self):
        self.write_scratch("out.txt", b"data")
        env = dict(os.environ, SANDBOX_AGENTS_ROOT=str(self.root), SANDBOX_REQUIRE_DOCKER="1", PATH=str(self.root))
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--agent", AGENT, "--max-total", "100", "out.txt:100"],
            env=env,
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )
        out = self.result(proc, 1)
        self.assertEqual(out, {"promoted": [], "rejected": [{"path": "*", "reason": "cannot confirm the sandbox has exited"}]})
        self.assertFalse(self.artifacts.exists())


if __name__ == "__main__":
    unittest.main()
