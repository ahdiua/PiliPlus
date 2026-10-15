"""Exercise release scripts against disposable local Git repositories.

Run with Python 3 and Git Bash installed. Git merges, tags, and pushes are real;
only GitHub API responses and the upstream fetch URL are replaced with fixtures.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
GIT = shutil.which("git")
BASH = os.environ.get("BASH_EXE") or (
    str(Path(GIT).resolve().parents[1] / "bin/bash.exe")
    if os.name == "nt" else shutil.which("bash")
)
UPSTREAM = "bggRGjQaUbCoE/PiliPlus"


class ReleasePolicyTest(unittest.TestCase):
    def git(self, *args, cwd=None):
        return subprocess.check_output(
            [GIT, *args], cwd=cwd or self.fork, text=True, stderr=subprocess.PIPE,
            env=self.env,
        ).strip()

    def setUp(self):
        harness = ROOT / ".fvm/release-policy-tests"
        harness.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=harness)
        self.path = Path(self.temp.name).resolve()
        # All disposable repositories and cleanup remain inside the harness.
        assert self.path.is_relative_to(harness.resolve())
        self.addCleanup(self.temp.cleanup)
        self.upstream = self.path / "upstream"
        self.fork = self.path / "fork"
        self.remote = self.path / "origin.git"
        self.env = os.environ.copy()
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_TERMINAL_PROMPT="0", GIT_AUTHOR_NAME="Test",
                        GIT_AUTHOR_EMAIL="test@example.com", GIT_COMMITTER_NAME="Test",
                        GIT_COMMITTER_EMAIL="test@example.com")
        self.upstream.mkdir()
        self.git("init", "-b", "main", cwd=self.upstream)
        (self.upstream / "pubspec.yaml").write_text("version: 2.1.6+1\n")
        self.git("add", ".", cwd=self.upstream)
        self.git("commit", "-m", "base", cwd=self.upstream)
        base = self.git("rev-parse", "HEAD", cwd=self.upstream)
        (self.upstream / "stable.txt").write_text("official change\n")
        self.git("add", ".", cwd=self.upstream)
        self.git("commit", "-m", "stable", cwd=self.upstream)
        self.stable = self.git("rev-parse", "HEAD", cwd=self.upstream)
        self.git("tag", "-a", "v2.1.6", "-m", "upstream stable", cwd=self.upstream)
        (self.upstream / "development.txt").write_text("unreleased change\n")
        self.git("add", ".", cwd=self.upstream)
        self.git("commit", "-m", "development", cwd=self.upstream)
        self.development = self.git("rev-parse", "HEAD", cwd=self.upstream)
        self.git("tag", "v2.1.7-pre", cwd=self.upstream)
        self.git("init", "--bare", str(self.remote), cwd=self.path)
        self.git("clone", str(self.upstream), str(self.fork), cwd=self.path)
        self.git("switch", "-C", "main", base)
        self.git("remote", "set-url", "origin", str(self.remote))
        (self.fork / "fork.txt").write_text("fork feature\n")
        self.git("add", ".")
        self.git("commit", "-m", "fork feature")
        self.git("push", "origin", "main")
        self.initial = self.git("rev-parse", "HEAD")
        self.output = self.path / "output.txt"
        self.summary = self.path / "summary.txt"
        self.runner = self.path / "runner.sh"
        self.runner.write_text(r'''#!/usr/bin/env bash
set -euo pipefail
git() {
    if [[ "$1" == fetch && "$3" == https://github.com/bggRGjQaUbCoE/PiliPlus.git ]]; then
        command git fetch --no-tags "$TEST_UPSTREAM" "$4"
    else
        command git "$@"
    fi
}
gh() {
    if [[ "$*" != *'draft == false and .prerelease == false'* ]]; then
        echo 'Missing full-release filter' >&2; return 1
    fi
    if [[ "$*" == *'/releases/latest'* ]]; then
        if [[ -n "${API_ERROR:-}" ]]; then
            echo "gh: fixture error (HTTP $API_ERROR)" >&2; return 1
        fi
        printf '%s\n' "$UPSTREAM_TAG"
    elif [[ "$*" == *'repos/test/fork/releases'* ]]; then
        printf '%s\n' "${PUBLISHED_TAGS:-}"
    else
        echo 'Unexpected API request' >&2; return 1
    fi
}
date() { printf '%s\n' "$TEST_TIME"; }
source "$TEST_SCRIPT"
''', encoding="utf-8", newline="\n")
        self.env.update(TEST_UPSTREAM=self.upstream.as_posix(), GH_REPO="test/fork",
                        UPSTREAM_TAG="v2.1.6", TEST_TIME="20261014000000",
                        GITHUB_OUTPUT=self.output.as_posix(),
                        GITHUB_STEP_SUMMARY=self.summary.as_posix())

    def sync(self, event="schedule", **extra):
        self.output.write_text("")
        self.summary.write_text("")
        env = dict(self.env, SYNC_EVENT_NAME=event,
                   TEST_SCRIPT=(ROOT / "lib/scripts/sync-upstream.sh").as_posix(),
                   **extra)
        result = subprocess.run([BASH, self.runner.as_posix()], cwd=self.fork,
                                env=env, text=True, capture_output=True)
        data = dict(line.split("=", 1) for line in self.output.read_text().splitlines())
        return result, data

    def successful_sync(self, *args, **kwargs):
        result, data = self.sync(*args, **kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return data

    def metadata(self, tag, channel):
        self.output.write_text("")
        env = dict(self.env, RELEASE_INPUT_TAG=tag, RELEASE_PRERELEASE=channel)
        result = subprocess.run([BASH, (ROOT / "lib/scripts/release-metadata.sh").as_posix()],
                                cwd=self.fork, env=env, text=True, capture_output=True)
        return result, self.output.read_text()

    def test_daily_merges_only_official_tag_and_preserves_fork(self):
        data = self.successful_sync()
        self.assertEqual(data["prerelease"], "false")
        self.assertEqual(data["tag"], "v2.1.6F")
        self.assertTrue((self.fork / "stable.txt").exists())
        self.assertTrue((self.fork / "fork.txt").exists())
        self.assertFalse((self.fork / "development.txt").exists())
        self.assertEqual(self.git("rev-parse", f'{data["tag"]}^{{commit}}'), data["ref"])
        self.assertEqual(self.git("rev-parse", "main", cwd=self.remote), data["ref"])
        result, metadata = self.metadata(data["tag"], "false")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("prerelease=false\n", metadata)

    def test_daily_skips_published_tag_after_manual_preview(self):
        stable = self.successful_sync()
        self.successful_sync("workflow_dispatch", TEST_TIME="20261014000100")
        before = self.git("rev-parse", "HEAD")
        data = self.successful_sync(PUBLISHED_TAGS=stable["tag"])
        self.assertEqual(data, {})
        self.assertEqual(self.git("rev-parse", "HEAD"), before)

    def test_failed_stable_build_retries_original_tag_and_commit(self):
        stable = self.successful_sync()
        self.successful_sync("workflow_dispatch", TEST_TIME="20261014000100")
        before = self.git("rev-parse", "HEAD")
        retry = self.successful_sync(TEST_TIME="20261015000000")
        self.assertEqual(retry, stable)
        self.assertEqual(self.git("rev-parse", "HEAD"), before)

    def test_new_official_tag_publishes_after_previous_success(self):
        old = self.successful_sync()
        self.git("tag", "-a", "v2.1.7", "-m", "next stable", cwd=self.upstream)
        new = self.successful_sync(UPSTREAM_TAG="v2.1.7", PUBLISHED_TAGS=old["tag"],
                                   TEST_TIME="20261015000000")
        self.assertNotEqual(new["tag"], old["tag"])
        self.assertEqual(new["tag"], "v2.1.7F")
        self.assertTrue((self.fork / "development.txt").exists())

    def test_official_tag_preserves_all_upstream_version_parts(self):
        self.git("tag", "-a", "2.1.6.2", "-m", "four-part stable", self.stable,
                 cwd=self.upstream)
        data = self.successful_sync(UPSTREAM_TAG="2.1.6.2")
        self.assertEqual(data["tag"], "2.1.6.2F")
        self.assertFalse((self.fork / "development.txt").exists())

    def test_legacy_published_timestamp_tag_is_not_republished(self):
        legacy = "2.1.6F.20261015013225"
        self.git("tag", "-a", legacy, "-m", f"Upstream release: {UPSTREAM}@v2.1.6")
        data = self.successful_sync(PUBLISHED_TAGS=legacy)
        self.assertEqual(data, {})
        self.assertEqual(self.git("tag", "--list", "v2.1.6F"), "")
        self.assertEqual(self.git("rev-parse", "HEAD"), self.initial)

    def test_incomplete_legacy_timestamp_release_reuses_tag_and_commit(self):
        legacy = "2.1.6F.20261015013225"
        self.git("tag", "-a", legacy, "-m", f"Upstream release: {UPSTREAM}@v2.1.6")
        self.successful_sync("workflow_dispatch", TEST_TIME="20261015020000")
        data = self.successful_sync()
        self.assertEqual(data, {"tag": legacy, "ref": self.initial, "prerelease": "false"})
        self.assertEqual(self.git("tag", "--list", "v2.1.6F"), "")

    def test_existing_unrelated_release_tag_is_not_overwritten(self):
        self.git("tag", "-a", "v2.1.6F", "-m", "unrelated tag")
        result, data = self.sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to overwrite", result.stdout)
        self.assertEqual(data, {})
        self.assertEqual(self.git("rev-parse", "v2.1.6F^{commit}"), self.initial)
        self.assertEqual(self.git("rev-parse", "main", cwd=self.remote), self.initial)

    def test_manual_merges_development_and_publishes_preview(self):
        data = self.successful_sync("workflow_dispatch", API_ERROR="500")
        self.assertEqual(data["prerelease"], "true")
        self.assertTrue(data["tag"].endswith("-pre"))
        self.assertTrue((self.fork / "development.txt").exists())
        result, metadata = self.metadata(data["tag"], "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("prerelease=true\n", metadata)

    def test_no_official_release_does_nothing(self):
        for extra in ({"API_ERROR": "404"}, {"UPSTREAM_TAG": ""}):
            with self.subTest(extra=extra):
                self.assertEqual(self.successful_sync(**extra), {})
                self.assertEqual(self.git("rev-parse", "HEAD"), self.initial)
                self.assertEqual(self.git("tag", "--list", "*F*"), "")

    def test_api_failure_stops_without_merge_or_tag(self):
        result, data = self.sync(API_ERROR="403")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(data, {})
        self.assertEqual(self.git("rev-parse", "HEAD"), self.initial)

    def test_merge_conflict_does_not_push_or_tag(self):
        (self.fork / "stable.txt").write_text("conflicting fork change\n")
        self.git("add", ".")
        self.git("commit", "-m", "fork conflict")
        before = self.git("rev-parse", "HEAD")
        result, data = self.sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(data, {})
        self.assertEqual(self.git("rev-parse", "HEAD"), before)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.git("rev-parse", "main", cwd=self.remote), self.initial)
        self.assertEqual(self.git("tag", "--list", "*F*"), "")

    def test_unexpected_event_cannot_publish(self):
        result, data = self.sync("push")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(data, {})
        self.assertEqual(self.git("rev-parse", "HEAD"), self.initial)

    def test_metadata_rejects_channel_mismatch_and_wrong_commit(self):
        stable = self.successful_sync()
        result, output = self.metadata(stable["tag"], "true")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output, "")
        preview = self.successful_sync("workflow_dispatch", TEST_TIME="20261014000100")
        result, output = self.metadata(preview["tag"], "false")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output, "")
        result, output = self.metadata(stable["tag"], "false")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
