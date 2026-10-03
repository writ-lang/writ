(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data
open Derive_table

(* Extension §6 — the stratified, semi-naive least fixpoint over [Space.t];
   the tables are [Derive_table]. [Rules_check] has already sorted, stratified
   and range-restricted the program, so the engine checks nothing. Cost (§6):
   joins are indexed, but an unbound guard root enumerates its roster every
   round, and there is no join planner. *)

(* ── Literals ────────────────────────────────────────────────────────────── *)

let value_of (env : Rules.env) (term : Rules.term) : string option =
  match term with
  | Rules.Const (c, _) -> Some c
  | Rules.Var (x, _) -> List.assoc_opt x env

(* A positive relation literal: probe on what is bound, bind the rest. A
   variable repeated in one literal binds at its first position. *)
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

(* A negated literal is a membership test, sound because §5 puts the relation
   in a lower, already complete stratum. An absence has no tree, hence
   [Premise_absent]. *)
let neg_step t rel (ts : Rules.term list) (env : Rules.env) kont =
  let st = store t rel in
  let args = Array.make st.arity 0 in
  let live = ref true in
  List.iteri
    (fun i term ->
      match value_of env term with
      (* §4 proved every argument ground; an ungroundable one fails. *)
      | None -> live := false
      | Some s -> (
          match key t st.col.(i) s with
          | Some c -> args.(i) <- c
          | None -> live := false))
    ts;
  if !live && probe st ~delta:false (Array.map Option.some args) = [] then
    kont env [ Rules.Premise_absent (rel, args) ]

(* §2: an unbound path root enumerates its sort's domain. Range restriction
   proved the sort is an entity type; anything else yields nothing. *)
let root_domain t rid (x : string) : string list =
  match List.assoc_opt (rid, x) t.prog.Rules.vars with
  | Some (Rules.Entity ty) -> Facts.entities t.sp ty
  | Some (Rules.Situation | Rules.Edge) | None -> []

(* A guard literal is compiled rather than passed to [Eval.guard_holds], whose
   [Is] can only test. A top-level [(is PATH V)], or a conjunct of a top-level
   [and], is read off the cell and may bind; every other shape is lowered to a
   closed kernel guard and answered by the kernel. *)
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
  (* A bare guard reads only fixed arrows (checked at read time), which are
     the same in every situation, so the initial one answers. *)
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
      | Rules.Phase (s, p) -> rel_step t "phase" [ s; p ] ~delta env kont
      | Rules.Phase_step (p, q) ->
          rel_step t "phase-step" [ p; q ] ~delta env kont
      (* G is a datum, not a term or column; §4 proved S bound. *)
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

(* Join the body in written order, as §4 simulated it. [drive] is the one
   literal read from [delta] this round; [-1] is the seeding round. *)
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

(* Only a positive literal of the current stratum can grow, so only it is
   worth driving from. *)
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
  (* [merge st || acc], not [acc || merge st]: every store must be merged. *)
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

(* The built-ins are extensional: complete before stratum 0, with a fact id
   but no derivation — §7's criterion for a leaf. *)
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
  let phase, phase_step = Facts.phases sp in
  List.iter (fun (s, p) -> ignore (insert t "phase" [| s; p |] None)) phase;
  List.iter
    (fun (p, q) -> ignore (insert t "phase-step" [| p; q |] None))
    phase_step;
  List.iter
    (fun (n, _) ->
      let st = store t n in
      ignore (merge st);
      st.delta <- [])
    builtin_cols

(* ── Demand ──────────────────────────────────────────────────────────────── *)

(* The relations one question needs: the target and everything a contributing
   rule reads, transitively. Lets a library declare expensive relations
   (ct.rules' [reach]) at no cost to questions that do not use them. *)
let cone (prog : Rules.program) (target : string) : string list =
  let reads rel =
    List.concat_map
      (fun (r : Rules.rule) ->
        if String.equal r.Rules.head rel then
          List.filter_map
            (function
              | Rules.Pos_rel (n, _, _) | Rules.Neg_rel (n, _, _) -> Some n
              | Rules.Built_in _ | Rules.Guard _ -> None)
            r.Rules.body
        else [])
      prog.Rules.rules
  in
  let rec go seen = function
    | [] -> seen
    | x :: rest ->
        if List.mem x seen then go seen rest else go (x :: seen) (reads x @ rest)
  in
  go [] [ target ]

let restrict (prog : Rules.program) (target : string) : Rules.program =
  let keep = cone prog target in
  {
    prog with
    Rules.relations =
      List.filter
        (fun (d : Rules.relation) -> List.mem d.Rules.rel_name keep)
        prog.Rules.relations;
    Rules.rules =
      List.filter
        (fun (r : Rules.rule) -> List.mem r.Rules.head keep)
        prog.Rules.rules;
  }

(* [?only] prunes the program to what can contribute to that relation.
   Omitted, every declared relation is computed. *)
let run ?only (sp : Space.t) (prog : Rules.program) : t =
  let prog = match only with None -> prog | Some r -> restrict prog r in
  let t = create sp prog in
  extensional t;
  List.iter (run_stratum t)
    (List.sort_uniq compare (List.map snd prog.Rules.strata));
  t
