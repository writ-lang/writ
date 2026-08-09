# Simplification candidates

Parked findings from reading `docs/tour.md`. Each is a candidate, not a
decision; promoting one means writing it its own design doc. Kept here so a
finding is not lost between reading sessions.

Status key: **parked** (recorded, not decided) · **designed** (has a spec) ·
**done**.

---

## 1. Entity-major instance clauses — **designed**

See [2026-08-09-entity-major-instances-design.md](2026-08-09-entity-major-instances-design.md).
Two clause shapes collapse to one. Word count unchanged at 27; the grammar
loses a production.

## 2. Remove `of` — **designed** (bundled with 9)

Promoted 2026-08-09 into
[2026-08-09-grammar-removals-design.md](2026-08-09-grammar-removals-design.md),
which ships together with candidate 1. Analysis below stands, with one
correction found while designing: the top-level arrow form is zero-use in
`.pol` files but has **2 uses in `tests/unit/test_names.ml`**, both testing
error paths that cease to exist — they get deleted, not migrated.

*Raised 2026-08-09, from tour step 2.*

`of` has two roles in the grammar. Measured across all 36 `.pol` files in `pol`,
`pol-problems` and `pol-arch`:

| Role | Uses |
| --- | --- |
| instance header — `(instance N (of SCHEMA) …)` | 25 |
| top-level arrow — `(arrow N (of T) (to T) …)` | **0** |
| arrows declared in a type body — `(arrow N (to T) …)` | 58 |

The top-level arrow alternative is dead grammar: never used, in any repo.

**Proposal.** Drop the top-level arrow alternative, and make the instance
header positional:

```lisp
(instance shelf library
  (book hamlet (status available)))
```

Unambiguous, because the name and the schema are atoms while every clause is a
list — the same atoms-versus-lists rule that carries candidate 1. It also
matches the positional style of `(use library)` and `(initial shelf)`.

**Effect.** `of` leaves the language: **27 → 26 words**. Appendix A loses one
alternative and one production. Migration is 25 one-line edits plus zero for
the dead form.

**Rejected variant.** `(instance shelf (library) …)` — ambiguous: `(library)`
is indistinguishable from a zero-entity clause `(TYPE)`.

**Open question — settled 2026-08-09.** Does the top-level form do anything the
type-body form cannot, such as attaching an arrow to a type from another loaded
schema? **No.** It is confined to its own schema:

```
pol: ext.pol:4:21: arrow `status` names an undeclared type `book` as its domain
```

It is a pure layout alternative — same expressive power, zero uses. Nothing is
lost by deleting it.

## 3. Remove `to` — **parked**, no recommendation

*Raised 2026-08-09, alongside candidate 2.*

`(arrow status (to shelf-state))` → `(arrow status shelf-state)`. Would take
26 → 25 words. 58 sites.

**For.** If candidate 2 removes the top-level arrow form, every arrow is
declared inside a type body, so the source is always implied by nesting and the
target is the only type position. `(arrow status shelf-state)` inside
`(type book …)` reads directly: a book has a status, which is a shelf-state.

**Against.** It contradicts the rule candidate 1 establishes — atoms are
entities, lists are slots. In `(arrow holder (to person) vacatable)` the list
is the target and the bare atoms are flags, which is the same rule one level
up. Positional makes atoms carry both roles, separated only by position and by
`fixed`/`vacatable` being reserved. The warrant is also weaker: this removes a
word, not an ambiguity, and `to` is part of what lets a schema line read as
English to a non-programmer (Appendix H's claim against Event-B's surface).

**Recommendation.** Hold until the tour read-through is finished — it interacts
with whatever else surfaces, and is a preference rather than a defect.

## 4. Remove `do` — **rejected**, with reason

*Raised 2026-08-09, from tour step 3.*

`(transition N (when G) (do EFFECT…))` → `(transition N (when G) EFFECT…)`.

**Syntactically removable.** Effects are headed by `set`, `vacate` and `gap` —
all kernel words, no user names in effect head position — so the flattened form
parses unambiguously.

**But it destroys a capability that is in use.** A form invoked inside a list
must expand to exactly **one** datum. `(do …)` being a datum is what lets a form
produce an effect *group*. `pol-problems/libraries/scheduling.lib.pol` says so
in its own comment — "the effect list is one datum, which is what lets a form
produce it" — and defines:

```lisp
(form (hand-over J FROM TO &rest E)
  => (do (set TO.held-by J) (vacate FROM.held-by) @E))
```

used in both job-shop models:

```lisp
(hand-over J J.first J.second (set J.stage on-second))
(hand-over J J.first J.second (set J.stage on-second) (took-turn J))
```

Without `do`, `hand-over` is inexpressible and the blocking rule must be spelled
out at every call site — the duplication it exists to prevent.
`pol/tests/models/politics.lib.pol` has the same shape in `(form (does &rest ES)
=> (do @ES))`.

**Contrast with candidate 2.** `of`'s dead alternative had zero uses and no
unique power. `do` has few uses but a power nothing else provides. Word count is
not the metric; expressiveness lost per word saved is.

## 5. `when` is not removable — **closed**, no action

*Noted 2026-08-09 while testing candidate 4, for the record.*

`when` looks symmetric with `do` and is not. A bare nullary form is a legal
guard on its own — `(when shelved)` builds — and a transition's name is also a
bare atom. Dropping `when` would make `(transition shelved (set …))` ambiguous
between a transition *named* `shelved` and an unnamed one *guarded by*
`shelved`. `when` is forced by ambiguity; `do` was forced by the form layer.
Neither is ceremony.

## 6. Transitions name entities, not types — **open question**, not a defect

*Raised 2026-08-09, from tour step 3: "nowhere do we say what instance we are
describing."*

**The label is not missing.** `(initial …)` names the instance, and it decides
the transition's whole namespace — with two instances declared, entities of the
unchosen one are `unknown entity or variable` inside a transition. A model has
exactly one live instance (§6.1: exactly one `use`, exactly one `initial`), so
naming it per transition would have exactly one possible answer.

**What the question really exposes** is a layer asymmetry the syntax does not
announce: the schema is type-level, a transition is entity-level. `hamlet` is
hard-coded, and "any book" is inexpressible — a `some`-bound variable is legal
in a guard but rejected in an effect:

```
pol: quant.pol:11:14: unknown entity or variable `b`
```

**Consequence.** Every non-trivial model generates its moves with forms —
river's `(ferry goat left right)`, queens' per-queen transitions, the tour's
`(lend-to lend-ana ana)`. Part of the form layer's job is covering this gap.

**Why it is probably right.** A transition denotes one partial map (§2.3), and
one datum is one rule for edges. If an effect could use a `some`-binder, one
datum would denote a nondeterministic set of maps and the edge set would stop
being readable from the text. Forms make the expansion explicit. The visible
cost is that `pol control` exports enumerated moves rather than quantified ones.

**If ever revisited**, the feature would be "quantified transitions", and it is
an *addition*, not a simplification — it would grow the language to shrink
models. Out of scope for the current pass.

**Done:** tour steps 3 and 6 now state the entity-level restriction and link it
to why forms exist, instead of motivating forms by surface duplication alone.

## 7. One primitive under `is` and `set` — **closed**, fork already taken

*Raised 2026-08-09, from tour step 3: could `(set X Y)` and `(is X Y)` both be
theorems of something more fundamental?*

**Guard side: already reduced.** `=` is not a kernel word — stdlib derives it
from `is`, `defined`, `not` and `and`. The two are interdefinable given
`defined`, since `(is A B)` is `(and (defined A) (defined B) (= A B))`, so
exactly one can be primitive; `is` was chosen because strictness cannot be
recovered from vacuity without `defined`. `defined` is itself irreducible by
§10.2's argument: it is not a disjunction over values, because for an open type
the values are the roster, which no schema-level form can see.

**Effect side: already reduced.** §10.3 — "`set` is the single generator of
change; richer effects are guarded `set`s, written as library forms" — realised
in stdlib's `toggle` and `latch`. `vacate` cannot fold into `set`:

```
pol: value vacant not in codomain person
```

`vacant` is not a member of the target type, and making it one would totalise
the type with a sentinel — the move §2.3 exists to refuse. Candidate 4's lesson
again: the word is few but the power is unique.

**The cross-category unification does exist — it is TLA+.** One equality over a
two-state relation: `x = v` is `is`, `x' = v` is `set`. Appendix H already lists
TLA+ as the neighbour whose "actions are exactly a condition and a change".
Adopting it would cost:

- **determinism** — primed equality makes the successor a relation, able to
  under- or overdetermine it. Pol's transition is a partial *map* (§2.3,
  Appendix I.2); "one datum, one edge per admitting state" (§2.2) and the
  `pol control` quiver export both depend on that;
- **the implicit frame** — assignment keeps unmentioned slots for free; primed
  equality needs `UNCHANGED ⟨…⟩`;
- **§2.4's cost argument** — enumeration is cheap because each move is a
  function. A relational successor is a search.

Not a redundancy to factor out; a fork taken deliberately, whose other branch is
a language that already ships.

## 8. Make slots vacatable by default — **rejected**, with reason

*Raised 2026-08-09, from tour step 5.*

Drop `vacatable`; let every slot be allowed to be empty. Measured across all
three repos, 128 arrows:

| Kind | Count |
| --- | --- |
| `fixed` (wiring, must be complete) | 56 |
| plain mutable | 37 |
| `fixed vacatable` | 18 |
| `vacatable` | 14, of which 7 are written as `maybe` |

*(125 arrow declarations, comments excluded, across all three repos.)*

93 of 125 cannot be empty. Default-total is the majority case; flipping it means
annotating 93 sites to save 32.

**Five costs:**

1. **The forgot-to-fill-it error disappears.** Today omitting a non-vacatable
   mutable slot fails the build — `mutable cell book.status for hamlet is not
   vacatable and has no value`. Under the proposal it silently becomes an empty
   slot, and every guard on it goes quietly false.
2. **Every box would mean "X or nothing"** — §2.3's own complaint, universalised.
   Partiality everywhere is as uninformative as partiality nowhere.
3. **The space inflates exactly like the sentinel it replaced.** Every domain
   gains the empty case; the river goes 2×3×3×3 = 54 to 3⁴ = **81** — the same
   number as §2.3's `eaten`-sentinel bloat. Default-vacatable *is* the sentinel
   move, with "empty" as the universal sentinel.
4. **Laws lose their teeth.** `=` is vacuous where a side is empty, so every
   equation becomes satisfiable by emptying slots.
5. **Wiring could go missing**, contradicting §9.3's "wiring must be complete"
   and §12.1's "wiring never varies".

`vacatable` marks the exception, which is what lets the default carry
information — the same reason `to`, `do` and `vacate` survive.

## 9. Remove `=>` from `form` — **designed** (author overruled the hold)

Promoted 2026-08-09 into
[2026-08-09-grammar-removals-design.md](2026-08-09-grammar-removals-design.md).
The readability objection below is recorded there as an accepted cost rather
than dropped. One thing the analysis below missed: **`=>` has a second home**,
`(map X => Y)` in schema dictionaries (§16.4, §17), so the design changes that
too — otherwise `=>` survives and the "no infix" goal is not met. Zero uses,
feature deferred, so it is a spec-only edit.

*Original analysis, retained:*

*Raised 2026-08-09, from tour step 6.*

`(form PATTERN => TEMPLATE…)` → `(form PATTERN TEMPLATE…)`. 59 sites.

**Removable, and free.** Position disambiguates: element 2 is the pattern (an
atom for a nullary form, a list otherwise), elements 3+ are templates. And it
changes no count — `=>` is punctuation, not one of the 27.

**The case for removing it is consistency, and it is real.** `=>` is the
language's **only infix token**. `@SLOT` is a prefix sigil; the `.` in a chain
is lexical, inside an atom. Every other datum in Pol is `(head args…)`. So `=>`
is the single exception to §2.5's "everything is a parenthesised list whose head
is a word" — a claim that was stated unqualified and is now corrected in the
spec to name this exception.

**The case for keeping it is that nothing else separates pattern from
template.** Elsewhere, atoms-versus-lists does the disambiguating work
(candidate 1). Here both sides are lists:

```lisp
(form (a b c) (d e f))          ; which is which? position only
(form (a b c) => (d e f))       ; unmistakable
```

Multi-template forms make it sharper — stdlib's `toggle` emits two transitions
across two lines, and `=>` marks where the definition begins.

**Verdict: hold.** Closer than candidate 3 (`to`), because `to` is a
head-position word consistent with everything else while `=>` is genuinely
anomalous. But it earns its keep in reader-facing work that no other rule
recovers. Revisit only if the "one shape, no exceptions" story becomes worth
more than the marker.

**Done:** §2.5 no longer overclaims; it names `=>` as the exception and says why.

## 10. Is `=` needed in an equation? — **closed**, already removed

*Raised 2026-08-09, from tour step 7.*

`=` is **not a kernel word** and has not been since §8.6 let a law hold a guard
— that is Appendix B's 28 → 27. An equation takes any guard; `=` is a stdlib
form.

**It cannot be swapped for `is`, though.** `=` is the Kleene comparison —
vacuous where either side has no answer:

```lisp
(form (= A B) => (not (and (defined A) (defined B) (not (is A B)))))
```

Rewriting the tour's law with strict `is` adds a violation:

```
equation borrow-local
  violated in 1 reachable situations   witness:
```

An empty witness means zero moves — the initial situation, where `holder` is
vacant. A book held by nobody would violate a rule about who may hold it.

Choosing `=` or `is` in a law is choosing what an empty slot means to that law.
**Partiality's fifth appearance**: arrows (§2.3), guards as domain of
definition, `gap`, `vacate`-is-not-`set` (candidate 7), and laws.

**Done:** tour step 7 now shows the `is` version and its violation, instead of
only noting that `=` is a library form.

---

### Side finding: a stale comment in `stdlib.pol` — **fixed 2026-08-09**

The `maybe` design note carried three claims that the codebase had outgrown:

| Claim | Actual |
| --- | --- |
| plain vacatable is "far and away the most-written arrow shape" | 14 of 125 — `fixed` leads at 56 |
| "jobshop-best's tick ladder is the one place that still wants" `fixed vacatable` | 18 sites; 17 are `arch.lib.pol` capability flags, 1 is the ladder |
| "Eight arrows … take `maybe`" | 7 |

The inversion that matters: **`fixed vacatable` (18) is now more common than the
plain vacatable arrow `maybe` abbreviates (14)** — the form sugars the rarer of
the two shapes, which is the reverse of the note's justification.

The note now carries the counted table with its date, and says plainly that its
frequency argument has inverted while its objections to the alternatives
(`fixed-maybe` as a name, flags-as-slots) still stand — leaving whether the
common shape deserves a spelling **open rather than settled**. Comment-only
change; verified the edited source still parses and `(maybe …)` still expands.
