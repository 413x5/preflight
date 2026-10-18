# Development Playbook

How software gets built here: the working loop, the gate, the records, and the conventions around them.
It is written for whoever picks up the work next — a new contributor or an agent — and it assumes nothing
about the language, framework or product. Where a rule depends on tooling, it names the _job_ ("the type
checker", "the fast tests", "the gate command"), not a specific tool.

Material sits side by side here. One kind is _principles_ — the habits, and the reasoning behind
them. The other is the _concrete conventions_ those habits are usually realized with: a repository layout,
a documentation structure, and the handful of named standards worth adopting. The principles are the part
you adapt to a project; the conventions are well-worn defaults to start from, and none of them assumes a
particular language or framework.

Read it before changing code. Every rule below carries its reasoning: a rule you cannot explain to the
next person is a rule they will break by accident.

## The one idea

**Make a hard-to-see failure loud and cheap to catch.** Almost everything here — the gate, the test
fixtures, the change-selection map, the meta-tests, the decision records — exists to turn a class of
silent mistake into a red check or a written rule. When two designs are otherwise equal, prefer the one
whose failure is louder. **Prefer a failing check to a sentence.**

## 1. Two speeds: the inner loop and the gate

Development happens at two speeds, and confusing them is the most common way to waste time.

- **The inner loop** is what you run while working: the fast checks — types, lint, unit tests — plus the
  _affected subset_ of the slow (behavioural) tests. It should take seconds to a couple of minutes. Run it
  often.
- **The full gate** is every check, composed in one command. It is the definition of done and it belongs at
  the _end_ of a task, before you call it finished or hand it off — not in the middle of one.

The gate is slow on purpose: it includes the checks the inner loop skips. A change is not done because the
inner loop is green; it is done when the gate is green.

## 2. The gate: one command, enforced everywhere

Define the gate **once**, as a single command that composes every check in cost order — cheapest first, so a
trivial failure fails fast:

```
build → types → lint → unit tests → (privacy/scan checks) → behavioural tests
```

Then reference that one command from everywhere a change can be checked: the local commit hook, continuous
integration, and the docs. The point is that the gate is _defined in one place_ — if CI and the local hook
list the steps separately, they drift, and a change passes one and fails the other.

CI should **mirror** the gate rather than reimplement it. A common shape is to split the same steps across
two jobs — a fast job (types, lint, units, scans) on every push and pull request, and a slow job (the
behavioural suite) that provisions whatever that suite needs. A change gets an answer in seconds, and both
jobs must pass before it lands.

**Fail closed on missing tooling.** If a required piece of the environment is absent — a browser the
behavioural tests drive, a linter, a review helper — the check **fails** rather than passing. A check that
quietly no-ops when its tool is missing is worse than no check, because it reports success it never earned.
Give every such check a _single-commit_ escape hatch (an environment variable, a bypass flag), and require
that whoever uses it **says so out loud** — in the commit message or the pull-request body. A deliberate,
visible bypass is fine; a silent one is the thing these checks exist to prevent.

**Enforce where the change lands, not only where it is made.** A local hook runs on the machine of whoever is
committing, and it runs on the message they are about to write. Both of those are escape routes:
the bypass flag, and the tool that commits without running hooks at all — and on a host that squash-merges, the
message that reaches the trunk is not the one the hook read but the **pull-request title**. So a rule that
matters is read a second time from what actually arrived (the pushed range, the title, the merged diff), where a
bypass is visible to everyone. The local check stays: it is the fast, courteous half. It is just not the
enforcement.

## 3. The review loop (a second, enforced half of the gate)

Passing tests is necessary, not sufficient. Before a change becomes a pull request, it is **reviewed** — by
a person or an automated reviewer. Treat the review as a real gate with a clear exit condition, not a
formality.

- **Review the pending change, not the whole branch.** The default scope is what the commit will contain:
  everything the last commit does not yet have, tracked and untracked. Branch-wide and committed-only scopes
  are opt-ins. This keeps a review cheap and local — no remote, no base, no fetch.
- **A committed change must be the change that was reviewed.** A read-only pre-commit check compares the
  content about to be committed against the content the last review covered, and **refuses** if they differ
  or if nothing was reviewed. The validity is **content-based, not time-based**: a review counts as long as
  the content it covered is what is being committed. There is no expiry, and no re-review just because time
  passed.
- **Loop until the exit condition.** Read the findings, fix everything material in _one pass_, then re-run
  the review. Two signals tell you when to stop:
  - a **new-vs-known** count. If every finding was already raised, judge each one on its merits rather than
    re-fixing blind — you may have already decided it is a false positive.
  - a **coverage** flag. If the reviewer reports that it omitted files — a limit was reached and it could
    not review everything — the review is **incomplete**, and a low issue count means _"the rest was not
    looked at"_, not _"the change is clean."_ The reviewer must **say so plainly**: that its coverage was
    partial. It does not act on the shortfall itself — what to do about it is the maintainer's decision
    (§13).
- **Answer the class, not the instance.** A finding is one member of a class the code did not exclude, and
  a patch that closes only what the reviewer saw leaves the rest for the next round — at a full review
  apiece. Before editing, ask **what class is this, and what would make every member of it impossible**. A
  completeness finding (_you check these, but more exist_) is the commonest member and is never closed by
  adding the next item: replace the set with the property that makes a set unnecessary — the directory
  rather than the files in it, the content rather than the marker, the parent rather than the spellings. A
  finite list is legitimate only when it is _closed_ and asserted against its source, so the check fails
  when the source grows. **Two rounds on one class is the signal; the third is a course you were already
  told to change.**
- **Tell the reviewer what is deliberate.** An automated reviewer cannot tell a documented trade-off from an
  oversight, so it will report a deliberate decision as a finding. Give it a short, facts-only context
  block — "this is intentional and here is why" — that is sent _alone_ with the review. Keep that block
  current: a stale entry actively misleads, which is worse than saying nothing.
- **Distinguish blocking from advisory enforcement.** Blocking checks refuse the commit. Advisory checks run
  _after_ the fact and can only report — use them for the one thing blocking checks cannot cover: **silent
  non-enforcement** (a review that ran in a scope that cannot vouch for this commit, a helper whose state is
  unreadable). An advisor should stay quiet on a _visible, deliberate_ bypass — the flag the author typed is
  its own notice — and speak up only when something was skipped without anyone seeing it.

## 4. Verification doctrine

These are the habits that make checks trustworthy. Each one exists because its absence produced a class of
false result.

**Two tiers by cost, physically separate.** Keep fast checks (pure logic, arithmetic, contracts — no
browser, no network, no server) apart from slow behavioural checks (the real system driven end to end).
Separate them by directory and by command so the fast tier can run in parallel and in seconds.

**Tests own their data; they never read production state.** The suite builds a deterministic fixture — fixed
ids, names, prices, counts — into a temporary location it created, and points the system under test at it
through configuration. Nothing reads real data, and nothing writes outside the temp directory. The
consequence is the whole point: **a red test always means the code changed, never that the data changed.**
A missing file, a re-run, or a different machine cannot turn into a failing check that says nothing about
the code.

**Select by change, with a conservative fallback.** Map every source file to the checks that can observe it
(in a machine-readable table, one entry per test group). Given a change, run only the affected group. This
is what lets a working session stay fast. Rules keep it honest:

- A file **no** rule claims, and the test harness's own files, escalate to **run everything** — never to run
  nothing. When ownership is unknown, the safe direction is more testing, not less.
- A small, deliberately curated **"observes nothing"** list (prose, formatter config, build output,
  stylesheets that no check asserts) selects nothing. Keep this list short and justified; it is the one
  place a change can skip tests, so it is the one place a mistake hides.

**Diff against the trunk, not `HEAD` (for check selection).** When selecting _checks_ from a change, compare
against the mainline branch. On a development branch, a clean working tree still carries the commits already
made, and `HEAD` would hide them; on the trunk the diff is the working tree alone, which is what you want.
Fall back to `HEAD` only when there is no trunk to compare against — an old clone or a detached CI checkout.

This is deliberately the **opposite base from the review loop** (§3). A review's default scope is the
_pending change_ (`HEAD` → working tree, untracked included), because it must be cheap and local — no
remote, no base, no fetch — and comparing the whole branch against the trunk is its opt-in. The two
disagree on purpose: **check selection wants the branch's own commits to count, while a review wants to see
only what is about to be committed.** Do not use one base for both.

**Meta-test: when a rule cannot be enforced by the compiler, enforce it with a test.** Some rules live in a
place no type checker or linter can see — inside a string that gets evaluated, inside a naming convention,
inside a registry. Do not rely on discipline. Write a fast test that **reads the sources as data** and fails
on a violation. This is cheap, runs in the inner loop, and cannot be forgotten.

**Every exception justifies itself inline.** A meta-test that forbids something will eventually meet a
legitimate exception. Do **not** keep an allow-list — the list itself becomes a place for problems to hide.
Instead require the exception to annotate itself on the line (or in the comment block directly above it)
with a marker and a reason, e.g. `rule-ok: <why>`. The exception then stays visible in review, on the line
where it matters. A rule nobody can grep for is a rule that gets broken quietly.

**Contract parity / lockstep.** Where a schema, a type or a stored shape is the source of truth, hold the
fixture to it in a test: assert that the fixture's shapes match the declared shapes **by key set**, not by
parse alone (a parse silently drops a field the contract no longer declares — exactly the drift worth
catching). The effect is that changing a contract is red until the fixture changes **in the same edit**. The
fixture and its expectations are the same file; they move together.

**Advisory is not resolved.** When a rule genuinely cannot be fully enforced — because it is about
judgement — say so honestly in the record and rely on review, rather than shipping a weaker test that
pretends to cover it. A test that only looks like it enforces something is the false result this whole
section is against.

**Prove a move lost nothing, because prose has no compiler.** Moving text between documents — a split, a trim, an
extraction — is the one refactor nothing checks: a rule can disappear and every test still passes, because no test
reads prose. The habit is to make the loss visible. Take the distinctive strings of the original — the identifiers,
the command spellings, the class names, the diagnostic text — and assert that each still appears **somewhere** in
the tree afterwards. Whatever appears nowhere is either relocated deliberately or was lost by accident, and only a
reading tells the two apart. It is cheap, it runs in the inner loop like any other check, and it catches the class
of mistake a careful rewrite makes most often: the sentence you were sure you moved. (The complement of §6's
"docs travel with the code": that rule says update the document; this one says prove you kept the content.)

Sweep for **whole phrases, not only identifiers**. A loss the identifier sweep cannot see is a sentence with nothing
quoted in it — the symptom a reader recognises the failure by ("the name pushes the column wider"), the command that
diagnoses it ("check the health endpoint for a `busy` that never clears"), the reason a field is read in that order.
Those carry no distinctive token, so grep for the _cue_ around them (`the tell`, `when a scrape`, `the check to
run`) and read what it belongs to. The check that passes while a sentence was dropped is the false result this rule
is against.

## 5. Records: decisions and incidents

Writing keeps a project's reasoning alive, in kinds that have different shapes and different jobs.

### 5.1 Decision records (the _why_)

Keep a numbered, append-only set of **decision records**. Each records one decision and the alternatives it
beat. The shape:

1. **Title** — the decision in one line.
2. **Metadata** — Status, Date, who decided, and what it supersedes or amends.
3. **Context and problem statement** — what forced a decision, in two or three sentences: the forces, the
   constraint, and what goes wrong without one. Link the code, incident or measurement it came from.
4. **Considered options** — each with what it buys and what it costs. **Keep the options that lost.**
5. **Decision** — present tense, and why it beat the others. **One decision per record.**
6. **Consequences** — both the good and the bad; a record is not marketing. Close with a mandatory
   **"what enforces it"**: a test, a hook, a schema, or a written rule. _A decision nothing enforces is a
   wish._

Rules that make the set usable:

- **Supersede, don't edit.** An accepted record is never edited into a different decision. A reversal is a
  new record that says what changed and why; the old one keeps its own date and gains a status line
  pointing forward. Link both directions. This is what makes "we tried that" answerable with the reason it
  was replaced, rather than a shrug.
- **An evaluation that ends in "no" is a result too.** Recording why an option was rejected is as valuable
  as recording why one was chosen.
- **One decision per file.** A second decision is a second record.
- **Say what it costs.** Every option — chosen or not — carries its cost.

### 5.2 Incident records (the _rules_)

When something breaks, write an **incident record** whose payload is not the story but the **rule it
produced**. The shape:

1. **Title** — the incident in plain language, dated.
2. **Fixed in** — the version or pass, or explicitly "never as a code change."
3. **Impact** — what was actually lost, in one or two sentences, quantified where possible. "None" is an
   honest entry when true.
4. **What happened** — the mechanism, past tense.
5. **How it was found** — the detection path. This is a deliberate slot: it records which surface is
   load-bearing.
6. **Root cause** — often one sentence. When it is genuinely unknown, **say so**; "never established" is
   the honest entry.
7. **What it changed** — the payload. Each item is a _rule, a check, a guard, or a process change_, not a
   resolution.

These habits make it pay off:

- **Turn the incident into a durable check.** The fix that lasts is the one a test or hook now holds. "What
  it changed" should name the check, not just the patch.
- **Cross-reference recurring bug classes.** When the same _kind_ of mistake shows up twice — a guard that
  answers the wrong question, a readiness check that returns too early — name the class and link the
  records. The class is the lesson; the instances are examples.

## 6. Documentation doctrine: one home per fact

Every fact about the project has exactly one home, chosen by **the question a reader is asking**. When a
fact has two homes they disagree, and a reader cannot tell which is right. So documents **link; they do not
restate.**

| Role                    | Answers                                           | Reader                               | Lifetime                                                         |
| ----------------------- | ------------------------------------------------- | ------------------------------------ | ---------------------------------------------------------------- |
| The readme / user guide | "what is it, how do I run it"                     | someone using the product            | edited as behaviour changes                                      |
| The rules file          | "what are the rules and traps _now_"              | whoever works on the code next       | always current; operational                                      |
| Decision records        | "why was this decided, and does it still hold"    | someone questioning a rule           | append-only; superseded, never edited                            |
| The changelog           | "what shipped in this version"                    | a user of the product                | **written once, never edited**; a correction is the next version |
| The history             | "what happened, and what each change replaced"    | someone reconstructing the arc       | long-form narrative; never copied back out                       |
| Incident records        | "what broke, what it cost, what rule it produced" | anyone about to re-introduce the bug | append-only                                                      |
| Measurements            | "the dated numbers"                               | anyone about to quote a count        | numbers **with the reason each moved**                           |
| The roadmap             | "what is left, and how to take it"                | whoever picks up next                | **only work that is not done**                                   |
| Reference material      | "what is the shape _now_"                         | whoever is changing that part        | current state only; the history lives in the narrative record    |

Rules that fall out of this:

- **Docs travel with the code, in the same edit.** A change is not finished while a doc still describes the
  old behaviour. Ask "who would be wrong now?" and update that document.
- **A reference is not a log.** Reference material — the shape of the system, the flags, the formats — states what
  is true **now**. What it replaced, and the measurement that forced the change, belong to the narrative record:
  keeping both in one document means the reader has to work out which half they are looking at. The one thing
  that stays is a reason the next person still needs — a floor a change must not drop, a constraint the current
  code still relies on. The test is whether the sentence would change their decision; "the rule is X, because Y
  breaks" is reference, while "the rule used to be W" is history. A reference that accumulates its own history is
  the doc the split (§7) was meant to prevent, one level down.
- **A claim that turned out to be false is repaired or deleted, never left as aspiration.** A design that
  was decided but never built moves to the roadmap's "not done" section — it does not linger in a doc as if
  it existed.
- **Comments follow the same rule as docs.** If your change makes a comment untrue, fix the comment in the
  same edit. A stale comment is worse than none.
- **A number in prose is a copy that nothing checks.** A figure written into a sentence is a second copy of
  a fact something else already owns — the run, the code, the artifact, the dated record — and the sentence
  is the copy with no reason to stay right. It rots silently, and a reader who catches it cannot tell
  whether the text or the thing it describes is the one that moved. Every shape of it is one defect:
  - **What a run printed** — a check count, a suite duration, an "N of M selected" figure. Worse than
    stale: a count that fell for a bad reason (a check started giving up instead of seeing the app) reads
    as an improvement.
  - **A count of the text's own list** — "three habits", "the two boundaries". It carries no information,
    since the list is right there, and it is one more thing to update beside the list it describes.
  - **A measurement of an artifact** — a file's line count, a comment ratio, a size in bytes.

  State the **shape** instead ("every section passed", "the sections the change can affect", "these
  habits"), quote the run's own output in a code fence so it reads as one transcript rather than a claim
  about the project, or point at the dated record. The test is *who notices when it is wrong*: if the
  answer is "a reader, eventually", the number does not belong in the sentence.

  **A number that IS the interface stays.** A knob's value, a timeout, a port, an exit code, a version, a
  format's bytes and offsets: changing one means changing the code, and the code is where it is checked.
  It applies to prose wherever it lives — a doc, a comment, a test's message, a template, a commit body —
  so a number repeated into a second document is the same defect as one written twice in the same file.
  Encode what can be encoded, and be honest about the rest: a count is greppable while a duration reads the
  same as a timeout, so that half stays with review — an advisory is not a resolution (§4).
- **Record a number only when it is dated and tied to the reason it moved** — especially when the direction
  is counter-intuitive.
- **Live, external facts get a date.** Facts surveyed from a website or a vendor page ("surveyed on this
  date", "re-check before you rely on it") decay; say when they were read and mark unverified ones.
- **The always-loaded file is the expensive one.** Documents are not equally cheap to keep open: one file is read
  **whole, every time, whether or not its subject comes up** (the rules file an agent loads, the contributor
  on-ramp, the readme), while the rest are read **on demand**, when a reader's task needs them. So the two are
  budgeted differently. The always-read file holds what is needed **before the reader knows which part they are
  touching** — the rules, the commands, the entry points, the traps and the ids — and **links out** for everything
  else. Detail there is not wrong, it is merely charged to every reader; the test is "would this change what
  someone does before they have chosen an area?" and anything past that belongs in the on-demand file. The budget
  shows up as review time, not as a failing check: an always-read file that has doubled is a cost no test reports.
- **A trap is worth its symptom and its tell.** A rules-and-traps file is not a manual: a trap earns its place for
  things that exist nowhere else — what the failure **looks like** when it happens, and what **identifies** it
  in the data or the output (the odd `null` in one field, the count that reads zero, the log line that repeats).
  The mechanism belongs in the reference file for that component. So when you extract a trap, keep the symptom,
  the rule and the tell, and link the explanation — and when you trim one, the test is whether the next reader
  could still recognise the failure, not whether the sentence reads well.

## 7. Documentation layout

Section 6 is the doctrine (one home per fact); this is the concrete shape that doctrine usually takes. The
following set is deliberately standard — a reader who has seen it before knows where to look.

**The document set at the root.** A project meant to outlive its author carries these:

| File                                        | Job                                                                                                                                                     |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `README.md`                                 | What the project is, why it exists, how to run it in a few lines, and a map to the rest. Keep it short; it links out rather than explaining everything. |
| `CONTRIBUTING.md`                           | The human on-ramp: setup, the gate, how to propose a change. It points at the rules file rather than duplicating rules.                                 |
| `CHANGELOG.md`                              | What shipped, per version (its shape is in §10).                                                                                                        |
| `SECURITY.md`                               | The threat model, and the private way to report a vulnerability.                                                                                        |
| `LICENSE`                                   | The licence — or an explicit statement that the code is private and unlicensed. Never leave this implied.                                               |
| `CODE_OF_CONDUCT.md`                        | For any project with contributors from outside.                                                                                                         |
| `ARCHITECTURE.md` (or `docs/architecture/`) | The big picture, once it is too large for the README. Split it per component when it stops fitting — see below.                                         |
| `AGENTS.md` (or the tool's equivalent)      | The operational rules for whoever works on the code next: invariants, commands, traps. A subtree may carry its own — the nearest file wins.             |

**The `docs/` tree.** Keep a `docs/README.md` that is an index — one line per document, so nothing is
orphaned. A common, workable shape:

```
docs/
├── README.md          the map: one line per document
├── adr/               decision records: NNNN-title.md, sequential, with a 0000-template
├── postmortems/       incident records: YYYY-MM-DD-title.md
├── runbooks/          how to operate, diagnose and recover
├── guides/            task-oriented "how do I…"
├── reference/         API, CLI, formats — the dry, complete tables
├── design/            a component map, one file per part (see below), once one file cannot hold it
├── roadmap.md         what is left, and how to take an item
├── history.md         the narrative of what changed, and what it replaced
└── measurements.md    the dated numbers, with the reason each moved
```

**A component map, when one architecture file stops fitting.** A single architecture document is right until it
is not, and the failure is quiet: it grows into a handful of unrelated sections, and a reader who needs to change
one part has to hold all of them in their head at once. Split it **per component** — one file for each part,
saying what that part **is**, how it is put together, what it promises and what it refuses. These make the
split pay off rather than just moving the mess:

- **Each file stands alone.** A reader arrives at one component and leaves knowing that component, without
  having read the others. Say what enters, what leaves, and what it must not reach across.
- **State the shape, and link to the why.** The rules and the traps keep one home; the decision record keeps the
  reasoning. A component file links to both rather than restating either (§6).
- **"What it refuses" is a section, not an omission.** The boundaries a component deliberately does not cross —
  a layer it will not import, a field it will not invent, a case it refuses rather than guesses — are the part a
  newcomer cannot infer from the code, and they are where a well-meaning change does damage.

Keep the map indexed from `docs/README.md` like every other document, and keep the set from growing by
accretion: a statement that stops being true is rewritten or deleted, never appended to. A reference is not a
log (§6) — and that rule is the one this split most often breaks, because a component file is exactly where a
"what it used to do" paragraph feels like context.

**The four kinds of documentation.** A widely used model (Diátaxis) holds that documentation comes in four
kinds, and that confusing them is what makes a doc set hard to use. Keep them separate, and be able to name
which kind you are writing:

- **Tutorials** — learning-oriented: a guided first success.
- **How-to guides** — task-oriented: steps that solve a specific problem.
- **Reference** — information-oriented: dry, complete and accurate (API, flags, formats).
- **Explanation** — understanding-oriented: the _why_, the background, the design.

**Conventions.**

- Numbered records are zero-padded and sequential (`0001`, `0002`), never reused; the number is the id.
- Dates in filenames and metadata use `YYYY-MM-DD` — it sorts chronologically and is unambiguous.
- One line per document in the index; a document the index does not mention is one nobody will find.
- Docs link to the code, and the code links back to the records.
- Keep docs as plain text (markdown) in the repository, so they are diffed and reviewed like code.

## 8. Repository layout

A canonical top-level layout that a newcomer can _guess_:

```
.
├── src/                 # product source — the only hand-written, shipped code
│   └── <layer>/         # grouped by responsibility, not by file type
├── tests/               # mirrors src/ (unit, integration, e2e) — or colocate *.test.*
├── docs/                # the documentation set (§7)
├── scripts/  (tools/)   # dev and ops helpers; not shipped
├── config/              # non-secret configuration and checked-in examples
├── .github/             # CI, issue/PR templates, CODEOWNERS, dependency bot
├── build/ (dist/ out/)  # generated output — never committed
├── README.md  CONTRIBUTING.md  CHANGELOG.md  SECURITY.md  LICENSE
├── .editorconfig  .gitignore  .gitattributes
├── .nvmrc / .tool-versions    # the runtime pin
├── .env.example                # documents required variables; never real values
└── <manifest>                  # package.json / pyproject.toml / Cargo.toml / go.mod
```

**Principles.**

- **One obvious place per kind of file.** If a newcomer has to ask where a file goes, the layout is missing
  a rule — not the newcomer a piece of knowledge.
- **Group source by responsibility, not by technical type.** A `utils/` (or `helpers/`, `common/`, `misc/`)
  directory becomes a dumping ground _and_ a coupling magnet: every module that touches it is coupled to
  every other. Name the layer after what it _does_ — its domain or its role — and keep it small.
- **Everything repeatable is a named command.** The manifest (or a task runner) is the single door to the
  project: `test`, `build`, `lint`, `verify`. Nobody should have to memorise a flag sequence.
- **Thin entry points, fat library.** Executables and CLI handlers parse arguments and wire things together;
  all the logic lives in importable, testable modules behind them.
- **Generated output is separated and ignored.** Build artifacts, coverage, caches and dependencies are all
  gitignored — never committed.
- **Configuration files in the repo, secrets in the environment.** Commit an example file that documents
  every variable; never a real value (§14).
- **Pin the runtime.** A version file (`.nvmrc`, `.tool-versions`, `.python-version`, a toolchain file)
  makes the environment reproducible and lets CI read the same pin.
- **Dotfiles carry conventions**: `.editorconfig` for whitespace, `.gitattributes` for line endings and
  binary handling, `.gitignore` for what must never be committed.

**Naming.**

- Directories and files: one case convention per project — `kebab-case` is safest across operating systems
  and URLs, `snake_case` is idiomatic in some languages. Pick one; never mix.
- One primary concept per file, and the file name is the concept.
- A test file is named after the file it tests, so it is findable at the same path.
- Numbered things (migrations, records) are zero-padded, sequential, and never renumbered.
- Avoid names that describe nothing (`util`, `helper`, `manager`, `common`, `misc`); name the
  responsibility instead.

## 9. Standards to adopt

The best practices above are codified in a handful of public, named specifications. Adopting them _by
name_ is what makes a sentence like "this is a minor bump" or "write a changelog entry" mean the same
thing to everyone:

| Standard                                    | Governs                                                                 |
| ------------------------------------------- | ----------------------------------------------------------------------- |
| **Semantic Versioning** (SemVer 2.0.0)      | Version numbers: breaking change → major, feature → minor, fix → patch. |
| **Keep a Changelog** (1.1.0)                | The changelog's human-readable shape and its group names.               |
| **Conventional Commits** (1.0.0)            | The commit grammar — its types map onto a SemVer bump.                  |
| **ADR** (and **MADR**, its common template) | The decision-record shape (§5.1).                                       |
| **Diátaxis**                                | The four kinds of documentation (§7).                                   |
| **The Twelve-Factor App**                   | Configuration in the environment, stateless processes, portability.     |
| **The testing pyramid**                     | The ratio of cheap fast tests to fewer slow end-to-end tests (§4).      |
| **Trunk-based development**                 | Short-lived branches, frequent integration, one trunk.                  |
| **OpenAPI / JSON Schema / Protobuf**        | Interface contracts, generated clients, validation at the boundary.     |
| **CODEOWNERS**                              | Who reviews what, enforced by the host.                                 |

Each is a public, versioned document — link it rather than paraphrase it. Where a project deliberately
departs from one, say so in a decision record: the departure is itself a decision.

## 10. Change mechanics

**Branches.** The mainline is the trunk. Work on a short-lived branch named after the type of change it
carries (`type/slug`), open a pull request, and **squash-merge** — one branch becomes one commit with one
subject. The unit of work is the unit that can be reviewed, reverted and attributed. The one exception is a
release commit, which may go directly to the trunk because it is the commit the release tag must name.

Do not rely on branch protection to enforce this if the hosting plan does not provide it — enforce it with
commit hooks and CI, and treat the convention as the rule.

**Commits.** Use a structured commit grammar: `type(scope): subject`, lower-case, imperative, a length
limit that fits one terminal line, a blank line, then a body. The body **says why and names what was run**.
The types are a small closed set (`feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`,
`revert`, `style`); the scope names the area and is encouraged, not required. **The version never appears in
a subject** — it lives in the machine-readable version field and the tag. Enforce the grammar with a commit
hook so a message that does not parse is rejected.

**Evidence, not verdicts.** A pull request says what changed, why, and **what you ran and what it said** —
commands and output, not "tests pass". A checklist covers the things that are easy to forget — but only the ones
a machine cannot already prove: the docs were updated in the same change, and nothing private leaked into the
diff. **An item the gate, CI or a hook already refuses is noise**, and worse than noise, because a box that is
ticked by obligation trains the reader to skim the list. The gate's own result belongs in the evidence, quoted
from the run, not asked for as a promise. The roles of the template's text are worth separating for the same
reason: a **heading** is the author's to fill in, while the guidance on what that heading wants is **hidden in a
comment**, so it does not read as structure the author is meant to keep. A template that ships its instructions as
visible prose gets those instructions back as the body.

**Releases.** Cut a release with a script that derives as much as it honestly can and leaves the judgement
to a person: bump the version, **draft** the changelog entry from the commits since the last tag, then let a
human edit it until it reads like something a user would want. Commit the bump under a `chore(release)`
subject and create a **signed, annotated tag** whose message is the entry. The script should **never push**
— publishing is a separate, deliberate act. Never move or delete a tag that has left the clone; people pin
to tags, so a wrong release is fixed by the next version.

**The changelog is written once and never edited.** A released section is not corrected afterwards — a
correction is the next version, the same rule the tags follow. Group entries by kind (Added, Changed,
Deprecated, Removed, Fixed, Security), with no commit hashes and no counts. Its `Security` group is
narrower than the name suggests: it is for a vulnerability **in this tree's own code**, never a dependency
version move (see §11).

## 11. Dependencies and toolchain

**A dependency must earn its place, and the reason is written down.** The rule is not "no dependencies" —
it is "the reason is stated and it holds." An _important_ dependency (one that removes more code than it
adds, or covers a whole job the tree would otherwise hand-roll) is welcome; a convenience dependency that
duplicates what is already here is not. When the reason is architectural, it lands with a decision record;
when it is not, with a changelog entry.

**A runtime dependency clears a higher bar than a development one.** What ships to users is the heavier
kind. Keep the shipped dependency count small enough that you could name every one and say why it is there.

**Check compatibility before a bump.** A toolchain version is a contract with its ecosystem's plugins and
linters. Pinned versions are pinned for a reason; check the peer ranges before moving one, and record the
reason a pin exists so the next person does not "helpfully" bump it.

**Where an outcome is recorded follows the remedy, not the severity.** When an automated bot can fix a
dependency problem on its own, the record is the bot's pull request and the lockfile it changes — merge it,
and do **not** write a hand-crafted twin pull request or changelog entry beside it. Two records for one
version move is the thing this rule exists to stop. When the remedy is **this tree's own code** changing,
that is an ordinary change: it travels with its changelog entry, and with a decision record if the choice
is architectural. A dismissal is the platform's own reason plus one sentence.

**An advisory with no patched release is a question, not a dismissal.** Ask what the package is doing here.
If the vulnerable path is unreachable, or the job is small, the remedy is _removal_ — not an acknowledgement
that it is fine to keep.

## 12. Architecture and code conventions

**Separate the pure layer from the world-touching layer.** Keep values and pure functions in a layer with
**no** system imports — no filesystem, no network, no DOM, no sockets — because everything else imports it
and the fast tests exercise it without any of that. Anything that reads a file, a page or a port lives in a
layer that touches the world. Put pure logic where it can be tested cheaply, and keep UI code in the UI
layer.

**Funnel persistence through a small number of seam modules.** All reads and writes of stored data go
through a handful of named modules — never a raw filesystem call scattered through the tree. This is what
lets the storage backing change (files today, a database tomorrow) behind one interface instead of a
rewrite. Keep the modules that merely move opaque bytes _outside_ the seam; they read no domain data.

**Validate at the boundary; trust inside.** Parse and validate data where it enters the system — from a
file, a network response, a request, a command-line argument — and then work with the inferred types
everywhere downstream. Do not re-validate in loops; the check belongs at the edge. A failed parse and a
missing input are the same "not usable" answer, and nothing downstream re-checks.

**Contracts are the single source of truth.** When a shape changes, change it in the contract **first**,
then follow the compiler and the fixtures. A field the page or the store can genuinely omit is optional;
otherwise it is required. The compiler is the map for every downstream change.

**Name by the abstraction, not the implementation.** A name that says "folder" where it means "one unit of
data" is a bug report about the provider that is coming. Let the vocabulary follow the seam: the model, the
payloads and the interfaces speak the abstraction; only the current implementation speaks its own
realization.

**Never delete a key an older build wrote.** A schema change drops a field from the _code_, never from
stored data that was already written. A rewrite may stop reading a field; it does not strip it from the
record.

**Comments explain _why_, not _what_.** Say what a choice protects against, especially where the choice is
surprising. Where a comment is load-bearing for comprehension, cross-reference the decision record that
explains it. Keep the reasoning where it helps the next reader, and fix a comment the moment your change
makes it untrue.

## 13. Guardrails

**Fail loud.** A guard that cannot tell a real value from a bad one should fail visibly rather than pick a
plausible default and continue. A loud failure is a bug report; a silent wrong value is a bug.

**An automated check reports; the maintainer decides.** When a check cannot complete its job — a reviewer
whose coverage was partial, a scanner that hit a limit, a tool that could not read an input — it must
**state plainly what it could not do**. It does not pick a remedy of its own, and nothing is instructed to
act on the shortfall automatically. Raising a limit, re-running, or accepting the risk is the maintainer's
call, made with the shortfall in front of them.

**Bias the default toward the safe direction.** An unknown field is treated as _significant_ rather than
ignored; an unmapped file runs _every_ check rather than none. When you cannot decide, choose the option
whose failure is more visible.

**Do not half-build a hard problem.** If the correct solution is a real cross-process lock, a proper
migration, or a genuine recovery path, and you cannot build it now, leave it **open and named** — do not
ship a partial version that looks finished. Say what would reopen it and what would close it.

**State the cost, not just the benefit.** Every decision has one; naming it is what lets the next person
decide whether the trade still holds.

**Nothing that cannot be grepped is a rule.** If a convention matters, encode it in a check (a compiler
rule, a lint rule, a meta-test) or give it a marker a reader can search for. A rule that lives only in
someone's memory is a rule that is already being broken somewhere.

## 14. Privacy, secrets and security posture

- **No secrets in the repository, ever.** Credentials, tokens and API keys live in the environment or a
  secret store — never in a file, a doc, a test, or a fixture. A dependency that needs a key gets it from
  the environment, and the repository's configuration layering is already the interface for that.
- **No telemetry and no third-party calls by default.** The only outbound traffic should be to the services
  the product genuinely needs. Do not add analytics, remote fonts, CDNs or scripts to a local tool. It
  should keep working with the network unplugged.
- **Config layers in one direction, with one answer per key.** Defaults, then machine-specific, then a
  project file, then environment, then command-line flags — narrower scope wins, and a command should be
  able to print every key with its value _and where that value came from_. When a layer is added, keep it a
  **subset** of the schema, not a mirror, so it does not have to be kept in step by hand.
- **A privacy scan should derive its vocabulary, not hard-code it.** If a repository must not contain
  private data, scan for the _words that actually exist_ in the private store at run time (derived from the
  data itself), not a fixed blocklist — "the list is itself the leak." Scan both tracked files **and commit
  messages**, because the history is published with the repository exactly as the files are. Offer the same
  inline escape hatch (`why-ok: <reason>`) that the meta-tests use, and let the scan pass honestly when
  there is nothing to check against.
- **Keep private data out of commits, screenshots and issue reports.** A name copied into a doc or a
  fixture leaves with the repository. Write examples in a _fixture_ vocabulary, never a real one.
- **Scrape, fetch and integrate responsibly.** Keep request rates polite and serial where a service is
  load-bearing, respect a challenge or rate limit rather than retrying in a loop, and never turn a debugging
  session into a load test.
- **A local tool is local on purpose.** If something binds to loopback with no authentication, that is a
  design decision about _where it runs_; exposing it beyond that is a security decision to raise
  explicitly, not a configuration tweak.

## 15. The reviewer's checklist

The recurring decision criteria, phrased as questions to ask of any change:

- **Does it earn its place?** For a new dependency, a new abstraction, a new file: does it remove more than
  it adds, or cover a whole job?
- **What enforces it?** Every rule should name the check, hook, schema or review that holds it. If nothing
  does, say so honestly rather than implying a check exists.
- **Is the safe direction the default?** When the system is unsure, does it fail loud and run more, rather
  than fail quiet and run less?
- **Does it state its cost?** Both the decision and the test suite cost something; are they named?
- **Does the test own its data?** Does a red result mean the code changed, or could it mean the data did?
- **Is the vocabulary the abstraction, or the implementation?** Will this name survive the next change of
  backing store?
- **Did the docs move with the code?** Who would be wrong now, and is that document updated in this change?
- **Could this leak private data — in a file, a fixture, a comment, or a commit message?**

---

_This playbook describes the **process**, not the product. Where a practice above depends on a specific tool
or language, adapt the tool and keep the reasoning — the reasoning is the part that transfers._
