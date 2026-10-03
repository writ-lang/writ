# What makes a domain tractable by Writ

Written to answer one question the rest of the documentation answers only by
example: **given a domain, how do you tell in advance whether Writ can hold
it?** The [README](../README.md#language-design) says why the language refuses
what it refuses; [Appendix G](kernel-spec.md#appendix-g--problems-tractable-with-writ)
lists domains that fit; this page is the test to apply to a new one.

The short version, stated first because it is the sentence worth remembering:

> The domain does not need to be finite. It needs to be **finitely quotientable
> by the questions you are asking of it.**

Everything below is that claim made precise.

---

## 1. What a model denotes

A **schema** is a finitely presented category: finitely many objects, finitely
many generating arrows, finitely many path equations. Objects come in two kinds —
entity types with named individuals, and enumerated types with named members.
Both carriers are finite, and both are **constant across all states**. That
constancy is the load-bearing restriction; almost everything else follows from
it.

An instance, in the usual sense, is a functor from the schema to Set. Writ fixes
the object part of that functor and lets only the arrow part vary — and splits
the arrows further:

- arrows marked `fixed` are **wiring**: assigned once, effectively part of the
  presentation;
- the rest are **cells**.

An arrow `a : A → B` with `|A| = n` is n independent cells, one per individual of
A. A state is one filling of every cell at once, so

```
    S  =  ∏  ( T_c  +  [vacatable_c] )
        cells
```

where `T_c` is the target carrier and the `+1` appears exactly when the arrow is
`vacatable`. A state is a section of that bundle.

This is what "the state machine is generated, not written" means formally: the
schema *is* the state space, presented rather than enumerated. The `fixed`
marking is the only thing standing between a model and a much larger product,
which is why it earns a keyword.

A **transition** is a partial endomorphism of S: a guard `G_t ⊆ S` — its domain
of definition, not a side condition — together with an update defined on `G_t`.
The machine is the closure `R*(s₀)` where `R = ⋃_t graph(t|G_t)`. Questions are
CTL over the resulting finite Kripke structure, and a Datalog reading over the
same universe via `derive`.

None of this is exotic. All the interesting content is in *where the finiteness
comes from*, which is the next three sections.

---

## 2. Condition I — fixed identity

Object carriers are constant across states. So the domain must have a **fixed,
known cast**: no creation, no destruction, no varying population.

The distinction people get wrong here is between topology and vertices:

- **Dynamic topology is fine.** "Who reports to whom" can vary freely — that is a
  cell valued in the candidate targets, plus ⊥ if the post may be empty.
- **Dynamic vertices are not.** "A new department is founded" has no
  representation, because the carrier of `department` is part of the
  presentation.

The standard workaround is to name the maximum cast up front and mark the unused
ones vacant — n slots, some empty, rather than a varying n. This is exact rather
than approximate whenever the domain really does have a ceiling, and it is a
misrepresentation whenever it does not. "Up to five signatories" models fine.
"Arbitrarily many claimants" does not.

Note this is a condition about **identity**, not about size. A thousand named
individuals is fine. Three unnamed ones that come and go is not.

---

## 3. Condition II — finite-index congruence relative to the questions

This is the real answer, and the thing that is hard to state because it is not a
condition on the domain at all. It is a condition on the **pair** (domain,
question set).

Fix a fact `f` with value range `V_f` — possibly infinite. Let `Φ_f` be the set
of predicates that the guards, the laws and the claims actually apply to `f`.
Define

```
    v ~ v'    iff    φ(v) = φ(v')   for every φ ∈ Φ_f
```

Writ can hold the domain faithfully exactly when `~` has **finite index** on
every fact's range.

When it does, the quotient `V_f / ~` is a finite set of named regions, and
carrying the region instead of the value loses nothing: two values in one class
were already indistinguishable to every rule in the model. The abstraction is a
**quotient, not a conservative over-approximation** — which is why no soundness
caveat is needed anywhere, and why "counting becomes naming, calculating becomes
writing down" is a theorem rather than a modelling trick.

[mgtt2writ](https://github.com/mgt-tool/mgtt2writ) is this theorem instantiated. mgtt's expression language has six
comparison operators and no arithmetic, so the constants a model mentions cut
each fact's range into finitely many intervals on which every predicate is
constant. `connection_count : ℤ` becomes `(below-500 at-or-above-500)`. Two
members, not two billion, and nothing is lost because nothing could ever have
observed the difference.

### Where it breaks, precisely

The condition needs `Φ` to factor through a **product of per-fact finite
quotients**. That is stronger than each fact individually having a finite
quotient, and it is where the boundary actually lies.

- `x < 500` factors. One fact, constants. Fine at any range size.
- `x < 500 ∧ y > 3` factors. Two facts, each against constants, so the pair
  quotient is 2 × 2.
- `x + y < 500` **does not factor.** No finite partition of x's range crossed
  with any finite partition of y's range generates that predicate: fixing x's
  region leaves y's threshold undetermined.
- `x < y` likewise does not factor, for the same reason.

So the failure mode is not "arithmetic" loosely construed. It is sharper and
more useful to state:

> **Predicates that couple two varying quantities are what Writ cannot hold.**
> A single quantity compared against fixed constants is always fine, however
> large or continuous its range.

That reframing matters because "no numbers" reads as a much heavier restriction
than it is. A model full of prices, timestamps and capacities is perfectly
representable, provided the rules only ever ask which side of a threshold each
one falls on. It stops being representable the moment a rule asks how one
compares with another.

The `x < y` case is worth calling out on its own, since it is the common one and
it looks innocuous. `CHECK (start < end)`, "the junior must not outrank the
senior", "spend must not exceed budget" — all three are couplings, and all three
fall outside. The escape, when there is one, is to make the comparison itself a
fact: carry `over-budget : (yes no)` as a cell that transitions maintain, rather
than deriving it. That is honest if some move actually establishes it, and a lie
if you are just hiding the arithmetic.

---

## 4. Condition III — no computed content in updates

An update writes a **named value**, not a function of the current one. So the
dynamics must be a finite set of rewrite rules over the named vocabulary:

```
    (set store.band large)          ✓   names a member
    (set store.count (+ count 1))   ✗   computes one
```

This is a separate condition from II and does not follow from it. A domain could
pass the finite-quotient test on its predicates and still want updates that
compute — an increment, an accumulation — and those have no representation even
when every *guard* in the model is threshold-based. Counters are the usual case,
and the usual honest answer is that a counter with no ceiling is outside the
tool, while a counter with a ceiling is just an enumerated type spelled
awkwardly.

---

## 5. Condition IV — termination is grammatical

No recursion, no iteration, no unbounded chains; every list finite. So
termination is a property of the grammar rather than something an individual
model can lose.

This is what buys the negative answer, and the argument is worth keeping
explicit. By Rice's theorem, every non-trivial semantic question about a
Turing-complete language is undecidable. That leaves a tool over such a language
two options: demand the author supply a proof, or search and report what it
found. The second cannot distinguish *no counterexample exists* from *none found
within the bound*. So `never` from a bounded search is not a census, and a claim
like "one lawful move destroys accountability forever" is worth nothing from a
tool that might merely have looked less far.

The comparison worth drawing, and worth putting in the README: **Alloy and TLC
take the bound from the user; Writ takes it from the schema.** In a bounded
model checker "no counterexample" is always relative to a scope someone chose,
so the negative answer is permanently hedged. Here the bound is a consequence of
the presentation, which is why `never` means what it says. That is Writ's actual
distinguishing claim, and it is currently buried.

---

## 6. Two size regimes

The `situations < 2 × designs` bound is real but conditional, and the condition
deserves a name because half of the worked models fall on each side.

**Committing regime.** The transition relation is acyclic: every move strictly
increases a measure — typically the number of filled cells — and nothing is ever
unset. Then every reachable state is a prefix of some complete assignment, and
with `aᵢ` candidates surviving the guards at step i:

```
    situations = Σ    ∏  aᵢ            designs = ∏ aᵢ
                k≤n  i≤k                        i≤n
```

The sum's last term is the design count and each earlier term is the next
divided by a step's candidate count, so where every step admits two or more, all
earlier terms together cannot double the last. Hence the bound, and hence the
inversion: **tightening a constraint makes the search smaller**, and a rejected
candidate costs one transition and no situations at all. Design, synthesis and
configuration problems live here.

**Reversible regime.** Moves can be undone, so the reachable set is a full
sub-product and you pay `∏_c |T_c|`. The river is this — the farmer can row back,
so no move settles anything, and 36 is simply what the product costs. Puzzles,
protocols, and failure-propagation models live here.

The tool says which you are in. `writ check` prints, under the size line,

```
regime: committing — no move can be undone
```

or

```
regime: reversible — 36 of 36 situations lie on cycles
```

measured from the space rather than read off the syntax: a model is committing
exactly when no situation can return to itself, which is the same partition
into phases that `writ graph` draws and `ct.rules` names. The count is how much
of the space the product reaches; a model whose moves are mostly one-way around
a small reversible core reports a small count against a large space, which is
the mixed case and the common one.

The practical reading: in the committing regime adding vocabulary is free and
tightening a constraint shrinks the search; in the reversible regime every
mutable cell multiplies the space, and the only lever is `fixed`.

---

## 7. The checklist

A domain fits Writ when all four hold:

1. **Fixed cast.** The things that exist are named in advance and do not come or
   go. Relationships between them may vary freely.
2. **Thresholds, not comparisons.** Every quantity enters the rules only through
   comparisons against fixed constants — never against another varying quantity.
3. **Settling, not computing.** What a move does is set a slot to a named value.
4. **An answer set you would read.** The model is too big precisely when its
   answer set is too big to have wanted; that is a fact about the question, not
   about the tool.

And the framing to put above the list:

> Writ does not require a finite world. It requires that your questions see only
> finitely much of it. A domain with continuous quantities is fine as long as
> every rule asks only which side of a threshold something falls on. The moment
> a rule asks *how much*, or compares one varying quantity with another, you have
> left.
