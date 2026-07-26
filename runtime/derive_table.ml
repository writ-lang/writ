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

(* An out-of-range index is still a code: it names no situation, so it matches
   nothing, which is the right answer for both a probe and a negation. Bounds
   are checked where a state is actually read ([Facts.state]). *)
let situation (s : string) : int option =
  match int_of_string_opt s with Some i when i >= 0 -> Some i | _ -> None

(* [code] looks up, [key] interns. A probe uses [code]: an atom the model never
   produced cannot be in any tuple, and interning it to find that out would grow
   the table for nothing. An insertion — and the argument of a negation, which
   has to be recorded as a premise — uses [key]. *)
let code t (srt : Rules.sort) (s : string) : int option =
  match srt with
  | Rules.Situation -> situation s
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

(* ── Answers ─────────────────────────────────────────────────────────────── *)

let sorts_of t rel : Rules.sort list option =
  Option.map (fun st -> Array.to_list st.col) (Hashtbl.find_opt t.rels rel)

let relations t : string list =
  List.sort compare (Hashtbl.fold (fun k _ acc -> k :: acc) t.rels [])

(* A bound query is the SAME fixpoint plus a filter, and the filter is the same
   probe the join uses — symmetric in argument position, because the per-column
   indexes are. That is what makes §2's "backward analysis is free" true rather
   than aspirational: [(reach X 2)] is not a separate backward traversal, it is
   [(reach S T)] answered through column 2's index. Rows come back in a
   deterministic order; how they are printed is the caller's business. *)
let query t rel (args : string option list) : int array list option =
  match Hashtbl.find_opt t.rels rel with
  | None -> None
  | Some st ->
      if List.length args <> st.arity then None
      else begin
        let want = Array.make st.arity None in
        let live = ref true in
        List.iteri
          (fun i a ->
            match a with
            | None -> ()
            | Some s -> (
                match code t st.col.(i) s with
                | Some c -> want.(i) <- Some c
                | None -> live := false))
          args;
        Some
          (if !live then List.sort compare (probe st ~delta:false want) else [])
      end

let row t rel (tup : int array) : string list =
  match Hashtbl.find_opt t.rels rel with
  | None -> []
  | Some st -> Array.to_list (Array.mapi (fun i c -> decode t st.col.(i) c) tup)

let fact_id t rel (args : string list) : Rules.fact_id option =
  match Hashtbl.find_opt t.rels rel with
  | None -> None
  | Some st ->
      if List.length args <> st.arity then None
      else begin
        let tup = Array.make st.arity 0 in
        let live = ref true in
        List.iteri
          (fun i s ->
            match code t st.col.(i) s with
            | Some c -> tup.(i) <- c
            | None -> live := false)
          args;
        if !live then Hashtbl.find_opt st.ids tup else None
      end

let fact t (id : Rules.fact_id) : Rules.fact option =
  Hashtbl.find_opt t.by_id id

(* [None] is a LEAF, not a missing entry (§7): an extensional fact read off the
   space is derived from nothing and has no tree beneath it. *)
let derivation t (id : Rules.fact_id) : Rules.derivation option =
  Hashtbl.find_opt t.derivs id
