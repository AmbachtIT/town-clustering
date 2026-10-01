# Town Clustering

Town Clustering is a mod for Transport Fever 3. In standard map generation towns
are distributed uniformly across the map. This mod leaves dense groups of towns
separated by empty countryside.

## How it works

Towns are placed natively in C++ while the new game dialog is open, and no mod
code runs in the menu, so there is no hook for *placing* towns differently. The
mod therefore lets generation finish untouched and then **redistributes** towns
on the first tick of the new game: the towns nearest a set of chosen cluster
centres keep their generated position, the rest are destroyed and re-created
next to a cluster, and the inter-town road network is rebuilt.

Cluster sizes follow a geometric series whose ratio is drawn per map from the
range the `cluster.variation` slider selects (`VARIATION_RATIO_MIN` ..
`VARIATION_RATIO_MAX`, floored by `SIZE_MIN_WEIGHT`), shuffled across the
centres.
Both the towns that stay and the towns that move are shared out by those
weights - weighting only the movers leaves the sizes barely a fifth apart,
because the towns that stay are spread evenly by geography.

The town count is preserved, so the player's Town Density choice still holds.
The rebuild uses the Map Editor's own town-import calls - `makeMapFromGame`,
`mapgen.createTowns`, then `makeTownDestroyCmd` / `makeTownCreateCmd`
(`gui/map_editor/map_editor.tl`, `makeTowns`).

See NOTES.md for the reverse-engineered details and for the terrain-based
approach in `generators/`, which was abandoned.

## Mod parameters

Declared in `mod/town_clustering_1/mod.json`; read back in the game script via
`api.engine.config.getModParams()`, which returns **1-based** indices into each
param's `values` list.

| key                | name           | values                               |
|--------------------|----------------|--------------------------------------|
| `cluster.count`    | Cluster Count  | 2 / 3 / 4 / 5 / 6 / 8                |
| `cluster.variation` | Cluster Sizes | Equal / Mild / Varied / Lopsided    |
| `cluster.keep`     | Towns Left In Place | 30% / 45% / 60% / 75% / 100%    |
| `cluster.isolated` | Isolated Towns | None / 5% / 10% / 20%                |

`cluster.keep` is the share of generated towns that keep the position the
generator gave them; the rest are moved next to a cluster. The total never
changes, so Town Density needs no adjustment. `cluster.isolated` is the share of
the moved towns left standing alone out in the country, scaled down so they read
as outlying hamlets.

There is no "cluster rate" parameter. An earlier draft specified one; it was
replaced by `cluster.keep` + `cluster.isolated`, which say the same thing in
terms the implementation can actually honour. A stale `cluster.rate`
entry may still sit in the game's `settings.lua` and is ignored.

## Layout

```
mod/town_clustering_1/      the publishable mod (deploy.ps1 installs this)
generators/                 abandoned terrain-generator approach, kept as history
tools/build.py              regenerates generators/ from the stock node trees
tools/check_tree.py         validates a generated node tree before the game sees it
```

## Conventions

- All files are LF (`.gitattributes` pins this); `core.autocrlf` must not win.
- `mod.json` param indices are 1-based - confirmed against the stock climate
  generators in `base/content/climates.zip`, which default to index 3 of
  `[Sparse, Scattered, Medium, Dense, Packed]`.
- `.gs.lua` game scripts run in the game state; never `require` anything under
  `::/gui/...` from them.
