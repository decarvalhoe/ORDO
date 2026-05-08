# CSV-IQ-02 Command Log

All commands were executed as non-destructive IQ checks. The retained form is a
controlled summary with hashes and exit statuses so the dossier can be reviewed
without preserving live account names, local paths, credential material, machine
identifiers, or private service locations.

## Command Records

| Command ID | UTC time | Actor ID | Action summary | Exit status | Retained evidence |
| --- | --- | --- | --- | --- | --- |
| CMD-IQ-001 | 2026-05-08T02:34:01Z | agent-cli-executor-01 | Captured source revision, branch reference, source cleanliness, remote reference hash, execution-node hash, and actor identity hash. | 0 | EV-IQ-002-01, EV-IQ-003-01 |
| CMD-IQ-002 | 2026-05-08T02:34:01Z | agent-cli-executor-01 | Counted controlled validation documents, scripts, libraries, templates, and example configs. | 0 | EV-IQ-004-01, EV-IQ-005-01 |
| CMD-IQ-003 | 2026-05-08T02:34:01Z | agent-cli-executor-01 | Verified repository-platform CLI identity and controlled issue-tracker read access using sanitized actor hashes. | 0 | EV-IQ-009-01, EV-IQ-010-01 |
| CMD-IQ-004 | 2026-05-08T02:34:01Z | agent-cli-executor-01 | Recorded runtime tool availability and version hashes for shell, version-control client, repository-platform CLI, JSON processor, and terminal multiplexer. | 0 | EV-IQ-007-01, EV-IQ-008-01 |
| CMD-IQ-005 | 2026-05-08T02:34:01Z | agent-cli-executor-01 | Ran shell syntax validation over controlled shell assets. | 0 | Output hash `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| CMD-IQ-006 | 2026-05-08T02:34:01Z | agent-cli-executor-01 | Reviewed executable-bit readiness for shell assets. | 0 | Non-executable direct-entry list hash `6609dbcc2beb71d49883ea177a86c27c4f20095e7815e4baab4a6964096d408d`; approved invocation path is through the shell interpreter |
| CMD-IQ-007 | 2026-05-08T02:34:01Z | agent-cli-executor-01 | Ran local shell lint runner. | 0 | Output hash `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| CMD-IQ-008 | 2026-05-08T02:34:01Z | agent-cli-executor-01 | Ran missing-configuration negative check with an isolated temporary input. | 1 | Fail-closed output hash `a7488acfaf2609df853774f0f9e26bbd6e7c4121324abf1e2c780364b438d69f` |
| CMD-IQ-009 | 2026-05-08T02:34:01Z | agent-cli-executor-01 | Ran missing-authentication negative check with an isolated empty credential context. | 1 | Fail-closed output hash `282200f287ed1c07be4ca6c6086f25aa61fdb00f185912468657ec8211c38bbe` |
| CMD-IQ-010 | 2026-05-08T02:34:01Z | agent-cli-executor-01 | Verified temporary state, audit, and evidence-store write-read behavior using a non-secret artifact. | 0 | Artifact digest `e73a7eccb82e5ece753704c6309808281fddaad314bf7ca4c29adb7ecf859a54` |
| CMD-IQ-011 | 2026-05-08T02:34:01Z | agent-cli-executor-01 | Verified altered-artifact detection with a non-secret sample and changed digest. | 0 | Original digest `a23a080a9bfe6bc57d71c793d3715e2d5fe78d9dc51e8a2bef6c1fb0ca5e9d4f`; changed digest `475325534a1ceb9ee1a984f421a67190d7e9fa628d1e925a595bc6244785b893` |
| CMD-IQ-012 | 2026-05-08T02:38:39Z | agent-cli-executor-01 | Ran repository diff whitespace validation before authoring the evidence pack. | 0 | Output hash `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| CMD-IQ-013 | 2026-05-08T02:38:39Z | agent-cli-executor-01 | Ran focused project-metadata regression. | 0 | Output hash `e3ee24861a11c4234519e628f1ebff794487f649cd4becee4aef98e867887f8d` |
| CMD-IQ-014 | 2026-05-08T02:38:39Z | agent-cli-executor-01 | Ran targeted shell regression suite for project metadata, example config, and config resolution checks. | 0 | Output hash `4291ec595faa10a1890a44d715b1761e14cac44e1ec504f8efaef0e78e9a1ca9` |
| CMD-IQ-015 | 2026-05-08T02:38:39Z | agent-cli-executor-01 | Re-ran local shell lint runner for retained validation evidence. | 0 | Output hash `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| CMD-IQ-016 | 2026-05-08T02:38:39Z | agent-cli-executor-01 | Re-ran shell syntax validation over controlled shell assets for retained validation evidence. | 0 | Output hash `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

## Retained Field Values

| Field | Value |
| --- | --- |
| Controlled validation document count | 14 |
| Controlled script count | 45 |
| Controlled library count | 24 |
| Controlled template count | 4 |
| Controlled example config count | 7 |
| Source status line count before evidence authoring | 0 |
| Source status hash before evidence authoring | e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 |
| Remote reference hash | c36042191cbd97258cec8967fe8673c8fbfc498b48fd9443a09e050a1d224d24 |
| Worktree location hash | b6514c840e5005f29d7e6b751b31b7d5de24ca09ecd6858d3bf882003eb4eb02 |
| Execution node hash | 7003548b821bcbe7ce22454c5c2a364216546852b0a3e6d51ea1746ee46b3270 |
| Operating environment hash | 62d3cfea4bd46d46749a50beea826ef6bcd1df2f48745e4bdbbd518eb479d18e |
| Executor identity hash | 53175bcc0524f37b47062fafdda28e3f8eb91d519ca0a184ca71bbebe72f969a |
| Version-control configured name hash | caacae3aca7d96a9ce179b8bc884bf5450f5e8e526359f95b4a709313d0a9fa8 |
| Version-control configured email hash | 7479bbe80bc6887eb32f86e539f684a277a4f5e25e1440f014437b698d907947 |
| Repository-platform config hash | f789d45b4cd59b1e4c7d8eaab104df02fc2663ca2b852d772905747e34857787 |
| Repository-platform actor hash | 3211f6fb2c0daec9c79f3d1217e03aee6a324f9203f3fadfbc14ae67e62455e2 |

## Runtime Inventory

| Runtime class | Availability | Version hash |
| --- | --- | --- |
| Shell | Pass | 0139877126c45c7436dfc7ec9542cbe1f6f4c7384c4eab20e4e97b9afd292694 |
| Version-control client | Pass | afe546045563315286ad2bcfb4a042a4e8e0aea3d76e2d31beeb1f549d19b865 |
| Repository-platform CLI | Pass | 05345f43999bb3cb081f540b79a305737f41afbf9fe5639ffcd7118e86549f67 |
| JSON processor | Pass | cb1c1b1ad33fb834a7b2b0c6c1b20455451f44924840893be295261fa57d70f5 |
| Terminal multiplexer | Pass | 2e131dff50dc2903f72dbe56b69ecfb490f5d00f606f39773046610c05a4a293 |

## Local Validation Commands

These bounded commands were used as IQ validation evidence. They are described
by purpose rather than live environment values.

| Validation command class | Scope | Status |
| --- | --- | --- |
| Repository diff whitespace check | Pending evidence-pack diff | Pass |
| Focused project metadata regression | Project metadata context behavior | Pass |
| Targeted shell regression runner | Project metadata, example configuration, and configuration resolution tests | Pass |
| Shell lint runner | Controlled shell assets | Pass |
| Shell syntax check | Controlled shell scripts, libraries, and tests | Pass |
