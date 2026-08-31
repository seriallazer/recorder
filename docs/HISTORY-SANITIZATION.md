# History-Sanitization Plan

This plan is intentionally not executed as part of ordinary release preparation. Recorder's 40-commit history, order, messages, authorship facts, and timestamps must be preserved. A targeted rewrite is appropriate only before the first public push and only if the existing personal name and email are not intended to be public.

## Findings

- One historical test fixture contains the exact text `Mayank's AirPods Pro Microphone`.
- Existing commit metadata uses `mooniitk@gmail.com` for the `Serial Lazer` author/committer identity.
- One commit is authored by `5.5-light <5.5-light@local>` and committed by `Serial Lazer`. Preserve that author identity unless there is a factual reason to change it.

The current working tree replaces the personal device name, but a normal commit does not remove it from earlier commits.

## Target state

- Replace only the exact device-name phrase with `Personal AirPods Pro Microphone` in historical blobs.
- Map only `Serial Lazer <mooniitk@gmail.com>` to `Serial Lazer <18477406+seriallazer@users.noreply.github.com>` in author and committer metadata.
- Preserve every commit, message, parent relationship, author date, and committer date.
- Accept that rewritten commits receive new object IDs.

## Procedure

Install `git-filter-repo` from its official distribution before starting. Work from a disposable clone and keep the original repository untouched until verification is complete.

Create `replacements.txt`:

```text
Mayank's AirPods Pro Microphone==>Personal AirPods Pro Microphone
```

Create `mailmap.txt`:

```text
Serial Lazer <18477406+seriallazer@users.noreply.github.com> <mooniitk@gmail.com>
```

Capture the timeline and count before rewriting:

```sh
git rev-list --count --all > /tmp/recorder-before-count.txt
git log --reverse --format='%aI|%cI|%s' > /tmp/recorder-before-timeline.txt
```

Run one targeted pass in the disposable clone:

```sh
git filter-repo \
  --replace-text replacements.txt \
  --mailmap mailmap.txt \
  --force
```

Verify the result:

```sh
git rev-list --count --all > /tmp/recorder-after-count.txt
git log --reverse --format='%aI|%cI|%s' > /tmp/recorder-after-timeline.txt

diff /tmp/recorder-before-count.txt /tmp/recorder-after-count.txt
diff /tmp/recorder-before-timeline.txt /tmp/recorder-after-timeline.txt

git log --all -S 'Mayank' --name-only
git log --all --format='%an <%ae> | %cn <%ce>' | sort -u
git fsck --full
```

The two `diff` commands and the `Mayank` search should produce no output. The identity list should contain the GitHub noreply address and retain `5.5-light <5.5-light@local>` as the author of its original commit.

Inspect the rewritten repository manually before adding or restoring a remote. Never force-push this rewrite over a repository that collaborators may already have cloned without coordinating the migration.
