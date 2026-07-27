
# Decision Trees, Bottom-Up — a Pol Method

A method for producing decision trees by generation rather than by
drawing. Facts are listed bottom-up; the tree is derived, audited, and
compressed by tooling; what reaches a human is a short list of genuine
decisions with proofs attached.

The running illustration is a codebase-reengineering roadmap; the
method itself is domain-neutral — any problem passing the fit test
below.

## Fit test

Use the method when all four hold:

- facts are **discrete** and gatherable in parallel;
- the possible actions are **enumerable** in advance;
- the horizon is **bounded** — finitely many meaningful states;
- the option space is past the **~50-node cliff** where a hand-drawn
  tree silently stops being complete.

Do not use it when any of these hold:

- the space is small and obvious — scoring beats formalisation;
- the substance is numeric or probabilistic — enums would distort it;
- the *options themselves* are the unknown — generation permutes a
  declared catalog, it invents nothing;
- elicitation would cost more than the decision is worth.

## The inversion

A hand-drawn tree is an input: its completeness is unverifiable — a
missing branch looks identical to a considered-and-pruned one — and a
changed fact invalidates everything downstream of it.

Here the tree is an **output**. Declared once: an ontology of facts, a
catalog of moves with honest preconditions, laws, and goals. Generated
from them: every reachable state and every route — completeness within
the frame is a property of the construction, not of anyone's
diligence. The residual risk (an incomplete *frame*) is real, smaller,
inspectable, and audited in Phase 3.

## The workflow

### Phase 0 — Frame

**You:**

- Design the schema: the kinds of things scouts may record, the arrows
  between them, the laws (drivers that must hold) as equations.
- Reduce soft drivers to small ordered scales as enums with
  comparison forms — budget `(cheap moderate ruinous)`, horizon
  `(q1 q2 h2)`.
- Decide the granularity. This is the load-bearing judgment: model at
  the level where decisions live, not where facts are cheapest.

**Pol:**

- Enforces the ontology from the first datum: a fact that does not fit
  the schema is a read error at a line, not a note in the margin.

*Example. Components with a state (embedded / extracted / deprecated),
a fixed license, a vacatable owner; a law that no team owns two
migrating components at once.*

### Phase 1 — Move catalog

**You (agents may propose, you admit):**

- Write the catalog as a library of forms — one form per action kind,
  each with its honest precondition and its effect.
- Where an action is known to violate a driver, note it: the tooling
  will demand the acknowledgment later.

**Pol:**

- Forms expand to transitions; a malformed or ill-typed action is an
  error at the line where it was invoked.
- The catalog is versioned text: reviewable, diffable, reusable across
  engagements.

*Example. `(extract C)` — enabled only where a seam exists and an
owner is known; `(license-swap C L)`; `(deprecate C)`;
`(freeze-team T)`.*

### Phase 2 — Scouting

**Agents (in parallel), you (spot-checking):**

- Fill the instance: rosters and valuations — the facts.
- Record unknowns as unknowns: an unscouted owner is `vacant`, never a
  guess.
- Where scouting stopped by decision, declare it: a `gap` move with
  the reason.
- Report anything the ontology cannot express — do not force it (see
  Phase 7).

**Pol:**

- Rejects vocabulary inventions: agents can only fill cells the schema
  declared, so a thousand parallel scouts produce one coherent fact
  base or loud errors — never a silently inconsistent pile.
- Records absence as data: `vacant` cells are queryable, so "what do
  we not know yet" is itself a listable finding.

### Phase 3 — Build and audit the inputs

**You:**

- Run the build; read three reports as a to-do list on the *inputs*.

**Pol:**

- **Dead ends** — reachable states no declared move exits: holes in
  the catalog, each with the route that exposes it.
- **n/a claims** — questions naming structure nobody scouted: holes in
  the fact base.
- **Gaps** — the declared boundaries, each with its shortest route in:
  the known edge of the analysis, distinguished from the unknown ones
  above.
- **Law report** — which moves *can* violate which drivers; every
  unacknowledged pairing is flagged.

This phase iterates with 0–2 until the audits are quiet or every noise
is understood.

### Phase 4 — Claims

**You:**

- Write goals as properties in a claims file, separate from the model:
  each target end-state as `possible` (achievable at all) and `live`
  (still achievable — the door-open question).
- Write queries for the lists you will want: current violations,
  unknowns, blocked items.
- Acknowledge the driver violations you accept, in `accept` datums —
  this file *is* the debt ledger, and it is checked: stale or missing
  acknowledgments fail the build.

**Pol:**

- Evaluates every claim over the entire generated space; every verdict
  carries a route or a counterexample; nothing is sampled.

*Example. `gpl-free` as live; `fully-decomposed` as possible;
a query listing components with vacant owners.*

### Phase 5 — Generation and compression

**You:** nothing.

**Pol:**

- Generates every reachable state and route from the facts and the
  catalog — the full tree, including the branches nobody would have
  drawn.
- Compresses it (rules-engine derivations):
  - **Chores vs. decisions** — a state where every enabled move leaves
    every goal's `live`-status identical is not a decision; such moves
    sequence freely. A state where enabled moves *diverge* in what
    they foreclose is a **key decision**, and the divergence is its
    tradeoff, stated as sets.
  - **Dominance** — a branch whose open-goal set is strictly contained
    in a sibling's is discarded, with proof.
  - **Symmetry** — interchangeable pieces collapse; witnesses report
    up to the swap.

### Phase 6 — Read the outputs

**You (and every stakeholder):**

- The **key-decision list** — usually a handful of states, each with:
  the enabled options, what each keeps open, what each forecloses,
  the shortest route to the decision point.
- **Roadmaps as witnesses** — for each achievable goal, the move
  sequence, replayable and disputable step by step.
- The **debt ledger** — every accepted violation, in one place, still
  producing findings.
- Choose among the undominated frontier. The model has no preferences;
  the final pick is yours, and the model's refusal to make it is what
  keeps its verdicts trustworthy.

Disagreement now localises: "I dispute this roadmap" decomposes into
"I dispute fact F" or "I dispute the precondition of move M" — an
evidence argument, not a strategy argument.

### Phase 7 — Revision loop

**Agents:** re-scout; update facts; commit. One commit = one state of
knowledge; sources in the commit message.

**You:** admit proposed schema extensions and new moves — the channel
from Phase 2 for "the ontology cannot say what I found". This channel
is what keeps the frame honest; without it the method is a confident
blind spot.

**Pol:**

- `pol compare --git` across commits: which goals were **gained**,
  which **lost**, by what the new facts revealed — the roadmap tree
  evolves under version control, and a quiet loss cannot pass review
  green.

## Artifacts

| File                | Content                                       | Author                      |
| ------------------- | --------------------------------------------- | --------------------------- |
| `frame.pol`       | schema: ontology, laws, scales                | you                         |
| `moves.lib.pol`   | the action catalog, as forms                  | you (+ admitted proposals)  |
| `findings.pol`    | the instance: facts, unknowns, declared stops | agents                      |
| `goals.claims`    | targets, queries, acknowledgments             | you                         |
| `decisions.rules` | chores/decisions, dominance derivations       | reusable across engagements |
| git history         | states of knowledge; compare pairs            | everyone                    |

## The accounting

|              | Hand-drawn tree                   | Generated tree                                           |
| ------------ | --------------------------------- | -------------------------------------------------------- |
| effort       | exponential in tree size          | linear-ish in facts + moves                              |
| parallelism  | none — one head                  | scouting is embarrassingly parallel                      |
| completeness | unverifiable                      | within-frame: by construction; frame: audited (Phase 3)  |
| revision     | redraw downstream                 | edit one fact, regenerate                                |
| review       | at conclusions — near-impossible | at atoms — each fact and precondition locally checkable |
| the residue  | everything                        | the frame, and the final pick among the frontier         |
