(* Claims data: the questions the interrogator answers. It lives in core (not
   syntax) so the engine can consume it without ever touching the front end;
   syntax merely parses into it. *)

type modality = Never | Possible | Live

type property = {
  name : string;
  text : string;
  modality : modality;
  formula : Model.guard;
}

type query = {
  name : string;
  binders : (string * string) list;
  guard : Model.guard;
}

type accept = { tr : string; eq : string }
type t = { props : property list; queries : query list; accepts : accept list }
