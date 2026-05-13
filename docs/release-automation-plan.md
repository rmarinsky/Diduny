# Release Automation Plan

## Current problem

- `release.yml` builds and publishes GitHub Release correctly.
- `appcast.xml` publication is fragile because it currently depends on writing back into protected `main`.
- `GitHub Actions` in this repo cannot create or approve PRs, so the current auto-PR approach fails.
- Version bumping is still manual and easy to forget.

## What to change

### 1. Stop publishing `appcast.xml` through `main`

Do not use `main/docs/appcast.xml` as the operational publication path.

Use one of these two options:

- **Preferred:** publish `appcast.xml` through `GitHub Pages` from a dedicated workflow/artifact
- **Acceptable:** publish `appcast.xml` to a dedicated `gh-pages` branch

Why:

- release pipeline should not depend on protected branch write access
- `appcast` is a release artifact, not product source code
- this removes the whole PR/create/merge problem from release flow

### 2. Split release into two responsibilities

#### A. Version preparation

This workflow decides and writes the next version.

Responsibilities:

- detect next semver bump
- update `MARKETING_VERSION` in `project.yml`
- regenerate `Diduny.xcodeproj` with `xcodegen`
- commit version bump
- create tag `vX.Y.Z`

#### B. Binary release

This workflow runs on tag push.

Responsibilities:

- archive app
- notarize
- build DMG
- sign Sparkle update
- create GitHub Release
- generate `appcast.xml`
- deploy `appcast.xml` to Pages

That split is important. Right now one workflow tries to do everything and mixes source-control concerns with artifact publication.

## Recommended release architecture

### Option 1 — best practical setup

Use:

- `main` for source code
- `GitHub Release` for DMG asset
- `GitHub Pages via Actions` for `appcast.xml`

Flow:

1. Merge PR into `main`
2. Release-prep workflow decides next version and creates a small release commit + tag
3. Tag triggers binary release workflow
4. Binary release workflow publishes DMG to GitHub Release
5. Same workflow generates final `appcast.xml`
6. Same workflow deploys `appcast.xml` via `actions/upload-pages-artifact` + `actions/deploy-pages`

Result:

- no writeback to `main`
- no appcast PR
- no branch-protection conflict
- Sparkle feed stays on `https://rmarinsky.github.io/Diduny/appcast.xml`

### Option 2 — simpler but worse

Use `gh-pages` branch as a pure publication branch for `appcast.xml`.

This still works, but:

- it is still git writeback
- it is easier to drift
- it is less clean than Pages artifact deployment

## Versioning strategy

### Do not use LLM as source of truth

LLM can suggest a bump. It should not decide release version automatically.

Why:

- semver is a policy decision
- diff-based AI guesses are often wrong on product impact
- release automation must be deterministic

Use LLM only as an advisory signal.

### Use deterministic version selection

Best options:

- PR label: `release:patch`, `release:minor`, `release:major`
- or Conventional Commits enforced in PR titles

For this repo, **PR labels are simpler and safer**.

Recommended rule:

- bugfix/internal improvement → `release:patch`
- new user-facing capability → `release:minor`
- breaking behavior/API/product reset → `release:major`

### Required automation

Add a PR check that:

- validates that one release label exists
- comments the calculated next version
- fails if label is missing on release-relevant PRs

Example:

- current version `1.12.3`
- PR labeled `release:patch`
- bot comment: `Next release will be 1.12.4`

## What should be automated

### On pull request

Automate:

- validate release label presence
- calculate next version preview
- optionally comment release note draft

Do not automate:

- tagging
- publishing

### On merge to `main`

Automate:

- read highest-priority release label from merged PR
- bump version in `project.yml`
- run `xcodegen`
- commit `Bump version to X.Y.Z`
- create and push tag `vX.Y.Z`

### On tag push

Automate:

- build/notarize/sign/release
- generate and publish `appcast.xml`
- optionally verify that feed URL contains new version after deploy

## Single source of truth for version

Keep version source in:

- `project.yml`

Everything else should be derived from that:

- `Diduny.xcodeproj`
- release tag
- appcast short version

Do not manually edit both `project.yml` and `project.pbxproj`.

Instead:

1. update `project.yml`
2. run `xcodegen generate`
3. commit generated project changes

## What to implement in repo

### A. Add version script

Create something like:

- `scripts/release/bump_version.sh`

Responsibilities:

- read current version from `project.yml`
- apply `patch|minor|major`
- write new version
- run `xcodegen generate`
- print new tag name

### B. Add PR validation workflow

Example file:

- `.github/workflows/release-label-check.yml`

Responsibilities:

- trigger on `pull_request`
- ensure exactly one of:
  - `release:patch`
  - `release:minor`
  - `release:major`
- compute and comment next version

### C. Add release-prep workflow

Example file:

- `.github/workflows/prepare-release.yml`

Responsibilities:

- trigger on merge to `main`
- inspect merged PR labels
- run `scripts/release/bump_version.sh`
- commit version bump
- create tag

### D. Simplify release workflow

Current `release.yml` should stop touching `main`.

Replace the `Commit appcast.xml via PR` block with:

- generate standalone `appcast.xml`
- deploy it via Pages Actions

## Suggested Pages deployment shape

Use a small temporary directory like:

- `build/pages/appcast.xml`

Then:

1. copy generated `appcast.xml` there
2. `actions/upload-pages-artifact`
3. `actions/deploy-pages`

This is cleaner than mutating repository state.

## About a Codex/Claude skill

Yes, a skill makes sense here, but only for **local operator workflow**, not as CI source of truth.

Useful skill scope:

- inspect current version
- inspect PR diff or branch diff
- suggest `patch/minor/major`
- update `project.yml`
- regenerate `Diduny.xcodeproj`
- draft release notes
- create tag
- monitor release workflow

Good skill name:

- `diduny-release-manager`

What it should not do:

- decide semver without a visible rule
- bypass CI policy
- silently publish releases

## Recommended final setup

### Minimal human input

Human does only two things:

1. set PR label `release:patch|minor|major`
2. merge PR

Everything else is automated.

### Why this is the right tradeoff

- deterministic
- easy to reason about
- no AI guess as hidden release authority
- no protected-branch fight during appcast publication
- low ceremony

## Implementation order

1. Move `appcast` publication off `main`
2. Add `bump_version.sh`
3. Add PR label validation workflow
4. Add merge-to-main release-prep workflow
5. Keep LLM/Codex only as advisory helper

## Short answer

The main fix is not “teach AI to bump version”.

The main fix is:

- **make versioning deterministic**
- **make appcast deployment artifact-based**
- **make release start from merge metadata, not from memory**

