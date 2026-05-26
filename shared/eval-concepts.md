# Eval Concepts

Shared vocabulary for making acceptance-criterion (AC) outcomes measurable across the pipeline. This file defines terms only — it introduces no skill, no state file, and no scoring gate. Skills and agents reference it; they do not inline it.

## Grader Taxonomy

Every acceptance criterion can be classified by the *kind of evidence* that objectively verifies it. A grader tag names the **type of verifier**, never a tool, framework, or file pattern. The moment a tag becomes `phpunit`, `playwright`, or `grep X`, it has crossed from WHAT into HOW and belongs in the plan, not the spec.

Four evidence categories — portable across PHP, React, infrastructure, and prose:

- **code** — outcome observable via automated test execution (a test passes or fails).
- **rule** — verifiable by static analysis of a structural property (a pattern present/absent, a count that matches).
- **model** — requires LLM judgment (prose quality, tone, completeness, semantic correctness).
- **human** — requires subjective human judgment or stakeholder sign-off.

A criterion carries exactly one grader tag, written as an indent-2 bullet under its Then clause:

```
- **AC-1.1**
  - Given ...
  - When ...
  - Then ...
  - grader: rule
```

## Reliability Vocabulary

- **pass@k** — the criterion passed on *at least one* of k attempts ("does it ever pass?").
- **pass^k** — the criterion passed on *all* k attempts ("does it pass consistently?").

A single verification run is **pass@1**. Reliability framing (pass@k vs pass^k) is meaningful only where re-verification is genuinely at stake — flaky fixes, retried gates. Do not inject pass^k framing into a single-pass QA summary.

## Eval Report Format

A per-AC report correlates each AC against its verification verdict:

| AC ID  | Verdict | Grader | Evidence                          |
|--------|---------|--------|-----------------------------------|
| AC-1.1 | PASS    | rule   | tasks.md:14 cites AC-1.1          |
| AC-2.1 | FAIL    | code   | test_export.php:88 AssertionError |

- **Verdict** is one of `PASS` / `FAIL` / `UNVERIFIED`.
- **Evidence** matches the grader type: `code` → file:line or verbatim test-runner excerpt; `rule` → structural-property assertion; `model` → LLM judgment note; `human` → reviewer sign-off.
- **Source:** the quality-guard AC-tagged gate output only — never the gap-analysis artifact (it answers diff-coverage, not adversarial correctness).
- **Multi-AC gate:** when one gate covers two or more ACs, emit one row per AC, each citing that gate's evidence; never collapse or omit an AC.
