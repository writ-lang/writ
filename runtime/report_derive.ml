open Pol_data

(* Extension §9's output for `pol derive`: the answer rows of a relation, and
   the derivation tree behind one fact. Pure strings, as [Report] is — the CLI
   does every print (fold F7).

   WHY NOT [Report.query_rows]. The row SHAPE is the same, and the shape is all
   that is shared: [query_rows] takes a [Claims.query] and heads its block with
   [NAME  (at state N)], because a §16.2 query is asked of one situation and
   names its columns after the variables it bound. A derived relation has
   neither — no query datum, no "at", and columns identified by position rather
   than by name. Bending that signature to serve both would mean passing a
   [Claims.query] that does not exist, so the shape is re-implemented here and
   the two stay honest about answering different questions. *)

(* ── Atoms ───────────────────────────────────────────────────────────────── *)

(* A SITUATION prints as its bare [Space.index] — [0], [3] — and never as [s0].
   The [s]-prefix notation was rejected because it collides with legal entity
   names: an entity called [s3] checks clean today, so [s3] in a column would
   be two different things depending on which sort the column has. Notation is
   sort-directed instead, and the sort is always known: [Derive_table.decode]
   renders a situation code as its index, and the same rule read backwards is
   what lets a bound query name a situation by typing [0]. *)

let indent (depth : int) : string = String.make (2 * depth) ' '

let path (p : Value.path) : string =
  String.concat "." (p.Value.root :: p.Value.steps)

(* A kernel guard as its source datum. [guard] gives the UNparenthesised form,
   because a leaf line is written bare ([is nabu.reports-to mid]) while a
   nested operand needs its parentheses back. *)
let rec guard (g : Model.guard) : string =
  match g with
  | Model.Is (p, Model.Lit v) -> "is " ^ path p ^ " " ^ v
  | Model.Is (p, Model.Chain q) -> "is " ^ path p ^ " " ^ path q
  | Model.Defined p -> "defined " ^ path p
  | Model.And gs -> "and " ^ operands gs
  | Model.Or gs -> "or " ^ operands gs
  | Model.Not g -> "not " ^ nested g
  | Model.Some_ (x, ty, g) -> "some (" ^ x ^ " " ^ ty ^ ") " ^ nested g

and nested (g : Model.guard) : string = "(" ^ guard g ^ ")"

and operands (gs : Model.guard list) : string =
  String.concat " " (List.map nested gs)

(* ── Rows (§9) ───────────────────────────────────────────────────────────── *)

let atom_row (t : Derive_table.t) (rel : string) (tup : int array) : string =
  "  " ^ String.concat "  " (Derive_answers.row t rel tup)

(* A header line, then the rows indented two spaces. The count is on the header
   because an empty answer set is an ANSWER (§9) and has to look like one: a
   header alone would otherwise read as a truncated report. *)
let rows (t : Derive_table.t) (rel : string) (tuples : int array list) : string
    =
  let n = List.length tuples in
  let header =
    rel ^ "  (" ^ string_of_int n ^ if n = 1 then " row)" else " rows)"
  in
  String.concat "\n" (header :: List.map (atom_row t rel) tuples)

(* ── Derivation trees (§7) ───────────────────────────────────────────────── *)

let fact_text (t : Derive_table.t) (f : Rules.fact) : string =
  String.concat " "
    (f.Rules.rel :: Derive_answers.row t f.Rules.rel f.Rules.args)

(* Two spaces of indent per level, so a fact proved from a fact proved from the
   model puts a line at four spaces. Three kinds of premise are LEAVES and each
   is written differently, because they are justified differently:

   - an extensional fact ([edge nabu-speaks 0 1]) — read off [Space.t], derived
     from nothing, so it prints as a fact with nothing under it;
   - a ground guard ([is nabu.reports-to mid]) — checked straight against the
     model, in the kernel's own guard syntax, which is what distinguishes it
     from a fact at a glance;
   - a completed-stratum negation ([not q mid]) — an absence has no tree, and
     its justification is that stratification completed [q] before this stratum
     began. *)
let rec node (t : Derive_table.t) (depth : int) (id : Rules.fact_id) :
    string list =
  let line =
    indent depth
    ^
    match Derive_answers.fact t id with
    | Some f -> fact_text t f
    | None -> "?"
  in
  match Derive_answers.derivation t id with
  | None -> [ line ]
  | Some d -> line :: List.concat_map (premise t (depth + 1)) d.Rules.premises

and premise (t : Derive_table.t) (depth : int) (p : Rules.premise) : string list
    =
  match p with
  | Rules.Premise_fact id -> node t depth id
  | Rules.Premise_guard g -> [ indent depth ^ guard g ]
  | Rules.Premise_absent (rel, args) ->
      [
        indent depth ^ "not "
        ^ String.concat " " (rel :: Derive_answers.row t rel args);
      ]

(* [--why] on a fact that does not hold is an ANSWER, not a failure (§7): the
   fact is named and reported underived, and the caller exits 0. An empty tree
   would be indistinguishable from a fact with no premises. *)
let why (t : Derive_table.t) (rel : string) (args : string list) : string =
  let asked = String.concat " " (rel :: args) in
  match Derive_answers.fact_id t rel args with
  | None -> asked ^ "\n" ^ indent 1 ^ "not derived"
  | Some id -> String.concat "\n" (node t 0 id)
