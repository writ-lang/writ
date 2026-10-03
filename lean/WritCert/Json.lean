/-
Copyright (C) 2026 Alex Kunich
SPDX-License-Identifier: AGPL-3.0-or-later

# A JSON reader, for certificates

Strict RFC 8259, integers only (`Lean.Data.Json` would link the elaborator
into the shipped binary). Trusted, like `WritCert.Import`, so kept plain.
-/

namespace Writ

inductive Json where
  | null
  | bool (b : Bool)
  | num (n : Int)
  | str (s : String)
  | arr (a : Array Json)
  | obj (kvs : Array (String × Json))
  deriving Inhabited

namespace Json

/-- For error messages only. -/
partial def compress : Json → String
  | .null => "null"
  | .bool b => toString b
  | .num n => toString n
  | .str s => "\"" ++ s ++ "\""
  | .arr a => "[" ++ ",".intercalate (a.toList.map compress) ++ "]"
  | .obj kvs => "{" ++ ",".intercalate (kvs.toList.map fun (k, v) => s!"\"{k}\":{compress v}") ++ "}"

def getObjVal? (j : Json) (k : String) : Except String Json :=
  match j with
  | .obj kvs =>
    match kvs.find? (·.1 == k) with
    | some (_, v) => .ok v
    | none => .error s!"no field {k}"
  | _ => .error "not an object"

def getNat? : Json → Except String Nat
  | .num n => if n ≥ 0 then .ok n.toNat else .error "negative"
  | _ => .error "not a number"

class FromJson (α : Type) where
  fromJson? : Json → Except String α

instance : FromJson String := ⟨fun | .str s => .ok s | _ => .error "not a string"⟩
instance : FromJson Bool := ⟨fun | .bool b => .ok b | _ => .error "not a boolean"⟩

def getObjValAs? (j : Json) (α : Type) [FromJson α] (k : String) : Except String α := do
  FromJson.fromJson? (← j.getObjVal? k)

/-! ## The parser -/

abbrev P := StateT Nat (ExceptT String (ReaderT ByteArray Id))

def peek? : P (Option UInt8) := do
  let b ← read
  let i ← get
  pure (if h : i < b.size then some b[i] else none)

def next : P UInt8 := do
  match ← peek? with
  | some c => modify (· + 1); pure c
  | none => throw "unexpected end of input"

def err {α} (what : String) : P α := do throw s!"{what} at byte {← get}"

partial def ws : P Unit := do
  match ← peek? with
  | some 32 | some 9 | some 10 | some 13 => modify (· + 1); ws
  | _ => pure ()

def expect (c : UInt8) : P Unit := do
  if (← next) != c then err s!"expected '{Char.ofNat c.toNat}'"

def lit (s : String) (v : Json) : P Json := do
  for c in s.toUTF8 do expect c
  pure v

def hex (c : UInt8) : P Nat :=
  if 48 ≤ c && c ≤ 57 then pure (c - 48).toNat
  else if 97 ≤ c && c ≤ 102 then pure (c - 87).toNat
  else if 65 ≤ c && c ≤ 70 then pure (c - 55).toNat
  else err "bad \\u escape"

def hex4 : P Nat := do
  let a ← hex (← next); let b ← hex (← next); let c ← hex (← next); let d ← hex (← next)
  pure (((a * 16 + b) * 16 + c) * 16 + d)

def utf8 (cp : Nat) : ByteArray :=
  if cp < 0x80 then ⟨#[cp.toUInt8]⟩
  else if cp < 0x800 then ⟨#[(0xC0 + cp / 64).toUInt8, (0x80 + cp % 64).toUInt8]⟩
  else if cp < 0x10000 then
    ⟨#[(0xE0 + cp / 4096).toUInt8, (0x80 + cp / 64 % 64).toUInt8, (0x80 + cp % 64).toUInt8]⟩
  else
    ⟨#[(0xF0 + cp / 262144).toUInt8, (0x80 + cp / 4096 % 64).toUInt8,
       (0x80 + cp / 64 % 64).toUInt8, (0x80 + cp % 64).toUInt8]⟩

/-- A string's body, after its opening quote, as raw bytes. -/
partial def strBody (acc : ByteArray) : P ByteArray := do
  match ← next with
  | 34 => pure acc
  | 92 =>
    match ← next with
    | 34 => strBody (acc.push 34)
    | 92 => strBody (acc.push 92)
    | 47 => strBody (acc.push 47)
    | 98 => strBody (acc.push 8)
    | 102 => strBody (acc.push 12)
    | 110 => strBody (acc.push 10)
    | 114 => strBody (acc.push 13)
    | 116 => strBody (acc.push 9)
    | 117 =>
      let u ← hex4
      let cp ← if 0xD800 ≤ u && u < 0xDC00 then do
          expect 92; expect 117
          let lo ← hex4
          unless 0xDC00 ≤ lo && lo < 0xE000 do err "unpaired surrogate"
          pure (0x10000 + (u - 0xD800) * 0x400 + (lo - 0xDC00))
        else if 0xDC00 ≤ u && u < 0xE000 then err "unpaired surrogate"
        else pure u
      strBody (acc ++ utf8 cp)
    | _ => err "bad escape"
  | c => if c < 32 then err "control character in a string" else strBody (acc.push c)

def string : P String := do
  let bytes ← strBody .empty
  match String.fromUTF8? bytes with
  | some s => pure s
  | none => err "a string that is not UTF-8"

partial def digits (acc : Nat) (any : Bool) : P (Nat × Bool) := do
  match ← peek? with
  | some c => if 48 ≤ c && c ≤ 57 then do modify (· + 1); digits (acc * 10 + (c - 48).toNat) true
              else pure (acc, any)
  | none => pure (acc, any)

def number : P Json := do
  let neg ← match ← peek? with
    | some 45 => do modify (· + 1); pure true
    | _ => pure false
  let (n, any) ← digits 0 false
  unless any do err "a number with no digits"
  match ← peek? with
  | some 46 | some 101 | some 69 => err "a non-integer number (certificates hold integers only)"
  | _ => pure (.num (if neg then -(n : Int) else n))

mutual
partial def value : P Json := do
  ws
  match ← peek? with
  | some 110 => lit "null" .null
  | some 116 => lit "true" (.bool true)
  | some 102 => lit "false" (.bool false)
  | some 34 => modify (· + 1); .str <$> string
  | some 91 => modify (· + 1); array #[]
  | some 123 => modify (· + 1); object #[]
  | some c => if c == 45 || (48 ≤ c && c ≤ 57) then number else err "unexpected character"
  | none => err "unexpected end of input"

partial def array (acc : Array Json) : P Json := do
  ws
  if (← peek?) == some 93 && acc.isEmpty then modify (· + 1); return .arr acc
  let v ← value
  ws
  match ← next with
  | 44 => array (acc.push v)
  | 93 => pure (.arr (acc.push v))
  | _ => err "expected ',' or ']'"

partial def object (acc : Array (String × Json)) : P Json := do
  ws
  if (← peek?) == some 125 && acc.isEmpty then modify (· + 1); return .obj acc
  expect 34
  let k ← string
  ws; expect 58
  let v ← value
  ws
  match ← next with
  | 44 => object (acc.push (k, v))
  | 125 => pure (.obj (acc.push (k, v)))
  | _ => err "expected ',' or '}'"
end

/-- Parse a whole document: one value, and nothing after it but whitespace. -/
def parseBytes (b : ByteArray) : Except String Json :=
  let p : P Json := do
    let v ← value
    ws
    if (← peek?).isSome then err "trailing data" else pure v
  match (p.run 0).run b with
  | .ok (v, _) => .ok v
  | .error e => .error e

def parse (s : String) : Except String Json := parseBytes s.toUTF8

end Json

end Writ
