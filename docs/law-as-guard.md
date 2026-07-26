# A law should hold a guard — a design note

*Status: proposal, nothing implemented. Blocked on the relational
extension settling (see "Sequencing"). Supersedes the "unify `is` and
`=`" sketch, which was wrong for the reason in "The correction" below.
Open question 1 is resolved and half-implemented; 2–4 remain.*

**The change in one line:** `equation` takes a **guard** instead of only
`(= CHAIN CHAIN)`, and `=` leaves the kernel for the standard library.

**28 → 27 kernel words, and no model has to be rewritten.**

## Why bother, when the rules engine exists

The relational extension already derives difference. Verified:

```lisp
(relation conflict (case))
(rule (conflict C) (is C.approver P) (is C.preparer P))
```

```
conflict  (1 row)
  c2
```

A shared variable across two `is` literals is equality; `--why` returns
the derivation tree naming the person who holds both roles; and with
`(holds S …)` the same rule works per-situation over mutable arrows. So
"which cases violate separation of duty **now**" is answered today, and
Appendix G's [:1469](kernel-spec.md#L1469) and
[:1480](kernel-spec.md#L1480) are honest.

What rules cannot reach is everything §15 gives a **declared law**:

> **laws** — for every (move, equation) pair, whether the move *can*
> break the law (guard-and-effect analysis); and every reachable
> situation violating an equation, with a minimal route.

plus §16.3's `accept` ledger of owned breakage. Rules observe the world;
they are not laws, so no move is analysed against them and none can be
acknowledged. That leaves Appendix G [:1450](kernel-spec.md#L1450) still
overclaiming:

> Which powers can violate the separation law, and **is every one
> acknowledged**?

Separation of duty cannot be a law today, so that question has no
answer — and it is a Pivotal-idea-2 question, the kind Pol exists for.
Same for [:1486](kernel-spec.md#L1486) and the lockout law.

So the case for this change is not only that the kernel gets smaller. It
is that **the smaller kernel says more.**

## The correction

An earlier sketch proposed merging `is` and `=` on the grounds that they
are one operation arbitrarily split. That was wrong. They disagree about
undefinedness, in opposite directions:

| | on an undefined side |
| --- | --- |
| `=` (§8.6) | *Kleene* — "the law does not apply there", vacuously satisfied |
| `is` (§10.2) | *strict* — "the chain **has an answer** and it equals V", so false |

Merging them would silently change the meaning of every existing law or
guard. Two equalities really do exist. The move is not to merge them but
to notice that **only one of them needs to be in the kernel**.

## The proposal

1. **Widen `is`** so its right-hand side may be a chain, not only a
   literal. A generalization, not a new word.
2. **`equation` takes a guard.** Its body becomes the guard language of
   §10.2 rather than the single form `(= CHAIN CHAIN)`.
3. **`=` becomes a stdlib form** supplying Kleene equality:

   ```lisp
   (form (= A B) => (not (and (defined A) (defined B) (not (is A B)))))
   ```

   Undefined either side → the `and` is false → the law holds vacuously,
   exactly as §8.6 specifies. Both defined and unequal → false. This is
   the Kleene truth table, spelled in strict primitives.

   *Derived by cases, not tested: it needs the widening in (1), since
   `(is A B)` with a chain on the right does not parse today. The three
   rows above are the check to write first.*

4. **Keep the implicit quantification.** §8.6 already says chains in an
   equation are written from the *type*: `case.investigator.independence`
   means "for every case". That stays, generalized from "both chains" to
   "every type-rooted chain in the guard", which must share one root
   type — the same *common start type* constraint §8.6 already imposes,
   just stated over a guard instead of a pair.

### What it costs: nothing, textually

Because `=` survives as a form and the quantification stays implicit,
**existing laws are unchanged, character for character**:

```lisp
(equation same-agency
  (= case.investigator.independence case.prosecutor.independence))
```

That is the current spec's §4 text and also the post-change text. No
migration, no corpus rewrite, no spec examples to re-cut.

### What it buys

Laws can now say things they could not:

```lisp
(equation separation-of-duty
  (differ case.approver case.preparer))
```

One line — and because it is a *law*, §15 reports which moves can break
it and §16.3 lets each be `accept`ed. Appendix G [:1450](kernel-spec.md#L1450)
becomes answerable. Disjunction and `some` come along for free, since the
body is now the whole guard language.

## An earlier version of this proposal, and why it lost

The first draft also removed the implicit quantification, requiring
`(all (c case) (= c.investigator… c.prosecutor…))`. It removes one more
special rule, which is tempting.

It loses on two counts. It makes every law longer for no gain in
meaning, and it forces a rewrite of every equation in every model,
fixture, example, and the spec's own §4 and Appendices C–D. Trading a
corpus-wide migration and permanently longer laws for the deletion of one
well-motivated convention is a bad trade. The convention is what makes a
law read like a law.

## The sugar, and the ceiling on it

Two facts about the expander bound what sugar is possible. Both verified:

- **Whole-chain slots work.** `(form (differ A B) => (not (is A B)))`
  invoked as `(differ b.f hi)` expands correctly and builds.
- **Segment splicing does not.** In a template, `X.A` substitutes **only
  its root**; the expander says so in as many words — *"A dot-path:
  substitute only its ROOT segment, keeping the rest."* So
  `(form (agree T P Q) => (all (it T) (= it.P it.Q)))` cannot work: `P`
  stays the literal atom `A`, and you get `box has no arrow A`.

That rules out the most compact sugar one might reach for — naming a type
and two arrow-*suffixes* — and leaves whole chains as the unit. Which is
fine, because with the implicit quantification kept, no wrapper sugar is
needed at all. **The best sugar here is not needing any.**

What the standard library should carry:

```lisp
; Kleene equality — the kernel's `=` before it moved here. Vacuously
; satisfied where either side has no answer (§8.6), which is what makes
; an unstaffed office break no seconding rule.
(form (= A B) => (not (and (defined A) (defined B) (not (is A B)))))

; Strict difference. NOTE the asymmetry with `=` above: `is` is strict,
; so an undefined side makes `differ` TRUE — a vacant approver differs
; from every preparer. For "both filled, and different", conjoin the
; `defined`s yourself; the kernel will not guess which you meant.
(form (differ A B) => (not (is A B)))
```

The comment on `differ` is the important half. Strict difference and
Kleene equality are not duals, and a library that hides that distinction
would be doing the same thing this note is undoing.

## Open questions to settle before implementing

1. **Bare variables on the right of `is`.** With a chain allowed there,
   what does `(is a.f x)` mean when `x` is a `some`-binder? **Resolved —
   see "Open question 1, resolved" below.**
2. **The common-root-type rule.** §8.6 constrains two chains to share a
   start type. Over an arbitrary guard this becomes "every type-rooted
   chain shares one root type" — worth stating explicitly as a static
   error, with the position of the offending chain.
3. **§15's breakage analysis gets harder.** "Can this move break the law"
   is currently a guard-and-effect analysis over two chains. Over
   arbitrary guards it either becomes conservative or becomes enumeration
   over the reachable space. Finiteness means it stays decidable either
   way (§12.4), but it is real work, not a rename.
4. **`=` must leave `Forms.reserved`**, which currently lists it, or the
   stdlib form cannot be declared.

## Open question 1, resolved: give binders a namespace

The ambiguity in `(is a.f x)` exists for one reason — **a binder name may
currently be anything at all.** `Grammar.binder_of` destructures
`(VAR TYPE)` and checks nothing, so all three of these `lo`s coexist and
the model builds:

```lisp
(schema s (type flag (lo hi)) (type box (arrow f (to flag))))
(instance i (of s) (box lo) (f (lo hi)))       ; entity lo, value lo
(transition t (when (some (lo box) (is lo.f hi))) (do (set lo.f lo)))
```

Remove the collision and the ambiguity goes with it. Two rules:

**(a) A binder name must be disjoint from every name readable in its
place** — §7's global names (types, entities, forms, equations) and
enumerated values anywhere in the loaded universe.

This is **disjointness, not global uniqueness**. `(some (b bureau) …)` in
two different transitions stays legal, because binders are scoped;
forcing `b1`, `b2`, `b3` through every model would be a cure worse than
the disease. Rebinding a name inside an enclosing binder's scope stays an
error — that is shadowing, which §7 already forbids.

**(b) A binder name may not be ALL-CAPS**, matching extension §1's
notation, so kernel binders and rule variables can never share a
spelling. Independent of (a), since a rule variable is not a global name.

With (a) in force, `(is a.f x)` has exactly one reading: if `x` is a
binder in scope it is the binder, otherwise it is a literal. It cannot be
both, because (a) forbids the collision.

**Why this beats the alternatives.** No sigil, no ALL-CAPS convention
leaking from the extension into the kernel, no shadowing rule, and no new
keyword. It is less a new rule than the completion of one the spec
already claims: §7 says "There is no shadowing", which is today vacuous
for binders, the one thing in the language that binds a name locally.

**Cost.** A model with a binder named after a value gets a new static
error and renames the binder. Conventional style — single letters for
binders, words for values — makes that rare, and the error names the
binder and the thing it collides with. The same shape as the §7
enforcement in gap 1 above, whose measured fallout was zero.

**One sub-decision left:** whether (a) checks against *all* enumerated
values universe-wide, or only those in the target type of the chain being
compared. Universe-wide is simpler to state and implement; type-directed
is more permissive but needs the type known at check time. Take
universe-wide unless it proves too strict.

**(b) is already in force where it matters.** `Rules_guard.binder` rejects
an ALL-CAPS binder in a `.rules` file, which is what makes
`core/data/rules.ml:69-71`'s substitution safe — every `Rules.gexp` reaching
`lower` comes from that decoder. In a *model* the spelling is accepted and
harmless, since model guards never pass through `lower`. So (b) needs no
work; an earlier draft of this note claimed otherwise and was wrong.

**(a) is done**, ahead of the rest of this note, because it closed a live
§7 violation on its own: a binder could shadow an entity, and `Eval` resolves
a chain root through the environment before the roster, so the binder won
silently. `Names.binders` now rejects it. Recorded as gap 7 in
`docs/conformance-gaps.md`. What remains for this proposal is only the
*enumerated values* half — a value cannot be a chain root, so it can be
shadowed only once a chain may appear on the right of `is`.

## Sequencing

0. ~~Reject ALL-CAPS binder names~~ — **not needed**; already enforced
   where it matters, in `Rules_guard.binder`. Rule (a)'s global-name half is
   **done** (gap 7); only its enumerated-values half waits on step 2.
1. **Wait for the relational extension to settle.** This changes
   `Model.Is`, which `core/data/rules.ml` lowers into, and that module is
   under active construction.
2. Widen `is`, and extend rule (a) to enumerated values in the same commit —
   the widening is what makes a value shadowable, so they belong together.
   Existing models are otherwise unaffected, because nothing yet puts a chain
   on the right.
3. Move `=` to stdlib and let `equation` take a guard, in **one** commit
   with the spec — §8.6, Appendix A's grammar, and Appendix B's keyword
   count all move together, and a kernel that disagrees with its own
   spec about how many words it has is worse than one word heavier.
4. Only then update Appendix G [:1450](kernel-spec.md#L1450) from an
   overclaim into an example.
