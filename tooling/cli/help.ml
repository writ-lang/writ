(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* The help text.

   It is DATA — one record per verb — rather than one string constant, because
   there are now two renderings of the same knowledge: `writ --help`, the whole
   reference, and `writ VERB --help`, one verb of it. Two hand-kept copies would
   be two copies, and the one that drifts is always the one nobody reads to the
   end. So a verb is described once, and both renderings are assembled from the
   same list.

   It is also why per-verb help is not a feature of `sql` alone. One verb
   answering --help while six do not is a CLI that has to be learnt twice; the
   cost of doing it uniformly, once the text is structured, is a fold.

   This module is IO-free (no print here; writ.ml prints it), so it crosses no
   layer or io-only gate. [Writ.usage] is DERIVED from the list below, so the
   one thing left to keep in step is the argument dispatch itself — a verb
   added here and not there answers --help and nothing else. *)

type verb = {
  name : string;
  summary : string;  (** one line, the header of `writ VERB --help` *)
  usage : string list;
  body : string;  (** unindented; both renderings indent it themselves *)
  options : string list;
  examples : string list;
}

let verbs =
  [
    {
      name = "check";
      summary = "build the model and report its size, gaps, dead ends and laws";
      usage = [ "writ check    MODEL.writ [--claims FILE.claims]" ];
      body =
        {|Build the model and print the report — the reachable state count and
edges; the gaps (points where the rules are declared silent); the
dead ends (situations with no move enabled); and, per equation,
whether a move can break the law and where it is violated. With
--claims it also checks each property and prints:
  holds NAME   — the property is true (a holding `possible` prints its
                 shortest satisfying route: the solution/example)
  fails NAME   — with `stuck at:` and a numbered witness route
  n/a   NAME   — the property names structure the schema lacks
plus query answers and law acknowledgments (unadmitted / stale).|};
      options =
        [
          "--claims FILE    the questions to ask (properties, queries, accepts)";
        ];
      examples =
        [
          "writ check   tests/models/any_model.writ --claims \
           tests/models/any_model.claims";
        ];
    };
    {
      name = "query";
      summary = "run one named query and print the satisfying bindings";
      usage = [ "writ query    MODEL.writ NAME [--at STATE]" ];
      body =
        {|Run one named query from the model's sibling .claims file and print
the satisfying variable bindings. --at STATE addresses a situation by
its state index (default: the initial situation, index 0).|};
      options = [ "--at STATE       address a situation by its state index" ];
      examples = [ "writ query   tests/models/any_model.writ captured --at 7" ];
    };
    {
      name = "compare";
      summary =
        "report each equation and property preserved / LOST / gained across \
         two models";
      usage =
        [
          "writ compare  OLD.writ NEW.writ [--map MAP.writ]";
          "writ compare  --git REV1 REV2 MODEL.writ [--map MAP.writ]";
        ];
      body =
        {|Build two models and report each equation and property as
`preserved`, `LOST`, or `gained` across the pair (properties come
from OLD's sibling .claims). --map carries `(map X => Y)` renames when
the two schemas differ. The --git form compares two revisions of one
file (`git show REV:MODEL`).|};
      options =
        [
          "--map MAP.writ    `(map X => Y)` renames when two schemas differ";
          "--git R1 R2 M    compare git revisions R1 and R2 of model M";
        ];
      examples =
        [
          "writ compare old.writ new.writ";
          "writ compare --git HEAD~1 HEAD model.writ";
        ];
    };
    {
      name = "control";
      summary =
        "emit the move list as an instance of the stdlib's `quiver` schema";
      usage = [ "writ control  MODEL.writ" ];
      body =
        {|Emit the model's move list as an instance of the standard library's
`quiver` schema — the dynamics as re-usable, checkable data.|};
      options = [];
      examples = [ "writ control model.writ" ];
    };
    {
      name = "schema";
      summary =
        "emit the model's schema as an instance of the stdlib's `olog` schema";
      usage = [ "writ schema   MODEL.writ" ];
      body =
        {|Emit the model's SCHEMA as an instance of the standard library's
`olog` schema — the map as data, the sibling of `control` one level
up. Types become `ob`, arrows `hom` with `dom`/`cod`, laws `eqn`
entities by name; a law's body is not encoded (kernel §17).|};
      options = [];
      examples = [ "writ schema  model.writ" ];
    };
    {
      name = "sql";
      summary = "read a relational schema as an olog, or write one back";
      usage =
        [
          "writ sql      SCHEMA.sql [--with-data] [--strict]   # DDL  -> a \
           model";
          "writ sql      MODEL.writ  [--strict]                 # model -> DDL";
        ];
      body =
        {|Read a relational schema as an olog, or write one back. ONE verb,
both directions: the direction is the EXTENSION, because there is one
mapping and reading it backwards is not a second feature. Output goes
to stdout, so the ordinary use is a redirect:

  writ sql schema.sql > shop.writ     # read a database
  writ check shop.writ                # ask it something
  writ sql shop.writ   > back.sql     # and write it out again

WHAT CROSSES. A table is a type, a foreign key an arrow, NULL
`vacatable`, an enum (or a CHECK … IN) an enumerated type keeping its
members. A primary key emits nothing — an entity IS its identity. A
single-row CHECK becomes an `equation`, which is the point: `writ
check` then reports not merely that a constraint is violated but
WHICH move can break it, with a route.

The line is that writ carries a column's value iff the column has
finitely many values worth naming. `boolean` and enums do. `varchar`,
`int` and `timestamptz` cross as arrows into a ONE-member domain:
present, exportable, and free, since a total arrow into a one-member
type has exactly one filling. Nullability costs a factor of two —
the one distinction writ can decide about a varchar, whether it is
there.

The SQL vocabulary arrives as forms over the 26 words, generated for
the database at hand, so a column is two tokens: `(varchar-255
email)`, `(timestamptz? shipped-at)`, `(fk buyer-id customers)`.
Nothing is loaded; the emitted model is kernel-only.

WHAT DOES NOT. Everything the DDL says that an olog cannot hold is
reported on stderr by line and reason, aggregated, never dropped in
silence — UNIQUE, arithmetic in a CHECK, DEFAULT, indexes, triggers.
UNIQUE is declined as UNSAYABLE rather than unimplemented: a law
ranges over one entity of its subject type and a bare `some` binder
is not comparable, so "two distinct rows agree" has no spelling.

--with-data reads INSERTs as the initial instance. That is for SEED
rows: an instance is ONE starting configuration and the state space
is a product over it, so a table's full contents is not what it
wants. --strict makes a decline a finding (exit 1), which is the
shape a CI check wants: fail when the DDL grows a construct the model
would have carried silently.

Round-tripping is defined on the MODEL, not the text — the export
normalises spellings on purpose — and the two facts SQL cannot state,
whether a key is ever UPDATEd and whether a plain column is wiring,
travel as `-- writ:` pragmas the import reads back.|};
      options =
        [
          "--with-data      read INSERT rows as the initial instance (import)";
          "--strict         exit 1 if anything in the input was declined";
        ];
      examples =
        [
          "writ sql schema.sql > model.writ      # read a database as a model";
          "writ sql schema.sql --with-data      # …with its INSERTs as the \
           instance";
          "writ sql model.writ  > schema.sql     # write the model out as DDL";
          "writ sql schema.sql --strict         # exit 1 if anything was \
           declined";
        ];
    };
    {
      name = "mgtt";
      summary = "read an mgtt architecture model as a writ model";
      usage =
        [
          "writ mgtt     MODEL.json [--strict]     # an mgtt export -> a model";
        ];
      body =
        {|Read an mgtt model (https://github.com/mgt-tool/mgtt) as a writ
model. mgtt describes a system's components, their dependencies, and
what "healthy" means for each; writ then enumerates every reachable
failure configuration and answers by exhaustion. Output goes to
stdout, so the ordinary use is a redirect:

  mgtt model export --json > system.json    # in the mgtt repo
  writ mgtt system.json    > system.writ
  writ check system.writ

The input is the RESOLVED export, not the YAML: mgtt merges each
provider type into the components using it and applies every
component-level override before writing it out. So this verb never
needs mgtt's provider registry, its install layout, or a credential —
the boundary mgtt defends stays defended.

WHAT CROSSES. A component type is a type, a component an entity, a
fact an arrow. A dependency is wiring, so it costs the state space
nothing. `failure_modes.<state>.can_cause` matched against a
dependent's `states.<state>.triggered_by` becomes one named
transition per edge, so a witness route reads as a failure chain.

The load-bearing part is that facts become FINITE domains. mgtt's
expressions compare a fact against a constant and have no arithmetic
at all, so the constants a model mentions cut each fact's values into
finitely many regions on which every predicate is constant. A region
is a member, and regions nothing separates are merged — so
`connection_count < 500` costs two members, not three. Two values in
one region were already indistinguishable to mgtt's own engine, so
nothing is approximated.

THE LAW. A component is healthy exactly when it is in its default
active state. mgtt derives one from `healthy:` and the other from the
type's state guards, and nothing keeps them consistent. Here it is an
`equation`, so `writ check` reports which move can break it and which
reachable situations do, with a route.

WHAT DOES NOT. A non-integer constant is refused rather than rounded,
a state no assignment satisfies is declined as unreachable, and a
fact no predicate mentions is not carried — writ has no values to
name for it. Probe cost, TTL and staleness stay with mgtt: writ has
no numbers and no clock. Everything declined is named on stderr,
never dropped in silence, and mgtt's own declines are forwarded.

Nothing is loaded; the emitted model is kernel-only.|};
      options =
        [ "--strict         exit 1 if anything in the input was declined" ];
      examples =
        [
          "writ mgtt system.json > system.writ   # read an architecture as a \
           model";
          "writ mgtt system.json --strict        # exit 1 if anything was \
           declined";
        ];
    };
    {
      name = "derive";
      summary = "answer a .rules relation over the model's enumerated universe";
      usage =
        [
          "writ derive   MODEL.writ RULES.rules RELATION | \"(RELATION ARG…)\"";
          "writ derive   MODEL.writ RULES.rules --why \"(RELATION ARG…)\"";
        ];
      body =
        {|Answer a .rules file's relations over the model's enumerated
universe (the relational extension, docs/interrogator.md). A bare
RELATION prints every row; a "(RELATION ARG…)" datum keeps only the
rows matching the arguments given, ALL-CAPS being a free variable.
Any position may be bound, so the dynamics run backward — "(reach X
2)" asks which situations reach state 2 — as readily as forward. A
situation is written as its state index, in and out; an entity by
name; an edge by its transition name. --why prints the derivation
tree of one fact whose arguments are all given, two spaces per
level, down to the extensional facts, ground guard checks and
completed-stratum negations it rests on. Every well-formed question
exits 0, an empty answer set included — an empty relation is an
answer — and an unreadable rules file or an undeclared relation
exits 2. This verb never exits 1. A relation is declared
`(relation NAME ARITY)`, or `(relation NAME (T1 … Tn))` to give a
sort per column (Situation, Edge, or a schema type) — needed when a
column's sort cannot be inferred, as it cannot for a variable
rooted in an arrow name that two types share.|};
      options =
        [
          "--why \"(R A…)\"   print one fact's derivation tree instead of rows";
        ];
      examples =
        [
          "writ derive  model.writ org.rules subordinate";
          "writ derive  model.writ org.rules \"(subordinate nabu X)\"";
          "writ derive  model.writ org.rules --why \"(subordinate nabu \
           cabinet)\"";
        ];
    };
    {
      name = "show";
      summary = "print what one situation is, addressed by its state index";
      usage = [ "writ show     MODEL.writ [--at STATE]…" ];
      body =
        {|Print a situation: every mutable cell as SRC.ARROW=VALUE (with the
empty set sign for a vacant one), the fewest moves that reach it from
the initial situation, and every move out of it with the index it
leads to — gap edges marked as such, since a situation whose only
exit is a gap is not a dead end. With no --at it shows the initial
situation, index 0.

This is the verb that reads back what the others answer WITH. `writ
derive` prints a relation's rows as state indices, and one numbering
is shared by the whole tool — the same index --at addresses here, that
`writ query --at` evaluates a query at, and that a witness route walks
to. So a derivation that answers "these situations are blocked" is
followed by asking what one of them holds, and the moves-out line says
whether it is stuck in fact or only in name.

Repeat --at to show several, which is the shape a derivation's answer
already has.|};
      options =
        [ "--at STATE       a situation's index; repeatable (default: 0)" ];
      examples =
        [
          "writ show    model.writ --at 17";
          "writ show    model.writ --at 17 --at 19";
        ];
    };
  ]

(* ---- rendering ---------------------------------------------------------- *)

let pad w s = s ^ String.make (max 0 (w - String.length s)) ' '

let indent n s =
  String.split_on_char '\n' s
  |> List.map (fun l -> if l = "" then "" else String.make n ' ' ^ l)
  |> String.concat "\n"

let bullets n xs =
  String.concat "\n" (List.map (fun x -> String.make n ' ' ^ x) xs)

let exit_status =
  {|EXIT STATUS  (the interface — scriptable)
  0   clean — the model built and nothing failed
  1   a finding — a failed property; a violated, unadmitted, or stale law; a
      guarantee lost in a comparison; or, with --strict, a declined construct
  2   unreadable input — a missing file, a parse error, or a bad command line|}

(* One verb, for `writ VERB --help`: everything about it and nothing about the
   others. The body sits at indent 2 here and at 11 in the full reference —
   which is the whole reason it is stored unindented. *)
let for_verb (name : string) : string option =
  match List.find_opt (fun v -> v.name = name) verbs with
  | None -> None
  | Some v ->
      let section title = function
        | [] -> []
        | xs -> [ title ^ "\n" ^ bullets 2 xs ]
      in
      Some
        (String.concat "\n\n"
           ([ "writ " ^ v.name ^ " — " ^ v.summary ]
           @ [ "USAGE\n" ^ bullets 2 v.usage ]
           @ [ indent 2 v.body ]
           @ section "OPTIONS" v.options
           @ section "EXAMPLES" v.examples
           @ [ exit_status; "`writ --help` is the full reference." ])
        ^ "\n")

let command_entry (v : verb) =
  match String.split_on_char '\n' v.body with
  | [] -> ""
  | first :: rest ->
      String.concat "\n"
        (("  " ^ pad 9 v.name ^ first)
        :: List.map
             (fun l -> if l = "" then "" else String.make 11 ' ' ^ l)
             rest)

let text =
  {|writ — Partial Olog: an abstract language for modelling real-world domains.

A Writ model is a state machine written down: a SCHEMA (the kinds of things that
exist and the typed arrows between them, plus the laws certain arrow-chains must
obey), an INSTANCE (one starting configuration), and TRANSITIONS (guarded moves).
`writ` enumerates every reachable situation — a finite space — and answers
questions about it by exhaustion, with a concrete route as evidence.

USAGE
|}
  ^ bullets 2 (List.concat_map (fun v -> v.usage) verbs)
  ^ {|
  writ help VERB | writ VERB --help
  writ --help | -h
  writ --version | -V | -v

COMMANDS
|}
  ^ String.concat "\n\n" (List.map command_entry verbs)
  ^ "\n\nOPTIONS\n"
  (* grouped by verb, in the COMMANDS block's own column, so the global list
     says which verb each flag belongs to without anyone writing it down *)
  ^ String.concat "\n"
      (List.concat_map
         (fun v ->
           List.mapi
             (fun i o -> "  " ^ pad 9 (if i = 0 then v.name else "") ^ o)
             v.options)
         verbs)
  ^ "\n\n" ^ exit_status
  ^ {|

FILES
  A .writ file is a MODEL (exactly one `use` and one `initial`, plus transitions)
  or a LIBRARY (declarations only). `(load "FILE")` pulls a library in; there is
  no implicit prelude. A model's questions live beside it in MODEL.claims. A
  .rules file is the third file type: relation declarations and rules, read by
  the same reader and form expander, named on the `derive` command line. A .sql
  file is not a writ file at all — `writ sql` reads it and prints one.

  `(load "FILE")` resolves in order: the including file's directory; $WRIT_LIB;
  the stdlib bundled beside the binary (../share/writ/lib); then ./core/stdlib. So
  the shipped `stdlib.writ` resolves from any directory. A DOMAIN library — a
  vocabulary for one subject — is not standard and is not shipped: keep it beside
  the models that load it, where the first rule of the search order finds it.

  That first rule cuts both ways: a `stdlib.writ` lying beside a model REPLACES
  the installed one, silently and by design. Set WRIT_TRACE_LOADS=1 to print
  which file each load resolved to, and which candidates were skipped — the
  question to ask whenever an edit to a library appears to have no effect.

INSTALLING  (all three land bin/writ + share/writ/lib, which is what the resolver
             above expects — see the README)
  make install-writ    from a checkout, into ~/.local — plain cp, no opam
  opam install .      the opam package: writ + writ-lsp + the stdlib into a switch
  make release        a tarball with a static binary + stdlib + install.sh, for
                      a machine with no OCaml, no opam and no network

EXAMPLES
|}
  ^ bullets 2 (List.concat_map (fun v -> v.examples) verbs)
  ^ {|

The language is specified in docs/kernel-spec.md. Worked examples that solve real
problems (the river crossing, knights & knaves, institutional scenarios) are
in github.com/writ-lang/writ-problems — clone it and run ./run-tests.sh.

Copyright (C) 2026 Alex Kunich.  License AGPL-3.0-or-later: GNU Affero GPL
version 3 or later <https://gnu.org/licenses/agpl.html>.  This is free software:
you are free to change and redistribute it, and a version you offer to users over
a network must offer them its source.  There is NO WARRANTY, to the extent
permitted by law.  The full text ships with the program, at
<prefix>/doc/writ/LICENSE.
|}
