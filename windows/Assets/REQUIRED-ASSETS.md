# Required MSIX assets — SPEC ONLY (no placeholder PNGs)

`makeappx pack` requires every asset the AppxManifest references to exist in the layout. This lane
stages the SPEC, not fake images: a 1x1 placeholder tile is not shippable and inventing a logo is
fabrication-adjacent (house law, inherited from the Academy windows lane). Absence fails the pack
step loudly, which correctly forces the real design step.

Deliver these PNGs into `windows/Assets/` — `package-msix.ps1` copies everything in this directory
into the layout's `Assets/` next to this file:

| File                     | Size (px) | Used as                                    |
| ------------------------ | --------- | ------------------------------------------ |
| `StoreLogo.png`          | 50x50     | Store listing logo (`Properties/Logo`)     |
| `Square150x150Logo.png`  | 150x150   | Start-menu medium tile                     |
| `Square44x44Logo.png`    | 44x44     | App list / taskbar icon                    |

Scale variants (`.scale-200` etc.) are welcome later; the three base files above are the minimum this
manifest needs to pack. Brand assets are a founder-reviewed design deliverable — do not generate
throwaway art to make CI green.
