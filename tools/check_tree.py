"""Sanity-check a generated node tree against the stock trees.

The generator crashes with an unhelpful "Missing input data" (GraphException)
if any node is missing a required input, so it is worth catching that here.
We infer each layerType's expected input set from how the stock trees use it.

Usage:  python tools/check_tree.py <generated.tree.lua> <stock_dir>
"""
import collections
import glob
import io
import os
import re
import sys

NODE_RE = re.compile(r"\n\t\t\t\{ \n.*?\n\t\t\t\},", re.S)


def parse(path):
    text = io.open(path, encoding="utf-8", errors="replace").read()
    nodes = []
    for block in NODE_RE.findall(text):
        layer = re.search(r'layerType = "([^"]+)"', block)
        name = re.search(r'name = "([^"]+)"', block)
        if not layer or not name:
            continue
        inputs = {}
        for m in re.finditer(
                r'\n\t\t\t\t\t(\w+) = \{ \n\s*key = "([^"]*)",\s*\n\s*nodeName = "([^"]*)",', block):
            inputs[m.group(1)] = (m.group(3), m.group(2))
        nodes.append({"name": name.group(1), "layerType": layer.group(1), "inputs": inputs})
    return nodes


def check_literals(path):
    """Catch unquoted string params.

    Emitting `key = cluster.count` instead of `key = "cluster.count"` is valid
    Lua syntax but reads as indexing a global, so the file loads and then dies
    with `attempt to index global 'cluster'`. Nothing downstream notices, so
    check that every scalar value is a number, boolean, string or table.
    """
    bad = []
    # "..." string, {...} table, [[...]] Lua long string, boolean, number
    ok = re.compile(r'^("|\{|\[\[|true$|false$|-?[\d.]+(e-?\d+)?$)')
    for i, line in enumerate(io.open(path, encoding="utf-8", errors="replace"), 1):
        m = re.match(r"\s*(\w+) = (.+?),?\s*$", line)
        if not m:
            continue
        value = m.group(2).strip()
        if not ok.match(value):
            bad.append("line %d: %s = %s" % (i, m.group(1), value))
    return bad


def main(generated, stock_dir):
    expected = collections.defaultdict(set)
    # Which output key consumers use for each producing layerType. Not every
    # node calls its output "out" - the .node subgraph types use "output" and
    # "point" - and a wrong key only shows up as an opaque assertion failure
    # during generation.
    out_keys = collections.defaultdict(set)
    for path in glob.glob(os.path.join(stock_dir, "*", "*_gen.tree.lua")):
        stock = parse(path)
        kinds = {n["name"]: n["layerType"] for n in stock}
        for n in stock:
            expected[n["layerType"]].add(frozenset(n["inputs"]))
            for src, key in n["inputs"].values():
                if src in kinds:
                    out_keys[kinds[src]].add(key)

    nodes = parse(generated)
    by_name = {n["name"]: n for n in nodes}
    problems = []

    for n in nodes:
        # every referenced node must exist, and must be read by a key that
        # type actually publishes
        for key, (src, out_key) in n["inputs"].items():
            if src not in by_name:
                problems.append("%s.%s -> unknown node %r" % (n["name"], key, src))
                continue
            src_type = by_name[src]["layerType"]
            known_keys = out_keys.get(src_type)
            if known_keys and out_key not in known_keys:
                problems.append(
                    "%s.%s reads %r from %s (%s); stock only ever reads %s"
                    % (n["name"], key, out_key, src, src_type, sorted(known_keys)))

        known = expected.get(n["layerType"])
        if not known:
            problems.append("%s: layerType %r never used in stock trees"
                            % (n["name"], n["layerType"]))
            continue
        got = frozenset(n["inputs"])
        if got not in known:
            # only complain if we are missing inputs the stock version always has
            always = set.intersection(*[set(s) for s in known])
            missing = always - set(got)
            if missing:
                problems.append("%s (%s): missing required input(s) %s; stock uses %s"
                                % (n["name"], n["layerType"], sorted(missing),
                                   sorted(sorted(s) for s in known)))

    problems += ["unquoted/odd literal - " + b for b in check_literals(generated)]

    print("checked %d nodes in %s" % (len(nodes), os.path.basename(generated)))
    if problems:
        print("PROBLEMS:")
        for p in problems:
            print("  -", p)
        return 1
    print("OK - every node's inputs match stock usage")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2]))
