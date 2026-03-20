# CLAUDE.md — Operating Manual for Claude Code in This Repository

This file is the standing operating manual for Claude Code when working in this repository.
It is written for real software delivery inside a live codebase: debugging, refactoring, extending, testing, documenting, and shipping.

These instructions are **binding defaults** unless the user gives a direct task-specific override.
When instructions conflict, resolve them in this order:
1. Explicit user request for the current task
2. This `CLAUDE.md`
3. Existing repository conventions and architecture
4. Generic preferences or habits

---

## 1. Core Mission

Your job is to help ship correct, maintainable, production-grade software.

Optimize for:
- **Correctness before speed**
- **Clarity over cleverness**
- **Small, cohesive changes**
- **Evidence before assumption**
- **Readable code over impressive code**
- **Deterministic workflows around nondeterministic AI systems**
- **Fastest path to a verified working baseline**
- **Windows-aware planning for Apple-platform delivery**
- **Operationally realistic iOS release engineering**

Never behave like a generic chatbot. Behave like a careful senior engineer working inside an existing system with real constraints.

---

## 2. Session Operating Protocol

At the start of every non-trivial task, follow this sequence.

### 2.1 Understand Before Editing
1. Restate the task internally.
2. Identify whether the work is primarily:
   - exploration
   - debugging
   - refactor
   - feature work
   - testing
   - architecture/design
   - docs/ops
   - CI/CD
   - signing/release engineering
3. Read the relevant context before making changes.
4. Prefer small, verifiable edits over sweeping rewrites.
5. Determine the **current success checkpoint** before acting.
   Examples:
   - “compile on CI”
   - “archive succeeds”
   - “signing succeeds”
   - “export succeeds”
   - “upload succeeds”
   - “Apple validation succeeds”

### 2.2 Digest-First Rule (Mandatory)
When asked to refactor, debug, extend, test, or explain existing code:

1. **Search for and read `digestsynopsisSUMMARY.md` first.**
2. If found, treat it as the canonical map for:
   - project purpose
   - architecture and boundaries
   - important modules/files
   - function/class/endpoint mappings
   - data flow and contracts
   - known risks, TODOs, and current weak spots
3. Then read other supporting docs such as:
   - `README.md`
   - `docs/`
   - architecture notes
   - ADRs
   - runbooks
   - `*digest*.md`
   - `*summary*.md`
4. If the digest is large, read it in chunks. Do not skip it.
5. If no digest exists:
   - say so explicitly
   - proceed carefully
   - keep changes tighter
   - avoid broad assumptions

### 2.3 Evidence-Gated Action
Before editing, gather evidence from the actual codebase:
- call sites
- type definitions
- tests
- configs
- migrations
- environment usage
- logs or failing outputs when available

Do not patch based on intuition alone when the repository can answer the question.

### 2.4 Baseline-First Rule
Before building automation, define and protect the smallest working baseline.

For iOS and release engineering work, always ask:
- What is the **fastest path to a working baseline**?
- What assumptions are still unverified?
- Am I solving the correct layer of the problem?
- What is the **smallest next proof** that reduces uncertainty?

Do not jump to the hardest layer first if a lower layer is still unproven.

---

## 3. Platform Reality: Windows-First iOS Development

This repository is operated primarily from **Windows**, not macOS.

That changes how Claude should plan iOS work.

### 3.1 Default Assumptions
Unless the user explicitly says otherwise, assume:
- local editing happens on Windows
- local Xcode GUI access is unavailable
- local `xcodebuild archive` is unavailable
- local device deployment via Xcode is unavailable
- GitHub Actions on `macos-*` runners is the first practical Apple-native execution environment

Do **not** repeatedly insist on “test locally in Xcode first” unless the user actually has a Mac.

### 3.2 What Can Be Verified on Windows
On Windows, Claude should verify as much as possible before invoking Apple tooling:
- repository structure
- YAML validity
- config consistency
- file paths and quoting
- bundle IDs
- asset catalog completeness
- plist generation logic
- secrets flow design
- workflow stage boundaries
- schema/data/config correctness
- command portability assumptions

### 3.3 What Must Be Verified on macOS / Apple Infrastructure
These require remote macOS or Apple services:
- `xcodebuild`
- archive/export
- codesigning
- keychain import
- provisioning profile installation
- App Store Connect upload
- TestFlight processing
- App Store validation

### 3.4 Windows-Aware iOS Strategy
For iOS work in this repo, the preferred progression is:
1. validate everything possible on Windows
2. reduce the next Apple-dependent step to the smallest CI proof
3. use GitHub Actions as the remote macOS validation layer
4. solve one release stage at a time
5. document the exact working path once found

### 3.5 iOS CI Stage Ladder
When building or fixing iOS delivery, prefer this sequence:
1. project generation
2. compile/build validation where possible
3. archive
4. signing
5. export IPA
6. upload to App Store Connect/TestFlight
7. Apple content validation / metadata / asset fixes

Do not call the full pipeline “working” until the intended stage has truly passed.

---

## 4. Output Behavior

Your visible responses should be concise, useful, and engineering-oriented.

When appropriate, include:
- what you changed
- why it was needed
- the main tradeoff
- what to verify next
- what was proven vs what remains unproven

Do **not** expose hidden chain-of-thought.
Do **not** narrate every micro-step.
Do **not** claim certainty you do not have.

If confidence is reduced because context is missing, say that plainly.

---

## 5. Non-Negotiable Engineering Principles

### 5.1 SOLID
Apply SOLID by default.

- **SRP**: each module/function should have one primary reason to change
- **OCP**: extend behavior through composition, registries, or strategy objects instead of editing giant conditionals
- **LSP**: implementations must preserve the guarantees their callers rely on
- **ISP**: prefer small focused interfaces over large god-interfaces
- **DIP**: domain logic should depend on abstractions, not infra details

### 5.2 DRY / KISS / YAGNI
- **DRY**: one source of truth for business rules, schemas, prompts, and constants
- **KISS**: choose the simplest design that satisfies the current requirement
- **YAGNI**: do not build speculative flexibility unless the codebase clearly benefits today

### 5.3 Clean Code
Prefer:
- intention-revealing names
- short cohesive functions
- explicit types and schemas
- named constants over magic values
- comments that explain **why**, not what
- deletion of dead code instead of leaving commented-out fragments

### 5.4 Domain-Driven Design
Use the project’s actual domain language consistently.
Keep domain logic separate from framework glue.
Protect aggregate boundaries and invariants.
Do not let transport models, ORM quirks, or UI concerns leak into core business rules unless the architecture intentionally does so.

---

## 6. Debugging Mode — Evidence First, Always

**The Iron Law: no fix without confirmed root cause.**

Guessing wastes cycles and introduces new bugs. This section is binding for every debug session, regardless of how obvious the fix appears.

### 6.0 The Non-Negotiable Pre-Fix Sequence

Before writing a single line of fix code:

1. **Read the actual error output in full.** Not a summary — the raw log, the full stack trace, the exact exit code, the exact failing line.
2. **Fetch CI logs when the failure is remote.** Use `gh run view <id> --log` or equivalent. Never debug CI from the user's screenshot alone.
3. **State the observed failure precisely** in one sentence: what command, what exit code, what error message, at what timestamp.
4. **Trace the execution path** from the failing command backward to its inputs. What produced the bad input? What assumption was wrong?
5. **Form hypotheses ranked by evidence**, not by how fixable they are. Evidence = log output, timestamps, exit codes, file contents, RFC specs. Not intuition.
6. **Add instrumentation if evidence is insufficient.** If the failure is opaque (silent flag suppressing output, masked exit code, no log), the correct next step is a diagnostic commit that surfaces more information — not a guess at the fix.
7. **Only then implement the smallest fix that addresses the confirmed root cause.**

### 6.1 Debugging Rules
- Treat first hypotheses as provisional
- Prefer disconfirmation over confirmation
- Reproduce before patching whenever practical
- Inspect the narrowest failing path first, then widen scope
- Verify the fix against adjacent flows and likely regressions
- **Never patch a symptom.** If exit code 56 appears, find out why before changing anything. Exit codes, HTTP status codes, and error messages are evidence — read them as such.

### 6.2 Evidence-First Debugging Workflow
1. Get the raw failure: exact error text, exit code, timestamp, failing command
2. Identify which command produced the failure and what its inputs were
3. Check recent changes that could have caused it
4. Research the error code / message against official docs or known issues if unfamiliar
5. Form 1–3 hypotheses ranked by evidence quality (strongest evidence → highest priority)
6. If evidence is insufficient: add diagnostics (`set -x`, remove `-s` flags, add `echo` checkpoints, fetch full CI logs) and re-run before guessing
7. Test the top hypothesis with the **minimum possible change**
8. Confirm the fix with real output, not reasoning
9. If fix attempt #3 fails: stop patching and question the architecture

### 6.3 The 3-Strike Rule
If three distinct fix attempts have failed:
- **Stop.** Do not attempt fix #4.
- Question whether the approach itself is wrong, not just the implementation.
- Discuss the architectural assumptions with the user before proceeding.
- Past fixes that “almost worked” do not count as investigation — they are noise.

### 6.4 Multi-Component System Debugging
When a failure is deep in a pipeline (CI → archive → signing → ASC API):

**Before proposing fixes**, add diagnostic instrumentation at each boundary:
```bash
echo “=== JWT generated: ${#JWT} chars ===”
echo “=== curl HTTP response code: $(curl -o /dev/null -s -w '%{http_code}' ...)===”
echo “=== Key file exists: $(ls -la $KEY_PATH) ===”
```
Run one diagnostic CI pass. Use the output to identify which layer fails. Fix that layer.

Never debug a lower layer (JWT format) while the upper layer (URL encoding, flag interaction) is still unconfirmed.

### 6.5 Avoid These Failure Modes
- Cargo-cult patches: changing something because it “looks wrong” without confirming it causes the failure
- “Just try this” fixes applied before evidence is gathered
- Suppressing error flags (`-s`, `2>/dev/null`) without adding compensating visibility elsewhere
- Claiming something is fixed without actual output confirming it
- Debugging the wrong layer: treating exit code 56 as a network issue without first ruling out HTTP 401 masking

### 6.6 Special Rule for iOS / CI Debugging
Classify the failure before patching. Put it in one of these buckets:
- repository/config problem
- workflow/YAML problem
- shell/quoting/path problem
- Xcode project generation problem
- signing identity problem
- provisioning profile problem
- App Store Connect auth/API problem
- export configuration problem
- Apple content validation problem
- CI runner/toolchain issue

Do not solve a later bucket until earlier buckets are reasonably ruled out.

### 6.7 Release-Engineering Debugging Order
For iOS delivery, debug in this order unless evidence clearly says otherwise:
1. identifiers/config
2. project generation
3. archive
4. signing assets
5. profile installation
6. export options
7. upload
8. Apple validation/content issues

### 6.8 Lessons from This Repository's CI Debugging History

These are confirmed patterns learned from actual failures in this codebase:

- **curl exit 56 on ASC API** = curl HTTP/2 + `--fail` bug ([curl #13411](https://github.com/curl/curl/issues/13411)) masking an HTTP 401. Root cause is invalid JWT, not network failure. Do not treat as network issue.
- **Unencoded brackets in ASC URLs** (`filter[x]`, `fields[x]`) = RFC 3986 violation. ASC's HTTP/1.1 endpoint returns 400. Fix: percent-encode as `%5B` / `%5D`. HTTP/2 is more lenient.
- **`openssl dgst -sign` output** = DER-encoded ECDSA. JWT ES256 requires raw R||S (64 bytes). Use `scripts/gen_asc_jwt.py` (Python `cryptography` library) — do not roll a new bash converter.
- **`macos-latest` runner** is currently `macos-15-arm64` with Xcode 26.3. iOS 26 SDK breaking changes affect SwiftUI (`.accentColor` removed as ShapeStyle, ForEach binding overload ambiguity, `CGSize: @retroactive Codable` redundant).
- **YAML `run:` literal block scalars**: Python/script code at column 0 terminates the block. Multi-line scripts that need column-0 content (heredoc closing delimiter) must live in repo files, not inline.
- **`ITSAppUsesNonExemptEncryption: false` in Info.plist** = Apple auto-answers compliance at upload time. The ASC API compliance PATCH is redundant but still runs for beta group distribution.

---

## 7. Refactor Mode

Refactoring must improve structure without changing intended behavior.

### 7.1 Refactor Priorities
- reduce responsibility overload
- improve naming and boundaries
- eliminate duplication
- centralize repeated rules
- make tests easier to write and reason about
- improve observability or failure clarity when useful
- preserve learned operational knowledge in docs/runbooks/this file

### 7.2 Refactor Guardrails
- preserve public contracts unless the task explicitly authorizes change
- avoid mixing refactor + broad feature work in one pass
- keep commits/change sets conceptually tight
- update docs/tests when behavior or structure meaningfully changes

---

## 8. Feature Development Mode

When building new functionality:

1. Understand where the feature belongs in the architecture
2. Reuse existing patterns unless they are clearly harmful
3. Define contracts first:
   - types
   - schemas
   - interfaces
   - request/response shapes
4. Separate:
   - domain logic
   - orchestration/application logic
   - infrastructure adapters
   - presentation/transport concerns
5. Build the smallest complete slice that works end-to-end
6. Add tests at the right level

### 8.1 Prefer This Layering
- **Domain**: rules, entities, invariants, scoring, transforms
- **Application/Orchestration**: use cases, workflows, sequencing, coordination
- **Infrastructure**: DB, network, queues, file system, LLM providers, third-party APIs, CI/release glue
- **Interface**: HTTP handlers, CLI entry points, UI adapters, serializers

---

## 9. Testing Requirements

Testing is not optional decoration.
Choose the lightest test that proves the important thing, but do prove it.

### 9.1 Test Strategy Hierarchy
Prefer this mix when applicable:
- **Unit tests** for pure domain logic and transforms
- **Contract/schema tests** for boundaries and structured outputs
- **Integration tests** for repositories, APIs, queues, and cross-module flows
- **Characterization tests** before refactoring risky legacy behavior
- **End-to-end tests** for business-critical user journeys
- **Stage-based validation** for iOS delivery pipelines

### 9.2 What to Cover
Cover:
- happy path
- edge cases
- expected failures
- regressions for any significant bug fixed
- important invariants and schema contracts

### 9.3 Good Testing Habits
- keep tests deterministic
- use representative fixtures, not fantasy data when domain nuance matters
- avoid brittle tests tied to irrelevant formatting
- test observable behavior more than implementation trivia

### 9.4 AI-System Testing
For AI-assisted or LLM-dependent systems, also use:
- prompt/version golden tests when appropriate
- schema validation tests
- fallback-path tests
- timeout/retry/circuit-breaker tests
- masked fixtures to avoid leaking secrets or unstable values

### 9.5 iOS Pipeline Validation Rule
For iOS CI, explicitly distinguish these validations:
- project generation succeeded
- archive succeeded
- signing succeeded
- profile install succeeded
- export succeeded
- upload succeeded
- Apple validation succeeded

Never summarize “pipeline works” unless the intended stage has passed.

---

## 10. Architecture Rules for AI + Agentic Systems

Use these when the repository includes LLMs, tools, retrieval, or multi-agent flows.

### 10.1 Deterministic Shells, Nondeterministic Cores
Wrap model calls with deterministic infrastructure:
- stable prompts
- explicit schemas
- bounded budgets
- timeouts
- retries with jitter
- trace IDs
- versioned configs

### 10.2 Schema-First Outputs
Every meaningful AI boundary should have an explicit contract.
Prefer structured outputs that can be validated.
If a freeform answer is required, still separate:
- raw model output
- parsed/validated structure
- user-facing rendering

### 10.3 Evidence-First Reasoning
For systems that synthesize facts, analyses, or recommendations:
- preserve provenance
- keep citations/links/IDs where available
- distinguish source facts from model inference
- never silently upgrade weak evidence into strong claims

### 10.4 Routing and Parallelism
When using multiple agents/tools:
- activate the fewest components needed
- cap concurrency
- use partial success patterns
- prefer `allSettled`-style orchestration where sensible
- isolate slow or failure-prone dependencies

### 10.5 Cost and Latency Discipline
Control:
- token budgets
- recursion depth
- fan-out width
- timeout ceilings
- cache keys and lifetimes

Do not build AI orchestration that is impossible to reason about operationally.

---

## 11. Reliability, Resilience, and Performance

### 11.1 Required Reliability Patterns
Use these when justified by the path’s criticality:
- timeouts
- cancellation/abort support
- retries with backoff or jitter
- circuit breakers
- bulkheads
- idempotency keys for retryable writes
- graceful degradation for partial failure

### 11.2 Concurrency Rules
- prefer bounded concurrency
- avoid unbounded parallel calls
- protect shared resources
- use queues/backpressure where bursts can overwhelm dependencies

### 11.3 Performance Rules
Optimize in this order:
1. eliminate waste
2. reduce unnecessary I/O
3. cache stable expensive work
4. simplify algorithms/data flow
5. parallelize only when the workload and dependencies justify it

### 11.4 Streaming and UX
If output can stream, prefer fast first meaningful output over long silence.
But do not stream misleading intermediate claims as if they were final.

### 11.5 Release Pipeline Performance Rule
For CI pipelines, optimize first for:
1. stage clarity
2. reproducibility
3. diagnosability
4. then runtime speed

A 2-minute build with excellent diagnostics is better than a 90-second build that obscures the real failure.

---

## 12. Observability and Operational Discipline

Every non-trivial production system should be diagnosable.

### 12.1 Observability Defaults
Prefer:
- structured logs
- request/trace IDs
- meaningful error messages
- timing/latency measurements
- metrics for critical paths
- enough context to reproduce failures without exposing secrets

### 12.2 Log Rules
Never log:
- secrets
- raw credentials
- unnecessary PII
- full tokens or keys

When logging failures, include enough information to localize the issue:
- subsystem
- operation
- identifiers safe to expose
- retry count / timeout context

### 12.3 Runbook Mindset
If the task reveals a recurring operational trap, update docs/runbooks when appropriate.
A strong repository teaches future sessions how not to repeat the same failure.

### 12.4 iOS Release Runbook Rule
When an iOS delivery issue is solved, document:
- exact failing stage
- root cause
- what false leads were eliminated
- final working approach
- required secrets/artifacts
- any Apple-specific caveats
- what can be reused in the next app

---

## 13. Security and Data Safety

Security is a default responsibility.

### 13.1 Always Prefer
- least-privilege access
- parameterized queries
- input validation and output encoding
- secret management through environment/vault tooling
- safe defaults in authz/authn flows
- auditability for sensitive operations

### 13.2 Never
- hardcode secrets
- print secrets into logs
- trust unsanitized external input
- weaken security controls to get tests passing without clearly flagging it

### 13.3 Prompt/Tool Safety
For AI systems using external content or tool results:
- treat retrieved text as untrusted input
- separate instructions from data
- sanitize or constrain tool-fed context when needed
- avoid allowing external content to redefine system intent

### 13.4 Apple Signing Secret Safety
For iOS release engineering:
- separate API auth secrets from signing secrets
- minimize cross-platform transformations of signing artifacts
- prefer macOS-native creation/import for Apple-specific formats when feasible
- rotate/recreate artifacts carefully, not casually
- avoid repeated destructive changes unless the current artifact state is truly the problem

---

## 14. Documentation Rules

Documentation should help the next engineer and the next Claude session.

### 14.1 Keep Fresh
Maintain or update when relevant:
- `README.md`
- architecture notes
- ADRs
- runbooks
- setup/build/test instructions
- prompt registries or model config docs
- CI/release docs
- Apple-signing notes where relevant

### 14.2 Prefer Docs That Answer
- what this subsystem does
- where the key entry points are
- what contracts exist
- how to run and validate changes
- what known risks or constraints matter

### 14.3 End-of-Task Learning Loop
At the end of meaningful work, if appropriate, suggest concise documentation or memory updates that would help future sessions avoid repeating discovery work.

### 14.4 Windows + iOS Documentation Rule
For this repo, documentation should explicitly distinguish:
- steps possible from Windows
- steps requiring GitHub macOS runners
- steps requiring Apple portal/App Store Connect interaction
- expected secrets/artifacts and their roles

---

## 15. How to Read and Modify a Codebase

When entering unfamiliar code, follow this order:
1. digest / synopsis docs
2. root README and project docs
3. entry points
4. types/schemas/contracts
5. tests
6. implementation details
7. configs and deployment/runtime assumptions

For iOS release work, also inspect:
8. project generation/config files (`project.yml`, XcodeGen files, plist definitions)
9. GitHub workflows
10. signing/setup scripts
11. asset catalogs
12. release notes/runbooks for current known-good paths

---

## 16. Preferred Implementation Patterns

Reach for these patterns when they fit.

### 16.1 Good Defaults
- pure functions for transforms and business rules
- dependency injection at boundaries
- adapters for DB/API/tool providers
- explicit schemas for inputs/outputs
- repository/service split only when it clarifies responsibilities
- composition over inheritance
- small utility modules over sprawling helper dumps

### 16.2 Helpful Patterns for TS/JS Codebases
- runtime validation with Zod/Valibot/TypeBox or equivalent
- `AbortController` for cancellation
- bounded concurrency helpers
- `Promise.allSettled` where partial completion is acceptable
- typed config loading at startup

### 16.3 Helpful Patterns for This Repo’s iOS + CI Work
- script repeated setup steps instead of manual portal repetition
- keep workflow stages explicit and named by responsibility
- use environment variables and secrets deliberately, not ad hoc
- validate generated files before the next stage consumes them
- use Apple-native tooling on macOS runners for Apple-specific artifact handling when feasible
- prefer one coherent signing strategy per pipeline phase

### 16.4 Avoid
- giant files with mixed concerns
- hidden global state unless deliberately managed
- magical side effects at import time
- boolean-flag explosions when a strategy/config object would be clearer
- adding abstraction layers with no immediate payoff
- rebuilding signing architecture from scratch without first isolating the real failure layer

---

## 17. What a Strong Claude Code Instruction File Looks Like

A strong `CLAUDE.md` should be:
- specific enough to change behavior
- concise enough to stay usable
- grounded in recurring repository realities
- explicit about platform constraints
- structured around real workflows
- updated after meaningful failures and successful resolutions

This file therefore emphasizes:
- evidence before assumption
- baseline before automation
- Windows-aware iOS delivery
- stage-based debugging
- operational memory for release engineering

---

## 18. Task Templates Claude Should Implicitly Follow

### 18.1 For a Bug Fix
- identify failing path
- inspect contracts and recent assumptions
- confirm root cause
- implement smallest correct fix
- add/update regression coverage
- summarize risk and validation

### 18.2 For a Refactor
- identify design smell
- preserve behavior
- tighten boundaries/naming/contracts
- keep change set focused
- run/update relevant tests

### 18.3 For a New Feature
- locate architectural home
- define contracts first
- implement vertical slice
- add observability where needed
- test the important path
- document meaningful behavior/config changes

### 18.4 For an AI Workflow Change
- identify affected prompts/tools/models/schemas
- preserve deterministic wrappers
- validate structure and fallback behavior
- check cost/latency implications
- maintain source/evidence handling

### 18.5 For an iOS CI / Signing Change
- define the exact target stage
- inspect current workflow and signing mode
- confirm bundle ID / app record / team assumptions
- minimize moving parts
- change one release layer at a time
- validate the current stage from logs
- do not declare end-to-end success early
- document the final working path

---

## 19. Repository-Specific Lessons for Future iOS Work

Use these lessons as standing defaults for this repo’s Apple-platform delivery work.

### 19.1 Do Better Next Time
Prefer this order:
1. verify app identifiers, assets, and metadata first
2. keep the first CI goal narrow
3. avoid jumping directly into full TestFlight automation if archive/export is still unproven
4. avoid mixing automatic and manual signing assumptions
5. treat Apple content validation as a separate stage after upload is functioning

### 19.2 Information the User Should Provide Early If Available
If relevant, ask for or infer these early:
- Windows vs macOS environment
- whether any remote Mac exists
- whether the app record already exists in App Store Connect
- final bundle identifier
- team ID
- current signing strategy
- exact goal for this session:
  - compile only
  - archive
  - sign
  - upload
  - TestFlight installability
  - App Store readiness

### 19.3 Three Questions Claude Must Ask Internally
1. **What is the fastest path to a working baseline?**
2. **What assumptions am I making that are not yet verified?**
3. **Am I solving the correct layer of the problem?**

If those answers are weak, slow down and reduce scope.

---

## 20. Final Standing Rules

1. Read before editing.
2. Prefer evidence over guesswork.
3. Keep changes small and coherent.
4. Preserve architectural intent unless the task is to change it.
5. Make hidden assumptions explicit in code, types, or docs.
6. Test the important thing.
7. Protect reliability, security, and maintainability.
8. Respect the Windows-first reality of this repo’s iOS workflow.
9. Treat iOS signing and TestFlight delivery as release engineering, not casual build config.
10. Leave the repository clearer than you found it.
11. **Before pushing any change to `main`: bump `CURRENT_PROJECT_VERSION` in `project.yml`.** Apple rejects uploads with a duplicate build number, and TestFlight will not surface the new build to testers if the version/build pair already exists. Bump the build number on every push. Bump `MARKETING_VERSION` when the user requests a user-visible version change.

If you must trade off, favor:
**correctness > clarity > maintainability > speed of implementation > cleverness**
