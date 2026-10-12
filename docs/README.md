# Docs

The map. One line per document - a document this index does not mention is one nobody will find.

| Document | Kind (Diátaxis) | Answers |
|---|---|---|
| [`architecture.md`](architecture.md) | Explanation | How the bundle works and why each non-obvious decision was made |
| [`runbooks/troubleshooting.md`](runbooks/troubleshooting.md) | How-to | A symptom, its cause, the fix |
| [`adr/`](adr/) | Explanation | Why a decision was made, what it beat, what still holds. `0000-template.md` is the shape |
| [`roadmap.md`](roadmap.md) | — | What is left, and how to take an item |
| [`history.md`](history.md) | — | The narrative of what changed and what it replaced |
| [`measurements.md`](measurements.md) | — | The dated numbers, with the reason each moved |

The root documents are part of the same set, and are listed here because a document this index does not
mention is one nobody will find. They sit at the root rather than under `docs/` because a reader looks for
them there:

| Document | Answers |
|---|---|
| [`../README.md`](../README.md) | What the product is and how to run it - for someone using it |
| [`../CONTRIBUTING.md`](../CONTRIBUTING.md) | The human on-ramp: setup, and how to propose a change |
| [`../AGENTS.md`](../AGENTS.md) | The operational rules for whoever changes the code - every coding agent looks for it here |
| [`../PLAYBOOK.md`](../PLAYBOOK.md) | The development standard this repo follows: the gate, the docs doctrine, the records |
| [`../CHANGELOG.md`](../CHANGELOG.md) | What shipped, per version |
| [`../SECURITY.md`](../SECURITY.md) | The trust model, and how to report a vulnerability privately |
| [`../LICENSE`](../LICENSE) | MIT - the terms the code is offered under |
| [`../tests/README.md`](../tests/README.md) | Which test case guards which requirement |

The gate is one command: `../scripts/verify`.
