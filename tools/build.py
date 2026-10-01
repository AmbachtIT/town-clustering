"""Build the Town Clustering terrain generators from the stock ones.

For every climate and every strength preset we emit two files:

  town_clustering_<climate><suffix>.tree.lua
      the stock node graph with a basin subgraph spliced into its height chain,
      everything else byte-for-byte identical
  town_clustering_<climate><suffix>.gen.lua
      the stock generator pointing at our tree

The subgraph roughens the land *outside* a set of broad basins, so flat
buildable ground survives only inside them. The engine's own town placer needs
level ground, so towns concentrate in the basins. We never move towns - the new
game dialog exposes no hook for that, only terrain.

    stock:    <source> ------------------------------> Heightmap output
    spliced:  <source> --+---------------------------> add --> Heightmap output
                         |                              ^
       seed --> basin noise --> basin mask --> mul ------+
       seed --> rough noise ----------------^

Strength is baked in and offered as separate generator entries rather than as
sliders. Sliders would need `param_number`, and it is still unproven whether
that resolves a key the game has not seen before (see NOTES.md). Presets need
no parameter plumbing at all.

Three node-graph gotchas, each of which cost a crash to find:

  * `voronoi_noise_map` looks like the obvious way to make cells, but it
    requires a `cellIndex` input - all four stock trees wire one - and without
    it generation dies with "Missing input data" (GraphException).
  * An output is addressed by key, and not every node calls it "out" (see
    OUTPUT_KEY). A wrong key fails with an assertion that names no node.
  * String params must be quoted: `key = cluster.count` is valid Lua that reads
    as indexing a global.

Also worth knowing: `ridged_noise_map` is the only noise type whose frequency
can be wired, but its value distribution differs enough from
`fractal_noise_map` that thresholds tuned for one do not suit the other. Using
it once made the whole effect all but vanish.

Always run tools/check_tree.py on the output before shipping it.

Usage:  python tools/build.py <stock_climates_dir> <mod_content_dir>
"""
import os
import re
import sys

PREFIX = "tr_"  # namespace so our nodes can never collide with stock names

REMAP = "gui/node_editor/remap_number.node"
COMBINE_POINT = "gui/node_editor/combine_point.node"

# A node's output is looked up by key and not every type calls it "out". Getting
# this wrong fails at generation with `Assertion 'it != map.end()' failed`
# (map_util.h:22), naming nothing. Derived from how the stock trees consume each
# type; tools/check_tree.py enforces it.
OUTPUT_KEY = {
    REMAP: "output",
    COMBINE_POINT: "point",
}

CLIMATES = ("temperate", "dry", "subarctic", "tropical")

# --- presets ----------------------------------------------------------------
#
# What we have learned by testing, with rough_octaves held at 4:
#
#   wavelength  amplitude  slope   result
#      142m        28m      20%    subtle clustering
#       90m        60m      67%    strong, single cluster, "very noisy"
#      275m        70m      25%    nothing at all
#
# 25% slope beat 20% yet did nothing, so slope is not what matters -
# WAVELENGTH is. A town needs a contiguous level footprint, and long swells
# leave plenty of level ground between them however steep their flanks. Short
# wavelengths deny a footprint. Smoothing by lengthening the wavelength
# therefore removes the very thing doing the work.
#
# Two other traps already paid for:
#   * Do not cut rough_octaves to smooth things. fBm at gain 0.5 accumulates
#     range over octaves, so fewer octaves means the raw noise spans much less
#     than the -1..1 window mapped into metres, and the real relief lands far
#     under the nominal amplitude.
#   * Cluster count follows basin_frequency, not the thresholds. Keep exclusion
#     fixed while tuning count, or the two confound each other.
#
# This round is a three-way comparison on temperate, including an exact
# reproduction of the configuration that demonstrably worked, as a control. If
# even the control fails, the model above is wrong and something else changed.
# Now that the splice sits on the land side, rivers survive, so the open
# question is purely how rugged the excluded land has to look. Three amplitudes
# at the wavelength we know works; pick the gentlest that still keeps towns out.
PROFILES = tuple(
    {
        "suffix": suffix,
        "label": label,
        "basin_frequency": 0.00014,   # ~7km basins
        "buildable_below": -0.30,
        "rough_above": -0.05,
        "amplitude": amplitude,
        "rough_frequency": 0.0050,    # ~200m - short enough to deny a footprint
        "rough_octaves": 4,
    }
    for suffix, label, amplitude in (
        ("_gentle", "Gentle", 30.0),
        ("", "Clustered", 42.0),
        ("_rugged", "Rugged", 60.0),
    )
)

# Temperate carries the three-way comparison; the other climates get one entry
# each using Test A, so the dropdown stays manageable while we settle roughness.
TEST_CLIMATE = "temperate"
DEFAULT_PROFILE = dict(PROFILES[1])

# The param_number slider experiment is parked for this round: cluster count is
# meaningless until exclusion reliably works, and an extra entry only muddies
# the comparison. See NOTES.md - still unproven.

def node(name, layer_type, inputs=None, params=None, position=(-0.18, -0.17)):
    """Emit one node block in exactly the format the stock trees use."""
    out = ["\t\t\t{ ", "\t\t\t\tcolor = { 0.9, 0.45, 0.1, 0.6, },"]
    if inputs:
        out.append("\t\t\t\tinputs = { ")
        for key in sorted(inputs):
            src_node, src_key = inputs[key]
            out.append("\t\t\t\t\t%s = { " % key)
            out.append('\t\t\t\t\t\tkey = "%s",' % src_key)
            out.append('\t\t\t\t\t\tnodeName = "%s",' % src_node)
            out.append("\t\t\t\t\t},")
        out.append("\t\t\t\t},")
    else:
        out.append("\t\t\t\tinputs = { },")
    out.append('\t\t\t\tlayerType = "%s",' % layer_type)
    out.append('\t\t\t\tname = "%s",' % name)
    if params:
        out.append("\t\t\t\tparams = { ")
        for key in sorted(params):
            value = params[key]
            if value is True:
                value = "true"
            elif value is False:
                value = "false"
            elif isinstance(value, str):
                # Must be quoted: `key = cluster.count` is valid Lua that reads
                # as indexing a global named 'cluster'.
                value = '"%s"' % value
            out.append("\t\t\t\t\t%s = %s," % (key, value))
        out.append("\t\t\t\t},")
    else:
        out.append("\t\t\t\tparams = { },")
    out.append("\t\t\t\tposition = { %s, %s, }," % position)
    out.append("\t\t\t},")
    return "\n".join(out)


def find_seed_source(text):
    match = re.search(
        r'seed = \{\s*\n\s*key = "seed",\s*\n\s*nodeName = "([^"]+)",', text)
    if not match:
        raise SystemExit("no seed source node found")
    return match.group(1)


def _blocks(text):
    return re.findall(r"\n\t\t\t\{ \n.*?\n\t\t\t\},", text, re.S)


def _in1(block):
    match = re.search(
        r'in1 = \{\s*\n\s*key = "out",\s*\n\s*nodeName = "([^"]+)",', block)
    return match.group(1) if match else None


def find_splice(text):
    """Return (block to rewire, name of the node currently feeding its in1).

    Every stock tree ends in add_map(land, river/water) -> height_map_output.
    Adding our relief to that *sum* puts it on top of already-carved riverbeds
    and fills them in, which visibly destroys the rivers. Splicing into the
    land side instead leaves the river term to be applied after us, so rivers
    still cut down through our terrain.
    """
    hm_block = None
    for block in _blocks(text):
        if 'layerType = "height_map_output"' in block:
            hm_block = block
            break
    if hm_block is None:
        raise SystemExit("no height_map_output node found")
    source = _in1(hm_block)
    if source is None:
        raise SystemExit("height_map_output has no in1 input")

    for block in _blocks(text):
        if ('name = "%s",' % source) in block:
            land = _in1(block)
            if 'layerType = "add_map"' in block and land is not None:
                return block, land
            break
    # Fall back to the output itself if the shape is not what we expect.
    return hm_block, source


def summarise(preset):
    basin_km = 1.0 / preset["basin_frequency"] / 1000.0
    if "lo_at_0" in preset:
        return ("basins ~%.1fkm | buildable threshold on a slider | %.0fm of relief"
                % (basin_km, preset["amplitude"]))
    return ("basins ~%.1fkm | buildable below %.2f | %.0fm of relief"
            % (basin_km, preset["buildable_below"], preset["amplitude"]))


def build_tree(stock_path, out_path, preset):
    text = open(stock_path, encoding="utf-8", errors="surrogateescape").read()
    seed = find_seed_source(text)
    target_block, source = find_splice(text)

    name = {key: PREFIX + key for key in (
        "basin_noise", "basin_mask", "rough_noise", "rough_scaled",
        "rough_masked", "height_with_basins",
        "p_clusters", "lo", "hi", "mask_from", "mask_to")}

    def ref(key, layer_type=None):
        """Reference one of our nodes by the output key its type publishes."""
        return (name[key], OUTPUT_KEY.get(layer_type, "out"))

    def remap(dst, src, lo, hi):
        """Map a normalised 0..1 number onto [lo, hi] - the stock idiom."""
        return node(name[dst], REMAP, inputs={"x": src},
                    params={"a_x": 0, "a_y": 1, "b_x": lo, "b_y": hi,
                            "clamp": True, "x": 0})

    if "lo_at_0" in preset:
        # Slider-driven thresholds. map_clamp_map takes from/to as points
        # (x = input value, y = output value), so each needs a combine_point.
        mask_nodes = [
            node(name["p_clusters"], "param_number",
                 params={"dummy": 0.5, "key": "clusters"}),
            remap("lo", ref("p_clusters"), preset["lo_at_0"], preset["lo_at_1"]),
            remap("hi", ref("p_clusters"), preset["hi_at_0"], preset["hi_at_1"]),
            node(name["mask_from"], COMBINE_POINT,
                 inputs={"x": ref("lo", REMAP)}, params={"x": 0, "y": 0}),
            node(name["mask_to"], COMBINE_POINT,
                 inputs={"x": ref("hi", REMAP)}, params={"x": 0, "y": 1}),
            node(name["basin_mask"], "map_clamp_map",
                 inputs={"in1": ref("basin_noise"),
                         "from": ref("mask_from", COMBINE_POINT),
                         "to": ref("mask_to", COMBINE_POINT)},
                 params={"clamp": True}),
        ]
    else:
        mask_nodes = [
            node(name["basin_mask"], "map_clamp_map",
                 inputs={"in1": ref("basin_noise")},
                 params={"clamp": True,
                         "from_x": preset["buildable_below"], "from_y": 0,
                         "to_x": preset["rough_above"], "to_y": 1}),
        ]

    nodes = [
        # Broad, slow-varying field deciding where the basins are.
        node(name["basin_noise"], "fractal_noise_map",
             inputs={"seed": (seed, "seed")},
             params={"frequency": preset["basin_frequency"], "gain": 0.5,
                     "lacunarity": 2.0, "numOctaves": 2}),
        # 0 inside a basin (terrain untouched) ramping to 1 outside it.
    ] + mask_nodes + [
        # The undulation itself, scaled from noise units into metres.
        node(name["rough_noise"], "fractal_noise_map",
             inputs={"seed": (seed, "seed")},
             params={"frequency": preset["rough_frequency"], "gain": 0.5,
                     "lacunarity": 2.0,
                     "numOctaves": preset.get("rough_octaves", 2)}),
        node(name["rough_scaled"], "map_clamp_map",
             inputs={"in1": ref("rough_noise")},
             params={"clamp": True, "from_x": -1, "from_y": 0,
                     "to_x": 1, "to_y": preset["amplitude"]}),
        # Apply it only outside the basins, then add onto the stock height.
        node(name["rough_masked"], "mul_map",
             inputs={"in1": ref("rough_scaled"), "in2": ref("basin_mask")}),
        node(name["height_with_basins"], "add_map",
             inputs={"in1": (source, "out"), "in2": ref("rough_masked")}),
    ]

    patched = target_block.replace(
        'nodeName = "%s",' % source,
        'nodeName = "%s",' % name["height_with_basins"], 1)
    if patched == target_block:
        raise SystemExit("failed to rewire the splice target")
    text = text.replace(target_block, patched, 1)

    anchor = "\t\tnodes = {\n"
    if anchor not in text:
        raise SystemExit("could not find the nodes array")
    text = text.replace(anchor, anchor + "\n".join(nodes) + "\n", 1)

    open(out_path, "w", encoding="utf-8", errors="surrogateescape",
         newline="\n").write(text)
    return seed, source, len(nodes)


HEADER = """-- %(display)s. GENERATED by tools/build.py - do not edit by hand.
--
-- Identical to the stock %(climate)s generator except for the node tree: ours is
-- the stock graph with a basin subgraph spliced into the height chain. Land
-- outside the basins is roughened, so the engine's town placer - which needs
-- level ground - concentrates towns in the basins. We never move towns; the new
-- game dialog exposes no hook for that, only terrain.
--
-- The oceans/water/mountains sliders are the stock ones and still work.
-- Strength is baked in; pick a different generator entry to change it.
--   %(summary)s
"""


SLIDER_BLOCK = """			{ 
				defaultIndex = 3,
				images = { },
				key = "clusters",
				name = _("Town Clusters"),
				tags = { },
				tooltip = _("Adjust roughly how many separate areas of level, buildable land the map has.\n\nFewer, larger areas push towns together; too many and they merge back into open countryside."),
				uiType = "Slider",
				valueIndices = { },
				values = {
					_("Very Few"),
					_("Few"),
					_("Medium"),
					_("Many"),
					_("Very Many"),
				},
				yearFrom = 0,
				yearTo = 0,
			},
"""


def build_gen(stock_gen, out_path, climate, tree_res, preset):
    text = open(stock_gen, encoding="utf-8").read()
    text = text.replace('nodeTree = "%s_gen.tree"' % climate,
                        'nodeTree = "%s"' % tree_res)
    text = text.replace('climate = "%s.clima"' % climate,
                        'climate = "::/climates/%s/%s.clima"' % (climate, climate))

    # The display name is not always the climate name - "dry" ships as "Desert"
    # - so take it from the desc block rather than guessing.
    found = {}

    def rename(match):
        found["label"] = match.group(2)
        return "%s%s (%s)%s" % (match.group(1), match.group(2),
                                preset["label"], match.group(3))

    text, count = re.subn(r'(desc = \{.*?name = _\(")([^"]+)("\))',
                          rename, text, count=1, flags=re.S)
    if not count:
        raise SystemExit("could not find the display name in " + stock_gen)
    text = re.sub(r"order = \d+", "order = 90", text, count=1)

    if "lo_at_0" in preset:
        marker = "\t\t},\n\t\tpreviewSeed"
        if marker not in text:
            raise SystemExit("could not find end of params list in " + stock_gen)
        text = text.replace(marker, SLIDER_BLOCK + marker, 1)

    display = "%s (%s)" % (found["label"], preset["label"])
    open(out_path, "w", encoding="utf-8", newline="\n").write(
        HEADER % {"display": display, "climate": climate,
                  "summary": summarise(preset)} + text)
    return display


def main(stock_dir, out_dir):
    built = []
    for climate in CLIMATES:
        stock_tree = os.path.join(stock_dir, climate, "%s_gen.tree.lua" % climate)
        stock_gen = os.path.join(stock_dir, climate, "%s.gen.lua" % climate)
        if not (os.path.exists(stock_tree) and os.path.exists(stock_gen)):
            print("skip %-10s (stock files not found)" % climate)
            continue
        presets = PROFILES if climate == TEST_CLIMATE else (DEFAULT_PROFILE,)
        for preset in presets:
            base = "town_clustering_%s%s" % (climate, preset["suffix"])
            build_tree(stock_tree, os.path.join(out_dir, base + ".tree.lua"), preset)
            display = build_gen(stock_gen,
                                os.path.join(out_dir, base + ".gen.lua"),
                                climate, base + ".tree", preset)
            print("%-34s %s" % (display, summarise(preset)))
            built.append(base)
    print("\n%d generators" % len(built))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
