(* Claims data: the questions the interrogator answers. It lives in core (not
   syntax) so the engine can consume it without ever touching the front end;
   syntax merely parses into it. *)

(* [Inevitable] is AF: not "can still reach" but "cannot avoid". It is the
   fourth of CTL's basic operators, joining the three already here, and the one
   a model with independent parties asks — a protocol that CAN still finish
   from everywhere is not a protocol that DOES.

   It carries the moves the question assumes are not starved for
   ever. The list belongs to the QUESTION and not to the model, which is what
   keeps one model answerable to both suites: "does this terminate whatever the
   network does" and "does it terminate if delivery is not refused for ever"
   are two questions about one protocol, and a model that carried the answer to
   the second could not be asked the first. Empty is the plain reading, over
   every run there is. *)
type modality = Never | Possible | Live | Inevitable of string list

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
