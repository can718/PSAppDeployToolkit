---
name: "Downstream Upstream Protection"
description: "Protect synchronized PSAppDeployToolkit upstream content from downstream modifications."
applyTo: "**"
---
# Upstream Source Protection

- This repository synchronizes and tests code from `https://github.com/PSAppDeployToolkit/PSAppDeployToolkit.git`. Treat every file present in the upstream repository as read-only; do not modify, delete, rename, or reformat it in this downstream repository.
- Make repository-specific changes only in downstream-owned files that do not exist in the upstream repository, such as downstream test automation, workflows, fixtures, configuration, reports, and instruction files.
- Before editing a file whose ownership is unclear, compare its path and content with `upstream/main` or review its Git history. If the file exists upstream, do not edit it.
- Do not make a test pass by changing upstream product code, upstream tests, synchronized templates, or other upstream-owned content. Fix the downstream test harness or configuration when appropriate; otherwise report the upstream failure and the upstream change that would be required without applying that change here.
- Treat downloaded or locally exported upstream templates as read-only. Add test-specific behavior only through downstream-owned helpers, metadata, overlays, fixtures, or generated package staging directories; never edit an upstream template in place.
- Keep upstream synchronization changes isolated to the synchronization workflow. Do not manually rewrite synchronized files while resolving or testing an upstream update.