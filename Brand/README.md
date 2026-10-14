# Ductane — the mark

A square cobalt tile with **Du** in white: the element Ductane, drawn as a cell of the periodic table. The corners are
square, never rounded.

| File | Use |
|---|---|
| `ductane.svg` | the tile, 24 points and up |
| `ductane-icon.svg` | the app icon, on Apple's 1024 grid |
| `favicon.svg` | a browser tab: the small cut, with the letters set larger, full bleed |
| `exports/` | PNGs of all of the above |

Every file here is generated from `EngineMark.letters` in `Sources/Ductane/EngineMark.swift`, and `EngineMarkTests`
fails if a file and the letters disagree.

| Color | Hex |
|---|---|
| Cobalt, the tile | `#1C3FE0` |
| White, the letters | `#FFFFFF` |
| Black, the splash ground | `#0B0B0C` |

## Crediting the engine

`SplashScreen` shows the tile with **Made with Ductane** beneath it, which is the simplest way to credit it. In running
text the name is written **Ductane**.

## The letters

The **D** and **u** are outlines traced from Inter Tight ExtraBold, © The Inter Tight Project Authors, under the
[SIL Open Font License 1.1](https://openfontlicense.org). The font itself is not part of this repository.
