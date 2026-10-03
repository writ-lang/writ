(* Copyright (C) 2026 Alex Kunich *)
(* SPDX-License-Identifier: AGPL-3.0-or-later *)

open Writ_data
open Writ_runtime

(* The certificate a second checker re-derives writ's answers from
   (docs/certificates.md; lean/ is the checker): the kernel model, the
   questions as guards, and the `writ check --json` object. No state graph —
   the checker rebuilds its own and holds writ's answer to it. *)

let str s = Json.String s
let strs l = Json.List (List.map str l)
let format_version = 2
let path (p : Value.path) : Json.t = strs (p.Value.root :: p.Value.steps)

let rhs = function
  | Model.Lit v -> Json.Assoc [ ("lit", str v) ]
  | Model.Chain p -> Json.Assoc [ ("chain", path p) ]

(* A guard as a tagged list in the kernel's spelling: [["is", PATH, RHS]],
   [["some", X, TYPE, G]], and so on. *)
let rec guard (g : Model.guard) : Json.t =
  match g with
  | Model.And gs -> Json.List (str "and" :: List.map guard gs)
  | Model.Or gs -> Json.List (str "or" :: List.map guard gs)
  | Model.Not g -> Json.List [ str "not"; guard g ]
  | Model.Is (p, r) -> Json.List [ str "is"; path p; rhs r ]
  | Model.Defined p -> Json.List [ str "defined"; path p ]
  | Model.Some_ (x, ty, g) -> Json.List [ str "some"; str x; str ty; guard g ]

let effect = function
  | Model.Set (p, r) -> Json.List [ str "set"; path p; rhs r ]
  | Model.Vacate p -> Json.List [ str "vacate"; path p ]
  | Model.Gap msg -> Json.List [ str "gap"; str msg ]

let cell = function Value.Filled v -> str v | Value.Vacant -> Json.Null

(* The label [Space.build] gives a move — its name, or [#i] by position — and
   so how an edge finds its move. *)
let via i (tr : Model.transition) =
  match tr.Model.name with Some n -> n | None -> "#" ^ string_of_int i

(* The kernel model. [members] is each type's extent as [Eval] ranges over it.
   [fixed] is the wiring as [State.build_ctx] reads it: every fixed arrow at
   every source, the first valuation naming it, vacant where none does. *)
let model (sp : Space.t) (m : Model.t) : Json.t =
  let ctx = sp.Space.ctx in
  let inst = m.Model.initial in
  let schema = m.Model.schema in
  let fixed =
    List.concat_map
      (fun (a : Schema.arrow) ->
        if not a.Schema.fixed then []
        else
          List.map
            (fun src ->
              let cr = { Instance.arrow = a.Schema.name; src } in
              let v =
                match List.assoc_opt cr inst.Instance.valuation with
                | Some c -> c
                | None -> Value.Vacant
              in
              Json.Assoc
                [ ("src", str src); ("arrow", str a.name); ("value", cell v) ])
            (State.sources schema inst a.Schema.dom))
      schema.Schema.arrows
  in
  Json.Assoc
    [
      ( "types",
        Json.List
          (List.map
             (fun (ty : Schema.ty) ->
               Json.Assoc
                 [
                   ("name", str ty.Schema.name);
                   ("members", strs (Eval.entities_of_type ctx ty.Schema.name));
                 ])
             schema.Schema.types) );
      ( "layout",
        Json.List
          (Array.to_list
             (Array.map
                (fun (cr : Instance.cellref) ->
                  Json.Assoc
                    [
                      ("src", str cr.Instance.src);
                      ("arrow", str cr.Instance.arrow);
                    ])
                ctx.State.layout.State.cells)) );
      ("fixed", Json.List fixed);
      ("initial", Json.List (Array.to_list (Array.map cell sp.Space.initial)));
      ( "transitions",
        Json.List
          (List.mapi
             (fun i (tr : Model.transition) ->
               Json.Assoc
                 [
                   ("name", str (via i tr));
                   ("guard", guard tr.Model.when_);
                   ("effects", Json.List (List.map effect tr.Model.effects));
                 ])
             sp.Space.transitions) );
      ( "equations",
        Json.List
          (List.map
             (fun (eq : Schema.equation) ->
               Json.Assoc
                 [
                   ("name", str eq.Schema.name);
                   ( "subject",
                     match Guard.free_roots eq.Schema.body with
                     | [ r ] -> str r
                     | _ -> Json.Null );
                   ("body", guard eq.Schema.body);
                 ])
             schema.Schema.equations) );
    ]

(* A question, lowered. [applicable] is writ's own n/a test, so the checker
   can say which verdicts it re-derived and which it took on trust. *)
let property (sp : Space.t) (p : Claims.property) : Json.t =
  let known =
    List.filter_map
      (fun (t : Model.transition) -> t.Model.name)
      sp.Space.transitions
  in
  let fair = Report_json.fair p.Claims.modality in
  Json.Assoc
    [
      ("name", str p.Claims.name);
      ("modality", str (Report_json.modality p.Claims.modality));
      ("fair", strs fair);
      ("formula", guard p.Claims.formula);
      ( "applicable",
        Json.Bool
          (Checker.guard_ok sp.Space.ctx [] p.Claims.formula
          && List.for_all (fun m -> List.mem m known) fair) );
    ]

let certificate ~(version : string) ~(sp : Space.t) ~(model_ : Model.t)
    ~(claims : Claims.t option) ~(report : Json.t) : Json.t =
  Json.Assoc
    [
      ("format", str "writ-certificate");
      ("version", Json.Int format_version);
      ("writ", str version);
      ("model", model sp model_);
      ( "properties",
        Json.List
          (match claims with
          | None -> []
          | Some c -> List.map (property sp) c.Claims.props) );
      ("report", report);
    ]

(* What writ-cert said about a certificate. Both front ends run the checker
   themselves (I/O) and render the result here so they word it the same. *)
type verdict =
  | Certified
  | Disagrees of string list  (** writ-cert refuted writ: a bug in writ *)
  | Partial of string list  (** some answers could not be certified *)
  | Absent  (** no writ-cert to ask *)
  | Failed of string  (** writ-cert ran and could not read the certificate *)

let starts_with p s =
  String.length s >= String.length p && String.sub s 0 (String.length p) = p

(* writ-cert's exit status and output, read: 0 certified, 1 refuted, 3 partly
   certified; 126/127 is the shell saying there was nothing to run. *)
let verdict_of_run ~(code : int) ~(output : string list) : verdict =
  let tagged p = List.filter (starts_with p) output in
  match code with
  | 0 -> Certified
  | 1 -> Disagrees (tagged "DISAGREES")
  | 3 -> Partial (tagged "uncertified")
  | 126 | 127 -> Absent
  | _ -> Failed (String.concat " " (List.filter (( <> ) "") output))

let verdict_line : verdict -> string = function
  | Certified -> "certified: every answer re-derived from the model (writ-cert)"
  | Disagrees ls ->
      String.concat "\n"
        ("NOT CERTIFIED: writ-cert refutes this report — a bug in writ:"
        :: List.map (fun l -> "  " ^ l) ls)
  | Partial ls ->
      String.concat "\n"
        ("partly certified: writ-cert could not certify:"
        :: List.map (fun l -> "  " ^ l) ls)
  | Absent -> "not certified: writ-cert is not installed (docs/certificates.md)"
  | Failed e -> "not certified: writ-cert failed: " ^ e

let verdict_json : verdict -> Json.t =
  let obj status ls =
    Json.Assoc [ ("status", str status); ("lines", strs ls) ]
  in
  function
  | Certified -> obj "certified" []
  | Disagrees ls -> obj "disagrees" ls
  | Partial ls -> obj "partial" ls
  | Absent -> obj "absent" []
  | Failed e -> obj "failed" [ e ]
