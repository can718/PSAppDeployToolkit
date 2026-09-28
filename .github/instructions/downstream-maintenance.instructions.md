---
name: "Downstream Maintenance"
description: "Use when diagnosing failures, developing downstream test automation, changing CI workflows, or maintaining the upstream synchronization and PSADT package test project."
applyTo: "**"
---
# Downstream Maintenance Rules

## Repository Purpose And Ownership

- This repository is a downstream synchronization and test project for `https://github.com/PSAppDeployToolkit/PSAppDeployToolkit.git`.
- Treat `upstream/main` as the source of truth for upstream file ownership. A path that exists in `upstream/main` is upstream-owned and read-only, even when the current branch already contains downstream changes to that path.
- Before editing, deleting, renaming, or formatting a file, verify its ownership with `git cat-file -e upstream/main:<path>`. If the command succeeds, do not change the file. When the upstream ref may be stale, fetch `upstream/main` before checking.
- A new downstream file must use a path that does not exist in `upstream/main`. Do not replace an upstream file with a downstream version or use a copied upstream file as an editable fork.
- Preserve all existing user changes, including staged and unstaged changes. Never revert, overwrite, or include them in another operation without an explicit request.

## Synchronization Contract

- `.github/workflows/sync-Upstream.yml` is the downstream-owned source of truth for synchronization behavior.
- Synchronize from `upstream/main` into downstream `main`, publish the result through `sync/upstream-main`, and use a pull request to integrate it into `main`.
- Upstream file changes must enter this repository only through the synchronization merge and its pull request. Do not manually reproduce, repair, or rewrite upstream changes.
- Never push to the `upstream` remote. Push downstream branches only to `origin`.
- Do not resolve an upstream merge conflict by silently changing upstream behavior. Preserve the upstream side and adapt downstream-owned files around it; if that is impossible, stop and report the conflict and affected paths.
- Use `--force-with-lease`, never `--force`, only when replacing the history of a known downstream branch after a rebase or an equivalent intentional rewrite. Do not rewrite `main` or an upstream branch.

## Downstream-Owned Surfaces

- The downstream instruction files are `.github/instructions/downstream-upstream-protection.instructions.md`, `.github/instructions/downstream-maintenance.instructions.md`, and `.github/instructions/psadt-package-assembly.instructions.md`.
- Downstream automation currently lives in `.github/workflows/sync-Upstream.yml`, `.github/workflows/run-*-tests*.yml`, `.github/workflows/notify_teams.yml`, `.github/workflows/test_notify_teams_manual.yml`, and downstream-only files under `.github/scripts/`.
- Downstream test infrastructure currently lives in `src/Tests/Additional/`, `src/Tests/Intune/`, downstream-only files under `src/Tests/_Shared/`, and downstream-only application definitions under `src/Tests/V3/` and `src/Tests/V4/`.
- These directory descriptions are not blanket permission to edit every file below them. Check each target path against `upstream/main`; ownership is determined per path.
- Prefer adding a downstream helper, wrapper, overlay, fixture, workflow, or generated staging step over changing synchronized product code or templates.

## Diagnosis Workflow

1. Capture the exact failing workflow, job, step, test name, runner label, and first actionable error. Treat later artifact or reporting failures as possible fallout.
2. Determine whether the failure is in upstream code, downstream assembly/test logic, or external infrastructure before editing.
3. Trace from the failing test or workflow step to the nearest downstream-owned helper that directly controls the behavior.
4. Compare template and package paths, environment variables, application metadata, commands, detection rules, and generated package contents before suspecting upstream product code.
5. Reproduce with the narrowest available application or Pester tag. Validate discovery separately when test enumeration may be the problem.
6. If the root cause is upstream-owned, do not patch it here. Record the failing evidence, upstream path and revision, and the change that would be required upstream.

## Validation Order

- Validate syntax and the smallest affected helper or application first.
- For package changes, validate the generated package shape, launcher, runtime directory, installer under `Files`, session/deployment values, and recording extension before platform publishing.
- Run focused Pester discovery and execution for the affected application or tag before broad Additional or Intune suites.
- Treat Additional, Intune, SCCM, interactive desktop, and TerraForge recording tests as environment-dependent. Run them through their existing workflows and required self-hosted Windows runner when local prerequisites are unavailable.
- After focused validation succeeds, validate the affected workflow path. Do not run unrelated broad upstream test suites merely to compensate for uncertain ownership or diagnosis.
- For instruction-only changes, run `git diff --check` and inspect the complete scoped diff. Confirm no upstream-owned file changed.

## External Configuration And Secrets

- Never write credentials, tokens, certificate contents, client secrets, tenant user codes, or other secret values into source, logs, reports, instructions, or chat output.
- Existing workflows obtain sensitive values from GitHub Actions secrets or variables, including `SYNC_PR_PAT`, `SYNC_GIT_USER_NAME`, `SYNC_GIT_USER_EMAIL`, `API_TOKEN_GITHUB`, `INFRA_MI_CLIENT_ID`, TerraForge settings, `AAD_USER_CODE`, and `TEST_CLIENTSECRET`.
- Preserve the existing self-hosted runner labels and SCCM, Intune, SMB, interactive-session, and TerraForge assumptions unless a task explicitly changes downstream infrastructure.
- When infrastructure or authentication is unavailable, distinguish an environment failure from a product regression. Skip only where the existing test contract permits it, and report the missing prerequisite clearly.

## Change Discipline

- Keep changes limited to downstream-owned files required by the task. Avoid unrelated cleanup, formatting, dependency updates, or generated-file churn.
- When adding an application test, update all downstream discovery filters, metadata, installer preparation, package assembly, platform publication, cleanup, and reporting paths that enumerate applications.
- Keep local-template workflows and upstream-artifact workflows behaviorally aligned where they intentionally test the same scenario, while preserving their distinct acquisition paths.
- After every change, review `git status` and the scoped diff. If any path exists in `upstream/main`, stop and remove only the changes made during the current task without disturbing pre-existing user changes.