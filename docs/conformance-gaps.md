# Conformance gaps

Places where the implementation and the kernel spec disagree, with a
reproduction for each. A gap belongs here rather than in a comment next
to the code, because the code that is *missing* has nowhere to hold a
comment.

Format: what the spec requires, what actually happens, why it matters,
and where the fix goes.

---

## 1. §7 global names are not enforced (except for forms)

**Status:** **fixed** 2026-07-26. Found while deciding whether adding
types to `stdlib.pol` reserves those names for every model — and the
answer is now yes, enforced. Kept rather than deleted because the
"expect fallout" warning below turned out to be answerable with a number,
and that number is worth recording.

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

*(All six rows read **yes** as of the fix below.)*

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

### How it was fixed

`core/syntax/names.ml`, called from `Parser.collect_decls`. The ordering
constraint was the whole design: §7 says *loaded universe*, and
reproduction (e)'s duplicate exists in neither file alone, so the check
has to run after `Loader` inlines the loads (§6.2) and the expander has
run. `collect_decls` is the first point where every declaration is in one
list, so it is the earliest place the rule can be stated at all — and it
covers `parse_library` too, since a library should not contradict itself
either.

Names are collected from the **raw datums** rather than from the decoded
schema, because that is what keeps a position on every one. A roster
clause `(TYPE e…)` is told from a valuation clause `(ARROW (E V)…)` by
shape — all-atom arguments versus list arguments — with `(of SCHEMA)`
skipped by name, so no schema is needed to read entity names off an
instance.

All five reproductions above now fail at the **second** declaration:

```
a.  1:32: type `v` is already declared
b.  2:19: type `v` is already declared
c.  2:33: entity `e` is already declared
d.  3:13: equation `e` is already declared
e.  2:20: type `v` is already declared
```

### §7 says *one* namespace, and it is implemented that way

The gap's table listed the four categories separately, which invites a
set per category. §7's text does not: "types, entities, forms, equations.
**One** namespace across the loaded universe." So a name held by a type is
not available to an entity, which none of the five reproductions covered:

```lisp
(schema m (type box) (type v (a b)))
(instance i (of m) (box box))          ; an entity named after its own type
```

```
2:25: entity `box` is already declared as a type
```

That case has its own test, flagged as the one a future refactor is most
likely to drop by keeping a set per kind.

### The fallout the warning predicted: none, measured

The paragraph above warns "**the day this gap is closed, those models
break**", and expects fallout proportional to how long the gap stayed
open. Measured across the whole repository — 16 unit suites (366 checks),
all eight example scenarios (58 checks), 24 standing fitness gates, 13
relational-extension gates, and all seven docker services — **nothing
broke.** Not one model, library, fixture or emitted quiver was relying on
the hole.

That is a fact about *this* repository at *this* size, not a general
reassurance. The standing cost §7 imposes is now real and demonstrable:
`stdlib.pol` declares `node` and `edge` (§2) plus `ob`, `hom`, `chain`
and `eqn` (§6), and a model that loads it may no longer declare its own:

```lisp
(load "stdlib.pol")
(schema m (type chain (a b)))
```

```
2:17: type `chain` is already declared
```

Which is the point. Six words is a price the standard library now visibly
charges, rather than one it charged silently by letting the lookup pick a
winner.

### Related: a reserved word reserves only against *form* names

Same root cause, worth recording beside it. `Forms.reserved` grew two
entries — `relation` and `rule` — when the `.rules` file type landed, and
`Forms.is_reserved` is consulted only by `Forms.collect`, i.e. for form
names and slot names. It does not reach type, entity, instance or
equation names. So this builds, with a type *and* an entity named after a
reserved word:

```lisp
(schema m (type rule (a b)) (type relation (c d)) (type box (arrow k (to rule))))
(instance i (of m) (box p) (k (p a)))
(use m)
(initial i)
```

```
states: 1   edges: 0        exit=0
```

*(This reproduction was originally written with an entity also named
`rule`. Closing the gap above invalidated it — an entity may no longer
take a name a type holds — so it is narrowed to the claim it was actually
making: a reserved word does not stop a **type** from taking it. Worth
noting as an instance of the hazard this whole file exists to manage: a
reproduction is only evidence while it still runs.)*

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
pol: x.pol:1:49: arrow `f` names an undeclared type `nosuchtype` as its codomain
exit=2

pol: a.pol:1:50: arrow `f` names an undeclared type `nosuchdom` as its domain
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

**Status:** **fixed** 2026-07-26. Found while implementing the relational
extension; recorded as a parked concern in the extension's design note
before the reproduction below showed it is worse than "no filename". Kept
rather than deleted because the reproduction is the record of *why* the
filename had to ride on the position instead of being attached by the
caller — the mistake the obvious fix makes.

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

### How it was fixed

The field went on `Errors.pos`, not on `Errors.t`, and it is set by the
**reader** rather than by `Loader.inline`. `pos` is constructed in exactly
one place in the engine — `Reader.at`, fed by a cursor that now carries the
name `read_string` was given — so all ~133 error construction sites
inherited a filename without one of them being touched, and a position is
never in existence without one. Setting it at the splice would have been
the same amount of code and wrong for the case that matters: by the time
`inline` runs, the datums it is splicing already exist, and anything that
reads a position before or after the splice deserves the same answer.

`Loader` labels each file with the name it read it under. The two names
differ for the file the caller asked about — `resolve` searches for a
basename (design D3) while the path the caller typed is what they can act
on — so the entry points pass the path as the label and a `(load …)`
target gets the name the load datum gave it.

The CLI now prints the error's own filename when it has one and falls back
to the path on the command line when it does not, never both: two
filenames on one error is two claims about where it is.

The reproduction above, before and after:

```
pol: m.pol: 1:55: expected an (arrow …) declaration        ; column 55 of a
exit=2                                                    ; 16-column line

pol: lib.pol:1:55: expected an (arrow …) declaration       ; where (equation
exit=2                                                     ; actually is
```

A same-file error names the same file it always did, now from the position
rather than from the command line: `pol: single.pol:1:56: …`. An error with
no position keeps the command line's path and its bare message, as it must
— `pol: nosuch.pol: cannot resolve load: nosuch.pol`.

`file = None` stayed meaningful — it is what a query typed on the command
line and an unnamed buffer have, and it means "no name", never "no
position".

The **editor** treats a position from another file as no position at all.
A diagnostic belongs to the document being analysed; a coordinate into a
loaded library indexes lines this buffer does not have, and drawing it
would underline whatever text happens to sit there with total confidence —
the same failure as the wrong filename, in the medium where it is hardest
to notice. So the range falls back to line 1, where an error with nowhere
to point already goes, and the message carries the real `file:line:col`.
That is the conservative option: it never claims a location it cannot
support, at the cost of not putting the squiggle on the `(load …)` that
pulled the fault in, which would need `inline` to thread the load site back
out.

Nine assertions pin it: `tests/unit/test_loadpath.ml` builds the
reproduction above over an in-memory resolver and checks the library is
named, that column 55 lands on the `(equation` that is wrong, and — the
assertion that would have failed before — that the loading file's line 1 is
too short to hold that column at all; plus a same-file fault naming the
caller's path, and a string read having a position and no file.
`tests/unit/test_lsp.ml` drives the cross-file buffer and checks the
squiggle is not pinned to one of its lines.

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

**Status:** **both fixed** 2026-07-26 — (a) by amending the document, (b)
by amending the code. Flagged at design time rather than discovered after.
These are gaps against `docs/interrogator.md`, not the kernel spec, and
are listed here because it is the same kind of debt.

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
pol: c.rules:2:33: `nabu` is not a situation, which is what column 1 of
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

### How both were fixed

**(a) the document was amended, not the code.** The choice was: narrow the
implementation to the strict reading and add the `(cell S SRC ARROW V)`
built-in the design had rejected, or say in §2 what "closed" was actually
meant to exclude. The second, because the strict reading forbids a
binding that has no other expression while §2's own two spelled-out
consequences work either way — so the loose reading costs nothing the
document asks for and buys the only way to ask "in situation S, where does
this arrow point". §2's table entry is now "G a guard datum, not a
variable", with a paragraph stating that G's free variables are the rule's
and that the fixed-arrow restriction applies only to a bare guard. The
superseded wording is called out in the document rather than quietly
swapped, so a reader of an older copy can tell what changed.

**(b) the code was amended.** `Derive_table.code` already returned `None`
for a constant its column can never hold; `query` folded that into an
empty answer, which is what made the two indistinguishable. `query` now
returns `Error (column, sort)` for the first impossible argument, and the
CLI turns it into exit 2 with the same wording the `.rules` parser uses:

```
$ pol derive rules_base.pol space.rules "(reach nabu X)"
pol: `nabu` is not a situation, which is what column 1 of `reach` takes
exit=2

$ pol derive rules_base.pol closure.rules "(subordinate zzz X)"
pol: `zzz` is not an entity of `person`, which is what column 1 of
`subordinate` takes
exit=2
```

while a genuine negative is still an answer:

```
$ pol derive rules_base.pol closure.rules "(subordinate cabinet X)"
subordinate  (0 rows)          exit=0
```

**A second hole found by fixing the first.** An out-of-range state index
took the other path: `situation` parsed it and never bounds-checked, so
`(reach 999 X)` in a four-situation space answered "0 rows" while
`(reach nabu X)` was rejected. `code` now range-checks against the space,
so both are impossible constants and both are reported. Fixing only the
documented half would have left the twin — the same mistake gap 2's
`(of TYPE)` domain nearly was.

**A test asserted the old behaviour and had to be corrected**, which is
worth recording because it is the one case where changing a test is not
weakening it: `test_derive.ml` checked that an unknown atom "is empty",
which is precisely the conflation this gap is about. It now asserts the
distinction instead — a row that does not hold is `[]`, an atom no roster
holds is `Error`. Two checks where there was one.

Verified: 17 unit suites (376 checks), examples 58/58, 24/24 standing
gates, 13/13 extension gates. Two files crossed the 300-line cap on the
way and were split at real seams — `runtime/derive_answers.ml` out of
`derive_table.ml` (maintaining the store versus interrogating it) and
`tests/unit/test_facts.ml` out of `test_derive.ml` (the §2 adapter versus
the §6 fixpoint, matching the modules they exercise).

---

## 6. Part II constraints unenforced — a systematic sweep

**Status:** **fixed** 2026-07-26 — nine of them, plus one twin the fix for the
eighth exposed. Found by reading Part II's **Constraints** bullets one at a time
against the front end rather than by tripping over a symptom, which is why they
arrive together. Two further holes the sweep uncovered in §9 are recorded at the
end as **open**, because closing them needs a decision this run had no mandate
to make.

### What the spec requires

Nine bullets, verbatim:

| § | Constraint |
| --- | --- |
| 8.1 | `schema` — NAME is fresh (§7) |
| 8.2 | `type` — NAME fresh; **VALUEs distinct** |
| 8.3 | `arrow` — FLAG is `fixed` or `vacatable`, **each at most once** |
| 8.3 | `arrow` — **NAME fresh among the owner's arrows** (§7) |
| 8.3 | `fixed` — "the answer is set once by the instance and never changes: wiring" |
| 9.3 | `vacant` — an empty slot is "permitted only for vacatable arrows" |
| 10.1 | `transition` — NAME, if present, fresh |
| 10.1 | `transition` — **exactly one `when`** |
| 10.1 | `transition` — **exactly one `do`** |

§13 puts all of them at the `static`/`parse` stages and requires every error to
"belong to one stage and name a `line:col`".

### What actually happened

Every reproduction below **built cleanly, exit 0**. The state-space line is what
`pol check` printed:

```lisp
; 1. §8.1 — two schemas of one name              states: 1  edges: 0
(schema m (type v (a b)))
(schema m (type w (c d)))
(instance i (of m)) (use m) (initial i)
```

```lisp
; 2. §8.2 — an enumerated type repeats a value    states: 1  edges: 0
(schema m (type v (a a)))
(instance i (of m)) (use m) (initial i)
```

```lisp
; 3. §8.3 — a flag twice                          states: 1  edges: 0
(schema m (type v (a b)) (type box (arrow f (to v) fixed fixed)))
(instance i (of m) (box p) (f (p a))) (use m) (initial i)
```

```lisp
; 4. §8.3 — one type, two arrows named f          states: 1  edges: 0
(schema m (type v (a b)) (type box (arrow f (to v)) (arrow f (to v))))
(instance i (of m) (box p) (f (p a))) (use m) (initial i)
```

```lisp
; 5. §10.1 — two (when …), the FIRST silently won  states: 1  edges: 0
(schema m (type v (a b)) (type box (arrow f (to v))))
(instance i (of m) (box p) (f (p a))) (use m) (initial i)
(transition t (when (is p.f b)) (when (is p.f a)) (do (set p.f b)))
```

```lisp
; 6. §10.1 — two (do …), the second discarded      states: 2  edges: 1
(schema m (type v (a b)) (type box (arrow f (to v)) (arrow g (to v))))
(instance i (of m) (box p) (f (p a)) (g (p a))) (use m) (initial i)
(transition t (when (is p.f a)) (do (set p.f b)) (do (set p.g b)))
```

```lisp
; 7. §10.1 — two transitions of one name           states: 4  edges: 4
(schema m (type v (a b)) (type box (arrow f (to v)) (arrow g (to v))))
(instance i (of m) (box p) (f (p a)) (g (p a))) (use m) (initial i)
(transition dup (when (is p.f a)) (do (set p.f b)))
(transition dup (when (is p.g a)) (do (set p.g b)))
```

```lisp
; 8. §8.3 — (set …) a fixed arrow                  states: 2  edges: 3
(schema m (type v (a b)) (type box (arrow f (to v) fixed) (arrow g (to v))))
(instance i (of m) (box p) (f (p a)) (g (p a))) (use m) (initial i)
(transition setfixed (when (is p.f a)) (do (set p.f b)))
(transition setstate (when (is p.g a)) (do (set p.g b)))
```

```lisp
; 9. §9.3 — (vacate …) a non-vacatable arrow   states: 2  edges: 1  dead ends: 1
(schema m (type v (a b)) (type box (arrow f (to v))))
(instance i (of m) (box p) (f (p a))) (use m) (initial i)
(transition emptyit (when (is p.f a)) (do (vacate p.f)))
```

Case 5 is the sharpest of the shape-level ones. With `p.f = a` initially, a
false first guard beside a true second one gave `states: 1  edges: 0` — the
first `when` won and the second was dropped without a word, so the author's move
existed nowhere and nothing said so.

### Why it matters

**Seven of the nine pick a silent winner.** That is gap 1's failure verbatim, in
seven more places: two declarations, or two clauses, claim one slot, the model
builds, and whichever the lookup reaches decides what the model *means*. `(a a)`
reads as a two-value type and behaves as a one-value type. Two arrows named `f`
on one type both stand, and `Schema.arrow_in`'s scan order decides what every
chain through `box.f` denotes. Two `do` clauses mean half the author's effects
are not in the model.

**Two of them change the state space, which is worse.** Cases 8 and 9 do not
merely mis-resolve a name; they distort the graph every modality answer is
computed over.

`State.build_ctx` hoists fixed cells out of the state vector, so a write to one
has no cell to land in: the effect applies, changes nothing, and the move
becomes a **phantom self-loop** wherever its guard holds. Case 8's space has one
real edge and reported **three**. Self-loops are exactly what `live` (AG EF F)
is most sensitive to — it reads one as progress — so an illegal write does not
just go unnoticed, it invents structure and then gets asked questions about it.

Case 9 goes the other way: `build_ctx` **rejects** an unset non-vacatable cell in
an instance, and a `(vacate …)` built one anyway. The engine could reach a
situation its own totality check forbids — reachable, reported, and
unrepresentable as a written instance.

**Case 7 broke a tool's own round-trip.** `pol control` emits one `edge` entity
per transition (§17), so two transitions named `dup` produce a quiver instance
whose roster names `dup` twice — and since gap 1 closed, that output no longer
re-parses:

```
pol: q.pol:5:13: entity `dup` is already declared — §7 gives types, entities,
forms and equations one namespace across the loaded universe
```

The standing gate `control-emits-reparseable-quiver` could not see it: its
fixture's transitions are uniquely named.

### How it was fixed

Four homes, each the place the constraint's own scope points at.

**`core/syntax/names.ml` — case 1.** A fourth `kind`, `Schema`. §8.1's single
constraint is "NAME is fresh (§7)", which cites *this* namespace rather than one
of its own, so a schema name collides with a type's exactly as two types do. The
section cited in the message is now chosen by the kind the author just wrote:
saying "§7 gives types, entities, forms and equations one namespace" over a
rejected `schema` would invite the reader to check §7 and find no schemas
listed, so a schema is told about §8.1 instead.

**`core/syntax/decl.ml` — cases 2, 3, 4.** Values and flags are checked inside
the decoders, where the repeated atom's position is in hand. Arrow-name
freshness cannot be: the two declarations need not sit together, since one may be
nested in a `(type …)` body and the other written at schema top level with an
`(of TYPE)` domain naming the same owner. So it joined the `check_*` pass that
already waits for the whole schema, keyed on the pair **(dom, name)** — never the
name alone. §7 is explicit that `bureau` and `case` may each own a `status`, and
`tests/examples/river` leans on it (`traveler.at`, `cargo.at`); a global check
would have passed every new test and broken the river. Two controls pin the
scoping.

`decl.ml` would have crossed the 300-line cap, and was split at the seam its own
comments already drew: `core/syntax/decl_checks.ml` holds `arrow_at` and the
three checks that need an assembled schema, `decl.ml` keeps the decoders. That is
a real division — decoding turns a datum into data and cannot see forward,
checking resolves names against the finished result.

**`core/syntax/parser.ml` — cases 5, 6, 7.** `List.find_map` was what made the
surplus clause vanish: it took the first match and never looked at the rest.
Collecting every `when` and every `do` is what makes the second one *nameable*,
and the second is what gets blamed — the first is where the author probably meant
to write it. Transition-name freshness is scoped to transitions, not global:
§10.1 says NAME must be fresh and, unlike §8.1, pointedly does **not** cite §7,
so a move may share a name with a type. There is a control for that too, and it
is the assertion that would fail if the check were ever folded into `Names`.

**`core/syntax/grammar.ml` — cases 8, 9.** `check_effect` already resolved an
effect's path against the schema, so the arrow being written was one line away.
`(set …)` now rejects a `fixed` last arrow and `(vacate …)` a non-`vacatable`
one, both at the path atom.

### The twin the eighth fix exposed

Asking whether `vacate` had the *other* hole found that it did. A
`fixed vacatable` arrow is writable by `(vacate …)`, and lands nowhere in exactly
the same way:

```lisp
(schema m (type v (a b)) (type box (arrow f (to v) fixed vacatable) (arrow g (to v))))
(instance i (of m) (box p) (f (p a)) (g (p a))) (use m) (initial i)
(transition vacfixed (when (is p.f a)) (do (vacate p.f)))
(transition setstate (when (is p.g a)) (do (set p.g b)))
```

```
states: 2   edges: 3        exit=0        ; one real edge, two phantom
```

So the rule is stated once, over both effects — *no move may write a fixed
arrow* — rather than twice as a property of `set`. Fixing only case 8 would have
left the twin, the same mistake gap 2's `(of TYPE)` domain nearly was and gap 5's
out-of-range situation index actually was. It is the third time in this file, and
the lesson is now cheap enough to state as a habit: when a rule is about a write,
check every verb that writes.

### The nine, before and after

```
1.  states: 1  edges: 0   ->  2:9  schema `m` is already declared
2.  states: 1  edges: 0   ->  1:22 `a` is already a value of type `v`
3.  states: 1  edges: 0   ->  1:58 arrow `f` repeats the flag `fixed`
4.  states: 1  edges: 0   ->  1:60 arrow `f` is already declared on `box`
5.  states: 1  edges: 0   ->  3:34 a transition has exactly one (when GUARD)
6.  states: 2  edges: 1   ->  3:51 a transition has exactly one (do EFFECT…)
7.  states: 4  edges: 4   ->  4:13 transition `dup` is already declared
8.  states: 2  edges: 3   ->  3:49 arrow `f` is fixed, so no move may set it
9.  states: 2  edges: 1   ->  3:51 arrow `f` is not vacatable, …
    twin: states: 2  edges: 3  ->  3:52 arrow `f` is fixed, so no move may empty it
```

And the two that distorted the space no longer do. Case 8's model, with the
illegal transition removed by its author, is the space it always should have
been — and `pol control` no longer lists a move that cannot move:

```
states: 2   edges: 1        (edge setstate)
```

Case 9's, with the arrow declared `vacatable` as §9.3 requires, likewise:
`states: 2  edges: 1`.

Sixteen assertions land in `tests/unit/test_names.ml`: eleven rejections — the
nine above, the twin, and arrow freshness across the two syntaxes — each the
reproduction verbatim, each asserting the exact `line:col`; and five controls for
the cases a careless fix would break: two types each owning an arrow
of one name, `fixed vacatable` together, a transition named after a type, and the
legal `set`/`vacate` of a mutable arrow. `tests/unit/test_control.ml` pins case
7's round-trip from both ends: the duplicate is refused before `control` can see
it, and what `control` emits from a model that *does* read now survives §7 rather
than only the reader — the check that would have caught the broken round-trip and
that the standing gate cannot.

Verified: 17 unit suites (394 checks, exit 0), `make examples` 58/58, 24/24
standing gates, 13/13 relational-extension gates, `make build`/`lint` green.
Nothing in the repository's models, libraries or fixtures was relying on any of
the nine.

### What the sweep covered and found clean

So the next reader knows where not to look again. Read bullet by bullet against
the code: **§5** (the value grammar), **§6** (`load`, once-per-file),
**§9** apart from the two below, **§11** (forms), and **§8.5 chain typing** —
`(is p.f.nosuch a)` is already `3:25: `v` has no arrow `nosuch``. §9.4's "each
exactly once" for `use` and `initial` was already enforced, and §9.2's "each
entity belongs to exactly one type" falls out of gap 1.

### Two more silent winners in §9 — also fixed

Found by the sweep and initially deferred, on the grounds that both needed a
decision about §7's namespace. On review that was the wrong call: the §7
question is real but **neither fix depends on it**. §9.1 says "NAME fresh", and
whatever namespace freshness is measured in, a second instance of the same name
is not fresh in it — exactly the reasoning already applied to §10.1's transition
names, which §7 also does not list. So both are closed the same way, in the
narrower namespace, leaving §7's scope open as a spec question rather than a
blocked fix:

```
3:11: instance `i` is already declared — §9.1 requires an instance name to be fresh
2:41: `p.f` is already given a value — §8.3 gives each entity's arrow one answer
```

The cell check is applied one value at a time rather than against the finished
list, so a repeat inside a **single** clause — `(f (p a) (p b))` — is caught as
well as one across two, at `2:37`. Both have controls beside them pinning the
legitimate shapes they resemble: several cells in one clause, and several
instances with distinct names.

What remains genuinely open is only the **question**, recorded here for the
spec: §7 lists types, entities, forms and equations, while §8.1 cites §7 for
schema names and §9.1 and §10.1 cite nothing. Either §7's list is incomplete or
instances and transitions have namespaces of their own — and the answer decides
whether an instance may be named after a type. Nothing in the implementation now
waits on it.

The original deferral is left below, because the reasoning is worth keeping
visible: it is a good example of a defensible-sounding block that dissolved on a
second look.

**a. §9.1 "NAME fresh" — two instances may share a name.**

```lisp
(schema m (type v (a b)) (type box (arrow f (to v))))
(instance i (of m) (box p) (f (p a)))
(instance i (of m) (box q) (f (q b)))
(use m) (initial i)
(transition t (when (is p.f a)) (do (set p.f b)))
```

```
states: 2   edges: 1        exit=0
```

`(initial i)` resolves through `List.find_opt`, so the first declaration wins and
the second — a different roster and a different valuation — is discarded. The
decision this needs: §7's namespace lists types, entities, forms and equations,
and **instances are not among them**, while §9.1 says "NAME fresh" without
citing §7. So either §7's list is incomplete or instance names have a namespace
of their own, and the answer determines whether an instance may be named after a
type. §8.1's schema names were fixable above precisely because §8.1 *does* cite
§7 and settles the question; §9.1 does not.

**b. §8.3 "each entity's arrow has one answer" — a cell may be valued twice.**

```lisp
(schema m (type v (a b)) (type box (arrow f (to v))))
(instance i (of m) (box p) (f (p a)) (f (p b))) (use m) (initial i)
```

```
states: 1   edges: 0        exit=0
```

`State.build_ctx`'s `val_of` scans the valuation and returns the first match, so
`p.f` is `a` and the `b` is silently dropped. §9.3's constraints do not spell
"at most once per cell" out as a bullet — the requirement is §8.3's "Each
entity's arrow has **one** answer" — so the fix has to decide which section it
is enforcing and where the rule is documented, and it belongs with (a) rather
than bolted onto this run.

---

## 7. A binder may shadow a global name

**Status:** **fixed** 2026-07-26. Found while resolving open question 1 of
`docs/law-as-guard.md`.

**A correction to this entry's first version, which overstated it.** It was
filed as a soundness hole in the rules engine, on the reading that
`core/data/rules.ml:69-71` justifies `lower` with a premise — "an ALL-CAPS
binder name is rejected at read time" — that nothing enforces. That was
wrong. It *is* enforced, in `core/syntax/rules_guard.ml:101-110`, which
rejects an ALL-CAPS binder with the exact reasoning the comment cites. Every
`Rules.gexp` reaching `lower` comes from that decoder, so the premise holds
and the rules engine is sound. The mistake was checking `Grammar.binder_of`,
the kernel's binder, and concluding about the extension's.

What survived the correction is a smaller, real gap, in the kernel rather
than the extension.

### What the spec requires

§7, *Names*: "There is no shadowing."

### What actually happened

`Grammar.binder_of` destructured `(VAR TYPE)` and checked nothing, so a
binder could take a name already held by an entity, type, equation or
schema. `Eval.eval_path` resolves a chain root through the binding
environment **before** the roster, so the binder silently hid the entity and
the model built:

```lisp
(schema m (type v (a b)) (type box (arrow f (to v))))
(instance i (of m) (box lo) (f (lo a)))
(transition t (when (some (lo box) (is lo.f a))) (do (set lo.f b)))
(use m) (initial i)
```

```
states: 2   edges: 1        exit=0
```

Note the three distinct `lo`s: an entity, an enumerated value, and a binder.
This is the same invisible winner-picking gap 1 closed for declarations,
arriving through the one door that gap left open — §7's namespace lists
types, entities, forms and equations, and a binder is none of those.

### How it was fixed

`Names.binders` collects every `(some (X T) …)` binder off the raw datums,
keeping a position on each; `Names.check` tests them against the declared
set once it is complete, so the collision is caught wherever the two sit.

```
3:28: binder `lo` shadows an entity of the same name — §7 gives types,
      entities, forms and equations one namespace, and there is no shadowing
```

**A binder is never added to the declared set.** It holds its name for the
length of a guard body, not the universe, so two transitions may each bind
`b`. Disjointness against global names, not uniqueness among binders —
forcing `b1`, `b2`, `b3` through every model would be a cure worse than the
disease. That control has its own test.

### What is deliberately not covered

- **ALL-CAPS binders in a model** are still accepted. In a `.rules` file the
  spelling would also read as a rule variable, which is why
  `Rules_guard.binder` rejects it; in a model it is merely unconventional,
  and rejecting it would be a style rule wearing a conformance badge.
- **`where` binders in a `.claims` file.** `Names.check` runs from
  `Parser.collect_decls`; claims are parsed by `Claims_parser`, which has its
  own unchecked `binder_of`. Same gap, different door, not yet closed.
- **Enumerated values** are not in the namespace checked against, because a
  value cannot be a chain root and so cannot today be shadowed by a binder.
  That changes if `docs/law-as-guard.md`'s widening lands, which is where
  that half belongs.
