/-
The certificate reader is trusted, so its corners are pinned here: escapes,
surrogate pairs, raw UTF-8, and the inputs it must refuse.
-/
import WritCert.Json
open Writ

def ok (s : String) : Option String := (Json.parse s).toOption.map (·.compress)
def str (s : String) : Option String :=
  match Json.parse s with | .ok (.str x) => some x | _ => none
def refused (s : String) : Bool := (Json.parse s).toOption.isNone

#guard ok "[1, -2, null, true, false, {}, []]" == some "[1,-2,null,true,false,{},[]]"
#guard ok " { \"a\" : [ {\"b\":0} ] } " == some "{\"a\":[{\"b\":0}]}"
#guard str "\"\\\" \\\\ \\/ \\n \\t\"" == some "\" \\ / \n \t"
#guard str "\"\\u00e9\"" == some "é"
#guard str "\"\\ud83d\\ude00\"" == some "😀"
#guard str "\"∅ — raw UTF-8\"" == some "∅ — raw UTF-8"
#guard str "\"\\u0001\"" == some "\x01"
#guard refused "[1,]"
#guard refused "{\"a\" 1}"
#guard refused "1.5"
#guard refused "1e3"
#guard refused "\"\\ud83d\""
#guard refused "\"bad \\q\""
#guard refused "\"raw\ncontrol\""
#guard refused "[1] 2"
#guard refused "nul"
#guard refused ""
