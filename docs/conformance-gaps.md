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
