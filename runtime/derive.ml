open Pol_data
open Derive_table

(* Extension §6 — the stratified, semi-naive least fixpoint over the finite
   universe [Space.t] already enumerated. The tables it fills, and the answers
   read back out of them, are [Derive_table].

   What arrives here is a [Rules.program] that [Rules_check] has already sorted,
   stratified and proved range-restricted in its WRITTEN order. The engine does
   no checking and must not: every diagnostic belongs at a [line:col], the
   parser is the only constructor of a program, and a second opinion computed
   down here could only ever disagree with the one the author was shown. So the
   join takes written order as given, negation takes stratification as given,
   and a bound situation takes its index as given.

   The cost, honestly (§6, §14): indexed relation joins, but a guard literal
   with an unbound path root is generate-and-test over that sort's roster, so a
   body with k of them costs Π|Dᵢ| PER ROUND, and a recursive relation runs for
   as many rounds as its derivation depth. There is no join planner and no magic
   set, and this run does not pretend otherwise. *)

(* ── Literals ────────────────────────────────────────────────────────────── *)

let value_of (env : Rules.env) (term : Rules.term) : string option =
  match term with
  | Rules.Const (c, _) -> Some c
  | Rules.Var (x, _) -> List.assoc_opt x env

(* A positive relation literal, built-in or user: probe on what is already
   bound, bind what is not. A variable repeated inside one literal binds at its
   first position and is checked at the rest. *)
let rel_step t rel (ts : Rules.term list) ~delta (env : Rules.env) kont =
  let st = store t rel in
  let want = Array.make st.arity None in
  let live = ref true in
  List.iteri
    (fun i term ->
      match value_of env term with
      | None -> ()
      | Some s -> (
          match code t st.col.(i) s with
          | Some c -> want.(i) <- Some c
          | None -> live := false))
    ts;
  if !live then
    List.iter
      (fun tup ->
        let rec bind i env = function
          | [] -> Some env
          | term :: rest -> (
              let v = decode t st.col.(i) tup.(i) in
              match term with
              | Rules.Const (c, _) ->
                  if String.equal c v then bind (i + 1) env rest else None
              | Rules.Var (x, _) -> (
                  match List.assoc_opt x env with
                  | Some b ->
                      if String.equal b v then bind (i + 1) env rest else None
                  | None -> bind (i + 1) ((x, v) :: env) rest))
        in
        match bind 0 env ts with
        | None -> ()
        | Some env' ->
            kont env' [ Rules.Premise_fact (Hashtbl.find st.ids tup) ])
      (probe st ~delta want)

(* A negated literal is a membership test, and §5 is what makes it sound: the
   relation is in a strictly lower stratum, so it was COMPLETE before this
   stratum began. An absence has no tree, which is why its premise is
   [Premise_absent] and not a fact id. *)
let neg_step t rel (ts : Rules.term list) (env : Rules.env) kont =
  let st = store t rel in
  let args = Array.make st.arity 0 in
  let live = ref true in
  List.iteri
    (fun i term ->
      match value_of env term with
      (* §4 proved every argument ground here; an ungroundable one can only fail
         the literal, never generate. *)
      | None -> live := false
      | Some s -> (
          match key t st.col.(i) s with
          | Some c -> args.(i) <- c
          | None -> live := false))
    ts;
  if !live && probe st ~delta:false (Array.map Option.some args) = [] then
    kont env [ Rules.Premise_absent (rel, args) ]

(* §2: an unbound path root enumerates its SORT's domain. Range restriction
   already proved that sort is an entity type — a situation is never a path
   root — so anything else yields no candidates and the literal simply fails. *)
let root_domain t rid (x : string) : string list =
  match List.assoc_opt (rid, x) t.prog.Rules.vars with
  | Some (Rules.Entity ty) -> Facts.entities t.sp ty
  | Some (Rules.Situation | Rules.Edge) | None -> []

(* A guard literal is COMPILED, not handed whole to [Eval.guard_holds], because
   [Model.Is] carries a plain string and the kernel evaluator compares it
   literally: it is a test and can never bind. So a top-level [(is PATH V)] —
   and a conjunct of a top-level [and], which §4 treats identically — is read
   functionally off the cell, and every other shape is a closed test lowered
   into the kernel guard and answered by the kernel. One guard semantics, the
   kernel's, with binding added only where the cell itself supplies the value. *)
let rec guard_step t rid sit (env : Rules.env) (g : Rules.gexp) kont =
  match g with
  | Rules.Is (p, v) ->
      let roots =
        match p.Rules.root with
        | Rules.Const _ -> [ env ]
        | Rules.Var (x, _) -> (
            match List.assoc_opt x env with
            | Some _ -> [ env ]
            | None -> List.map (fun e -> (x, e) :: env) (root_domain t rid x))
      in
      List.iter
        (fun env1 ->
          match Facts.read t.sp sit (Rules.lower_path env1 p) with
          | None -> ()
          | Some w -> (
              let out =
                match v with
                | Rules.Const (c, _) ->
                    if String.equal c w then Some env1 else None
                | Rules.Var (y, _) -> (
                    match List.assoc_opt y env1 with
                    | Some b -> if String.equal b w then Some env1 else None
                    | None -> Some ((y, w) :: env1))
              in
              match out with
              | None -> ()
              | Some env2 ->
                  kont env2 [ Rules.Premise_guard (Rules.lower g env2) ]))
        roots
  | Rules.And gs ->
      let rec seq env prems = function
        | [] -> kont env (List.rev prems)
        | g :: rest ->
            guard_step t rid sit env g (fun e ps ->
                seq e (List.rev_append ps prems) rest)
      in
      seq env [] gs
  | Rules.Defined _ | Rules.Or _ | Rules.Not _ | Rules.Some_ _ ->
      let mg = Rules.lower g env in
      if Facts.holds t.sp sit mg then kont env [ Rules.Premise_guard mg ]

let literal_step t (r : Rules.rule) ~delta (env : Rules.env) (l : Rules.literal)
    kont =
  match l with
  | Rules.Pos_rel (rel, ts, _) -> rel_step t rel ts ~delta env kont
  | Rules.Neg_rel (rel, ts, _) -> neg_step t rel ts env kont
  (* A bare guard names no situation, and every step of its paths was proved to
     be a FIXED arrow at read time: wiring reads the same in every situation, so
     the initial one answers for all of them. *)
  | Rules.Guard (g, _) -> (
      match Facts.init t.sp with
      | None -> ()
      | Some s0 -> guard_step t r.Rules.id s0 env g kont)
  | Rules.Built_in (b, _) -> (
      match b with
      | Rules.Situation_ s -> rel_step t "situation" [ s ] ~delta env kont
      | Rules.Init s -> rel_step t "init" [ s ] ~delta env kont
      | Rules.Edge_ (e, s1, s2) ->
          rel_step t "edge" [ e; s1; s2 ] ~delta env kont
      | Rules.Gap_edge (e, s) -> rel_step t "gap-edge" [ e; s ] ~delta env kont
      (* G is a datum, never a term: it is not interned, not joined, and not a
         column. Only S is, and §4 proved it already bound. *)
      | Rules.Holds (s, g) -> (
          match Option.bind (value_of env s) situation with
          | None -> ()
          | Some i -> guard_step t r.Rules.id i env g kont))

(* ── The fixpoint ────────────────────────────────────────────────────────── *)

let emit t (r : Rules.rule) (env : Rules.env) (prems : Rules.premise list) =
  let st = store t r.Rules.head in
  let tup = Array.make st.arity 0 in
  let live = ref true in
  List.iteri
    (fun i term ->
      match value_of env term with
      | None -> live := false
      | Some s -> (
          match key t st.col.(i) s with
          | Some c -> tup.(i) <- c
          | None -> live := false))
    r.Rules.head_args;
  if !live then
    ignore
      (insert t r.Rules.head tup
         (Some { Rules.by = r.Rules.id; premises = prems }))

(* Join the body in WRITTEN order — the order §4 simulated when it decided what
   each literal may assume bound. [drive] is the index of the one literal read
   from [delta] this round; [-1] is the seeding round, where every literal reads
   [total]. *)
let run_body t (r : Rules.rule) ~(drive : int) =
  let rec go i env prems = function
    | [] -> emit t r env (List.rev prems)
    | l :: rest ->
        literal_step t r ~delta:(i = drive) env l (fun env' ps ->
            go (i + 1) env' (List.rev_append ps prems) rest)
  in
  go 0 [] [] r.Rules.body

let stratum t rel =
  match List.assoc_opt rel t.prog.Rules.strata with Some k -> k | None -> 0

(* Only a positive literal of the CURRENT stratum can grow during this stratum's
   rounds, so only it has a delta worth driving from. *)
let drives t lv (l : Rules.literal) =
  match l with
  | Rules.Pos_rel (q, _, _) -> stratum t q = lv
  | Rules.Neg_rel _ | Rules.Built_in _ | Rules.Guard _ -> false

let run_stratum t lv =
  let rules =
    List.filter
      (fun (r : Rules.rule) -> stratum t r.Rules.head = lv)
      t.prog.Rules.rules
  in
  let heads =
    List.filter_map
      (fun (d : Rules.relation) ->
        if stratum t d.Rules.rel_name = lv then Some (store t d.Rules.rel_name)
        else None)
      t.prog.Rules.relations
  in
  (* [merge st || acc], not [acc || merge st]: every store must be merged, and
     [||] would short-circuit past the ones after the first that grew. *)
  let boundary () =
    List.fold_left (fun acc st -> merge st || acc) false heads
  in
  List.iter (fun r -> run_body t r ~drive:(-1)) rules;
  let rec rounds () =
    if boundary () then begin
      List.iter
        (fun (r : Rules.rule) ->
          List.iteri
            (fun i l -> if drives t lv l then run_body t r ~drive:i)
            r.Rules.body)
        rules;
      rounds ()
    end
  in
  rounds ()

(* The built-ins are extensional: read off the space, complete before stratum 0,
   and derived from nothing — so they carry a fact id (a premise needs one) and
   no derivation entry, which is exactly §7's criterion for a leaf. *)
let extensional t =
  let sp = t.sp in
  List.iter
    (fun i -> ignore (insert t "situation" [| i |] None))
    (Facts.situations sp);
  (match Facts.init sp with
  | None -> ()
  | Some i -> ignore (insert t "init" [| i |] None));
  List.iter
    (fun (via, a, b) -> ignore (insert t "edge" [| intern t via; a; b |] None))
    (Facts.edges sp);
  List.iter
    (fun (via, a) -> ignore (insert t "gap-edge" [| intern t via; a |] None))
    (Facts.gap_edges sp);
  List.iter
    (fun (n, _) ->
      let st = store t n in
      ignore (merge st);
      st.delta <- [])
    builtin_cols

let run (sp : Space.t) (prog : Rules.program) : t =
  let t = create sp prog in
  extensional t;
  List.iter (run_stratum t)
    (List.sort_uniq compare (List.map snd prog.Rules.strata));
  t
