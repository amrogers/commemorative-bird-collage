# Commemorative Bird Collage

Renders a [fugleramme](https://github.com/arnegiacomo/fugleramme)-style bird-art
collage from a single day's eBird observations. Give it a date and an eBird region
code, and it fetches every checklist, tallies species by frequency, matches each
to a vintage 1800s plate or a modern illustrated sticker, scales birds by body mass,
and packs them into a customisable shape. Three files come out:

| Output | Default size | Description |
|---|---|---|
| `sonoma_wedding_birds.png` | 12 × 8 in | Landscape print — birds numbered, key underneath |
| `sonoma_wedding_puzzle.png` | 18.9 × 25.2 in | Portrait jigsaw — birds packed inside a heart with corner flourishes |
| `sonoma_wedding_species_list.png` | 8.5 × 11 in | Species-list card with checklist counts |

> No preview image is included by default. If you'd like to add one, open a PR or
> drop a small JPEG in the repo root and let me know.

This is an R port of the collage/packing logic from
[fugleramme](https://github.com/arnegiacomo/fugleramme) (MIT).

---

## Setup

### R packages

```r
install.packages(c("here", "magick", "jsonlite", "dplyr", "systemfonts", "ragg"))
install.packages("rebird")   # only if fetching fresh eBird data
install.packages("readxl")   # only if using an Excel shape file
```

### eBird API key

A free key is available at <https://ebird.org/api/keygen>.

Store it in one of two ways (the script tries both in order):

1. **File** — create `ebird_api.txt` in the project root containing just the key,
   one line, no quotes. This file is git-ignored.
2. **Environment variable** — add `EBIRD_KEY=your_key_here` to `~/.Renviron`.

No key is needed to run the script with the included example data
(`data/ebird/summary_2026-10-10_US-CA-097_county.csv`); the download step is
skipped when the summary CSV already exists.

### project_dir

The script uses the [`here`](https://here.r-lib.org/) package to find the project
root automatically — no path editing required. Open the script in Positron or
RStudio with the project root as your working directory (or run
`source("code/bird_collage.R")` from the root), and `here::here()` resolves
everything correctly.

---

## Running with the example data

```r
source("code/bird_collage.R")
```

The script reads `data/ebird/summary_2026-10-10_US-CA-097_county.csv` (already
included), downloads artwork on first run into `data/art_cache/`, and writes
output to `output/vintage/`.

To generate data for a different date and region, set `cfg$wedding_date` and
`cfg$region`, provide an eBird API key, and delete (or never create) the summary
CSV for that date.

---

## Configuration

All settings live in the `cfg` list near the top of `code/bird_collage.R`.

### Art style (`cfg$art`)

```r
art = "vintage"   # "vintage": 1800s plates + kacho-e woodblock fill-ins
                  # "modern":  flat illustrated stickers
```

### Which outputs to make (`cfg$outputs`)

```r
outputs = c("print", "puzzle", "list")   # remove any you don't need
```

### Print and puzzle sizes

`cfg$print` and `cfg$puzzle` control paper size, DPI, and font sizes (inches / pt).
The defaults give a 12 × 8 in print and an 18.9 × 25.2 in jigsaw (5 670 × 7 560 px),
both at 300 dpi. Drop to `dpi = 200` on the puzzle if R runs short of memory.

### Subtitle layout (`cfg$puzzle$subtitle_layout`)

```r
subtitle_layout = "split"    # "split"  — text flanks the shape, left and right
                              # "bottom" — subtitle sits below the shape
```

### Shape (`cfg$puzzle$shape`)

```r
shape = list(
  type      = "heart",    # "filled" (whole page), "heart", or path to .xlsx/.csv/.image
  stretch   = TRUE,       # stretch to the page's proportions
  height    = 1.0,        # share of the space between title and bottom margin
  dip_round = 0.5,        # roundness of the heart's V notch (0 = sharp, 1 = shallow)
  tip_round = 0.1         # roundness of the bottom point (0 = sharp, 0.6 = blunt)
)
```

For a custom shape, point `type` at an `.xlsx` or `.csv` grid of 1s (birds) and
0s (empty), or a black-and-white image (black = bird area).

### Corner flourishes (`cfg$puzzle$corners`)

```r
corners = list(
  file     = here::here("data", "corner_images", "oak_leaf.jpg"),
  size_cm  = 7.7,        # longest side of each corner
  inset_cm = 1.9,        # gap from the page edge
  mirror   = TRUE,       # mirror into all four corners
  remove   = "colour",   # background removal: "colour", "flood", or "none"
  fuzz     = 15          # % colour-match tolerance; raise if a halo remains
)
```

Set `file = NA` for no corner decoration.

### Custom bird cut-outs (`data/custom_birds/`)

Drop your own transparent PNG or WEBP files into `data/custom_birds/` using the
naming convention `genus-species.png` (e.g. `melospiza-melodia.png`). The script
uses these in preference to the downloaded artwork. Run the script once first —
`output/vintage/missing_art.csv` lists species without pictures and suggests
save paths.

---

## Folder layout

```
commemorative-bird-collage/
├── code/
│   └── bird_collage.R                                # main script
├── data/
│   ├── ebird/
│   │   └── summary_2026-10-10_US-CA-097_county.csv  # example data (Sonoma Co., 10 Oct 2026)
│   ├── corner_images/
│   │   └── oak_leaf.jpg                              # corner decoration source
│   └── custom_birds/                                 # optional: add your own PNG/WEBP cut-outs
├── output/                                           # git-ignored; created on first run
│   └── vintage/
│       ├── sonoma_wedding_birds.png
│       ├── sonoma_wedding_puzzle.png
│       ├── sonoma_wedding_species_list.png
│       └── credits.txt
├── LICENSE
├── .gitignore
└── README.md
```

Artwork, fonts, and raw eBird checklist data are downloaded or generated at runtime
and are not stored in this repository.

---

## Credits and licences

The script downloads artwork from these sources at runtime — none is stored in
this repository.

| Asset | Source | Licence |
|---|---|---|
| Vintage bird plates | [fugleramme](https://github.com/arnegiacomo/fugleramme) — 1800s natural-history illustrations | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) |
| Kacho-e woodblock fill-ins | [AvianVisitors](https://github.com/Twarner491/AvianVisitors) | [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) — **non-commercial only** |
| Modern stickers | [huashu-bird-sticker](https://github.com/alchaincyf/huashu-bird-sticker) | [PolyForm Shield 1.0.0](https://polyformproject.org/licenses/shield/1.0.0/) — credit + link required; not for birding or bird-ID apps |
| Body-mass data | AVONET (Tobias et al. 2022, *Ecology Letters*) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Bird observation data | [eBird](https://ebird.org) | [eBird Data Access Terms](https://www.birds.cornell.edu/home/ebird-data-access-terms-of-use/) |

The packing and collage algorithm is ported from
[fugleramme](https://github.com/arnegiacomo/fugleramme) (MIT licence).

**Code licence:** MIT — see [LICENSE](LICENSE).
