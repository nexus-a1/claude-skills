# Release Concepts

Canonical terminology for all release-management skills (`/create-release-branch`, `/create-release`, `/merge-release`, `/release`). Include this file in any skill that talks about releases so the LLM uses the same definitions every time.

## Versioning

Semantic versioning: `v{major}.{minor}.{patch}` — always with the leading `v`.

Examples: `v1.0.0`, `v3.5.2`, `v10.0.0`.

## Core Terms

**Release branch** — a branch named `release/v{major}.{minor}.{patch}`. Example: `release/v3.5.0`. A release branch represents an **in-flight release** and counts as a release for the purpose of resolution below.

**Tag** — a git tag named `v{major}.{minor}.{patch}`. Every tag should be paired with a GitHub Release, but a bare tag (tag without a Release) still counts as a tag for resolution purposes. Missing Releases are a policy violation fixed separately, not a reason to ignore the tag.

**RC tag (pre-release tag)** — a tag containing a pre-release suffix, e.g. `v3.5.0-rc.1`. **RC tags are not "real" tags** for the purpose of latest-release resolution and must be excluded. They exist only for pre-release workflows. The only time an RC tag is consulted is when computing the *next RC number* inside a specific release line (e.g. finding the next `-rc.N` for `v3.5.0`).

**Release** — a released or in-flight version of the product. Concretely, any of:
- a GitHub Release paired with a tag (fully released), or
- a bare tag `v{major}.{minor}.{patch}` (released, Release entry missing — policy violation), or
- a release branch `release/v{major}.{minor}.{patch}` (in-flight).

RC tags are **not** releases.

**Latest release** — the most recent release, determined by comparing the latest non-RC tag against the latest `release/*` branch. See resolution rules below.

## Latest Release Resolution

Given the newest tag `T` and the newest release branch `B`:

| Scenario | Result |
|----------|--------|
| `T` version > `B` version | take the **tag** |
| `T` version < `B` version | take the **branch** |
| `T` version == `B` version | take the **tag** (tag wins the tie) |
| Only `T` exists | take the **tag** |
| Only `B` exists | take the **branch** |
| Neither exists | no latest release — treat as `v0.0.0` baseline |

Comparison is by semver: `3.10.0` > `3.9.9` > `3.9.0`.

### Examples

| Latest tag | Latest branch | Latest release |
|------------|---------------|----------------|
| `v3.5.0` | `release/v3.5.0` | `v3.5.0` (tag — tie) |
| `v3.5.0` | `release/v3.6.0` | `release/v3.6.0` (branch newer) |
| `v3.5.0` | `release/v3.4.0` | `v3.5.0` (tag newer) |
| `v3.5.0` | none | `v3.5.0` |
| none | `release/v1.0.0` | `release/v1.0.0` |

## Resolver Script

Skills must not re-derive "latest release" from raw `git tag` / `git branch` output. Use the deterministic resolver:

```bash
source "${CLAUDE_PLUGIN_ROOT}/shared/resolve-latest-release.sh"
resolve_latest_release            # prints: <kind> <ref> <version>
#   kind     = tag | branch | none
#   ref      = v3.5.0 | release/v3.6.0 | (empty)
#   version  = 3.5.0  | 3.6.0          | 0.0.0
```

One call, one answer. Do not ask the model to compare tags against branches in prose — it will drift.
