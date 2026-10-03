# Copyright (C) 2026 Alex Kunich
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tamper with a good certificate in every way a buggy writ could, and write
each variant out. Every one must make writ-cert say DISAGREES (exit 1).

    python3 test/tamper.py GOOD.json OUTDIR
"""
import copy, json, os, sys

good = json.load(open(sys.argv[1]))
out = sys.argv[2]
os.makedirs(out, exist_ok=True)

def variant(name, f):
    c = copy.deepcopy(good)
    f(c)
    json.dump(c, open(os.path.join(out, name + ".json"), "w"))

def prop(c, name):
    return next(p for p in c["report"]["properties"] if p["name"] == name)

def wrong_count(c):  c["report"]["states"] += 1
def wrong_edges(c):  c["report"]["edges"] -= 1
def flip_verdict(c):
    p = c["report"]["properties"][0]
    p["verdict"] = "fails" if p["verdict"] == "holds" else "holds"
def bad_witness(c):        # a witness move that does not land where it says
    for p in c["report"]["properties"]:
        if p["witness"]:
            p["witness"][0]["to"] = (p["witness"][0]["to"] + 1) % c["report"]["states"]
            return
    raise SystemExit("no witness to tamper with")
def long_witness(c):       # a route that is real but not shortest
    p = next(p for p in c["report"]["properties"] if len(p["witness"]) >= 1)
    first = p["witness"][0]
    back = {"flip": "flip-back", "wander": None}
    p["witness"] = [{"move": "flip", "to": 1, "origin": None},
                    {"move": "flip-back", "to": 0, "origin": None}] + p["witness"]
def wrong_stuck(c):        # a stuck situation writ never reached that way
    p = next(p for p in c["report"]["properties"] if p["stuck_at"] is not None)
    p["stuck_at"] = (p["stuck_at"] + 1) % c["report"]["states"]
def dead_end(c):     c["report"]["dead_ends"] = []

for name, f in list(globals().items()):
    if callable(f) and f.__code__.co_argcount == 1 and name not in ("variant", "prop"):
        variant(name, f)
