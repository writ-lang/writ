(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data

(* Extension §1's fact tables and the answers read off them; [Derive] is the
   fixpoint that fills them. A bound query uses the same [probe] as the join:
   [(reach X 2)] is the forward relation read through column 2's index, which
   is why §2's backward analysis is free. *)

(* ── Atom coding ─────────────────────────────────────────────────────────── *)

(* A tuple is an int array. Entities and edge names are interned; a situation
   is its [Space.index] (the notation of §9). Codes of different sorts may
   collide, which is harmless because a column has exactly one sort. *)

type store = {
  arity : int;
  col : Rules.sort array;
  (* Membership over TOTAL ∪ NEXT, and each tuple's fact id. *)
  ids : (int array, Rules.fact_id) Hashtbl.t;
  (* One index per argument position, over TOTAL only, kept on merge: a bound
     argument is a probe, in either direction. *)
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

(* Parses only; [code] adds the range check. [key] does not need one: every
   index the engine inserts came from the space. *)
let situation (s : string) : int option =
  match int_of_string_opt s with Some i when i >= 0 -> Some i | _ -> None

(* [code] looks up, [key] interns. A probe uses [code], since an atom the model
   never produced is in no tuple. Insertions and negation arguments (recorded
   as premises) use [key]. *)
let code t (srt : Rules.sort) (s : string) : int option =
  match srt with
  (* Range-checked so [query] can tell an index naming no situation from an
     empty answer. *)
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

(* Total: every relation a literal names is declared (checked at read time)
   and every built-in is created below. *)
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
            (* Unreachable: the checker rejects an unsorted column. *)
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
    (* Only the first derivation is kept, so [--why] is a walk, not a
       search. *)
    (match d with
    | None -> ()
    | Some d -> Hashtbl.replace t.derivs id d);
    st.next <- tup :: st.next;
    true
  end

(* The round boundary. New facts land in [next], which nothing probes, and
   become visible only here. So every premise of a fact predates its round,
   the first-derivation graph is acyclic, and [--why] cannot loop — whatever
   order the rules are tried in. Merging eagerly would give the same answers
   but lose this guarantee. *)
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

(* The one way to read a relation: [total], or the driving literal's [delta] —
   never [next]. Candidates come from the first bound position's index; with no
   join planner (§6), a body pays for its written order. *)
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
