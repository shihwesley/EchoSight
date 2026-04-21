# Execution Workflow — EchoSight AVP v0.1

## Project

- **name:** EchoSight
- **type:** greenfield
- **platform:** visionOS 2.0+ (Apple Vision Pro)
- **build_cmd:** `set -o pipefail && xcodebuild -scheme EchoSight -destination 'generic/platform=visionOS' build 2>&1 | xcbeautify`
- **test_cmd:** `set -o pipefail && xcodebuild test -scheme EchoSight -destination 'platform=visionOS Simulator,name=Apple Vision Pro' 2>&1 | xcbeautify`

## Execution Gates

- **between_phases:** review (Quality priority → require review at phase boundaries)
- **between_sprints:** auto (within a phase, sprint handoffs are self-managed)
- **between_specs:** auto (within a sprint, spec sub-tasks flow sequentially)

## Phase Gate Checklist

Before advancing from Phase N → Phase N+1:

1. All Phase N spec tasks `completed`
2. Build green (xcodebuild succeeds)
3. Tests green (`xcodebuild test`)
4. HIG quick-audit (if UI spec touched)
5. `findings.md` updated with any new decisions

## Continuation Prompt Template

For agents resuming a spec:

```
You are executing spec: {spec_name}
Phase {N}, Sprint {M}
Parent manifest: docs/plans/manifest.md
Your spec file: docs/plans/specs/{spec_name}-spec.md
Findings: docs/plans/findings.md

Read your spec file first. Check dependencies are `completed` in progress.md.
Work through your ## Tasks section in order.
Mark each sub-task `in_progress` when starting, `completed` when done.
On spec completion: update progress.md Spec Status row + mark parent task completed.
```
