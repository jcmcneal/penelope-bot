# iOS Release Workflow

Conduit uses `main` for ongoing development, a long-lived `deploy` branch for TestFlight uploads, and optional short-lived release branches/tags for App Store candidates.

## Branch and PR model

- `main` is the development source of truth.
- `deploy` is the TestFlight ship branch. Any push/merge to `deploy` runs `.github/workflows/testflight.yml` (archive + App Store Connect upload).
- `release/<marketing-version>` is optional: cut from a known `main` commit when you need a frozen App Store candidate with an audit PR.
- A release PR targets `main` and stays open as the audit trail for that candidate. Keep it draft while the candidate is still being tested; mark it ready only after final QA.
- Do not merge unrelated `main` work into a release branch. Only backport fixes that are required for that release.

The release branch must not be reused for the next release. After shipping, keep the release tag and start a new release branch from the latest `main`.

## Day-to-day TestFlight (`deploy`)

Ship a build that is already on `main`:

```bash
git fetch origin
git switch deploy
git pull --ff-only origin deploy
git merge --ff-only origin/main   # or open a PR: main → deploy
git push origin deploy
```

That push triggers the TestFlight workflow. Marketing version still comes from `project.yml` on the commit being shipped. Build number is assigned automatically for `deploy` pushes (UTC `YYYYMMDDHHMM`) so App Store Connect never sees a reused `CURRENT_PROJECT_VERSION`. You can still pin versions via `workflow_dispatch` inputs or an `ios/v*` tag.

Prefer merging `main` into `deploy` (fast-forward when possible) over committing directly on `deploy`, so `deploy` stays a ship pointer rather than a second development line.

## 1. Cut a release candidate

Start after the feature PRs intended for the release have been merged into `main`:

```bash
git fetch origin
git switch main
git pull --ff-only origin main
git switch -c release/<marketing-version>
```

Update `project.yml` on the release branch:

- `MARKETING_VERSION` is the App Store version, such as `0.1.3`.
- `CURRENT_PROJECT_VERSION` is the monotonically increasing build number. Every new TestFlight/App Store upload needs a new build number.

Then regenerate and commit the release metadata. The generated `Conduit.xcodeproj` is not the source of truth; `project.yml` is.

```bash
xcodegen generate
git add project.yml
git commit -m "Prepare <marketing-version> build <build-number> for TestFlight"
git push -u origin release/<marketing-version>
```

Open a draft PR from `release/<marketing-version>` to `main`, for example:

> Prepare `<marketing-version>` build `<build-number>` for TestFlight / App Store

The PR description should include the marketing version, build number, starting `main` commit, and the intended release scope.

## 2. Test the release branch

Build and test from the release branch itself. Do not test a moving `main` checkout and assume it represents the candidate.

If testing finds a bug:

1. Open a normal fix PR against `main`.
2. Merge that fix PR after review and CI pass.
3. Cherry-pick the merged fix commit into the release branch, preserving provenance with `-x`:

   ```bash
   git switch release/<marketing-version>
   git pull --ff-only origin release/<marketing-version>
   git cherry-pick -x <merged-fix-commit>
   ```

   If the fix PR was squash-merged, use the resulting squash commit SHA. Before cherry-picking, check whether an equivalent fix is already present on the release branch; if it is, skip the cherry-pick to avoid duplicate commits or an unnecessary conflict.

4. Increment `CURRENT_PROJECT_VERSION` for the next TestFlight upload, regenerate if needed, then commit and push the release metadata:

   ```bash
   git add project.yml
   git commit -m "Bump build number to <build-number> for TestFlight"
   git push origin release/<marketing-version>
   ```

5. Run the full test suite and repeat TestFlight testing.

The fix is merged into `main` first so ongoing development receives it even if the release candidate is later abandoned. If the cherry-pick conflicts, resolve the equivalent change on the release branch, run the full tests, and record the relationship in the release PR.

## 3. Freeze and ship

When the release candidate passes final QA:

1. Stop adding unrelated changes to the release branch.
2. Pin and record the exact candidate commit:

   ```bash
   RELEASE_SHA=$(git rev-parse HEAD)
   echo "$RELEASE_SHA"
   ```

3. Create an immutable tag containing both the App Store version and build number:

   ```bash
   git tag -a ios/v<marketing-version>-build-<build-number> \
     -m "iOS <marketing-version> build <build-number>" "$RELEASE_SHA"
   git push origin ios/v<marketing-version>-build-<build-number>
   ```

4. Archive and upload the app to App Store Connect from that exact tagged commit.
5. Record the tag, commit SHA, marketing version, and build number in the release PR or release notes.
6. After the candidate has been uploaded and accepted for release, mark the release PR ready and merge it into `main`.

The tag and uploaded archive—not a later `main` commit—are the canonical record of what was released. Do not move or force-push a release tag.

## 4. Fixes after submission

If Apple rejects the build or QA finds a release-blocking issue after submission:

- Fix the issue in a PR against `main`.
- Merge it normally.
- Cherry-pick the merged fix into the release branch.
- Increment the build number, run the full tests, create a new tag, and upload a new candidate.

Never modify an already-uploaded tag. Each uploaded candidate gets a distinct build number and tag.

## Rules of thumb

- `main` is where fixes land first; the release branch is where approved fixes are backported.
- Keep release branches focused on the candidate: release metadata plus required fixes only.
- Do not merge all of `main` forward into a release branch.
- Do not reuse an old release branch for a later version.
- Always test and archive from the exact branch/tag being shipped.
