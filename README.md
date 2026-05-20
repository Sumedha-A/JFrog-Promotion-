# JFrog Build Promotion — Silent Success Reproduction

This repository deterministically reproduces the issue where the JFrog
`Build Promotion` task in Azure DevOps reports

```
[Info] Promoted build <name>/<number> to: <target-repo> repository.
Artifactory response: 200
```

…but **no artifact is actually present in the target repository**, and a
subsequent download step fails with:

```
[Error] No errors, but also no files affected (fail-no-op flag).
```

It also ships a corrected pipeline that performs a real, end-to-end promote
and verifies that the artifact lands in the target repo.

This is a long-standing behaviour of `POST /api/build/promote/...`:
the endpoint iterates over the artifacts recorded in the published
**build-info** JSON and copies/moves them. If the build-info has **zero
artifacts** (or artifacts whose `repo` field is empty), the API returns
`200 OK` with `"messages": []` and the CLI logs "Promoted successfully" —
because, from Artifactory's point of view, there was nothing to do.

References:

* [jfrog/jenkins-artifactory-plugin#156](https://github.com/jfrog/jenkins-artifactory-plugin/issues/156) — same symptom, different CI.
* JFrog KB `RTFACT-26868` — "Build promote is not copying the files to
  the desired repository while trying to promote".
* [jfrog/jfrog-cli#1873](https://github.com/jfrog/jfrog-cli/issues/1873) — undefined `repo` field in build-info causes silent skip.

---

## Repository layout

```
.
├── azure-pipelines/
│   ├── 01-repro-silent-success.yml   # reproduces the bug
│   ├── 02-fixed-promote.yml          # correct end-to-end promote
│   └── 03-repro-cli-direct.yml       # repro using `jf` CLI directly
├── scripts/
│   └── make-sample-zip.ps1           # creates a tiny zip at runtime
└── README.md
```

No binaries are committed — the sample zip is generated inside the pipeline.

---

## Prerequisites

1. **An Artifactory instance** (Cloud or Self-Hosted) reachable from your
   Azure DevOps agents.
2. **Two generic local repositories**, e.g.
   * `generic-dev` — the staging/source repo
   * `generic-release` — the production/target repo

   You can rename these via the pipeline parameters below.
3. **An Azure DevOps service connection** of type *JFrog Platform* (or
   *JFrog Artifactory*) — note its name; it's passed via the
   `artifactoryConnection` parameter (default: `rcm-artifactory-service`,
   matching the original case).
4. **The "JFrog Azure DevOps Extension"** installed in your Azure DevOps
   organisation — same tasks the customer uses
   (`JFrogGenericArtifacts@1`, `JFrogPublishBuildInfo@1`,
   `JFrogBuildPromotion@1`).

   Marketplace: https://marketplace.visualstudio.com/items?itemName=JFrog.jfrog-azure-devops-extension

---

## How to run

1. In Azure DevOps → *Pipelines* → *New Pipeline* → *GitHub* → select
   this repository.
2. Choose **Existing Azure Pipelines YAML file** and pick one of:
   * `/azure-pipelines/01-repro-silent-success.yml` — to reproduce the bug.
   * `/azure-pipelines/02-fixed-promote.yml` — to see the correct flow.
3. At runtime, set the parameters (Artifactory service connection name,
   source repo, target repo) to match your instance.

### Expected results

| Pipeline | Promote step log | Target repo | Download step |
|---|---|---|---|
| `01-repro-silent-success.yml` | `Promoted build ... to: <target> repository.` (green) | **Empty for this build** | Fails with `No errors, but also no files affected` |
| `02-fixed-promote.yml`        | `Promoted build ... to: <target> repository.` (green) | Contains the zip | Succeeds |

In both pipelines the **promote task's stdout is identical**. The only
difference is whether the prior upload was correctly associated with the
build-info — proving the silent-success is not a promote bug but an
upstream upload/publish bug.

---

## What each pipeline does

### `01-repro-silent-success.yml` — reproduces the customer's symptom

Stage `Build_and_Publish`:

1. Generates `rcm-operations-3.4.1.zip` on the agent.
2. **Uploads it to `generic-dev` with `collectBuildInfo: false`** —
   so the artifact is NOT recorded against the build.
3. **Publishes a build-info anyway** for
   `demo/jfrog-promotion-repro/<Build.BuildId>` — produces an empty
   build-info (`modules[*].artifacts == []`).

Stage `Promote` (mirrors the customer's YAML exactly):

```yaml
- task: JFrogBuildPromotion@1
  displayName: 'Promote artifact. The error message "Error occurred while copying: null" appears if the artifact has already been promoted.'
  continueOnError: true
  env:
    JFROG_CLI_LOG_LEVEL: DEBUG
  inputs:
    artifactoryConnection: ${{ parameters.artifactoryConnection }}
    buildName: demo/jfrog-promotion-repro
    buildNumber: $(Build.BuildId)
    targetRepo: ${{ parameters.targetRepo }}
    status: release
    includeDependencies: false
    copy: true
```

Stage `Download_From_Target` (mirrors the customer's release pipeline):

* Tries to download `<target-repo>/demo/jfrog-promotion-repro/rcm-operations-3.4.1.zip`
* Fails with `No errors, but also no files affected (fail-no-op flag).`

### `02-fixed-promote.yml` — same flow done correctly

Differences from `01`:

* Upload uses `collectBuildInfo: true` and the **same** `buildName` /
  `buildNumber` that the promote step uses later.
* `JFrogPublishBuildInfo@1` runs on the **same agent / working dir**
  after upload — so artifacts are present in build-info.
* Promote step has `continueOnError` **removed** and `failFast: true`.
* Adds an explicit `jf rt search` post-promote verification step that
  fails the stage if the artifact isn't present in the target repo.

### `03-repro-cli-direct.yml` — same repro using raw `jf` CLI

Useful for confirming the issue is independent of the extension version
and present in vanilla `jfrog-cli`. Pins
`JFROG_CLI_VERSION=2.100.0` (matching the customer's debug log) and runs
`jf rt upload`, `jf rt build-publish`, `jf rt build-promote`,
`jf rt download` directly.

---

## Reading the proof in Artifactory

After running `01-repro-silent-success.yml`, open in the Artifactory UI:

```
<your-base-url>/ui/builds/demo/jfrog-promotion-repro/<Build.BuildId>
```

You will see the build appear with **0 published artifacts** under
*Published Modules*, and the *Release History* tab will show a
`release` status promotion event — yet no files were touched.

Equivalent REST check:

```bash
curl -u <user>:<pat> \
  "<base-url>/artifactory/api/build/demo%2Fjfrog-promotion-repro/<Build.BuildId>" \
  | jq '.buildInfo.modules[].artifacts // []'
# => []
```

That empty `artifacts` array IS the bug. Promote has nothing to copy.

---

## The fix (mirrored in `02-fixed-promote.yml`)

1. Always pass `collectBuildInfo: true` plus matching `buildName` /
   `buildNumber` on every upload that belongs to the build.
2. Run `JFrogPublishBuildInfo@1` on the same agent after all uploads,
   with no `JFrogToolsInstaller` `--clean` or `jf rt build-clean` in
   between.
3. Set an explicit `sourceRepo` on the promote task.
4. Use `failFast: true` and **remove `continueOnError: true`**.
5. Add a post-promote `jf rt search` (or AQL) assertion in the release
   pipeline before the deploy step — fail fast if the artifact is
   missing.
