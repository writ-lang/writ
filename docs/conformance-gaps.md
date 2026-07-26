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
