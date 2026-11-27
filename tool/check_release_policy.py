"""Exercise the release scripts against disposable local Git repositories.

Run with Python 3 and Git Bash installed. Git merges, tags, and pushes are real;
only GitHub API responses and the upstream fetch URL are replaced with fixtures.

Releases are tags pushed by hand (lib/scripts/release-tag.sh); syncing upstream
(lib/scripts/sync-upstream.sh) only merges and pushes main. See
docs/releases.md.
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
        self.git("fetch", "origin")
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
    if [[ "$*" == *'repos/bggRGjQaUbCoE/PiliPlus/releases/latest'* ]]; then
        if [[ -n "${API_ERROR:-}" ]]; then
            echo "gh: fixture error (HTTP $API_ERROR)" >&2; return 1
        fi
        printf '%s\n' "$UPSTREAM_TAG"
    else
        echo 'Unexpected API request' >&2; return 1
    fi
}
source "$TEST_SCRIPT"
''', encoding="utf-8", newline="\n")
        self.env.update(TEST_UPSTREAM=self.upstream.as_posix(), UPSTREAM_TAG="v2.1.6",
                        GITHUB_OUTPUT=self.output.as_posix(),
                        GITHUB_STEP_SUMMARY=self.summary.as_posix())

    def run_script(self, script, **extra):
        self.output.write_text("")
        self.summary.write_text("")
        env = dict(self.env, TEST_SCRIPT=(ROOT / "lib/scripts" / script).as_posix(),
                   **extra)
        result = subprocess.run([BASH, self.runner.as_posix()], cwd=self.fork,
                                env=env, text=True, capture_output=True)
        data = dict(line.split("=", 1) for line in self.output.read_text().splitlines())
        return result, data

    def sync(self, source="release", **extra):
        return self.run_script("sync-upstream.sh", SYNC_SOURCE=source, **extra)

    def successful_sync(self, *args, **kwargs):
        result, data = self.sync(*args, **kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # Syncing never hands a release to the build.
        self.assertEqual(data, {})
        return self.summary.read_text()

    def release_tag(self, tag):
        return self.run_script("release-tag.sh", RELEASE_TAG=tag)

    def metadata(self, tag, channel):
        self.output.write_text("")
        env = dict(self.env, RELEASE_INPUT_TAG=tag, RELEASE_PRERELEASE=channel)
        result = subprocess.run([BASH, (ROOT / "lib/scripts/release-metadata.sh").as_posix()],
                                cwd=self.fork, env=env, text=True, capture_output=True)
        return result, self.output.read_text()

    def remote_main(self):
        return self.git("rev-parse", "main", cwd=self.remote)

    def release_tags(self):
        return self.git("tag", "--list", "*F*")

    # Syncing upstream

    def test_release_source_merges_only_the_official_tag_and_pushes_main(self):
        summary = self.successful_sync()
        self.assertTrue((self.fork / "stable.txt").exists())
        self.assertTrue((self.fork / "fork.txt").exists())
        self.assertFalse((self.fork / "development.txt").exists())
        self.assertEqual(self.remote_main(), self.git("rev-parse", "HEAD"))
        self.assertIn(f"{UPSTREAM}@v2.1.6", self.git("log", "-1", "--format=%s"))
        self.assertEqual(self.release_tags(), "")
        self.assertIn("push a tag such as v2.1.6F ", summary)

    def test_release_source_suggests_a_fork_number_after_a_release(self):
        self.git("tag", "v2.1.6F")
        summary = self.successful_sync()
        self.assertIn("push a tag such as v2.1.6F.<n> ", summary)

    def test_main_source_merges_upstream_development(self):
        summary = self.successful_sync("main")
        self.assertTrue((self.fork / "development.txt").exists())
        self.assertTrue((self.fork / "fork.txt").exists())
        self.assertEqual(self.remote_main(), self.git("rev-parse", "HEAD"))
        self.assertEqual(self.release_tags(), "")
        self.assertIn("push a tag such as 2.1.6F.<n> ", summary)

    def test_merged_upstream_is_not_merged_again(self):
        self.successful_sync()
        before = self.git("rev-parse", "HEAD")
        summary = self.successful_sync()
        self.assertIn("already contains", summary)
        self.assertEqual(self.git("rev-parse", "HEAD"), before)
        self.assertEqual(self.remote_main(), before)

    def test_no_official_release_does_nothing(self):
        for extra in ({"API_ERROR": "404"}, {"UPSTREAM_TAG": ""}):
            with self.subTest(extra=extra):
                self.successful_sync(**extra)
                self.assertEqual(self.git("rev-parse", "HEAD"), self.initial)
                self.assertEqual(self.remote_main(), self.initial)

    def test_api_failure_stops_without_merge(self):
        result, data = self.sync(API_ERROR="403")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(data, {})
        self.assertEqual(self.git("rev-parse", "HEAD"), self.initial)
        self.assertEqual(self.remote_main(), self.initial)

    def test_merge_conflict_does_not_push(self):
        (self.fork / "stable.txt").write_text("conflicting fork change\n")
        self.git("add", ".")
        self.git("commit", "-m", "fork conflict")
        before = self.git("rev-parse", "HEAD")
        result, data = self.sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("conflicts", result.stdout)
        self.assertEqual(data, {})
        self.assertEqual(self.git("rev-parse", "HEAD"), before)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.remote_main(), self.initial)

    def test_unknown_source_fails(self):
        result, data = self.sync("schedule")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(data, {})
        self.assertEqual(self.remote_main(), self.initial)

    # Releasing a pushed tag

    def test_release_tag_forms_and_channels(self):
        for tag, prerelease in (("2.1.6F", "false"), ("2.1.6F.1", "false"),
                                ("2.1.6.2F.3", "false"), ("v2.1.6F.12", "false"),
                                ("2.1.6F-pre", "true"), ("2.1.6F.2-pre", "true")):
            with self.subTest(tag=tag):
                self.git("tag", tag)
                result, data = self.release_tag(tag)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(data, {"tag": tag, "ref": self.initial,
                                        "prerelease": prerelease})

    def test_release_tag_rejects_other_forms(self):
        for tag in ("2.1.6", "2.1.6.1", "2.1.6F.0", "2.1.6F.01", "2.1.6F1",
                    "2.1.6-pre", "2.1.6F.1-beta", "F2.1.6", "2.1.6F.1.2"):
            with self.subTest(tag=tag):
                self.git("tag", tag)
                result, data = self.release_tag(tag)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("is not <upstream version>F", result.stdout)
                self.assertEqual(data, {})

    def test_release_tag_must_match_pubspec(self):
        self.git("tag", "2.1.7F.1")
        result, data = self.release_tag("2.1.7F.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pubspec.yaml", result.stdout)
        self.assertEqual(data, {})

    def test_release_tag_must_be_on_main(self):
        self.git("switch", "-c", "side")
        (self.fork / "side.txt").write_text("not on main\n")
        self.git("add", ".")
        self.git("commit", "-m", "side")
        self.git("tag", "2.1.6F.1")
        result, data = self.release_tag("2.1.6F.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not on main", result.stdout)
        self.assertEqual(data, {})

    def test_missing_release_tag_fails(self):
        result, data = self.release_tag("2.1.6F.9")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not exist", result.stdout)
        self.assertEqual(data, {})

    def test_metadata_rejects_channel_mismatch_and_wrong_commit(self):
        self.git("tag", "2.1.6F.1")
        self.git("tag", "2.1.6F.2-pre")
        result, output = self.metadata("2.1.6F.1", "false")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("prerelease=false\n", output)
        result, output = self.metadata("2.1.6F.2-pre", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("prerelease=true\n", output)
        for tag, channel in (("2.1.6F.1", "true"), ("2.1.6F.2-pre", "false")):
            with self.subTest(tag=tag, channel=channel):
                result, output = self.metadata(tag, channel)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output, "")
        (self.fork / "later.txt").write_text("later\n")
        self.git("add", ".")
        self.git("commit", "-m", "later")
        result, output = self.metadata("2.1.6F.1", "false")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
