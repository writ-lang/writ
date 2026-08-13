(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Pol_data

(* Extension §6's DATA STRUCTURE: the interned fact tables, and the answers read
   off them. The fixpoint that fills them is [Derive] — the seam is between the
   tables and the algorithm, and it is where the two readings of one probe meet.

   Because a bound query is answered by the SAME probe the join uses, it lives
   here beside it rather than in the engine: [(reach X 2)] is not a backward
   traversal, it is the forward relation read through column 2's index. That
   symmetry is the whole of §2's "backward analysis is free", and keeping the
   two callers on one function is what stops them from drifting apart. *)

(* ── Atom coding ─────────────────────────────────────────────────────────── *)

(* A tuple is an int array, so every atom is an int. Entities and edge names are
   interned; a SITUATION is its [Space.index] and is not interned, because the
   space's numbering is already the notation (§9) and a second one would have to
   be kept in step with it. Codes from different sorts are therefore drawn from
   two numberings and can collide numerically — harmless, because a column has
   exactly one sort and two codes never meet outside a column. *)

type store = {
  arity : int;
  col : Rules.sort array;
  (* Membership over TOTAL ∪ NEXT, and the fact id of each tuple. *)
  ids : (int array, Rules.fact_id) Hashtbl.t;
  (* One index per argument position, over TOTAL only, maintained on merge. It
     is what makes a bound argument a probe instead of a scan — in either
     direction, which is why running the dynamics backward costs nothing. *)
  pos : (int, int array list) Hashtbl.t array;
  mutable all : int array list;
  mutable delta : int array list;
  mutable next : int array list;
}

type t = {
  sp : Space.t;
  prog : Rules.program;
  atoms : (string, int) Hashtbl.t;
  mutable names : string array;
  mutable n_atoms : int;
  rels : (string, store) Hashtbl.t;
  by_id : (Rules.fact_id, Rules.fact) Hashtbl.t;
  derivs : (Rules.fact_id, Rules.derivation) Hashtbl.t;
  mutable n_facts : int;
}

let intern t (s : string) : int =
  match Hashtbl.find_opt t.atoms s with
  | Some i -> i
  | None ->
      let i = t.n_atoms in
      if i >= Array.length t.names then begin
        let grown = Array.make (max 32 (2 * i)) "" in
        Array.blit t.names 0 grown 0 i;
        t.names <- grown
      end;
      t.names.(i) <- s;
      Hashtbl.replace t.atoms s i;
      t.n_atoms <- i + 1;
      i

(* Parses; does NOT bound-check. [code] adds the range test, because that is the
   caller that has to tell "no rows" from "that index names no situation" — see
   the comment there. [key] deliberately does not: it interns for insertion, and
   every index the engine inserts came out of the space already. *)
let situation (s : string) : int option =
  match int_of_string_opt s with Some i when i >= 0 -> Some i | _ -> None

(* [code] looks up, [key] interns. A probe uses [code]: an atom the model never
   produced cannot be in any tuple, and interning it to find that out would grow
   the table for nothing. An insertion — and the argument of a negation, which
   has to be recorded as a premise — uses [key]. *)
let code t (srt : Rules.sort) (s : string) : int option =
  match srt with
  (* Range-checked, not merely parsed: index 999 of a four-situation space is as
     impossible as an entity no roster holds, and [query] now tells the two apart
     from an empty answer. Safe on the join path too — every index the engine
     puts in a tuple came out of the space to begin with. *)
  | Rules.Situation -> (
      match situation s with
      | Some i when i < Array.length t.sp.Space.states -> Some i
      | _ -> None)
  | Rules.Edge | Rules.Entity _ -> Hashtbl.find_opt t.atoms s

let key t (srt : Rules.sort) (s : string) : int option =
  match srt with
  | Rules.Situation -> situation s
  | Rules.Edge | Rules.Entity _ -> Some (intern t s)

let decode t (srt : Rules.sort) (i : int) : string =
  match srt with
  | Rules.Situation -> string_of_int i
  | Rules.Edge | Rules.Entity _ -> t.names.(i)

(* ── The relation tables ─────────────────────────────────────────────────── *)

let builtin_cols =
  [
    ("situation", [ Rules.Situation ]);
    ("init", [ Rules.Situation ]);
    ("edge", [ Rules.Edge; Rules.Situation; Rules.Situation ]);
    ("gap-edge", [ Rules.Edge; Rules.Situation ]);
    ("phase", [ Rules.Situation; Rules.Situation ]);
    ("phase-step", [ Rules.Situation; Rules.Situation ]);
  ]

let make_store (cols : Rules.sort list) : store =
  let a = List.length cols in
  {
    arity = a;
    col = Array.of_list cols;
    ids = Hashtbl.create 64;
    pos = Array.init a (fun _ -> Hashtbl.create 64);
    all = [];
    delta = [];
    next = [];
  }

(* Total by construction: every relation a literal names is declared (checked at
   read time) and every built-in is created below. *)
let store t rel : store = Hashtbl.find t.rels rel

let create (sp : Space.t) (prog : Rules.program) : t =
  let t =
    {
      sp;
      prog;
      atoms = Hashtbl.create 64;
      names = Array.make 32 "";
      n_atoms = 0;
      rels = Hashtbl.create 16;
      by_id = Hashtbl.create 256;
      derivs = Hashtbl.create 256;
      n_facts = 0;
    }
  in
  List.iter
    (fun (n, cs) -> Hashtbl.replace t.rels n (make_store cs))
    builtin_cols;
  List.iter
    (fun (r : Rules.relation) ->
      let a =
        match r.Rules.cols with
        | Rules.Arity a -> a
        | Rules.Sorts ss -> List.length ss
      in
      let cs =
        List.init a (fun i ->
            match List.assoc_opt (r.Rules.rel_name, i) prog.Rules.sorts with
            | Some s -> s
            (* Unreachable: a column the inference could not sort is rejected at
               the declaration. Written out rather than raised, because the
               engine must not invent failure modes the checker excluded. *)
            | None -> Rules.Entity "")
      in
      Hashtbl.replace t.rels r.Rules.rel_name (make_store cs))
    prog.Rules.relations;
  t

let insert t rel (tup : int array) (d : Rules.derivation option) : bool =
  let st = store t rel in
  if Hashtbl.mem st.ids tup then false
  else begin
    let id = t.n_facts in
    t.n_facts <- id + 1;
    Hashtbl.replace st.ids tup id;
    Hashtbl.replace t.by_id id { Rules.rel; args = tup };
    (* Only the FIRST derivation is kept: memory linear in the fact count, and
       [--why] a walk rather than a search. *)
    (match d with
    | None -> ()
    | Some d -> Hashtbl.replace t.derivs id d);
    st.next <- tup :: st.next;
    true
  end

(* THE ROUND BOUNDARY, and the reason it is a correctness invariant rather than
   a tuning knob. New facts land in [next]; nothing probes [next]. They become
   visible only here, between rounds. So every premise of a fact predates the
   round the fact was found in, the first-derivation graph is strictly
   round-DECREASING, hence acyclic, and [--why] cannot walk a cycle.

   That is a stronger guarantee than "insertion order happens to be a total
   order", which is the accident an eager merge would leave the witness resting
   on: it survives any change to the order rules are tried in, and it is what
   makes the acyclicity a property of the algorithm rather than of this loop.
   The answer set is identical either way, so nothing at the level of output
   would notice its loss. *)
let merge (st : store) : bool =
  let fresh = List.rev st.next in
  st.next <- [];
  st.delta <- fresh;
  List.iter
    (fun tup ->
      st.all <- tup :: st.all;
      Array.iteri
        (fun i v ->
          let cur =
            match Hashtbl.find_opt st.pos.(i) v with Some l -> l | None -> []
          in
          Hashtbl.replace st.pos.(i) v (tup :: cur))
        tup)
    fresh;
  fresh <> []

let matches (want : int option array) (tup : int array) : bool =
  let rec go i =
    i >= Array.length tup
    || (match want.(i) with None -> true | Some v -> v = tup.(i))
       && go (i + 1)
  in
  go 0

(* The one way anything reads a relation: [total], or the driving literal's
   [delta] — never [next]. Candidates come from the index of the FIRST bound
   position; there is no join planner and no magic set (§6), so a body pays for
   the order it is written in. *)
let probe (st : store) ~(delta : bool) (want : int option array) :
    int array list =
  let cands =
    if delta then st.delta
    else
      let rec first i =
        if i >= st.arity then st.all
        else
          match want.(i) with
          | Some v -> (
              match Hashtbl.find_opt st.pos.(i) v with
              | Some l -> l
              | None -> [])
          | None -> first (i + 1)
      in
      first 0
  in
  List.filter (matches want) cands
