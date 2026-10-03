# What makes a domain tractable by Writ

The test for whether Writ can hold a new domain.
[Kernel spec §2](kernel-spec.md#2-language-design) says why the language refuses what it
does; [Appendix G](kernel-spec.md#appendix-g--problems-tractable-with-writ)
lists domains that fit.

> The domain does not need to be finite. It needs to be **finitely quotientable
> by the questions you are asking of it.**

---

## 1. What a model denotes

A **schema** is a finitely presented category. Its objects — entity types
and enumerated types — have finite carriers that are **constant across all
states**. An instance is a functor to Set whose object part is fixed; of the
arrows, those marked `fixed` are **wiring** and the rest are **cells**, one per
individual of the source. A state fills every cell, so

```
    S  =  ∏  ( T_c  +  [vacatable_c] )
        cells
```

with `+1` exactly when the arrow is `vacatable`: the schema *is* the state
space. A **transition** is a partial endomorphism of S, defined on its guard
`G_t ⊆ S`; the machine is `R*(s₀)` with `R = ⋃_t graph(t|G_t)`, and questions
are CTL over that finite Kripke structure.

---

## 2. Condition I — fixed identity

The domain needs a **fixed, known cast**. Who reports to whom may vary (a
cell, plus ⊥ if the post may be empty); a new department being founded cannot
be represented. Naming the maximum cast and leaving some vacant is exact when
there is a ceiling ("up to five signatories"), wrong when there is not. It is
about identity, not size: a thousand named individuals are fine.

---

## 3. Condition II — finite-index congruence relative to the questions

A condition on the pair (domain, questions). For a fact `f` with range `V_f`,
possibly infinite, let `Φ_f` be the predicates the guards, laws and claims
apply to it:

```
    v ~ v'    iff    φ(v) = φ(v')   for every φ ∈ Φ_f
```

Writ holds the domain faithfully exactly when `~` has **finite index** on
every fact's range. Carrying the region `V_f / ~` instead of the value is
then a **quotient, not an over-approximation** — no rule could tell values in
one class apart. [mgtt2writ](https://github.com/mgt-tool/mgtt2writ) does this:
`connection_count : ℤ` becomes `(below-500 at-or-above-500)`.

### Where it breaks

`Φ` must factor through a **product of per-fact finite quotients**:

- `x < 500` factors — one fact against a constant, at any range size.
- `x < 500 ∧ y > 3` factors — a 2 × 2 quotient.
- `x + y < 500` **does not** — fixing x's region leaves y's threshold open.
- `x < y` does not, for the same reason.

> **Predicates that couple two varying quantities are what Writ cannot hold.**
> A single quantity compared against fixed constants is always fine, however
> large or continuous its range.

`CHECK (start < end)` and "spend must not exceed budget" are couplings. The
escape is to make the comparison a fact — an `over-budget : (yes no)` cell —
honest only if some move really establishes it.

---

## 4. Condition III — no computed content in updates

An update writes a **named value**, not a function of the current one:

```
    (set store.band large)          ✓   names a member
    (set store.count (+ count 1))   ✗   computes one
```

This is independent of II. A counter with no ceiling is outside the tool;
one with a ceiling is an enumerated type.

---

## 5. Condition IV — termination is grammatical

No recursion, iteration or unbounded chains, so every model terminates and a
negative answer is a census. A bounded search over a Turing-complete language
cannot tell *no counterexample* from *none found*: **Alloy and TLC take the
bound from the user; Writ takes it from the schema.**

---

## 6. Two size regimes

The `situations < 2 × designs` bound holds only in the first of two regimes.

**Committing.** Every move strictly increases a measure (typically the filled
cells), so reachable states are prefixes of complete assignments. With `aᵢ`
candidates surviving at step i:

```
    situations = Σ    ∏  aᵢ            designs = ∏ aᵢ
                k≤n  i≤k                        i≤n
```

With two or more candidates per step the earlier terms cannot double the
last, so **tightening a constraint shrinks the search**. Design and
configuration problems live here.

**Reversible.** Moves can be undone, so you pay the sub-product `∏_c |T_c|`.
Puzzles, protocols and failure models live here.

`writ check` prints which, under the size line:

```
regime: committing — no move can be undone
```

or

```
regime: reversible — 36 of 36 situations lie on cycles
```

It is measured from the phase partition `writ graph` draws; a small count means a
mostly one-way model around a reversible core. In the reversible regime every
mutable cell multiplies the space, and the lever is `fixed`.

---

## 7. The checklist

A domain fits Writ when all four hold:

1. **Fixed cast.** The things that exist are named in advance and do not come or
   go. Relationships between them may vary freely.
2. **Thresholds, not comparisons.** Every quantity enters the rules only through
   comparisons against fixed constants — never against another varying quantity.
3. **Settling, not computing.** What a move does is set a slot to a named value.
4. **An answer set you would read.** A model is too big exactly when its answer
   set is too big to have wanted — a fact about the question, not the tool.
