# A tour of Writ

Ten runnable steps, each adding a few words, ending with [the whole language
on one page](#cheat-sheet); [`kernel-spec.md`](kernel-spec.md) is the
reference. You need `writ` on your `PATH` (`make install-writ`). Line numbers
are for reference only — strip them before running.

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

- `schema` — what kinds of things exist, and how they point.
- `type` — one kind of thing.
- `instance` — one concrete filling of the schema.
- `use` — which schema the model runs on.
- `initial` — which filling it starts from.

`(book hamlet)` is a **clause** declaring `hamlet` a `book`. Nothing can vary,
so there is one situation, and with no moves it is a dead end.

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

- `arrow` — how one kind of thing points at another.
- `to` — where the arrow lands.

A **slot** is one entity plus one arrow — the cell holding that entity's
answer:

```
           status
          ┌───────────┐
   hamlet │ available │
          └───────────┘
```

Two values are possible, but only one state is reachable: nothing moves yet.

## 3. A move, and a move back

```lisp
 1  ;; added after (initial shelf)
 2  (transition lend
 3    (when (is hamlet.status available))
 4    (do  (set hamlet.status lent)))
```

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

You never write a state or an edge: `lend` contributes an edge from every
state where its guard is true. A transition names entities, not types — there
is no "any book" in an effect. The book is now stuck on loan; add the way
back:

```lisp
 1  (transition return
 2    (when (is hamlet.status lent))
 3    (do  (set hamlet.status available)))
```

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
 6    "the book can go out on loan"
 7    witness:  1. lend   → #1   hamlet.status: available → lent
 8  holds  always-lendable
 9    "from every reachable state, a loan is still possible"
```

**No new language words — still 12 of 26.** These are claims-file words.

- `property` — a named question, with an optional doc string.
- `(possible F)` — some reachable state satisfies F.
- `(never F)` — no reachable state does.
- `(live F)` — from *every* reachable state, an F-state is still reachable.

A holding `possible` prints its shortest route: each step names the situation
it lands in (`#1`; `writ show --at 1` renders it) and the cells it changed.
What a modality wraps is an ordinary guard, the same as a `when`.

## 5. Nothing, as itself

A book on the shelf is held by nobody — and nobody is not a person.

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

`writ` prints an empty slot as `∅`:

```
           status     holder
          ┌───────────┬────────┐
   hamlet │ available │ ∅      │
          └───────────┴────────┘
```

With the slot empty, every `(is hamlet.holder …)` is false; `defined` asks
whether there is an answer at all ([why partial](kernel-spec.md#23-the-arrows-are-partial)).

## 6. Your own vocabulary

`lend-ana` and `lend-ben` differ by one word. A form names the shape once:

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
- `NAME`, `WHO` — ALL-CAPS **blanks**, filled by the invocation.

A form only renames and pastes, so the result is identical and errors point at
the line you wrote.

## 7. A law, and the tool breaking it

A book should only be lent within its own branch — two routes through the
schema that must agree.

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
 7    violated in 1 reachable situations   witness: 1. lend-ben → #2
 8  $ echo $?
 9  1
```

**Three more — 22 of 26.**

- `equation` — declares a law: an arrow-chain identity that must hold.
- `fixed` — marks an arrow as **wiring**: set by the instance, never varying.
- `load` — pulls in another file; `=` is a form from `stdlib.writ`.

`=` is vacuous: true when either side has no answer. Written with the strict
`is`, the law is broken by the shelved book itself —

```
 1  equation borrow-local
 2    violated in 1 reachable situations   witness:
```

— an empty witness: the initial situation.

A law is checked, not enforced: the violating state stays, reported with the
move that reaches it, and the exit status is 1. *Violated in* is about what is
reachable; *can be broken by* lists every move that writes a slot the law
reads.

## 8. Own it, or guard it

Either acknowledge the breakage:

```lisp
 1  ;; library.claims
 2  (accept lend-ben borrow-local)
```

```console
 1  $ writ check library.writ --claims library.claims
 2  states: 3   edges: 4
 3  gaps: none
 4  dead ends: none
 5  equation borrow-local
 6    can be broken by: lend-ana, lend-ben, return   (acknowledge in claims)
 7    violated in 1 reachable situations   witness: 1. lend-ben → #2
 8  unadmitted  lend-ana may break borrow-local
 9  unadmitted  return may break borrow-local
```

**No new language words — still 22 of 26.**

- `accept` — claims-file vocabulary: "this move may break that law." Any
  such move not accepted is reported `unadmitted`.

Or fix the rule by tightening the guard:

```lisp
 1  (form (lend-to NAME WHO)
 2    (transition NAME
 3         (when (and (is hamlet.status available)
 4                    (is WHO.member-of hamlet.home)))
 5         (do  (set hamlet.status lent) (set hamlet.holder WHO))))
```

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

The violating state is now unreachable, and the model got smaller: a
tighter constraint shrinks the search.

## 9. Where the rules stop

Some questions the rules do not answer. Say so:

```lisp
 1  (transition lose
 2    (when (is hamlet.status lent))
 3    (do  (gap "the rules do not say what happens to a lost book")))
```

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

A gap is a declared exit; a dead end is a stop nobody wrote down.

## 10. The trap

Withdrawing a book, with no way back:

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
10    "the book can go out on loan"
11    witness:  1. lend-ana   → #1   hamlet.status: available → lent, hamlet.holder: ∅ → ana
12  fails  always-lendable
13    "from every reachable state, a loan is still possible"
14    stuck at: #2 (hamlet.status=withdrawn hamlet.holder=∅)
15    witness:  1. withdraw   → #2   hamlet.status: available → withdrawn
16  local-members  (at state 0)
17    p = ana
```

**No new language words — 23 of 26, and the tour ends here.**

- `query` — claims-file vocabulary: answer with the satisfying bindings.
- `where` — binds the variables a query ranges over.

`lendable` holds but `always-lendable` fails: one lawful move strands the book
where it can never be lent again, and `writ` names it. The unused words, `or`,
`some` and `&rest`, are in the cheat sheet.

## The whole model

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

Everything else — `=`, "for all", domain vocabularies — is forms over these.

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

Every `GUARD` is the language's own (§10.2).

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

**0** clean · **1** a finding — a failed or n/a property, a violated or
unadmitted or stale law, a lost guarantee · **2** unreadable input.

## Things that will catch you once

- **A `some`-binder can only be a chain root.** `(is hamlet.holder p)` is not
  comparable and reports `n/a`; use `(defined hamlet.holder)`.
- **Forms are per file.** A `.claims` file using `=` or `all` needs its own
  `(load "stdlib.writ")`.
- **`is` is strict, `=` is vacuous** on an empty slot.
- **Name your transitions**, or reports have nothing to print.
- **`writ query` reads `MODEL.claims` by default**; `--claims FILE` overrides
  it and is required with `--stdin`.
- **Slots need exactly one entity**: `(person ana ben (member-of north))` is an
  error.
- **All of an entity's slots go in one clause** (§7).

---

Next: [the language design](kernel-spec.md#2-language-design),
[the spec](kernel-spec.md), and
[writ-problems](https://github.com/writ-lang/writ-problems) for larger models.
