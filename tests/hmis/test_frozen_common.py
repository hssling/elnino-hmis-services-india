"""Paper E never edits models/common/R (plan Task 7 spec-gap note; rulings F16, F51).

Paper D's assert_frozen()/d_assert_frozen() refuse to run when models/common/R differs from the A or C tag, and
Paper D's ASO 2026 refresh depends on them. Paper E's monthly extensions live in models/E/R and call the common
functions unchanged, so the annual behaviour of Papers A-D is unchanged by construction. This test checks both
tracked differences (staged or not) against each tag and untracked, non-ignored files under models/common/R, as D's
assert_frozen does.
"""
import subprocess
from pathlib import Path

import pytest

from tests.hmis.release_mode import RELEASE

# The public release has neither the author's tags (its copies are renamed, and it is one root commit) nor, as a zip,
# any .git: the frozen-code check is a guard of the private repository.
pytestmark = pytest.mark.skipif(RELEASE, reason="release mode: checks models/common/R against version-control tags of "
                                                "the author's working repository, which the public release does not "
                                                "contain")
REPO = Path(__file__).resolve().parents[2]
FROZEN = "models/common/R"
TAGS = ("paperA-submitted", "paperC-submitted", "paperC-submitted-2")


def git(*args: str) -> str:
    out = subprocess.run(["git", "-C", str(REPO), *args], capture_output=True, text=True, check=True)
    return out.stdout.strip()


@pytest.mark.parametrize("tag", TAGS)
def test_models_common_r_unchanged_against_tag(tag):
    assert git("rev-parse", "--verify", "--quiet", f"refs/tags/{tag}"), f"tag {tag} is missing"
    assert git("diff", "--name-only", tag, "--", FROZEN) == ""


def test_no_untracked_files_under_models_common_r():
    assert git("ls-files", "--others", "--exclude-standard", "--", FROZEN) == ""
    # git status --porcelain covers staged, unstaged and untracked changes against HEAD as well
    assert git("status", "--porcelain", "--", FROZEN) == ""
