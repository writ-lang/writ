# Conformance gaps

Places where the implementation and the kernel spec disagree, with a
reproduction for each. A gap belongs here rather than in a comment next
to the code, because the code that is *missing* has nowhere to hold a
comment.

Format: what the spec requires, what actually happens, why it matters,
and where the fix goes.

---

## 1. §7 global names are not enforced (except for forms)

**Status:** open. Found 2026-07-26 while deciding whether adding types to
`stdlib.pol` reserves those names for every model.

### What the spec requires

§7, *Names*:

> **Global names** — types, entities, forms, equations. One namespace
> across the loaded universe; declaring an existing name is an error.
> There is no shadowing.

with the worked example spelled out in the same section:

> But a second `(type person …)` anywhere in the universe is an error at
> the second declaration.

§13 agrees, listing **duplicate names** among the `static` stage errors.
Pivotal idea 7 leans on the same rule — "every error still points at a
line the author wrote" is only true if a redeclaration is caught at the
line that redeclares.

### What actually happens

Of the four categories §7 names, only one is checked:

| Category | Duplicate rejected? |
| --- | --- |
| Types, in one schema | **no** |
| Types, across two schemas | **no** |
| Types, library vs. loading model | **no** |
| Entities (roster) | **no** |
| Equations | **no** |
| Forms | yes — `form \`f\` is already declared` |

Each reproduction below builds cleanly and reports `states: 1  edges: 0`
where the spec requires a static error.

```lisp
; a. two types of the same name, in ONE schema
(schema m (type v (a b)) (type v (c d)))
(instance i (of m))
(use m)
(initial i)
```

```lisp
; b. two types of the same name, in two schemas
(schema one (type v (a b)))
(schema two (type v (c d)))
(instance i (of two))
(use two)
(initial i)
```

```lisp
; c. two entities of the same name in one roster
(schema m (type box) (type v (a b)))
(instance i (of m) (box e) (box e))
(use m)
(initial i)
```

```lisp
; d. two equations of the same name
(schema m (type v (a b)) (type box (arrow f (to v)) (arrow g (to v)))
  (equation e (= box.f box.g))
  (equation e (= box.g box.f)))
(instance i (of m) (box p) (f (p a)) (g (p a)))
(use m)
(initial i)
```

```lisp
; e. a library's type name and the loading model's, across files
;    dup-lib.pol:
(schema lib (type v (a b)))
;    the model:
(load "dup-lib.pol")
(schema mine (type v (c d)))
(instance i (of mine))
(use mine)
(initial i)
```

Case (a) is the sharpest: a duplicate inside a single schema needs no
loading, no libraries, and no cross-file reasoning to be obviously wrong.
Case (e) is the one that bites in practice, because it is how a standard
library silently loses an argument with the model that loaded it.

### Why it matters

**It silently picks a winner.** Two declarations claim one name and the
model builds, so whichever the lookup finds decides what the model
*means*. The author is never told there was a choice. That is the exact
failure §7 exists to prevent, and it is worse than an error because it is
invisible.

**It makes the standard library's namespace cost unenforced but real.**
`stdlib.pol` declares `node` and `edge` (§2) and `ob`, `hom`, `chain`,
`eqn` (§6). Under §7 those six words are reserved for every model that
loads it. Today nothing enforces that, so a model may declare its own
`chain` and build. **The day this gap is closed, those models break.**
Whoever fixes it should expect fallout proportional to how long the gap
stayed open — which is the argument for fixing it sooner rather than
later.

**It undercuts the once-per-file load rule.** §6.2 justifies idempotent
loading on the grounds that "a repeated-name error always signals two
*different* declarations claiming one name". That guarantee is only worth
having if repeated names are errors at all.

### Where the fix goes

There is already a working template: `core/syntax/forms.ml:149` raises

```
form `f` is already declared
```

positioned at the offending declaration. The same shape is wanted for
types, entities, and equations — one accumulating set of declared names
per loaded universe, checked at each declaration, blamed at the second
one with its own `line:col`.

Note the ordering constraint: the check must run over the **loaded
universe**, after `load` inlining (§6.2), not per file — otherwise
reproduction (e) still slips through, since neither file contains a
duplicate on its own.

### Why it is not fixed yet

`core/syntax/decl.ml` and the parser are where the relational extension's
`.rules` work is landing. This is a small static check and worth doing,
but not worth a merge conflict in the module someone else is mid-way
through. Pick it up once that settles.

### Related: a reserved word reserves only against *form* names

Same root cause, worth recording beside it. `Forms.reserved` grew two
entries — `relation` and `rule` — when the `.rules` file type landed, and
`Forms.is_reserved` is consulted only by `Forms.collect`, i.e. for form
names and slot names. It does not reach type, entity, instance or
equation names. So this builds, with a type *and* an entity named after a
reserved word:

```lisp
(schema m (type rule (a b)) (type relation (c d))
          (type box (arrow k (to rule))))
(instance i (of m) (box rule) (k (rule a)))
(use m)
(initial i)
```

```
states: 1   edges: 0        exit=0
```

This is not currently harmful — the three file types are read by
different parsers, so a `.pol` type named `rule` never meets the `.rules`
declaration keyword. It is recorded because the fix for the gap above
will decide, one way or the other, whether reserved words join the global
namespace, and that decision should be made deliberately rather than
inherited.

---

## 2. §8.3 an arrow's `to` type need not be declared

**Status:** **fixed** 2026-07-26, same day it was found (while building
fixtures for the relational extension). Kept here rather than deleted,
because the shape of the bad diagnostic is the useful part of the record
— and because the `(of TYPE)` half of it was found only by asking
whether the twin existed.

### What the spec requires

§8.3, *Constraints*:

> The `to` TYPE must be a *named*, declared type.

§13 puts unknown names at the **parse** stage, and requires that every
error "belongs to one stage and names a `line:col`".

### What actually happens

The undeclared codomain is accepted. The model fails later, at a
different stage, with a message that blames the instance for a schema
fault and carries **no position at all**:

```lisp
(schema m (type v (a b)) (type box (arrow f (to nosuchtype))))
(instance i (of m) (box p))
(use m)
(initial i)
```

```
pol: x.pol: mutable cell box.f for p is not vacatable and has no value
exit=2
```

Give the arrow a value and the misdirection changes but does not
improve:

```lisp
(instance i (of m) (box p) (f (p a)))
```

```
pol: x.pol: value out of domain for cell box.f for p
exit=2
```

Neither message contains the string `nosuchtype`.

### Why it matters

**The exit status is right and the diagnosis is wrong**, which is the
worst combination: a CI gate keyed on the exit code stays honest while
the author is sent to the wrong line. There is no line to send them to,
because the message has no `line:col` — so this is simultaneously a §8.3
violation and a §13 violation.

**It is worse in a library.** The declaration is in one file and the
symptom in another, so the author reads a complaint about *their*
instance caused by a type name *the library* got wrong.

**Pivotal idea 7 is the casualty.** "Every error still points at a line
the author wrote" is exactly what does not happen here.

### The `(of TYPE)` twin

Asking whether the same hole existed on the other endpoint found that it
did — a top-level arrow whose explicit domain names nothing also built
clean, `states: 1  edges: 0`, exit 0:

```lisp
(schema m (type v (a b)) (arrow f (of nosuchdom) (to v)))
(instance i (of m))
(use m)
(initial i)
```

Fixing only the codomain would have left the twin.

### How it was fixed

`core/syntax/decl.ml`. The check cannot live in `decode_arrow`, because a
type may be declared **after** the arrow that points at it — a forward
reference is legal and must stay legal. So the schema has to be whole
first, which is exactly the position `check_equation` was already in:
decode returns the offending atom's position beside the value, and a
`check_*` pass re-attaches it once the schema exists. `decode_arrow` now
returns an `arrow_at` carrying `cod_at` and an optional `dom_at`
(`None` inside a `(type …)` body, where the domain is the enclosing type
and cannot fail), and `check_arrow` resolves both against `Schema.type_of`.

Both endpoints now report at the atom that is wrong:

```
pol: x.pol: 1:49: arrow `f` names an undeclared type `nosuchtype` as its codomain
exit=2

pol: a.pol: 1:50: arrow `f` names an undeclared type `nosuchdom` as its domain
exit=2
```

Three assertions in `tests/unit/test_data.ml` pin the behaviour: each
rejection's exact `line:col` and the offending name, plus a control that
a forward reference to a later-declared type still builds — which is the
assertion that would fail if someone "simplified" the check back into
`decode_arrow`.

`make build` / `test` / `lint` green, 24/24 standing gates, 13/13
relational-extension gates, `make examples` 58/58. Nothing in the repo's
own models, libraries, or fixtures was relying on the hole.

---

## 3. §13 a position from a loaded file is reported against the *loading* file

**Status:** open. Found 2026-07-26 while implementing the relational
extension; recorded as a parked concern in the extension's design note
before the reproduction below showed it is worse than "no filename".

### What the spec requires

§13: *"Every error belongs to one stage and names a `line:col`."* The
guarantee is only useful if the reader can tell **which file** those
coordinates index.

### What actually happens

`Errors.t` is `{ pos : pos option; msg : string }` — there is no filename
field — and `loader.ml` inlines a loaded file's datums into the loading
file's datum list, carrying their positions with them. The CLI then
prints the path it was *given*. The two are combined into a coordinate
that points at the wrong file:

```lisp
;; lib.pol — one line, 84 columns; the fault is the (equation …) sitting
;; inside a (type …) body, at column 55
(schema lib (type v (a b)) (type box (arrow f (to v)) (equation e (= box.f box.f))))
```

```lisp
;; m.pol — line 1 is `(load "lib.pol")`, sixteen columns
(load "lib.pol")
(schema mine (type w (c d)))
(instance i (of mine))
(use mine)
(initial i)
```

```
pol: m.pol: 1:55: expected an (arrow …) declaration
exit=2
```

The position is correct for `lib.pol`, whose line 1 runs to column 84.
The filename is `m.pol`, whose line 1 has 16 columns. Column 55 of the
named file does not exist.

### Why it matters

An absent filename would send the reader looking. A **wrong** filename
sends them to a specific place and tells them, with false confidence,
that the fault is there. In an editor this is worse still: the LSP hands
the diagnostic to whichever document it is analysing, so the squiggle
lands on a line of the loading file chosen essentially at random.

This is the same mechanism §6.2 relies on for its own guarantee, so the
cost lands precisely where libraries are used — the case the load rules
exist to support.

### Where the fix goes

Add a `file : string option` to `Errors.t`, set it when `Loader.inline`
splices a loaded file's datums, and print it in preference to the path on
the command line. This is a one-field change to a type in `core/data/`
that every error path in the engine constructs, so it is mechanical but
wide — which is why it was parked rather than done inside a feature run.

### Why it is not fixed yet

Engine-wide and pre-existing. It wants its own change, not a corner of
someone else's.

---

## 4. Part III §16.4 and §17 are unimplemented

**Status:** open by decision, not by oversight. Recorded here because
missing code has nowhere to hold a comment.

### What the spec requires

Part III is headed *normative for tools*. §16.4 specifies dictionaries —
`(functor NAME (from SCHEMA) (to SCHEMA) …)` and `(check SCHEMA.PROPERTY
via NAME)`, with totality, shape and law checks. §17 specifies comparison,
search and export, of which `pol compare` and `pol control` ship.

### What actually happens

```
$ pol functor …     pol: usage: …   (unknown verb)
$ pol migrate …     pol: usage: …
$ pol solve …       pol: usage: …
```

No CLI module implements `functor` or `check … via`; §17's fiber
reporting is likewise absent. The words `functor`, `via`, `from`, `over`
and `map` **are** in `Forms.reserved`, so the vocabulary is held open
against future forms — the syntax is reserved, the behaviour is not
built.

### Why it matters

A tool that reads Part III as normative and finds three of its verbs
missing cannot rely on the exit-status contract for them. The honest
position is that `pol` implements Part II in full and Part III in part;
the README and CHANGELOG both say so, and this file is where the
enumeration lives.

### Where the fix goes

`tooling/cli/` gained one module per verb during the relational
extension, so a new verb is a new `cmd_*.ml` plus a dispatch arm.
`docs/interrogator.md` §3 specifies `pol solve --functor` as *finding* a
dictionary where §16.4 *checks* one, and notes the two share the
totality, shape and law machinery — so §16.4 and the solver are best
built together rather than in either order.

### Why it is not fixed yet

Deliberately out of scope: the extension run implemented §0–§2, §4 and §5
and stopped. §3 is planned as its own run.

---

## 5. The relational extension diverges from its own §2 in two places

**Status:** open, both flagged at design time rather than discovered
after. These are gaps against `docs/interrogator.md`, not the kernel
spec, and are listed here because it is the same kind of debt.

### a. "closed" is read loosely in `(holds S G)`

§2's table says:

> `(holds S G)` — guard G is true in S (G a closed guard datum)

The implementation reads *closed* as "G is a guard datum, not a
variable", and permits G's free variables to be **rule** variables bound
by the surrounding body, so `(holds S (is X.a Y))` binds `Y` off a
mutable cell.

The strict reading is implementable and costs exactly one capability:
variable-binding over mutable cells in a named situation. Both of §2's
own spelled-out consequences work without it — the modality encodings
lift a closed formula out of a `.claims` file, and "backward analysis is
free" uses `edge` with no `holds` at all. So this is a **capability
addition**, defensible on its merits, and not a repair of a broken
promise. The honest alternative, if the loose reading is ever regretted,
is the sixth built-in the design considered and rejected:
`(cell S SRC ARROW V)`, which extends §2's table visibly instead of
re-reading one word.

**Fix:** decide, then make the document and the code agree. Either amend
§2's wording to say what "closed" excludes, or narrow the implementation
and add `(cell …)`.

### b. a CLI query argument that cannot inhabit its column answers empty

Inside a `.rules` file, a constant that cannot inhabit its column is
rejected at read time with a position:

```
pol: c.rules: 2:33: `nabu` is not a situation, which is what column 1 of
built-in `init` takes
exit=2
```

The same category of mistake on the command line is silent:

```
$ pol derive rules_base.pol space.rules "(reach nabu X)"
reach  (0 rows)
exit=0
```

This is *within* spec — §4 makes an empty answer set a legitimate answer
and 0 the right status for a well-formed query — but the CLI knows the
column's sort (that is how it reads integers as situations), so it knows
enough to say `nabu` can never appear there. An author debugging a query
that returns nothing has no way to tell "no rows match" from "this
question was malformed".

**Fix:** apply the same column check to query arguments in
`cmd_derive.ml`, and exit 2 with the same message. The check already
exists — `Rules_paths.check_col` — and the sorts are already computed;
only the call site is missing.

### Why neither is fixed yet

Both were surfaced by the extension's own design review and recorded as
accepted rather than overlooked. (a) is a decision awaiting an owner; (b)
is small and should be picked up with the next `pol derive` change.
