# Town Clustering

A mod for **Transport Fever 3**. The stock map generator spreads towns evenly
across the map; this mod leaves dense groups of towns separated by empty
countryside, which gives inter-city lines somewhere to actually go.

![Town Clustering](mod/town_clustering_1/_metadata/0.png)

## How it works

Towns are placed natively in C++ while the new game dialog is open, and no mod
code runs in the menu, so there is no hook for *placing* towns differently.

So the mod lets generation finish untouched and prunes afterwards, on the first
tick of the new game:

1. Pick cluster centres by farthest-point sampling, so they spread across the
   map without needing to know the map size.
2. Keep the towns nearest a centre; destroy the rest.
3. Spare a few of the doomed towns as isolated ones and scale them down, so they
   read as outlying hamlets.
4. Rebuild the inter-town road network for the survivors, so no road dead-ends
   where a town used to be.

**Towns are never moved.** Pruning keeps terrain, rivers and industries exactly
as the stock generator made them, and every surviving town sits on a position the
engine already judged valid.

## Settings

| Setting        | Values                       | Meaning                                        |
|----------------|------------------------------|------------------------------------------------|
| Cluster Count  | 2 / 3 / 4 / 5 / 6 / 8        | How many groups to form                        |
| Towns Kept     | 30% / 45% / 60% / 75% / 100% | Share of generated towns that survive pruning  |
| Isolated Towns | None / 5% / 10% / 20%        | Share of survivors left standing alone         |

Because the mod only ever *removes* towns, **raise the game's own Town Density**
to compensate for the ones that get pruned.

## Installing

```powershell
.\deploy.ps1
```

Then restart the game - mods are read at startup. Enable *Town Clustering* in the
mod list before starting a new game.

The mod only needs to be active when the game starts; afterwards it does nothing
and can safely be removed from the savegame. It changes the world, so it is not a
cosmetic mod and achievements stay disabled while it is active. Adding it to an
established save does nothing at all - it refuses to prune once more than ten
game days have passed, rather than delete towns out from under you.

## Publishing

Publishing goes through the in-game mod manager (mod.io), which only reads the
**staging area** - not the mods folder:

```powershell
.\deploy.ps1 -Staging     # copy to staging_area\
.\deploy.ps1 -Validate    # copy, then run the game's own mod validator
```

Then open the Mod Manager in-game, validate and publish from the staging entry.
The validator grades PC and console separately, so a mod that is fine on PC can
still report console-only problems.

`mod.json` → `url` and `_metadata/modinfo.json` → `url` stay empty until the
mod.io page exists; fill both in afterwards.

`_metadata/0.png` is the listing image, 1920×1080 to match the shipped mods. It
is a drawn illustration, **not a screenshot** - see below.

## Repository layout

```
mod/town_clustering_1/      the publishable mod; deploy.ps1 installs this
  mod.json                  manifest: id, revision, params, severities
  _content.json             content file list
  _metadata/modinfo.json    name, summary, description, authors, tags
  _metadata/0.png           listing image (1920×1080)
  content/town_pruning.gs.lua      registers the game script
  content/town_pruning.script.tl   the pruning itself
generators/                 abandoned terrain-generator approach, kept as history
art/listing-pruned.png      alternative listing image (see below)
tools/build.py              regenerates generators/ from the stock node trees
tools/check_tree.py         validates a generated node tree before the game sees it
tools/make_listing_image.ps1  redraws the listing image
NOTES.md                    reverse-engineered TF3 modding notes
```

### The listing image

`tools/make_listing_image.ps1` draws it with GDI+, so it can be regenerated
rather than re-edited by hand. It is a stylised map, not a capture of the game -
there is no real screenshot in this repository yet. Two variants:

```powershell
.\tools\make_listing_image.ps1 -Variant arrows   # towns pulled together (current 0.png)
.\tools\make_listing_image.ps1 -Variant pruned   # towns between clusters struck out
```

`arrows` reads as "clustering" instantly but implies the mod *moves* towns, which
it does not. `pruned` shows what actually happens - towns are removed, survivors
never move - and is the more honest picture. To swap:

```powershell
.\tools\make_listing_image.ps1 -Variant pruned
```

Replace either with a real annotated in-game screenshot when there is one.

### About `generators/`

The first approach shaped *terrain* instead: a mod-supplied climate generator
whose node graph roughens everything outside a few broad basins, so flat
buildable ground - which the engine's town placer needs - survives only inside
them. It works, and mod generators do appear in the new game dialog, but it buys
clustering by deforming the whole map. The pruning mod supersedes it. The files
are kept because the node-tree findings in NOTES.md were expensive to get.

## Development

No Lua or Teal toolchain is installed; the game compiles `.tl` at load time and
reports failures to `crash_dump/stdout.txt`. `tlconfig.lua` is there for editor
type-checking against the game's shipped `tealdef` definitions.

The mod logs with the prefix `[town-clustering]`. If that prefix never appears in
the log, the game script never ran.

## Licence

MIT - see [LICENSE](LICENSE).
