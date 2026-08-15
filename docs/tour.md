# A tour of Writ

Ten steps. Each one is a complete model you can run, each adds a few words,
and the output shown is the output you get. At the end: [the whole language
on one page](#cheat-sheet).

This is the on-ramp. [`kernel-spec.md`](kernel-spec.md) is the reference —
precise, normative, and not meant to be read front to back first.

You need `writ` on your `PATH` (`make install-writ`). Put each file in an empty
directory and run the command under it.

Every block carries **line numbers, restarting at 1 in each block**, so a line
can be named — "step 7, line 12". They are not part of the source; strip the
leading number and two spaces before running.

---

## 1. A thing exists

```lisp
 1  ;; library.writ
 2  (schema library
 3    (type book))
 4
 5  (instance shelf library
 6    (book hamlet))
 7
 8  (use library)
 9  (initial shelf)
```

```console
 1  $ writ check library.writ
 2  states: 1   edges: 0
 3  gaps: none
 4  dead ends: 1
 5    reached by: (initial)
```

**Five words — 5 of 26.**

- `schema` — declares a map: what kinds of things exist, and how they point.
- `type` — one kind of thing. `book` is now a kind.
- `instance` — one concrete filling of that map.
- `use` — which schema the model runs on.
- `initial` — which filling it starts from.

`(book hamlet)` is a **clause**: it declares `hamlet` as a member of type
`book`. The head is the type's own name, not a keyword — which is why clauses
cost no vocabulary. An instance is a list of them, and there is only ever this
one shape.

One situation, because nothing can vary; no moves, so it is a dead end.
**`writ` reports the size of a model before you ask it anything.**

## 2. A thing with a state

```lisp
 1  (schema library
 2    (type shelf-state (available lent))
 3    (type book
 4      (arrow status (to shelf-state))))
 5
 6  (instance shelf library
 7    (book hamlet (status available)))
 8
 9  (use library)
10  (initial shelf)
```

```console
 1  $ writ check library.writ
 2  states: 1   edges: 0
 3  gaps: none
 4  dead ends: 1
 5    reached by: (initial)
```

**Two more — 7 of 26.**

- `arrow` — how one kind of thing points at another. Every `book` has a
  `status`.
- `to` — where the arrow lands: a member of `shelf-state`.

The clause grew a **slot**: `(book hamlet (status available))` reads as one
sentence — a book, hamlet, whose status is available. Declaring the entity and
filling its slots is one act, in one place.

A **slot** is one entity plus one arrow — the cell where that entity's answer
lives. The schema names the arrows, the instance names the entities, and every
pairing of the two is a slot:

```
           status
          ┌───────────┐
   hamlet │ available │
          └───────────┘
```

Columns are arrows, rows are entities, cells are slots. Nothing declares a slot
directly; you get exactly the ones the schema and the instance imply. Add a
second book and there are two, add a second arrow and there are four.

Two arrangements now exist **on paper** — available and lent — but still only
one *state*. A state is one the model can reach, and nothing yet moves.

## 3. A move, and a move back

```lisp
 1  ;; added after (initial shelf)
 2  (transition lend
 3    (when (is hamlet.status available))
 4    (do  (set hamlet.status lent)))```

```console
 1  $ writ check library.writ
 2  states: 2   edges: 1
 3  gaps: none
 4  dead ends: 1
 5    reached by: lend
```

**Five more — 12 of 26.**

- `transition` — a move: a condition and a change.
- `when` — the condition, called a **guard**.
- `do` — the change, one or more **effects**.
- `is` — a guard: tests a chain against a value.
- `set` — an effect: writes one.

You never write a state or an edge. `lend` is a *rule* for edges — it
contributes one from every state where its guard is true. Here that is one
state, so one edge. The book is now stuck out on loan, hence the dead end. Add
the way back:

Note what a transition is written over: **entities, not types.** `hamlet` is
named outright, and it resolves because `(initial shelf)` chose the instance it
belongs to — a model has exactly one, so nothing has to say which. There is no
way to write "any book": a `some`-bound variable is legal in a guard but not in
an effect. That is deliberate — one datum stays one rule for edges — and it is
why step 6 needs forms.

```lisp
 1  (transition return
 2    (when (is hamlet.status lent))
 3    (do  (set hamlet.status available)))```

```console
 1  $ writ check library.writ
 2  states: 2   edges: 2
 3  gaps: none
 4  dead ends: none
```

## 4. Asking a question

Questions live in a separate file, so the same questions can be put to many
models.

```lisp
 1  ;; library.claims
 2  (property lendable "the book can go out on loan"
 3    (possible (is hamlet.status lent)))
 4
 5  (property always-lendable "from every reachable state, a loan is still possible"
 6    (live (is hamlet.status lent)))
```

```console
 1  $ writ check library.writ --claims library.claims
 2  states: 2   edges: 2
 3  gaps: none
 4  dead ends: none
 5  holds  lendable
 6    witness:  1. lend
 7  holds  always-lendable
```

**No new language words — still 12 of 26.** `property`, `possible` and `live`
belong to the claims file, not to the language. A model cannot see them, which
is why one set of questions can be put to many models.

- `property` — a named question, with an optional doc string.
- `(possible F)` — some reachable state satisfies F.
- `(never F)` — no reachable state does.
- `(live F)` — from *every* reachable state, an F-state is still reachable.

The difference between the three is the point of the tool. A holding
`possible` prints its route — `1. lend` — because the shortest way to get there
*is* the answer. `live` is the one that finds traps; it has nothing to report
yet, and will in step 10.

**What each modality wraps is a guard — the language's, not the claims file's.**
`(is hamlet.status lent)` here is the same construct as the `when` in step 3,
and it means the same thing. A guard has three homes: the `when` of a
transition, the body of an `equation` (step 7), and the inside of a modality.
That is why a claims file can say `and`, `not`, `defined` or `some` without
those being claims words — a claims file is a thin vocabulary wrapped around
ordinary guards.

## 5. Nothing, as itself

A book on loan is held by someone. A book on the shelf is held by **nobody** —
and nobody is not a person.

```lisp
 1  (schema library
 2    (type shelf-state (available lent))
 3    (type person)
 4    (type book
 5      (arrow status (to shelf-state))
 6      (arrow holder (to person) vacatable)))
 7
 8  (instance shelf library
 9    (book   hamlet (status available) (holder vacant))
10    (person ana ben))
11
12  (use library)
13  (initial shelf)
14
15  (transition lend-ana
16    (when (is hamlet.status available))
17    (do  (set hamlet.status lent) (set hamlet.holder ana)))
18
19  (transition lend-ben
20    (when (is hamlet.status available))
21    (do  (set hamlet.status lent) (set hamlet.holder ben)))
22
23  (transition return
24    (when (is hamlet.status lent))
25    (do  (set hamlet.status available) (vacate hamlet.holder)))
```

```lisp
 1  ;; library.claims
 2  (property no-phantom-loan "a lent book always has a holder"
 3    (never (and (is hamlet.status lent) (not (defined hamlet.holder)))))
 4
 5  (property shelved-means-nobody "an available book is held by nobody"
 6    (never (and (is hamlet.status available) (defined hamlet.holder))))
```

```console
 1  $ writ check library.writ --claims library.claims
 2  states: 3   edges: 4
 3  gaps: none
 4  dead ends: none
 5  holds  no-phantom-loan
 6  holds  shelved-means-nobody
```

**Six more — 18 of 26.**

- `vacatable` — a schema flag: this slot is allowed to be empty.
- `vacant` — an instance value: it *is* empty to begin with.
- `vacate` — an effect: empty it in a move.
- `defined` — a guard: does this chain have an answer at all?
- `and` — a guard: every operand true.
- `not` — a guard: the operand false.

The last three are **language** words, not claims words, even though the file
above is where they first appear — guards work in a `when` exactly as they work
inside a modality (step 4). `(when (not (defined hamlet.holder)))` is a legal
transition guard, and means what it says here.

`hamlet` has two slots now, and one of them holds nothing — `writ` prints an
empty slot as `∅`:

```
           status     holder
          ┌───────────┬────────┐
   hamlet │ available │ ∅      │
          └───────────┴────────┘
```

There is no `nobody` person, and that is deliberate — see
[why partial](kernel-spec.md#23-the-arrows-are-partial).

`defined` asks about the slot itself, which is not the same as testing a value.
With the slot empty, `(is hamlet.holder ana)` and `(is hamlet.holder ben)` are
*both* false. Both-false is the signature of an empty slot; `defined` is what
tells it apart from an answer you did not expect.

## 6. Your own vocabulary

`lend-ana` and `lend-ben` differ by one word, because a transition names
entities and cannot quantify over a type (step 3). Forms are how that gap is
closed — name the shape once:

```lisp
 1  (form (lend-to NAME WHO)
 2    (transition NAME
 3         (when (is hamlet.status available))
 4         (do  (set hamlet.status lent) (set hamlet.holder WHO))))
 5
 6  (lend-to lend-ana ana)
 7  (lend-to lend-ben ben)
```

```console
 1  $ writ check library.writ --claims library.claims
 2  states: 3   edges: 4
 3  gaps: none
 4  dead ends: none
 5  holds  no-phantom-loan
 6  holds  shelved-means-nobody
```

**One more — 19 of 26.**

- `form` — declares a pattern and what it expands into.
- `NAME`, `WHO` — ALL-CAPS atoms in the pattern are **blanks**, filled by
  whatever the invocation puts there. A convention, not a keyword.

Byte-identical results, because a form can only **rename and paste**: it cannot
compute, loop, or test. That is why an error inside expanded code still points
at the line you wrote, and why whole domain vocabularies are libraries rather
than compiler features.

Pass a name through, as `NAME` does here. An unnamed transition works, but then
reports have nothing to call it.

## 7. A law, and the tool breaking it

Books belong to a branch; so do members; a book should only be lent to someone
from its own branch. That is two routes through the schema that must agree —
which is what an `equation` is.

```lisp
 1  (load "stdlib.writ")
 2
 3  (schema library
 4    (type shelf-state (available lent))
 5    (type branch)
 6    (type person
 7      (arrow member-of (to branch) fixed))
 8    (type book
 9      (arrow home   (to branch) fixed)
10      (arrow status (to shelf-state))
11      (arrow holder (to person) vacatable))
12    (equation borrow-local
13      (= book.holder.member-of book.home)))
14
15  (instance shelf library
16    (branch north south)
17    (person ana (member-of north))
18    (person ben (member-of south))
19    (book   hamlet (home   north)
20                   (status available)
21                   (holder vacant)))
```

```console
 1  $ writ check library.writ
 2  states: 3   edges: 4
 3  gaps: none
 4  dead ends: none
 5  equation borrow-local
 6    can be broken by: lend-ana, lend-ben, return   (acknowledge in claims)
 7    violated in 1 reachable situations   witness: 1. lend-ben
 8  $ echo $?
 9  1
```

**Three more — 22 of 26.**

- `equation` — declares a law: an arrow-chain identity that must hold.
- `fixed` — marks an arrow as **wiring**: set once by the instance, never
  varying. `member-of` and `home` are facts about the world, not state.
- `load` — pulls in another file. Needed here because `=` is *not* a kernel
  word: it is a form from `stdlib.writ`.

An equation holds **a guard** — any guard — so `=` is a choice, not a fixture.
It is the *vacuous* comparison: true whenever either side has no answer. Write
the same law with `is`, which is strict, and the shelved book becomes a
violation of it —

```
 1  equation borrow-local
 2    violated in 1 reachable situations   witness:
```

— an empty witness, meaning zero moves: the initial situation, where `holder`
is vacant. A book held by nobody is not breaking a rule about who may hold it.
Choosing between `=` and `is` in a law is choosing what an empty slot means to
that law, and it is the same decision as step 5, one level up.

**Declaring a law does not enforce it.** The violating state stays in the model
and gets reported, with the exact move that reaches it: `lend-ben`. Exit status
is 1 — a finding. A tool that silently deleted the illegal state could not have
told you which of your own rules breaks your own law.

Note the two separate lines. *Violated in 1 situations* is a fact about what is
reachable. *Can be broken by* is a fact about what each move **writes** — a
capability, listed for every move that touches a slot the law reads, whether or
not it does break it today.

## 8. Own it, or guard it

Two honest answers. Acknowledge the breakage:

```lisp
 1  ;; library.claims
 2  (accept lend-ben borrow-local)```

```console
 1  $ writ check library.writ --claims library.claims
 2  states: 3   edges: 4
 3  gaps: none
 4  dead ends: none
 5  equation borrow-local
 6    can be broken by: lend-ana, lend-ben, return   (acknowledge in claims)
 7    violated in 1 reachable situations   witness: 1. lend-ben
 8  unadmitted  lend-ana may break borrow-local
 9  unadmitted  return may break borrow-local
```

**No new language words — still 22 of 26.**

- `accept` — claims-file vocabulary: "this move is known to be able to break
  that law." Every move that can break it and is *not* accepted is reported
  `unadmitted`. The ledger is complete, or it complains.

Or fix the rule, by tightening the guard:

```lisp
 1  (form (lend-to NAME WHO)
 2    (transition NAME
 3         (when (and (is hamlet.status available)
 4                    (is WHO.member-of hamlet.home)))
 5         (do  (set hamlet.status lent) (set hamlet.holder WHO))))```

```console
 1  $ writ check library.writ
 2  states: 2   edges: 2
 3  gaps: none
 4  dead ends: none
 5  equation borrow-local
 6    can be broken by: lend-ana, lend-ben, return   (acknowledge in claims)
 7  $ echo $?
 8  0
```

The violating state is now unreachable, so there is nothing to report — and the
model got **smaller**. A constraint that rejects candidates shrinks the search.
`can be broken by` still lists all three, because that line never was about
reachability.

## 9. Where the rules stop

Some questions the rules simply do not answer. Say so:

```lisp
 1  (transition lose
 2    (when (is hamlet.status lent))
 3    (do  (gap "the rules do not say what happens to a lost book")))```

```console
 1  $ writ check library.writ
 2  states: 2   edges: 3
 3  gaps: 1
 4    lose — "the rules do not say what happens to a lost book" (min 1 moves)
 5  dead ends: none
 6  equation borrow-local
 7    can be broken by: lend-ana, lend-ben, return   (acknowledge in claims)
```

**One more — 23 of 26.**

- `gap` — an effect: end the model here, with a message, instead of inventing
  a successor.

A gap is reported with its message and the shortest route in, and it is *not* a
dead end: a gap is a declared exit, a dead end is a silence nobody wrote down.
The tool keeps them apart so you can tell "we decided not to model this" from
"we missed this".

## 10. The trap

One more move — withdrawing a book from circulation, with no way back:

```lisp
 1  (type shelf-state (available lent withdrawn))    ; was (available lent)
 2
 3  (transition withdraw
 4    (when (is hamlet.status available))
 5    (do  (set hamlet.status withdrawn)))
```

```lisp
 1  ;; library.claims
 2  (accept lend-ana borrow-local)
 3  (accept lend-ben borrow-local)
 4  (accept return   borrow-local)
 5
 6  (property lendable "the book can go out on loan"
 7    (possible (is hamlet.status lent)))
 8
 9  (property always-lendable "from every reachable state, a loan is still possible"
10    (live (is hamlet.status lent)))
11
12  (query local-members (where (p person)) (is p.member-of north))
```

```console
 1  $ writ check library.writ --claims library.claims
 2  states: 3   edges: 4
 3  gaps: 1
 4    lose — "the rules do not say what happens to a lost book" (min 1 moves)
 5  dead ends: 1
 6    reached by: withdraw
 7  equation borrow-local
 8    can be broken by: lend-ana, lend-ben, return   (acknowledge in claims)
 9  holds  lendable
10    witness:  1. lend-ana
11  fails  always-lendable
12    stuck at: (hamlet.status=withdrawn hamlet.holder=∅)
13    witness:  1. withdraw
14  local-members  (at state 0)
15    p = ana
```

**No new language words — 23 of 26, and that is where the tour ends.**

- `query` — claims-file vocabulary: answer with the satisfying bindings rather
  than yes or no.
- `where` — binds the variables a query ranges over.

`lendable` still holds — a loan is possible. `always-lendable` **fails**, and
the gap between those two answers is the whole reason for the tool: one lawful
move puts the book somewhere no future move can lend it from again. `writ` names
the move (`withdraw`), the state it strands you in, and prints the empty slot
as `∅`.

The three words the tour never needed are `or`, `some` and `&rest`. They are in
the cheat sheet.

## The whole model

Assembled, this is what you have been building:

```lisp
 1  ;; library.writ
 2  (load "stdlib.writ")
 3
 4  (schema library
 5    (type shelf-state (available lent withdrawn))
 6    (type branch)
 7    (type person
 8      (arrow member-of (to branch) fixed))
 9    (type book
10      (arrow home   (to branch) fixed)
11      (arrow status (to shelf-state))
12      (arrow holder (to person) vacatable))
13    (equation borrow-local
14      (= book.holder.member-of book.home)))
15
16  (instance shelf library
17    (branch north south)
18    (person ana (member-of north))
19    (person ben (member-of south))
20    (book   hamlet (home   north)
21                   (status available)
22                   (holder vacant)))
23
24  (use library)
25  (initial shelf)
26
27  (form (lend-to NAME WHO)
28    (transition NAME
29         (when (and (is hamlet.status available)
30                    (is WHO.member-of hamlet.home)))
31         (do  (set hamlet.status lent) (set hamlet.holder WHO))))
32
33  (lend-to lend-ana ana)
34  (lend-to lend-ben ben)
35
36  (transition return
37    (when (is hamlet.status lent))
38    (do  (set hamlet.status available) (vacate hamlet.holder)))
39
40  (transition lose
41    (when (is hamlet.status lent))
42    (do  (gap "the rules do not say what happens to a lost book")))
43
44  (transition withdraw
45    (when (is hamlet.status available))
46    (do  (set hamlet.status withdrawn)))
```

46 lines of model and 11 of claims, using every idea in the language. The rest
is the same words applied to bigger worlds.

---

# Cheat sheet

## The 26 words

| Group              | Words                                                                            | What they do                                                           |
| ------------------ | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| **File**     | `load`                                                                         | textual include, idempotent                                            |
| **Schema**   | `schema` `type` `arrow` `to` `of` `fixed` `vacatable` `equation` | what kinds of things exist, how they point, what must agree            |
| **Instance** | `instance` `vacant`                                                          | one filling of a schema, empty slots included                          |
| **Model**    | `use` `initial`                                                              | which schema, and which filling to start from                          |
| **Moves**    | `transition` `when` `do` `set` `vacate` `gap`                        | a condition and a change                                               |
| **Guards**   | `is` `defined` `and` `or` `not` `some`                               | the whole logic — one syntax, used by a move, a law and a claim alike |
| **Forms**    | `form` `&rest`                                                               | rename and paste, nothing more                                         |

`@` is punctuation, not a word. ALL-CAPS blanks are a convention, not
syntax. Everything else — ordering, `=`, "for all", entire domain
vocabularies — is a library of forms written in these 26. The kernel does not
grow.

## The shape of a file

```
 1  (load "FILE")                                   ; optional, repeatable
 2
 3  (schema NAME
 4    (type NAME)                                   ; open: members come from the instance
 5    (type NAME (VALUE…))                          ; enumerated
 6    (type NAME (arrow A (to T) FLAG…) …)          ; an arrow is owned by a type
 7    (equation NAME GUARD))                        ; a law: one free root
 8
 9    FLAG ::= fixed        ; wiring — set once, never varies
10           | vacatable    ; the slot may be empty
11
12  (instance NAME SCHEMA CLAUSE…)
13
14    CLAUSE ::= (TYPE ENTITY… SLOT…)               ; entities are atoms, slots are lists
15    SLOT   ::= (ARROW value)                      ; value may be `vacant`
16                                                  ; slots need exactly one entity
17
18  (use SCHEMA)
19  (initial INSTANCE)
20
21  (transition [NAME] (when GUARD) (do EFFECT…))
22
23    GUARD  ::= (and G…) | (or G…) | (not G)
24             | (is CHAIN rhs) | (defined CHAIN)
25             | (some (VAR TYPE) G)
26             | NAME                               ; a nullary form
27    EFFECT ::= (set CHAIN rhs) | (vacate CHAIN) | (gap "MSG")
28    CHAIN  ::= entity.arrow.arrow…                ; follow arrows; literal, finite
29
30  (form (NAME BLANK… [&rest BLANK]) TEMPLATE…) ; ALL-CAPS blanks; @BLANK splices
31  (form NAME DATUM)                            ; nullary, used as a bare atom
```

## The claims file

Not part of the language — a separate document the model cannot see. Only the
words below are claims vocabulary; every `GUARD` in them is the language's own
(§10.2), the same construct `when` and `equation` take.

```
 1  (property NAME ["DOC"] (possible GUARD))        ; some reachable state satisfies it
 2  (property NAME ["DOC"] (never    GUARD))        ; none does
 3  (property NAME ["DOC"] (live     GUARD))        ; from EVERY state, still reachable
 4  (property NAME ["DOC"] (inevitable GUARD))      ; …and no run avoids it
      …(inevitable GUARD (fair MOVE…))            ; …assuming those are not starved
 5  (query    NAME (where (VAR TYPE)…) GUARD)       ; answer = the satisfying bindings
 6  (accept   TRANSITION EQUATION…)                 ; "we know this move can break that law"
```

## What `stdlib.writ` gives you

| Form                | What it is                                                                            |
| ------------------- | ------------------------------------------------------------------------------------- |
| `(= A B)`         | equality, vacuous where either side is empty — so a law about an unfilled slot holds |
| `(differ A B)`    | strict difference; an empty side makes it true                                        |
| `(all (X T) G)`   | for-all, derived from the kernel's one quantifier                                     |
| `(maybe A T)`     | shorthand for a vacatable arrow                                                       |
| `(span R A B)`    | a junction type, for a many-to-many relation                                          |
| `(toggle P A B)`  | two guarded moves flipping a slot between two values                                  |
| `(latch P A B)`   | a one-way move, with no way back                                                      |
| `quiver` `olog` | schemas describing moves and schemas, so the export commands emit ordinary instances  |

## Commands, and what they exit with

```
 1  writ check   MODEL [--claims F]     size, gaps, dead ends, laws, properties
 2  writ query   MODEL NAME [--at N]    one query's bindings, at a state
                 [--claims F]             …from F rather than the sibling
 3  writ compare OLD NEW [--map M]      preserved / LOST / gained
 4  writ derive  MODEL RULES.rules R    the same universe, asked relationally
 5  writ control MODEL                  the move list, as data
 6  writ schema  MODEL                  the schema, as data
```

**0** clean · **1** a finding — a failed property, a violated or unadmitted or
stale law, a lost guarantee · **2** unreadable input.

## Things that will catch you once

- **A `some`-binder can only be a chain root**, never the right-hand side of
  `is`. `(some (p person) (is p.member-of north))` is fine;
  `(is hamlet.holder p)` is not comparable, and makes the whole property
  report as `n/a` rather than failing. To ask "is it held at all", use
  `(defined hamlet.holder)`.
- **Forms are per file.** A `.claims` file using `=` or `all` needs its own
  `(load "stdlib.writ")`; there is no implicit prelude.
- **`is` is strict, `=` is vacuous.** `(is X v)` is false when the chain has no
  answer. `(= A B)` is *true* when either side has none. Both are deliberate;
  pick by whether an empty slot should break the rule.
- **Name your transitions**, especially inside forms, or witnesses and law
  reports have nothing to print.
- **`writ query` reads the model's sibling `.claims` by default** —
  `MODEL.writ` → `MODEL.claims`. `--claims FILE` overrides it, and is required
  with `--stdin`, which has no sibling to find.
- **A gap is not a dead end.** One is declared silence, the other is silence
  nobody declared. They are reported separately on purpose.
- **Slots need exactly one entity.** `(person ana ben)` declares two members;
  `(person ana (member-of north))` declares one and fills a slot.
  `(person ana ben (member-of north))` is an error rather than a broadcast —
  say it twice if you mean it twice.
- **All of an entity's slots go in one clause.** Entity names are fresh (§7),
  so an entity is declared exactly once; there is no second clause to add to
  later.

---

Next: [the language design](kernel-spec.md#2-language-design) — why partial,
why not Turing-complete, why s-expressions — then
[the spec](kernel-spec.md) as reference, and
[writ-problems](https://github.com/writ-lang/writ-problems) for worked models
larger than a book on a shelf.
