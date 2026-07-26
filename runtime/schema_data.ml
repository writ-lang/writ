open Pol_data

(* [pol schema] — render a model's SCHEMA as a re-parseable instance of the
   standard library's [olog] schema (kernel §17), the sibling of [Control] one
   level up: where that makes a model's dynamics ordinary data, this makes its
   map ordinary data. Re-parsing the emitted string against [olog] validates it.

   Engine layer: a pure string builder, no I/O and no front end. The printing
   lives in [tooling/cli/cmd_schema.ml].

   WHAT IS EMITTED, and what is not. Types become [ob], arrows become [hom]
   with [dom]/[cod], laws become [eqn] entities BY NAME. A law's body is not
   encoded: since §8.6 it is a guard, not a pair of chains, and the two §16.4
   checks this export exists to collapse — totality and shape — read only
   [dom] and [cod]. The third, equation preservation, is semantic (§16.4
   evaluates it against the target's instance), so no structural encoding
   would make it structural. See docs/schema-as-data.md. *)

(* Arrow names are scoped to their dom (§7), so two types may each own a
   [status] and the schema is still legal. Entity names in the emitted instance
   are NOT scoped — they share one namespace — so each arrow needs a name that
   is unique across the whole export and does not collide with a type name
   either.

   [dom-arrow] is the natural spelling and is what a reader wants to see. It is
   freshened by appending [_] until it clashes with nothing, exactly as
   [Control] freshens its synthesised edge names: a schema containing a type
   literally called [case-status] must not silently take the name the arrow
   [case.status] would have used. No dot is ever introduced, because a dotted
   atom is a chain to the reader (§5.2), not an entity name. *)
let hom_names (s : Schema.t) : (Schema.arrow * string) list =
  let type_names =
    List.map (fun (t : Schema.ty) -> t.Schema.name) s.Schema.types
  in
  let eq_names =
    List.map (fun (e : Schema.equation) -> e.Schema.name) s.Schema.equations
  in
  let taken = ref (s.Schema.name :: (type_names @ eq_names)) in
  let rec fresh cand =
    if List.mem cand !taken then fresh (cand ^ "_") else cand
  in
  List.map
    (fun (a : Schema.arrow) ->
      let n = fresh (a.Schema.dom ^ "-" ^ a.Schema.name) in
      taken := n :: !taken;
      (a, n))
    s.Schema.arrows

let olog (name : string) (s : Schema.t) : string =
  let homs = hom_names s in
  let buf = Buffer.create 512 in
  let add = Buffer.add_string buf in
  (* The leading [(load "stdlib.pol")] makes the output a self-contained
     library, so [(of olog)] resolves when the string is re-parsed. *)
  add "(load \"stdlib.pol\")\n\n";
  add ("(instance " ^ name ^ "-schema (of olog)\n");
  let joined f xs = String.concat "" (List.map f xs) in
  add
    ("  (ob"
    ^ joined (fun (t : Schema.ty) -> " " ^ t.Schema.name) s.Schema.types
    ^ ")\n");
  if homs <> [] then add ("  (hom" ^ joined (fun (_, n) -> " " ^ n) homs ^ ")\n");
  if s.Schema.equations <> [] then
    add
      ("  (eqn"
      ^ joined
          (fun (e : Schema.equation) -> " " ^ e.Schema.name)
          s.Schema.equations
      ^ ")\n");
  if homs <> [] then begin
    add
      ("  (dom"
      ^ joined
          (fun ((a : Schema.arrow), n) -> " (" ^ n ^ " " ^ a.Schema.dom ^ ")")
          homs
      ^ ")\n");
    add
      ("  (cod"
      ^ joined
          (fun ((a : Schema.arrow), n) -> " (" ^ n ^ " " ^ a.Schema.cod ^ ")")
          homs
      ^ ")")
  end;
  add ")\n";
  Buffer.contents buf
