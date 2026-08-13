(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

(* Facts to finite domains — the reduction the whole bridge rests on.

   Writ has no numbers, deliberately: it is what buys the negative answer, a
   `never` that is a census rather than a search that found nothing. mgtt's
   facts are ints, floats, durations and bytes. So this module is where the
   crossing is either honest or it is nothing.

   It is honest because of a property of mgtt rather than a cleverness here:
   its expression language compares a fact against a CONSTANT and has no
   arithmetic at all. So the constants a model mentions cut each fact's value
   line into finitely many regions, and every predicate in the model is
   constant on each region. A region becomes a member; two concrete values in
   one region were already indistinguishable to mgtt's own engine. Nothing is
   approximated and nothing is lost — this is the kernel spec's "counting
   becomes naming, calculating becomes writing down", applied to a fact.

   Merging matters as much as cutting. `connection_count < 500` does not
   separate 500 from 501, so a domain of three members would carry a
   distinction no rule can make and double the state space to do it. The
   regions are cut by every constant, then collapsed wherever no gathered
   predicate tells two neighbours apart.

   A fact NO predicate mentions has no regions at all. It cannot become an
   arrow — there is nothing to name — and it is declined rather than dropped,
   because a fact silently absent from the model is a probe whose result the
   check would ignore. *)

type member = string
type domain = { dfact : string; dtype : string; members : member list }

(* ---- gathering ----------------------------------------------------------- *)

(* Every predicate that bears on a type: its own healthy list, each state's
   guard, and the healthy override of every component using it. The last is why
   this takes a roster — a domain is a property of the type AND its components,
   since an override may compare against a constant the type never mentions. *)
let predicates_of (ty : Mgtt_ast.ty) (comps : Mgtt_ast.comp list) : string list
    =
  ty.Mgtt_ast.thealthy
  @ List.map (fun (s : Mgtt_ast.state) -> s.Mgtt_ast.swhen) ty.Mgtt_ast.states
  @ List.concat_map (fun (c : Mgtt_ast.comp) -> c.Mgtt_ast.chealthy) comps

(* Parse what parses; hand back what does not, as a decline naming the text.
   A predicate that will not parse is not fatal: the rest of the type still
   yields a model worth checking, and the decline says exactly what was lost. *)
let parsed_predicates (ty : Mgtt_ast.ty) (comps : Mgtt_ast.comp list) :
    Mgtt_expr.t list * Mgtt_ast.decline list =
  List.fold_left
    (fun (es, ds) src ->
      match Mgtt_expr.parse src with
      | Ok e -> (e :: es, ds)
      | Error m ->
          ( es,
            {
              Mgtt_ast.what = ty.Mgtt_ast.tname ^ ": " ^ src;
              why = "expression not readable: " ^ m;
            }
            :: ds ))
    ([], []) (predicates_of ty comps)

(* Every (op, constant) a predicate applies to one fact. *)
let rec constraints_on (fact : string) (e : Mgtt_expr.t) :
    (Mgtt_expr.cmp * Mgtt_expr.rhs) list =
  match e with
  | Mgtt_expr.And (a, b) | Mgtt_expr.Or (a, b) ->
      constraints_on fact a @ constraints_on fact b
  | Mgtt_expr.Cmp c when c.Mgtt_expr.fact = fact ->
      [ (c.Mgtt_expr.op, c.Mgtt_expr.rhs) ]
  | Mgtt_expr.Cmp _ -> []

(* ---- naming -------------------------------------------------------------- *)

let sanitize (s : string) : string =
  String.map
    (fun c ->
      if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-' then c
      else if c >= 'A' && c <= 'Z' then Char.lowercase_ascii c
      else '-')
    s

(* ---- numeric domains ----------------------------------------------------- *)

(* A region of the value line, as a representative and a name. [rep] is what
   [satisfies] evaluates predicates at: any value in the region answers every
   predicate the same way, so one representative decides them all. *)
type region = { rname : string; rep : int }

let int_constants (cs : (Mgtt_expr.cmp * Mgtt_expr.rhs) list) : int list =
  List.sort_uniq compare
    (List.filter_map
       (function _, Mgtt_expr.Lit_int i -> Some i | _ -> None)
       cs)

let eval_int (op : Mgtt_expr.cmp) (v : int) (k : int) : bool =
  match op with
  | Mgtt_expr.Eq -> v = k
  | Mgtt_expr.Neq -> v <> k
  | Mgtt_expr.Lt -> v < k
  | Mgtt_expr.Gt -> v > k
  | Mgtt_expr.Lte -> v <= k
  | Mgtt_expr.Gte -> v >= k

(* Cut at every constant, finest-first: below k1, exactly k1, the open interval
   up to k2, exactly k2, … and everything above the last. [merge_regions] then
   collapses whatever no predicate separates, so cutting too finely here costs
   nothing and cutting too coarsely would lose a distinction for good. *)
let cut_regions (ks : int list) : region list =
  match ks with
  | [] -> []
  | first :: _ ->
      let last = List.nth ks (List.length ks - 1) in
      let rec weave = function
        | [] -> []
        | k :: rest ->
            let here = { rname = "exactly-" ^ string_of_int k; rep = k } in
            let gap =
              match rest with
              | next :: _ ->
                  [ { rname = "under-" ^ string_of_int next; rep = next - 1 } ]
              | [] -> []
            in
            (here :: gap) @ weave rest
      in
      ({ rname = "below-" ^ string_of_int first; rep = first - 1 } :: weave ks)
      @ [ { rname = "above-" ^ string_of_int last; rep = last + 1 } ]

(* Two neighbouring regions merge when no gathered predicate tells them apart.
   The merged name is read off the pair: a region that runs from below a
   constant up to but not including it stays `below-k`; one that starts at a
   constant and runs on becomes `at-or-above-k`. *)
let merge_regions (cs : (Mgtt_expr.cmp * Mgtt_expr.rhs) list) (rs : region list)
    : region list =
  let same a b =
    List.for_all
      (function
        | op, Mgtt_expr.Lit_int k -> eval_int op a.rep k = eval_int op b.rep k
        | _ -> true)
      cs
  in
  let rename first last =
    if first.rname = last.rname then first.rname
    else
      match (first.rname, last.rname) with
      | f, _ when String.length f > 6 && String.sub f 0 6 = "below-" -> f
      | f, l when String.length f > 8 && String.sub f 0 8 = "exactly-" ->
          let k = String.sub f 8 (String.length f - 8) in
          if String.length l > 6 && String.sub l 0 6 = "above-" then
            "at-or-above-" ^ k
          else "from-" ^ k
      | f, _ -> f
  in
  let rec go acc = function
    | [] -> List.rev acc
    | r :: rest ->
        let rec take_while_same last kept = function
          | x :: xs when same last x -> take_while_same x (x :: kept) xs
          | remaining -> (List.rev kept, remaining)
        in
        let group, remaining = take_while_same r [ r ] rest in
        let last = List.nth group (List.length group - 1) in
        go ({ rname = rename r last; rep = r.rep } :: acc) remaining
  in
  go [] rs

(* ---- building the domains ------------------------------------------------ *)

let bool_members = [ "yes"; "no" ]

let string_members (cs : (Mgtt_expr.cmp * Mgtt_expr.rhs) list) : string list =
  let lits =
    List.sort_uniq compare
      (List.filter_map
         (function _, Mgtt_expr.Lit_str s -> Some (sanitize s) | _ -> None)
         cs)
  in
  lits @ [ "other" ]

let is_bool cs =
  List.exists (function _, Mgtt_expr.Lit_bool _ -> true | _ -> false) cs

let is_string cs =
  List.exists (function _, Mgtt_expr.Lit_str _ -> true | _ -> false) cs

(* The joint domain a pair of compared facts shares. Three members is exactly
   what the six operators can distinguish about two values with no arithmetic
   between them. *)
let pair_members = [ "fewer"; "equal"; "more" ]
let pair_name (a, b) = a ^ ":" ^ b

let of_type (ty : Mgtt_ast.ty) (comps : Mgtt_ast.comp list) :
    domain list * Mgtt_ast.decline list =
  let exprs, declines = parsed_predicates ty comps in
  let pairs =
    List.sort_uniq compare (List.concat_map Mgtt_expr.pairs_of exprs)
  in
  let paired fact = List.exists (fun (a, b) -> a = fact || b = fact) pairs in
  let mentioned =
    List.sort_uniq compare (List.concat_map Mgtt_expr.facts_of exprs)
  in

  let pair_domains =
    List.map
      (fun p ->
        { dfact = pair_name p; dtype = "mgtt.pair"; members = pair_members })
      pairs
  in

  let single_domains, more_declines =
    List.fold_left
      (fun (doms, ds) (fact, ftype) ->
        if paired fact then
          (* A fact compared BOTH with a sibling and against a constant needs a
             joint domain over the two facts' regions, not an ordering alone:
             `ready_replicas == desired_replicas` and `desired_replicas == 0`
             constrain the same pair of cells and an ordering cannot express
             the second. Emitting the ordering alone and letting the constant
             comparison fail is sound — the guards that need it are refused,
             so moves are LOST rather than invented — but it is a real gap and
             it says so here rather than leaving the caller to infer it from a
             missing transition. *)
          let consts =
            List.filter
              (function _, Mgtt_expr.Lit_int _ -> true | _ -> false)
              (List.concat_map (constraints_on fact) exprs)
          in
          if consts = [] then (doms, ds)
          else
            ( doms,
              {
                Mgtt_ast.what = ty.Mgtt_ast.tname ^ "." ^ fact;
                why =
                  "compared both with a sibling fact and against a constant; \
                   only the ordering is carried, so guards using the constant \
                   are refused and the moves needing them are not emitted";
              }
              :: ds )
        else if not (List.mem fact mentioned) then
          ( doms,
            {
              Mgtt_ast.what = ty.Mgtt_ast.tname ^ "." ^ fact;
              why =
                "no predicate mentions this fact, so it has no values worth \
                 naming — it is not carried into the model";
            }
            :: ds )
        else
          let cs = List.concat_map (constraints_on fact) exprs in
          let members =
            if is_bool cs then bool_members
            else if is_string cs then string_members cs
            else
              match int_constants cs with
              | [] -> []
              | ks ->
                  List.map
                    (fun r -> r.rname)
                    (merge_regions cs (cut_regions ks))
          in
          if members = [] then
            ( doms,
              {
                Mgtt_ast.what = ty.Mgtt_ast.tname ^ "." ^ fact;
                why = "compared against nothing writ can name";
              }
              :: ds )
          else ({ dfact = fact; dtype = ftype; members } :: doms, ds))
      ([], []) ty.Mgtt_ast.facts
  in
  (List.rev single_domains @ pair_domains, List.rev (more_declines @ declines))

(* ---- evaluating against an assignment ------------------------------------ *)

(* The representative value of a member, for the numeric case. Recovering it
   from the name keeps [domain] a plain list of strings, which is what the
   emitter wants to print. *)
let rep_of_member (m : member) : int option =
  let starts p =
    String.length m > String.length p && String.sub m 0 (String.length p) = p
  in
  let after p =
    String.sub m (String.length p) (String.length m - String.length p)
  in
  if starts "below-" then
    Option.map (fun k -> k - 1) (int_of_string_opt (after "below-"))
  else if starts "under-" then
    Option.map (fun k -> k - 1) (int_of_string_opt (after "under-"))
  else if starts "exactly-" then int_of_string_opt (after "exactly-")
  else if starts "at-or-above-" then int_of_string_opt (after "at-or-above-")
  else if starts "from-" then int_of_string_opt (after "from-")
  else if starts "above-" then
    Option.map (fun k -> k + 1) (int_of_string_opt (after "above-"))
  else None

let pair_key a b = if a <= b then a ^ ":" ^ b else b ^ ":" ^ a

(* Does [assign] — a member per domain — satisfy [e]?

   Used by the emitter to pick a representative assignment for a state, and by
   the instance builder to find a healthy starting value. Anything it cannot
   decide is false rather than true: an emitter that guessed "satisfied" would
   write a move that does not realise the state it claims to. *)
let rec satisfies (doms : domain list) (e : Mgtt_expr.t)
    (assign : (string * member) list) : bool =
  match e with
  | Mgtt_expr.And (a, b) -> satisfies doms a assign && satisfies doms b assign
  | Mgtt_expr.Or (a, b) -> satisfies doms a assign || satisfies doms b assign
  | Mgtt_expr.Cmp { fact; op; rhs = Mgtt_expr.Fact_ref other } -> (
      match List.assoc_opt (pair_key fact other) assign with
      | None -> false
      | Some m ->
          (* the pair's member is written from the alphabetically-first fact's
             point of view, so flip the reading when this fact is the second *)
          let flip = fact > other in
          let ord =
            match m with "fewer" -> -1 | "equal" -> 0 | "more" -> 1 | _ -> 0
          in
          let ord = if flip then -ord else ord in
          let cmp0 =
            match op with
            | Mgtt_expr.Eq -> ord = 0
            | Mgtt_expr.Neq -> ord <> 0
            | Mgtt_expr.Lt -> ord < 0
            | Mgtt_expr.Gt -> ord > 0
            | Mgtt_expr.Lte -> ord <= 0
            | Mgtt_expr.Gte -> ord >= 0
          in
          cmp0)
  | Mgtt_expr.Cmp { fact; op; rhs } -> (
      match List.assoc_opt fact assign with
      | None -> false
      | Some m -> (
          match rhs with
          | Mgtt_expr.Lit_bool b ->
              let v = m = "yes" in
              if op = Mgtt_expr.Neq then v <> b else v = b
          | Mgtt_expr.Lit_str s ->
              let v = m = sanitize s in
              if op = Mgtt_expr.Neq then not v else v
          | Mgtt_expr.Lit_int k -> (
              match rep_of_member m with
              | Some v -> eval_int op v k
              | None -> false)
          | Mgtt_expr.Fact_ref _ -> false))

(* The members of one domain, or [] when the fact was not carried. *)
let members_of (doms : domain list) (fact : string) : member list =
  match List.find_opt (fun d -> d.dfact = fact) doms with
  | Some d -> d.members
  | None -> []
