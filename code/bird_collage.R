# =============================================================================
# Sonoma wedding birds - a static "fugleramme" print
#
# 1. Downloads every eBird checklist from Sonoma County (US-CA-097) on the
#    wedding day (eBird API 2.0), and counts how many checklists (records)
#    reported each species.
# 2. Matches each species to a picture, in one of two styles:
#      "vintage" - hand-cut 1800s plates (fugleramme), with kacho-e woodblock
#                  birds (AvianVisitors) filling the gaps
#      "modern"  - illustrated stickers with a white outline
#                  (huashu-bird-sticker), matched by eBird species code
# 3. Ranks species by records and numbers them: pictured species 1..P, then the
#    species with no picture continue from P+1.
# 4. Renders a collage the way fugleramme does: birds sized by real body mass
#    (AVONET, compressed by mass^0.14), packed largest-first with no
#    overlapping silhouettes, on a textured paper page, a number under each
#    bird. Three outputs: a landscape print with a numbered key, a portrait
#    jigsaw puzzle, and a species-list card for the puzzle box.
#
# Ported from: https://github.com/arnegiacomo/fugleramme
#   src/fugleramme/render/collage.py  - sizing, shrink-to-fit search, labels
#   src/fugleramme/render/packing.py  - spiral / voids packers (FFT collision)
#   src/fugleramme/render/paper.py    - paper texture, halo toning, feathering
#   src/fugleramme/render/sizes.py    - mass weights, bird-box span ratio
#
# Licences: fugleramme plates CC BY-SA 4.0; AvianVisitors CC BY-NC-SA 4.0;
# huashu stickers PolyForm Shield 1.0.0 (credit + link required); body mass
# AVONET (Tobias et al. 2022, CC BY 4.0). The script writes a credits file for
# the back of the frame.
#
# Setup (once):
#   install.packages(c("here", "rebird", "magick", "jsonlite", "dplyr", "systemfonts", "ragg"))
#   (and "readxl" if your puzzle shape is an Excel file)
#   eBird API key goes in <project_dir>/ebird_api.txt (just the key on one line).
#
# Each art style writes to its own folder (output/vintage/, output/modern/).
# The species list is written to CSV before rendering, so you can drop birds,
# pick plate variants, or add your own cut-outs (see `custom_dir`) and re-render.
# =============================================================================

library(here)
library(magick)
library(jsonlite)
library(dplyr)

# ---- 0. Settings -------------------------------------------------------------
# Text sizes are in points (pt) on the printed page, distances in cm.

cfg <- list(
  # ---- The day ----
  wedding_date = "2026-10-10",
  region       = "US-CA-097",     # Sonoma County
  # "county": every checklist in the region.  "venue": only checklists within
  # radius_km of the venue.
  mode         = "county",
  venue        = c(lat = 38.2919, lng = -122.4580),
  radius_km    = 15,
  # How species are ranked (and so numbered): "checklists" (records reporting
  # it) or "individuals" (birds counted). Ties go to the other, then taxonomy.
  rank_by      = "checklists",

  # ---- The birds ----
  art          = "vintage",       # "vintage" (1800s plates) or "modern" (stickers)
  max_birds    = NA,              # NA = picture every species with art; else the top N
  labels       = "common",        # names in the key and list: "common" or "scientific"; "none" = no numbers or key
  layout       = "spiral",        # birds on a full page: "spiral" (round cluster) or "voids" (fills corners)
  halo_feather_cm = 0.15,         # vintage: how far the plates' paper ring fades into the page

  # ---- Wording ----
  title        = "Birds of Sonoma County",   # "" = no title
  subtitle     = NULL,            # NULL = the date and counts; your own text (use "\n" between lines); "" = none
  title_font   = "cormorant",     # title and subtitles

  # Fonts, wherever one is asked for below: a built-in period italic
  # ("playfair", "cormorant", "garamond", "baskerville", "gentium"), a Google
  # Fonts family name exactly as on fonts.google.com (downloaded into
  # data/fonts/ the first time), an installed font's name, or a .ttf/.otf path.

  outputs      = c("print", "puzzle", "list"),   # which of the three to make

  # ---- 1. Landscape print: numbers by the birds, a numbered key underneath ----
  print = list(
    width_in = 12, height_in = 8, dpi = 300,
    title_pt    = 29,
    subtitle_pt = 14,             # one line under the title
    number_font = "playfair",
    number_pt   = 11,             # the number under each bird
    key_font    = "gentium",      # the names in the key
    key_pt      = 7               # the key (numbers and names)
  ),

  # ---- 2. The jigsaw puzzle: portrait, numbers by the birds, no key ----
  puzzle = list(
    width_in = 18.9, height_in = 25.2, dpi = 300,   # 5670 x 7560 px; drop dpi to 200 if R runs short of memory
    title_pt    = 68,
    number_font = "Modern No. 20",                  # Office font, C:/Windows/Fonts/MOD20.TTF
    number_pt   = 24,

    # The date and counts at the foot of the page:
    #   "bottom": centred, the date with the counts beneath it
    #   "split":  the date bottom-left, the counts bottom-right, each block
    #             centre-justified, sitting just above the bottom corner
    #             flourishes (or subtitle_bottom_cm up if there are none)
    subtitle_layout    = "split",
    subtitle_pt        = 65,
    subtitle_bottom_cm = 2.5,     # "bottom": page's bottom edge to the baseline of the last line
    subtitle_side_cm   = 7.8,     # "split": left / right page edge to the centre of each block

    # Where the birds go. type: "filled" (the whole page), "heart", or the path
    # to your own shape - an .xlsx/.csv grid of 1s (birds) and 0s (empty), or a
    # black-and-white image (black = birds).
    shape = list(
      type      = "heart",
      stretch   = TRUE,           # TRUE: stretch to the page's proportions; FALSE: keep its own
      height    = 1.0,            # share of the space between the title and the bottom margin
      shift_cm  = 0,              # move the shape down (+) or up (-); stops at the edges
      dip_round = 0.5,            # heart: round the V between the lobes (0 sharp - 1 shallow)
      tip_round = 0.1             # heart: round the bottom point (0 sharp - 0.6 blunt)
    ),

    # Corner flourishes: the image for the TOP-LEFT corner, mirrored into the
    # other three. Its background is removed and the cut-out saved to
    # data/corners/ for checking. Birds are kept off them. file = NA: none.
    corners = list(
      file    = here::here("data", "corner_images", "oak_leaf.jpg"),
      size_cm  = 7.7,             # longest side
      inset_cm = 1.9,             # gap from the page edges
      mirror   = TRUE,            # FALSE: the same image, unflipped, in every corner
      # "colour": clear every pixel near the background colour (also between leaves)
      # "flood":  clear only background touching the image's edges
      # "none":   the image is already transparent
      remove   = "colour",
      fuzz     = 15               # % colour difference still counted as background; raise if a halo is left
    )
  ),

  # ---- 3. Species-list card for the puzzle box: every species, numbered ----
  # The list's type is sized automatically to fill the card. columns = "auto"
  # picks 1-4 for the largest type, or give a number.
  list_page = list(
    width_in = 8.5, height_in = 11, dpi = 300,
    title_pt    = 31,
    subtitle_pt = 15,
    font        = "Modern No. 20",   # numbers, names and counts
    columns     = "auto",
    counts      = TRUE               # show each species' count
  ),

  # Project folder (this script lives in code/)
  project_dir  = here::here(),
  key_file     = "ebird_api.txt"  # eBird API key, inside project_dir
)

cfg$art <- match.arg(cfg$art, c("vintage", "modern"))
cfg$puzzle$subtitle_layout <- match.arg(cfg$puzzle$subtitle_layout, c("bottom", "split"))
cfg$cache_dir  <- file.path(cfg$project_dir, "data", "art_cache")     # downloaded art, fonts, tables
cfg$custom_dir <- file.path(cfg$project_dir, "data", "custom_birds")  # your own <genus-species>.png cut-outs
cfg$out_dir    <- file.path(cfg$project_dir, "output", cfg$art)       # species lists, credits, the prints

if (is.na(cfg$wedding_date)) stop("Set cfg$wedding_date first, e.g. \"2026-09-19\".")
cfg$wedding_date <- as.Date(cfg$wedding_date)
dir.create(cfg$out_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(cfg$custom_dir, showWarnings = FALSE, recursive = TRUE)

# Art sources
REPOS <- c(
  fugleramme = "https://raw.githubusercontent.com/arnegiacomo/fugleramme/main/",
  # huashu-bird-sticker (github.com/alchaincyf/huashu-bird-sticker): a sticker
  # for nearly every living species, AI-drawn from reference photos.
  huashu     = "https://raw.githubusercontent.com/alchaincyf/huashu-bird-sticker/main/")
STYLE <- "assets/artwork/classic/"
# AvianVisitors (github.com/Twarner491/AvianVisitors): 666 cut-outs of 333
# North American species (perched + flight), AI-generated (Gemini) in an
# Edo-period kacho-e woodblock style. CC BY-NC-SA 4.0: credit it, no selling.
AV_REPO_RAW <- "https://raw.githubusercontent.com/Twarner491/AvianVisitors/main/"
AV_DIR      <- "avian/assets/illustrations/"   # <genus-species>.png perched, -2.png flight
AV_STAMPS   <- "https://theodore.net/assets/avian-stamps/illustrations/"   # <sci-slug>.webp

# Constants from the fugleramme render code
SIZE_EXPONENT <- 0.14                 # sizes.py: heaviest ~2.5x lightest
PAPER         <- c(242, 237, 226)     # paper.py TARGET_PAPER
INK           <- "#3b3229"
KEY_INK       <- "#8a7b68"            # paler ink for the dots, counts and subtitle
PACK_SHORT    <- 1200                 # collage.py: layout packed at this short side
MARGIN        <- 0.04                 # page edge, fraction of short side
MAX_SHARE     <- 0.7                  # most of the short side one plate may take
ATTEMPTS      <- 20                   # shrink steps of 0.9
REFINE        <- 3                    # bisection steps after the first fit
K             <- 6                    # packing.py: pack pixels per cell
ALPHA_CUTOFF  <- 24
SUB_LEAD      <- 1.35                 # line spacing of a multi-line subtitle, in ems
SPLIT_GAP_CM  <- 0.5                  # "split" subtitle: gap above the bottom flourishes

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a
pt_px <- function(pt, dpi) pt * dpi / 72
cm_px <- function(cm, dpi) (cm %||% 0) / 2.54 * dpi


# ---- 1. eBird: species seen that day ----------------------------------------

# Key from the project's key file; falls back to EBIRD_KEY in ~/.Renviron.
# Tolerates a bare key, a quoted key, or a line like "EBIRD_KEY=abc123".
read_key <- function(path) {
  if (!file.exists(path)) return("")
  txt <- trimws(readLines(path, warn = FALSE))
  txt <- txt[nzchar(txt)][1]
  if (is.na(txt)) return("")
  txt <- sub("^.*[=:]\\s*", "", txt)
  gsub("[\"' ]", "", txt)
}
ebird_key <- read_key(file.path(cfg$project_dir, cfg$key_file))
if (!nzchar(ebird_key)) ebird_key <- Sys.getenv("EBIRD_KEY")

# rebird returns slightly different column spellings across versions/endpoints;
# fold them to one set.
col_of <- function(df, ...) {
  nm <- tolower(gsub("[^A-Za-z]", "", names(df)))
  i  <- match(tolower(c(...)), nm)
  i  <- i[!is.na(i)][1]
  if (is.na(i)) rep(NA, nrow(df)) else df[[i]]
}

tidy_taxonomy <- function(tax) {
  data.frame(
    speciesCode = col_of(tax, "speciescode"),
    sciName     = col_of(tax, "sciname", "scientificname"),
    comName     = col_of(tax, "comname", "commonname"),
    category    = col_of(tax, "category"),
    taxonOrder  = suppressWarnings(as.numeric(col_of(tax, "taxonorder"))),
    reportAs    = col_of(tax, "reportas"),
    stringsAsFactors = FALSE
  )
}

haversine_km <- function(lat1, lng1, lat2, lng2) {
  rad <- pi / 180
  a <- sin((lat2 - lat1) * rad / 2)^2 +
       cos(lat1 * rad) * cos(lat2 * rad) * sin((lng2 - lng1) * rad / 2)^2
  6371 * 2 * asin(sqrt(pmin(1, a)))
}

# Every report -> its species: subspecies groups and forms roll up via reportAs;
# spuhs, slashes, hybrids and domestics have nothing to draw and drop out.
to_species <- function(codes, tax) {
  row    <- tax[match(codes, tax$speciesCode), ]
  parent <- ifelse(row$category %in% "species", row$speciesCode, row$reportAs)
  parent[!(parent %in% tax$speciesCode[tax$category %in% "species"])] <- NA
  parent
}

# Direct eBird API 2.0 call, cached as the raw JSON text under data/ebird/.
# (rebird's checklist parser drops the observations, so checklists, feeds and
# hotspots are read straight from the API; rebird still supplies the taxonomy.)
ebird_json <- function(path, cache, query = list()) {
  if (!file.exists(cache)) {
    q   <- c(query, key = ebird_key)
    u   <- paste0("https://api.ebird.org/v2/", path, "?",
                  paste(names(q), vapply(q, function(v) utils::URLencode(as.character(v), reserved = TRUE), ""),
                        sep = "=", collapse = "&"))
    con <- url(u, encoding = "UTF-8")
    txt <- paste(readLines(con, warn = FALSE), collapse = "\n")
    close(con)
    Sys.sleep(0.2)  # be polite to the API
    writeLines(txt, cache, useBytes = TRUE)
  }
  jsonlite::fromJSON(paste(readLines(cache, warn = FALSE, encoding = "UTF-8"), collapse = "\n"),
                     flatten = TRUE)
}

# The checklists submitted for one region or hotspot on the day (API max 200)
day_feed <- function(region, dir) {
  d <- cfg$wedding_date
  f <- ebird_json(sprintf("product/lists/%s/%s", region, format(d, "%Y/%m/%d")),
                  file.path(dir, paste0("feed_", region, ".json")), list(maxResults = 200))
  if (!length(f) || !NROW(f)) return(data.frame())
  data.frame(subId = col_of(f, "subid"),
             lat   = suppressWarnings(as.numeric(col_of(f, "loclat", "lat"))),
             lng   = suppressWarnings(as.numeric(col_of(f, "loclng", "lng"))),
             stringsAsFactors = FALSE)
}

# Every checklist for the day, one row per (checklist, report). Raw JSON is
# kept in data/ebird/<date>/, so each checklist is downloaded once, ever.
get_day_records <- function(cfg) {
  dir <- file.path(cfg$project_dir, "data", "ebird", format(cfg$wedding_date))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  near_venue <- function(lat, lng) cfg$mode != "venue" | is.na(lat) |
    haversine_km(cfg$venue[["lat"]], cfg$venue[["lng"]], lat, lng) <= cfg$radius_km

  feed <- day_feed(cfg$region, dir)

  # The county feed stops at 200. On a busy day (October Big Day, say), top it
  # up from each hotspot's own feed. Checklists at personal locations beyond
  # the 200 can't be reached this way, so the count is still a lower bound.
  if (nrow(feed) >= 200) {
    since <- as.numeric(Sys.Date() - cfg$wedding_date) + 1
    hs <- ebird_json(paste0("ref/hotspot/", cfg$region),
                     file.path(dir, "hotspots.json"),
                     c(list(fmt = "json"), if (since <= 30) list(back = since)))
    hs <- data.frame(locId = col_of(hs, "locid"),
                     lat = suppressWarnings(as.numeric(col_of(hs, "lat"))),
                     lng = suppressWarnings(as.numeric(col_of(hs, "lng"))),
                     stringsAsFactors = FALSE)
    hs <- hs[near_venue(hs$lat, hs$lng), ]
    message("County feed is capped at 200; checking ", nrow(hs), " hotspots for more ",
            "(first run only, then cached)...")
    extra <- lapply(hs$locId, function(id)
      tryCatch(day_feed(id, dir), error = function(e) data.frame()))
    feed <- bind_rows(feed, bind_rows(extra))
  }

  feed <- feed[!is.na(feed$subId) & near_venue(feed$lat, feed$lng), ]
  sub  <- unique(feed$subId)
  message(length(sub), " checklists on ", format(cfg$wedding_date, "%d %B %Y"))

  first_error <- NULL
  per_list <- lapply(sub, function(id) {
    ck <- tryCatch(ebird_json(paste0("product/checklist/view/", id), file.path(dir, paste0(id, ".json"))),
                   error = function(e) { if (is.null(first_error)) first_error <<- conditionMessage(e); NULL })
    obs <- ck$obs
    if (is.null(obs) || !NROW(obs)) return(NULL)
    # "X" (present, not counted) becomes NA: it still counts as a record
    data.frame(subId   = id,
               code    = col_of(obs, "speciescode"),
               howmany = suppressWarnings(as.numeric(col_of(obs, "howmanystr", "howmanyatmost", "howmany"))),
               stringsAsFactors = FALSE)
  })
  out <- bind_rows(per_list)
  if (!nrow(out)) stop("No observations could be read from ", length(sub), " checklists. ",
                       "First error: ", first_error %||% "none (checklists were empty)")
  if (!is.null(first_error)) warning("Some checklists failed to download, e.g.: ", first_error)
  out
}

# ---- Species summary: built once, then reused ----
# One row per species with its checklist and individual counts, saved as a CSV
# in data/ebird/. If it exists, the script reads it and skips eBird entirely.
# Delete it to rebuild, e.g. after late checklists come in. The file name
# records the date, region and area, so changing those builds a new one.
summary_file <- file.path(cfg$project_dir, "data", "ebird", sprintf(
  "summary_%s_%s_%s.csv", format(cfg$wedding_date), cfg$region,
  if (cfg$mode == "venue") sprintf("venue%gkm", cfg$radius_km) else "county"))

if (file.exists(summary_file)) {
  message("Using saved eBird summary: ", basename(summary_file))
} else {
  if (!nzchar(ebird_key)) stop("No eBird key found in ", cfg$key_file, " or EBIRD_KEY.")
  if (!requireNamespace("rebird", quietly = TRUE)) stop("Building the summary needs: install.packages(\"rebird\")")
  tax_file <- file.path(cfg$project_dir, "data", "ebird", "taxonomy.rds")
  if (!file.exists(tax_file)) {
    dir.create(dirname(tax_file), recursive = TRUE, showWarnings = FALSE)
    saveRDS(tidy_taxonomy(rebird::ebirdtaxonomy(key = ebird_key)), tax_file)
  }
  tax     <- readRDS(tax_file)
  records <- get_day_records(cfg) |>
    mutate(speciesCode = to_species(code, tax)) |>
    filter(!is.na(speciesCode))

  # A species reported twice on one checklist (e.g. two subspecies) is one
  # record there; its counts are added.
  built <- records |>
    group_by(speciesCode, subId) |>
    summarise(howmany = sum(howmany, na.rm = TRUE), .groups = "drop") |>
    group_by(speciesCode) |>
    summarise(checklists = n(), individuals = sum(howmany), .groups = "drop") |>
    left_join(tax[, c("speciesCode", "sciName", "comName", "taxonOrder")], by = "speciesCode") |>
    mutate(total_checklists = length(unique(records$subId))) |>   # day total
    arrange(taxonOrder)
  utils::write.csv(built, summary_file, row.names = FALSE)
  message("Saved eBird summary: ", basename(summary_file))
}

species <- utils::read.csv(summary_file, stringsAsFactors = FALSE) |>
  mutate(n = if (cfg$rank_by == "individuals") individuals else checklists)
message(nrow(species), " species on ", species$total_checklists[1], " checklists")


# ---- 2. Artwork, masses and fonts -------------------------------------------

# A file from one of the art repos, downloaded once into the cache
fetch <- function(path, repo = "fugleramme") {
  dest <- if (repo == "fugleramme") file.path(cfg$cache_dir, path) else file.path(cfg$cache_dir, repo, path)
  if (!file.exists(dest)) {
    dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
    utils::download.file(paste0(REPOS[[repo]], path), dest, mode = "wb", quiet = TRUE)
  }
  dest
}

# Download an image; NULL (and nothing left behind) if it isn't there or won't open
safe_download <- function(url, dest) {
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  ok <- file.exists(dest) || !inherits(try(suppressWarnings(        # a miss is expected, not a problem
    utils::download.file(url, dest, mode = "wb", quiet = TRUE)), silent = TRUE), "try-error")
  if (ok && !inherits(try(image_read(dest), silent = TRUE), "try-error")) return(dest)
  unlink(dest)
  NULL
}

aliases <- jsonlite::read_json(fetch("assets/birdnet_aliases.json"))   # legacy -> current names
masses  <- utils::read.csv(fetch("assets/bird_sizes.csv"), stringsAsFactors = FALSE)

# ---- Fonts ----
# Built-in names come from fugleramme's vendored fonts. Otherwise: a path, an
# installed font, one already in data/fonts/, or a Google Fonts download
# (systemfonts >= 1.2.0).
BUILTIN_FONTS <- c(
  playfair    = "assets/fonts/playfairdisplay/PlayfairDisplay-Italic.ttf",   # high-contrast Didone
  cormorant   = "assets/fonts/cormorantgaramond/CormorantGaramond-Italic.ttf",
  garamond    = "assets/fonts/ebgaramond/EBGaramond-Italic.ttf",
  baskerville = "assets/fonts/librebaskerville/LibreBaskerville-Italic.ttf",
  gentium     = "assets/fonts/gentiumbookplus/GentiumBookPlus-Italic.ttf")
FONT_DIR <- file.path(cfg$project_dir, "data", "fonts")

regular_of <- function(files) {        # prefer the upright regular file of a family
  files <- files[grepl("\\.(ttf|otf)$", files, ignore.case = TRUE)]
  pick  <- files[grepl("regular", basename(files), ignore.case = TRUE)]
  if (!length(pick)) pick <- files[!grepl("italic|bold|light|thin|black", basename(files), ignore.case = TRUE)]
  if (!length(pick)) pick <- files
  pick[1]
}

.fonts <- new.env()
get_font <- function(name) {
  if (!is.null(.fonts[[name]])) return(.fonts[[name]])
  path <- if (tolower(name) %in% names(BUILTIN_FONTS)) fetch(BUILTIN_FONTS[[tolower(name)]])
          else if (file.exists(name)) name
          else {
    sf  <- systemfonts::system_fonts()
    hit <- sf$path[tolower(sf$family) == tolower(name)]
    if (length(hit)) regular_of(hit) else {
      slug  <- tolower(gsub("[^A-Za-z0-9]", "", name))
      saved <- function() {
        f <- list.files(FONT_DIR, recursive = TRUE, full.names = TRUE)
        f[startsWith(tolower(gsub("[^A-Za-z0-9]", "", basename(f))), slug)]
      }
      if (!length(saved())) {
        dir.create(FONT_DIR, recursive = TRUE, showWarnings = FALSE)
        message("Downloading \"", name, "\" from Google Fonts...")
        tryCatch(systemfonts::get_from_google_fonts(name, dir = FONT_DIR), error = function(e) FALSE)
      }
      if (length(saved())) regular_of(saved()) else NA_character_
    }
  }
  if (is.na(path)) {
    warning("Couldn't find or download the font \"", name, "\". Check the name matches ",
            "fonts.google.com exactly. Using Playfair for now.")
    path <- fetch(BUILTIN_FONTS[["playfair"]])
  }
  assign(name, path, envir = .fonts)
  path
}
title_font <- get_font(cfg$title_font)

# names.py: "Turdus merula" -> "turdus-merula"; variants are "<key>-2.webp" etc.
shape_key <- function(sci) tolower(gsub("[\\s_]+", "-", trimws(sci), perl = TRUE))
alias_key <- setNames(shape_key(unlist(aliases)), shape_key(names(aliases)))
legacy_of <- setNames(names(alias_key), alias_key)
# A species' name key plus its older / newer names
keys_of   <- function(sci) { k <- shape_key(sci); unique(na.omit(c(k, alias_key[k], legacy_of[k]))) }

# Your own cut-outs in data/custom_birds/ (<genus-species>.png) beat everything
custom <- data.frame(path = list.files(cfg$custom_dir, "\\.(png|webp)$", full.names = TRUE),
                     stringsAsFactors = FALSE) |>
  mutate(key = sub("-\\d+$", "", sub("\\.(png|webp)$", "", basename(path))))

# ---- Vintage: fugleramme plates, AvianVisitors for the gaps ----
if (cfg$art == "vintage") {
  manifest <- jsonlite::read_json(fetch(paste0(STYLE, "manifest.json")))
  geometry <- jsonlite::read_json(fetch(paste0(STYLE, "geometry.json")))
  art_index <- data.frame(file = names(manifest), stringsAsFactors = FALSE) |>
    mutate(stem    = sub("\\.(webp|png)$", "", basename(file)),
           key     = sub("-\\d+$", "", stem),
           variant = ifelse(grepl("-\\d+$", stem),
                            suppressWarnings(as.integer(sub(".*-", "", stem))), 1L),
           source  = vapply(file, function(f) manifest[[f]]$source %||% NA_character_, ""),
           url     = vapply(file, function(f) manifest[[f]]$url %||% NA_character_, ""))
}

# Which plate each species wears. Defaults to the first variant; to change one,
# set e.g. variant_choice <- c("Turdus migratorius" = 2).
variant_choice <- c()

find_classic <- function(sci) {
  rows <- art_index[art_index$key %in% keys_of(sci), ]
  if (!nrow(rows)) return(NULL)
  want <- if (sci %in% names(variant_choice)) variant_choice[[sci]] else NA
  row  <- if (!is.na(want) && want %in% rows$variant) rows[rows$variant == want, ][1, ]
          else rows[order(rows$variant), ][1, ]
  list(file = row$file, path = NA, source = row$source, url = row$url, ref = NA)
}

# AvianVisitors: perched pose first, flight if that's all there is, then the
# project's static Atlas stamp
find_av <- function(sci) {
  for (key in keys_of(sci)) for (p in c("", "-2")) {
    file <- paste0(key, p, ".png")
    got  <- safe_download(paste0(AV_REPO_RAW, AV_DIR, file), file.path(cfg$cache_dir, "avianvisitors", file))
    if (!is.null(got)) return(list(file = NA, path = got, source = "avianvisitors", ref = NA,
                                   url = paste0("https://github.com/Twarner491/AvianVisitors/blob/main/", AV_DIR, file)))
  }
  k     <- shape_key(sci)
  stamp <- paste0(AV_STAMPS, k, ".webp")
  got   <- safe_download(stamp, file.path(cfg$cache_dir, "avianvisitors", paste0(k, "-stamp.webp")))
  if (!is.null(got)) return(list(file = NA, path = got, source = "avianvisitors", url = stamp, ref = NA))
  NULL
}

# ---- Modern: huashu stickers, matched by eBird code, then by name, then by former name ----
if (cfg$art == "modern") {
  stickers <- utils::read.csv(fetch("data/species.csv", "huashu"), stringsAsFactors = FALSE,
                              encoding = "UTF-8", na.strings = c("", "NA"))
  stickers <- stickers[!is.na(stickers$sticker_file), ]
  stickers$key  <- shape_key(stickers$scientific_name)
  # former (IOC) names, e.g. Western Willet's sticker was filed under Willet
  stickers$prev <- lapply(strsplit(ifelse(is.na(stickers$previous_ioc_ids), "", stickers$previous_ioc_ids),
                                   "[;|, ]+"), shape_key)
}

find_sticker <- function(code, sci) {
  i <- match(code, stickers$ebird)
  keys <- keys_of(sci)
  if (is.na(i)) i <- c(na.omit(match(keys, stickers$key)), NA)[1]
  if (is.na(i)) i <- c(which(vapply(stickers$prev, function(p) any(keys %in% p), TRUE)), NA)[1]
  if (is.na(i)) return(NULL)
  f   <- stickers$sticker_file[i]
  got <- safe_download(paste0(REPOS[["huashu"]], f), file.path(cfg$cache_dir, "huashu", f))
  if (is.null(got)) return(NULL)
  who <- stickers$reference_author[i]
  list(file = NA, path = got, source = "huashu",
       url  = paste0("https://github.com/alchaincyf/huashu-bird-sticker/blob/main/", f),
       ref  = paste0("drawn from ", if (is.na(who)) "a reference photo" else paste("a photo by", who),
                     if (!is.na(stickers$reference_page[i])) paste0(" (", stickers$reference_page[i], ")") else ""))
}

find_art <- function(code, sci) {
  hit <- custom[custom$key %in% keys_of(sci), ]
  if (nrow(hit)) return(list(file = NA, path = hit$path[1], source = "custom", url = NA, ref = NA))
  if (cfg$art == "modern") find_sticker(code, sci) else find_classic(sci) %||% find_av(sci)
}

message("Finding ", cfg$art, " art for ", nrow(species), " species (downloads are cached)...")
arts <- Map(find_art, species$speciesCode, species$sciName)
art_field <- function(field) vapply(arts, function(a) as.character(a[[field]] %||% NA), "")
species <- species |>
  mutate(has_art  = !vapply(arts, is.null, TRUE),
         art_file = art_field("file"), art_path = art_field("path"),
         source   = art_field("source"), url = art_field("url"), art_ref = art_field("ref"),
         mass_g   = masses$mass_g[match(sciName, masses$scientific_name)])

# ---- Rank and number ----
# Most-reported first (ties: the other count, then taxonomic order). The
# pictured species are numbered 1..P; every other species continues from P+1.
tiebreak <- if (cfg$rank_by == "individuals") species$checklists else species$individuals
species  <- species[order(-species$n, -tiebreak, species$taxonOrder), ]
species$pictured <- species$has_art
if (!is.na(cfg$max_birds))
  species$pictured <- species$has_art & cumsum(species$has_art) <= cfg$max_birds
species <- rbind(species[species$pictured, ], species[!species$pictured, ])
species$number <- seq_len(nrow(species))
species$list   <- ifelse(species$pictured, "pictured", "not pictured")

# Species with no picture: search links for hunting one down to cut yourself.
missing <- species |>
  filter(!has_art) |>
  transmute(comName, sciName,
            search = paste0("https://commons.wikimedia.org/w/index.php?title=Special:MediaSearch&type=image&search=",
                            utils::URLencode(paste(sciName, "Audubon"), reserved = TRUE)),
            save_as = file.path(cfg$custom_dir, paste0(shape_key(sciName), ".png")))

first_cols <- c("number", "list", "comName", "sciName", "checklists", "individuals")
utils::write.csv(species[, c(first_cols, setdiff(names(species), first_cols))],
                 file.path(cfg$out_dir, "species.csv"), row.names = FALSE)
utils::write.csv(missing, file.path(cfg$out_dir, "missing_art.csv"), row.names = FALSE)
message(sum(species$has_art), " of ", nrow(species), " species have a picture; ",
        "the rest are listed in output/", cfg$art, "/missing_art.csv")


# ---- 3. Image helpers --------------------------------------------------------

fftfreq <- function(n) { k <- 0:(n - 1); ifelse(k < ceiling(n / 2), k, k - n) / n }

# Alpha as a logical [row = y, col = x] matrix
alpha_matrix <- function(img) {
  d <- image_data(img, "rgba")
  t(matrix(as.integer(d[4, , ]), nrow = dim(d)[2]) > ALPHA_CUTOFF)
}

# Square (Chebyshev) dilation by r, separable
dilate_box <- function(m, r) {
  nr <- nrow(m); nc <- ncol(m); out <- m
  for (k in seq_len(min(r, nr - 1))) {
    out[(k + 1):nr, ] <- out[(k + 1):nr, ] | m[1:(nr - k), ]
    out[1:(nr - k), ] <- out[1:(nr - k), ] | m[(k + 1):nr, ]
  }
  m2 <- out
  for (k in seq_len(min(r, nc - 1))) {
    out[, (k + 1):nc] <- out[, (k + 1):nc] | m2[, 1:(nc - k)]
    out[, 1:(nc - k)] <- out[, 1:(nc - k)] | m2[, (k + 1):nc]
  }
  out
}

# paper.py paper_texture: soft clouds over faint grain, shaped in frequency
# space so the 512 tile repeats seamlessly. The page's grain as a 512 x 512
# tile of small integer offsets, [y, x]. Cached: the page and the paper rings
# round the plates share it, so a ring carries the texture of the page beneath.
.paper_noise <- NULL
paper_noise <- function(tile = 512, strength = 1.6, beta = 2, largest = 96) {
  if (!is.null(.paper_noise)) return(.paper_noise)
  set.seed(0)
  f      <- fftfreq(tile)
  gain   <- pmax(sqrt(outer(f^2, f^2, "+")), 1 / largest)^(-beta / 2)
  shaped <- Re(fft(fft(matrix(rnorm(tile^2), tile)) * gain, inverse = TRUE))
  .paper_noise <<- round(shaped * strength / sd(shaped))
  .paper_noise
}

paper_texture <- function(w, h, tile = 512) {
  noise  <- paper_noise(tile)
  arr    <- array(as.raw(0), c(3, tile, tile))
  for (ch in 1:3) arr[ch, , ] <- as.raw(t(pmin(255, pmax(0, PAPER[ch] + noise))))
  # Repeat the one tile in ImageMagick, so a 25-inch page never sits in R's memory
  one <- image_read(arr)
  row <- image_append(rep(one, ceiling(w / tile)))
  image_crop(image_append(rep(row, ceiling(h / tile)), stack = TRUE), sprintf("%dx%d+0+0", w, h))
}

# paper.py process_sprite (simplified): the vintage cut-outs keep a ring of
# scan paper. Shift that paper to the page's tone, snap the bright fringe at
# the cut, then feather the edge so the patch melts into the page. Returns a
# padded image. `halo = FALSE` is for clean cut-outs (AvianVisitors, stickers):
# no toning, only a hairline soften so the bird's own edge stays crisp.
# `at`: where the padded image's top-left lands on the page (px), so the paper
# ring and fringe take the page's own texture at that spot.
process_sprite <- function(img, feather, pad, halo = TRUE, at = NULL) {
  d <- image_data(img, "rgba")
  w <- dim(d)[2]; h <- dim(d)[3]
  ch <- lapply(1:4, function(i) matrix(as.integer(d[i, , ]), w, h))
  r <- ch[[1]]; g <- ch[[2]]; b <- ch[[3]]; a <- ch[[4]]

  if (halo) {
    opaque <- a > ALPHA_CUTOFF
    ring   <- opaque & dilate_box(!opaque, 4)
    paper  <- if (sum(ring) > 50) c(median(r[ring]), median(g[ring]), median(b[ring])) else PAPER
    mx <- pmax(r, g, b); mn <- pmin(r, g, b)
    dist <- pmax(abs(r - paper[1]), abs(g - paper[2]), abs(b - paper[3]))
    paper_px <- opaque & dist < 50 & (mx - mn) < 55 & mx > 160   # pale birds are safe
    delta <- PAPER - paper
    clamp <- function(x) pmin(255, pmax(0, round(x)))
    r[paper_px] <- clamp(r[paper_px] + delta[1])
    g[paper_px] <- clamp(g[paper_px] + delta[2])
    b[paper_px] <- clamp(b[paper_px] + delta[3])
    snap <- ring & paper_px
    r[snap] <- PAPER[1]; g[snap] <- PAPER[2]; b[snap] <- PAPER[3]
  } else {
    feather  <- 0.6
    paper_px <- matrix(FALSE, w, h)
  }

  W2 <- w + 2 * pad; H2 <- h + 2 * pad
  inx <- (pad + 1):(pad + w); iny <- (pad + 1):(pad + h)
  R <- matrix(PAPER[1], W2, H2); G <- matrix(PAPER[2], W2, H2); B <- matrix(PAPER[3], W2, H2)
  A <- matrix(0, W2, H2)
  R[inx, iny] <- r; G[inx, iny] <- g; B[inx, iny] <- b; A[inx, iny] <- a
  clear <- A <= ALPHA_CUTOFF                     # feather reveals paper, not old RGB
  R[clear] <- PAPER[1]; G[clear] <- PAPER[2]; B[clear] <- PAPER[3]

  if (!is.null(at)) {                            # page texture on the ring and fringe
    noise <- paper_noise(); tile <- nrow(noise)
    tex   <- t(noise[((at[2] + seq_len(H2) - 1) %% tile) + 1, ((at[1] + seq_len(W2) - 1) %% tile) + 1])
    pp    <- matrix(FALSE, W2, H2); pp[inx, iny] <- paper_px
    m     <- clear | pp
    R[m] <- pmin(255, pmax(0, R[m] + tex[m]))
    G[m] <- pmin(255, pmax(0, G[m] + tex[m]))
    B[m] <- pmin(255, pmax(0, B[m] + tex[m]))
  }

  aimg  <- image_read(array(as.raw(A), c(1, W2, H2)))
  ablur <- image_blur(aimg, radius = ceiling(3 * feather), sigma = feather)
  A2    <- matrix(as.integer(image_data(ablur, "gray")[1, , ]), W2, H2)

  out <- array(as.raw(0), c(4, W2, H2))
  out[1, , ] <- as.raw(R); out[2, , ] <- as.raw(G); out[3, , ] <- as.raw(B)
  out[4, , ] <- as.raw(A2)
  image_read(out)
}

# ---- Text: drawn with ragg + systemfonts from the exact font file ----
# magick's own text drawing takes a font *name* and can silently fall back to a
# default font when given a file (notably on Windows), so every string is
# rendered by ragg: the .ttf/.otf is registered with systemfonts under a
# private family name, drawn to a transparent image and composited onto the
# page. Sizes are in output px (an em); rendered strings are cached.

.font_fams <- new.env()
font_family <- function(path) {
  path <- normalizePath(path, winslash = "/", mustWork = TRUE)
  fam  <- .font_fams[[path]]
  if (is.null(fam)) {
    fam <- paste0("sonomafont", length(ls(.font_fams)) + 1)
    systemfonts::register_font(fam, plain = path)
    assign(path, fam, envir = .font_fams)
  }
  fam
}

.text_cache <- new.env()
# One string as a transparent image, with where its baseline origin sits
# (ox, oy, px from the top-left) and its ink bounds (l, r, t, b).
text_img <- function(txt, font, size, colour = "black") {
  size <- max(1, round(size))
  id   <- paste(txt, font, size, colour, sep = "\r")
  hit  <- .text_cache[[id]]
  if (!is.null(hit)) return(hit)
  w  <- ceiling(size * (1.3 * nchar(txt) + 3)); h <- ceiling(size * 2.4)
  ox <- size; oy <- round(1.6 * size)
  cap <- ragg::agg_capture(width = w, height = h, units = "px", res = 72, background = "transparent")
  grid::grid.text(txt, x = grid::unit(ox, "bigpts"), y = grid::unit(h - oy, "bigpts"),
                  just = c("left", "bottom"),
                  gp = grid::gpar(fontfamily = font_family(font), fontsize = size, col = colour))
  ras <- cap(native = FALSE)
  grDevices::dev.off()
  img <- image_read(ras)
  a   <- image_data(img, "rgba")[4, , ]                 # alpha, [x, y]
  ink_x <- which(apply(a != as.raw(0), 1, any)); ink_y <- which(apply(a != as.raw(0), 2, any))
  out <- list(img = img, ox = ox, oy = oy,
              l = if (length(ink_x)) min(ink_x) - 1 else ox, r = if (length(ink_x)) max(ink_x) else ox,
              t = if (length(ink_y)) min(ink_y) - 1 else oy, b = if (length(ink_y)) max(ink_y) else oy)
  assign(id, out, envir = .text_cache)
  out
}

# Draw `txt` with its baseline at y_base. align "left": the ink starts at x;
# "right": the ink ends at x; "center": the ink is centred on x.
draw_text <- function(canvas, txt, font, size, colour, x, y_base, align = "left") {
  if (!nzchar(txt)) return(canvas)
  t  <- text_img(txt, font, size, colour)
  x0 <- switch(align, center = x - (t$l + t$r) / 2, right = x - t$r, x - t$l)
  image_composite(canvas, t$img, operator = "over",
                  offset = sprintf("%+d%+d", round(x0), round(y_base - t$oy)))
}

# Ink width and height of a string at `size` px
measure_text <- function(txt, font, size = 100) {
  t <- text_img(txt, font, size)
  c(w = t$r - t$l, h = t$b - t$t)
}

# A font's cap height per 100 px: how far below a line's top its baseline sits
baseline_of <- function(font) measure_text("H", font)[["h"]]

# Mirror or not, decided by the name alone (collage.py _flip)
flip_of <- function(name) { u <- utf8ToInt(name); sum(u * seq_along(u)) %% 2 == 1 }


# ---- 4. Load the birds to draw -----------------------------------------------

draw <- species[species$pictured, ]
labels_on <- cfg$labels != "none"

load_bird <- function(row) {
  path <- if (!is.na(row$art_path)) row$art_path else fetch(paste0(STYLE, row$art_file))
  full <- image_trim(image_read(path))
  info <- image_info(full)
  # sizes.py span_ratio: how much bigger the plate is than the bird on it, from
  # the hand-drawn bird box - only valid if it was drawn on this exact crop.
  ratio <- 1
  geo <- if (!is.na(row$art_file)) geometry[[row$art_file]] else NULL
  if (!is.null(geo) && geo$cut[[1]] == info$width && geo$cut[[2]] == info$height) {
    bx   <- unlist(geo$box)
    span <- max((bx[3] - bx[1]) * info$width, (bx[4] - bx[2]) * info$height)
    if (span > 0) ratio <- max(info$width, info$height) / span
  }
  # Only a small copy stays in memory, for packing; the full picture is read
  # again from `path` when the bird is drawn.
  list(key = shape_key(row$sciName), name = row$sciName, path = path,
       label = if (labels_on) as.character(row$number) else "",
       master = image_resize(full, "900x900>"),
       ratio = ratio, flip = flip_of(row$sciName),
       halo = !(row$source %in% c("avianvisitors", "huashu")),   # only the scanned plates have a paper ring
       mass = ifelse(is.na(row$mass_g), median(masses$mass_g), row$mass_g))
}

message("Loading ", nrow(draw), " pictures...")
birds <- lapply(seq_len(nrow(draw)), function(i) load_bird(draw[i, ]))


# ---- 5. Packing (packing.py) -------------------------------------------------
# Collision tests are cross-correlations: one FFT gives the overlap of a sprite
# with the occupied page at every offset at once. Work on a grid of K-pixel
# cells; max-pooling can only over-report a collision, never miss one.

pool <- function(m) {
  out <- matrix(0, ceiling(nrow(m) / K), ceiling(ncol(m) / K))
  idx <- which(m, arr.ind = TRUE)
  out[cbind((idx[, 1] - 1) %/% K + 1, (idx[, 2] - 1) %/% K + 1)] <- 1
  out
}

xcorr <- function(field, FM) Re(fft(fft(field) * FM, inverse = TRUE)) / length(field)

# allowed: the cells birds may use (a shape), or NULL for the whole board.
# Emptiness is measured as a share of the *allowed* paper nearby, so a narrow
# part of a shape (the heart's point) scores as empty as the middle and gets
# filled, instead of looking half-full because of the forbidden paper round it.
make_board <- function(H, W, sigma = 8, allowed = NULL) {
  pad <- ceiling(3 * sigma) + 1
  P   <- matrix(0, H + 2 * pad, W + 2 * pad)
  gy  <- fftfreq(nrow(P)); gx <- fftfreq(ncol(P))
  gauss <- exp(-2 * (pi * sigma)^2 * outer(gy^2, gx^2, "+"))
  smooth <- function(f) Re(fft(fft(f) * gauss, inverse = TRUE)) / length(f)
  iy <- (pad + 1):(pad + H); ix <- (pad + 1):(pad + W)
  page <- P; page[iy, ix] <- if (is.null(allowed)) 1 else allowed * 1
  share <- pmax(smooth(page)[iy, ix], 1e-6)
  list(
    # how empty the paper is around each cell, padded so edges do not wrap
    emptiness = function(occ) { f <- P; f[iy, ix] <- !occ; smooth(f)[iy, ix] / share },
    # free cells touching something solid; the page edge counts too
    halo = function(occ) {
      e <- matrix(TRUE, H + 2, W + 2); e[2:(H + 1), 2:(W + 1)] <- occ
      d <- e[2:(H + 1), 2:(W + 1)] | e[1:H, 2:(W + 1)] | e[3:(H + 2), 2:(W + 1)] |
           e[2:(H + 1), 1:W] | e[2:(H + 1), 3:(W + 2)]
      (d & !occ) * 1
    }
  )
}

# `blocked`: cells no bird may cover (outside the heart), or NULL for none.
# Birds are pulled toward the middle of the free area, not of the page.
pack <- function(masks, H, W, layout, blocked = NULL) {
  occ   <- if (is.null(blocked)) matrix(FALSE, H, W) else blocked
  free  <- which(!occ, arr.ind = TRUE)
  cy    <- mean(free[, 1]) - 0.5; cx <- mean(free[, 2]) - 0.5
  board <- if (layout == "voids") make_board(H, W, allowed = if (is.null(blocked)) NULL else !blocked) else NULL
  pos   <- matrix(NA_integer_, length(masks), 2, dimnames = list(NULL, c("x", "y")))
  for (i in seq_along(masks)) {
    m <- masks[[i]]; h <- nrow(m); w <- ncol(m)
    if (h > H || w > W) return(NULL)
    M <- matrix(0, H, W); M[1:h, 1:w] <- m
    FM <- Conj(fft(M))
    ok <- xcorr(occ * 1, FM) < 0.5
    if (h > 1) ok[(H - h + 2):H, ] <- FALSE        # no running off the page
    if (w > 1) ok[, (W - w + 2):W] <- FALSE
    if (!any(ok)) return(NULL)
    dist <- sqrt(outer((0:(H - 1)) + h / 2 - cy, rep(1, W))^2 +
                 outer(rep(1, H), (0:(W - 1)) + w / 2 - cx)^2)
    cost <- if (layout == "voids") {
      area <- max(1, sum(m))
      -xcorr(board$emptiness(occ), FM) / area - 0.8 * xcorr(board$halo(occ), FM) / sqrt(area) + 0.02 * dist
    } else dist                                     # spiral: nearest the middle wins
    cost[!ok] <- Inf
    k <- which.min(cost); y <- (k - 1) %% H + 1; x <- (k - 1) %/% H + 1
    occ[y:(y + h - 1), x:(x + w - 1)] <- occ[y:(y + h - 1), x:(x + w - 1)] | (m > 0)
    pos[i, ] <- c(x, y)
  }
  pos
}

# collage.py _with_label: join a bird and its number into one footprint, the
# number centred under the body and raised until it clears the outline.
with_label <- function(art, lw, lh, gap) {
  ah <- nrow(art); aw <- ncol(art)
  centre <- sum((seq_len(aw) - 1) * colSums(art)) / max(1, sum(art))
  offset <- round(centre - lw / 2)
  left   <- min(0, offset)
  width  <- max(aw, offset + lw) - left
  ax <- -left; lx <- offset - left
  c0 <- max(1, lx - ax + 1); c1 <- min(aw, lx - ax + lw)
  rows <- if (c1 >= c0) which(rowSums(art[, c0:c1, drop = FALSE]) > 0) else integer(0)
  top  <- (if (length(rows)) max(rows) else ah) + gap
  mask <- matrix(FALSE, max(ah, top + lh), width)
  mask[1:ah, (ax + 1):(ax + aw)] <- art
  mask[(top + 1):(top + lh), (lx + 1):(lx + lw)] <- TRUE
  list(mask = mask, art_at = c(ax, 0), label_at = c(lx, top), lw = lw)
}

mask_cache <- new.env()
art_mask <- function(b, dim) {
  id <- paste(b$key, dim)
  if (!is.null(mask_cache[[id]])) return(mask_cache[[id]])
  img <- image_resize(b$master, sprintf("%dx%d", dim, dim))
  if (b$flip) img <- image_flop(img)
  mask_cache[[id]] <- alpha_matrix(img)
}


# ---- 6. Title, subtitle and key ----------------------------------------------

has_title    <- function() !is.null(cfg$title) && nzchar(cfg$title)
has_subtitle <- function() is.null(cfg$subtitle) || nzchar(cfg$subtitle)

# The subtitle's lines for each placement. Default: the date and the counts
# (every bird counted on every checklist; an "X" adds none). Your own
# cfg$subtitle is split at "\n": "top" joins the lines with a middle dot,
# "bottom" stacks them, "split" puts the first line on the left and the rest
# on the right.
subtitle_text <- function(where = "top") {
  date  <- trimws(format(cfg$wedding_date, "%e %B %Y"))
  birds <- sprintf("%s birds", format(sum(species$individuals, na.rm = TRUE), big.mark = ","))
  spp   <- sprintf("%d species", nrow(species))
  own   <- if (is.null(cfg$subtitle)) NULL else strsplit(cfg$subtitle, "\n", fixed = TRUE)[[1]]
  lines <- own %||% c(date, paste0(birds, ", ", spp))
  switch(where,
    top    = paste(lines, collapse = "  \u00b7  "),
    bottom = lines,
    split  = if (is.null(own)) list(left = date, right = c(birds, spp))
             else list(left = own[1], right = own[-1]))
}

# Height of the title block (output px): the title, plus the subtitle under it
title_block_px <- function(page, with_sub) {
  (if (has_title()) 1.5 * pt_px(page$title_pt, page$dpi) else 0) +
    (if (with_sub && has_subtitle()) 1.4 * pt_px(page$subtitle_pt, page$dpi) else 0)
}

# The title, centred, its top `y` px from the top; with_sub: the one-line
# subtitle under it.
draw_title <- function(canvas, page, y, with_sub = TRUE) {
  tsize <- pt_px(page$title_pt, page$dpi)
  ssize <- pt_px(page$subtitle_pt, page$dpi)
  cap   <- baseline_of(title_font) / 100
  if (has_title())
    canvas <- draw_text(canvas, cfg$title, title_font, tsize, INK, page$W / 2, y + cap * tsize, align = "center")
  if (with_sub && has_subtitle())
    canvas <- draw_text(canvas, subtitle_text("top"), title_font, ssize, KEY_INK, page$W / 2,
                        y + (if (has_title()) 1.2 * tsize else 0) + cap * ssize, align = "center")
  canvas
}

# The puzzle's subtitle at the foot of the page, one row per line: text, x,
# baseline y, size (output px), all centre-justified.
subtitle_plan <- function(page, cut) {
  W <- page$W; H <- page$H; dpi <- page$dpi
  size  <- pt_px(page$subtitle_pt, dpi)
  stack <- function(ln, x, base)       # lines upward from the last baseline
    data.frame(text = ln, x = x, y = base - (length(ln) - seq_along(ln)) * SUB_LEAD * size,
               size = size, stringsAsFactors = FALSE)
  if (page$subtitle_layout == "bottom")
    return(stack(subtitle_text("bottom"), W / 2, H - cm_px(page$subtitle_bottom_cm, dpi)))

  # split: the lowest baselines just above the bottom flourishes
  txt  <- subtitle_text("split")
  base <- if (is.null(cut)) H - cm_px(page$subtitle_bottom_cm, dpi) else {
    cl <- corner_layout(cut, page)
    min(cl$xy[3, 2], cl$xy[4, 2]) - cm_px(SPLIT_GAP_CM, dpi) - 0.3 * size   # 0.3 em for descenders
  }
  side <- cm_px(page$subtitle_side_cm, dpi)
  rbind(stack(txt$left, side, base), if (length(txt$right)) stack(txt$right, W - side, base))
}

# The key: one centred paragraph under the birds, pictured species in number
# order, wrapped into centred lines.
#   1 Anna's Hummingbird · 2 California Scrub-Jay · 3 Acorn Woodpecker · ...
DOT <- "\u00b7"

key_layout <- function(page, avail_w) {
  nf <- page$number_font; tf <- page$key_font
  size <- pt_px(page$key_pt, page$dpi); k <- size / 100      # widths measured at size 100
  ent <- data.frame(num  = as.character(draw$number),
                    name = if (cfg$labels == "scientific") draw$sciName else draw$comName,
                    stringsAsFactors = FALSE)
  ent$num_w  <- vapply(ent$num,  function(t) measure_text(t, nf)[["w"]], 0)
  ent$name_w <- vapply(ent$name, function(t) measure_text(t, tf)[["w"]], 0)
  num_gap <- 0.3 * size; dot_pad <- 0.55 * size
  dot_w   <- measure_text(DOT, tf)[["w"]] * k
  sep_w   <- dot_w + 2 * dot_pad
  tok_w   <- ent$num_w * k + num_gap + ent$name_w * k

  # Greedy wrap: start a new line when the next species would overflow
  lines <- list(); cur <- integer(0); cur_w <- 0
  for (i in seq_len(nrow(ent))) {
    add <- if (length(cur)) sep_w + tok_w[i] else tok_w[i]
    if (length(cur) && cur_w + add > avail_w) {
      lines[[length(lines) + 1]] <- cur; cur <- i; cur_w <- tok_w[i]
    } else { cur <- c(cur, i); cur_w <- cur_w + add }
  }
  if (length(cur)) lines[[length(lines) + 1]] <- cur
  lead <- 1.55 * size
  key  <- list(size = size, k = k, lead = lead, num_gap = num_gap, dot_w = dot_w, dot_pad = dot_pad,
               lines = lines, ent = ent, height = length(lines) * lead,
               line_w = vapply(lines, function(ix) sum(tok_w[ix]) + (length(ix) - 1) * sep_w, 0))
  if (key$height > 0.3 * page$H)
    warning(sprintf("The key takes %.0f%% of the page height; a smaller print$key_pt leaves the birds more room.",
                    100 * key$height / page$H))
  key
}

draw_key <- function(canvas, key, page, top) {
  ent  <- key$ent; nf <- page$number_font; tf <- page$key_font
  base <- max(baseline_of(nf), baseline_of(tf)) * key$k     # every font on the same baseline
  for (li in seq_along(key$lines)) {
    ix <- key$lines[[li]]
    x  <- (page$W - key$line_w[li]) / 2
    yb <- top + (li - 1) * key$lead + base
    for (j in seq_along(ix)) {
      i <- ix[j]
      canvas <- draw_text(canvas, ent$num[i], nf, key$size, INK, x, yb)
      x <- x + ent$num_w[i] * key$k + key$num_gap
      canvas <- draw_text(canvas, ent$name[i], tf, key$size, INK, x, yb)
      x <- x + ent$name_w[i] * key$k
      if (j < length(ix)) {
        x <- x + key$dot_pad
        canvas <- draw_text(canvas, DOT, tf, key$size, KEY_INK, x, yb)
        x <- x + key$dot_w + key$dot_pad
      }
    }
  }
  canvas
}


# ---- 7. Shapes and corner flourishes -----------------------------------------

# The classic heart curve, x = 16 sin^3 t, y = 13 cos t - 5 cos 2t - 2 cos 3t
# - cos 4t (two round lobes, a dip between them, a sharp point), scaled to fill
# an H x W grid and centred. Returns TRUE for cells inside the heart.
heart_mask <- function(H, W, sh) {
  t  <- seq(0, 2 * pi, length.out = 1441)
  x  <- 16 * sin(t)^3
  y  <- 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
  sx <- W / diff(range(x)); sy <- H / diff(range(y))
  if (!isTRUE(sh$stretch)) sx <- sy <- min(sx, sy)              # keep the heart's own proportions
  px <- (x - mean(range(x))) * sx + W / 2
  py <- (max(y) - y) * sy + (H - diff(range(y)) * sy) / 2      # lobes up, point down
  n  <- length(px)
  x1 <- px[-n]; y1 <- py[-n]; x2 <- px[-1]; y2 <- py[-1]
  inside <- matrix(FALSE, H, W)
  for (r in seq_len(H)) {                  # scanline fill through each cell row's middle
    yc    <- r - 0.5
    cross <- (y1 <= yc & y2 > yc) | (y2 <= yc & y1 > yc)
    if (sum(cross) < 2) next
    xs <- sort(x1[cross] + (yc - y1[cross]) * (x2[cross] - x1[cross]) / (y2[cross] - y1[cross]))
    for (j in seq(1, length(xs) - 1, by = 2)) {
      c0 <- max(1, ceiling(xs[j] + 0.5)); c1 <- min(W, floor(xs[j + 1] + 0.5))
      if (c1 >= c0) inside[r, c0:c1] <- TRUE
    }
  }
  inside <- round_dips(inside, round((sh$dip_round %||% 0) * 0.12 * min(H, W)))
  round_tips(inside, round((sh$tip_round %||% 0) * 0.12 * min(H, W)))
}

# Grow a mask by r cells with a near-round brush (alternating square and cross
# steps make an octagon).
grow_oct <- function(x, r) {
  for (i in seq_len(r)) {
    if (i %% 2) x <- dilate_box(x, 1) else {
      y <- x; n <- nrow(x); k <- ncol(x)
      y[-1, ] <- y[-1, ] | x[-n, ]; y[-n, ] <- y[-n, ] | x[-1, ]
      y[, -1] <- y[, -1] | x[, -k]; y[, -k] <- y[, -k] | x[, -1]
      x <- y
    }
  }
  x
}

# Pad by r empty cells, apply f, crop back, so the page edge acts like empty paper
with_pad <- function(m, r, f) {
  p <- matrix(FALSE, nrow(m) + 2 * r, ncol(m) + 2 * r)
  p[r + seq_len(nrow(m)), r + seq_len(ncol(m))] <- m
  f(p)[r + seq_len(nrow(m)), r + seq_len(ncol(m))]
}

# Closing (grow, then shrink back): fills inward-pointing corners like the
# heart's top V, leaving outward points and smooth curves as they were.
round_dips <- function(m, r) {
  if (r < 1) return(m)
  with_pad(m, r, function(p) !grow_oct(!grow_oct(p, r), r))
}

# Opening (shrink, then grow back): rounds outward points like the heart's
# bottom tip to a curve of radius r, leaving inward corners and gentle curves.
round_tips <- function(m, r) {
  if (r < 1) return(m)
  with_pad(m, r, function(p) grow_oct(!grow_oct(!p, r), r))
}

# Your own shape: an .xlsx/.csv grid of 1s and 0s, or an image (black = birds),
# scaled to the H x W grid by nearest neighbour. With stretch = FALSE it keeps
# its own proportions and is centred.
shape_mask <- function(path, H, W, stretch = TRUE) {
  ext <- tolower(tools::file_ext(path))
  m <- switch(ext,
    xlsx = , xls = {
      if (!requireNamespace("readxl", quietly = TRUE)) stop("Reading Excel needs: install.packages(\"readxl\")")
      as.matrix(readxl::read_excel(path, col_names = FALSE, .name_repair = "minimal"))
    },
    csv  = as.matrix(utils::read.csv(path, header = FALSE)),
    {                                     # an image: dark pixels are birds
      img <- image_convert(image_flatten(image_background(image_read(path), "white")), colorspace = "gray")
      d   <- image_data(img, "gray")[1, , ]
      t(matrix(as.integer(d), nrow = dim(d)[1]) < 128)
    })
  m <- matrix(suppressWarnings(as.numeric(m)), nrow(m)) > 0.5
  m[is.na(m)] <- FALSE
  if (!any(m)) stop("The shape file ", basename(path), " has no 1s (or black pixels) in it.")
  m <- m[which(rowSums(m) > 0), which(colSums(m) > 0), drop = FALSE]   # trim empty edges
  nr <- nrow(m); nc <- ncol(m)
  sy <- H / nr; sx <- W / nc
  if (!stretch) sx <- sy <- min(sx, sy)
  out <- matrix(FALSE, H, W)
  h <- floor(nr * sy); w <- floor(nc * sx)
  r0 <- (H - h) %/% 2; c0 <- (W - w) %/% 2
  ri <- pmin(nr, floor((seq_len(h) - 0.5) / sy) + 1)
  ci <- pmin(nc, floor((seq_len(w) - 0.5) / sx) + 1)
  out[r0 + seq_len(h), c0 + seq_len(w)] <- m[ri, ci]
  out
}

# Background removal for the corner image. The background colour is sampled
# from the image's four corners (median of a small patch at each).
cut_corner <- function(cn) {
  img <- image_convert(image_read(cn$file), matte = TRUE)
  if (cn$remove != "none") {
    i  <- image_info(img); w <- i$width; h <- i$height
    d  <- image_data(img, "rgb")
    p  <- 5                                          # patch size, px
    xs <- c(seq_len(p), w - p + seq_len(p)); ys <- c(seq_len(p), h - p + seq_len(p))
    bg <- vapply(1:3, function(ch) median(as.integer(d[ch, xs, ys])), 0)
    bg <- rgb(bg[1], bg[2], bg[3], maxColorValue = 255)
    if (cn$remove == "flood") {
      for (pt in list(c(0, 0), c(w - 1, 0), c(0, h - 1), c(w - 1, h - 1)))
        img <- image_fill(img, "none", point = sprintf("+%d+%d", pt[1], pt[2]), fuzz = cn$fuzz)
    } else {
      img <- image_transparent(img, bg, fuzz = cn$fuzz)
    }
    message("Corner background removed (", bg, ", fuzz ", cn$fuzz, "%)")
  }
  img <- image_trim(img)
  saved <- file.path(cfg$project_dir, "data", "corners",
                     paste0(tools::file_path_sans_ext(basename(cn$file)), "_cutout.png"))
  dir.create(dirname(saved), recursive = TRUE, showWarnings = FALSE)
  image_write(img, saved, format = "png")
  message("Corner cut-out saved for checking: ", saved)
  img
}

# The four oriented pieces and their top-left positions on the page. `scale`
# maps output px to the grid wanted (1 = output; 1/s = pack pixels).
corner_layout <- function(cut, page, scale = 1) {
  cn    <- page$corners
  size  <- round(cm_px(cn$size_cm, page$dpi) * scale)
  inset <- round(cm_px(cn$inset_cm, page$dpi) * scale)
  W <- round(page$W * scale); H <- round(page$H * scale)
  piece <- image_resize(cut, sprintf("%dx%d", size, size), filter = "Lanczos")
  i <- image_info(piece); w <- i$width; h <- i$height
  imgs <- if (isTRUE(cn$mirror))
    list(piece, image_flop(piece), image_flip(piece), image_flip(image_flop(piece))) else rep(list(piece), 4)
  xy <- rbind(c(inset, inset), c(W - w - inset, inset),
              c(inset, H - h - inset), c(W - w - inset, H - h - inset))
  list(imgs = imgs, xy = round(xy))
}


# ---- 8. The collage (collage.py _placements / _layout) -----------------------

# `page` carries the page size (W, H px, dpi) and the text settings; the
# puzzle's page also has subtitle_layout, shape and corners. The print has a
# key (page$key) and its subtitle under the title.
render_collage <- function(birds, out_file, page) {
  W <- page$W; H <- page$H; dpi <- page$dpi
  shape   <- page$shape$type %||% "filled"
  layout  <- if (shape == "filled") cfg$layout else "voids"   # voids hugs a shape's edge
  if (!(shape %in% c("filled", "heart")) && !file.exists(shape))
    stop("shape$type must be \"filled\", \"heart\" or the path to a shape file; can't find ", shape)
  corners <- !is.null(page$corners) && !is.na(page$corners$file %||% NA)
  if (corners && !file.exists(page$corners$file)) stop("Corner image not found: ", page$corners$file)
  cut <- if (corners) cut_corner(page$corners) else NULL

  names_on <- labels_on
  nf <- page$number_font
  ref_h <- measure_text("0123456789", nf)[["h"]]
  for (i in seq_along(birds)) birds[[i]]$text_w <- measure_text(birds[[i]]$label, nf)[["w"]]

  # The layout is packed on a small page (short side PACK_SHORT), s times smaller
  pack_h <- PACK_SHORT; pack_w <- round(PACK_SHORT * W / H)
  if (W < H) { pack_w <- PACK_SHORT; pack_h <- round(PACK_SHORT * H / W) }
  short <- PACK_SHORT
  s     <- min(W, H) / short
  mpx   <- round(MARGIN * short)

  # Page, top to bottom: margin, title, birds, key, margin
  bottom_sub <- !is.null(page$subtitle_layout) && has_subtitle()
  sub_plan   <- if (bottom_sub) subtitle_plan(page, cut) else NULL
  cap_t      <- baseline_of(title_font) / 100
  key        <- if (names_on && isTRUE(page$key)) key_layout(page, W - 2 * mpx * s) else NULL
  key_gap    <- round(0.03 * short)
  key_h      <- if (is.null(key)) 0 else ceiling(key$height / s) + key_gap
  top        <- mpx + ceiling(title_block_px(page, with_sub = !bottom_sub) / s)
  bottom     <- pack_h - mpx - key_h
  # A full page stops above a centred bottom subtitle; a shape's area runs on
  # to the bottom margin (birds are only kept off the lettering, below).
  if (bottom_sub && shape == "filled" && page$subtitle_layout == "bottom")
    bottom <- min(bottom, floor(min(sub_plan$y - cap_t * sub_plan$size) / s) - round(0.02 * short))
  box_w <- pack_w - 2 * mpx
  box_h <- bottom - top
  if (box_h < 0.3 * pack_h) stop("The title, key and subtitle leave too little room for the birds; make their text smaller.")
  Wc <- ceiling(box_w / K); Hc <- ceiling(box_h / K)

  # The shape: built at a fixed height (shape$height of the area), centred,
  # then slid by shift_cm - its size and outline never change with the shift.
  blocked <- NULL
  if (shape != "filled") {
    sh   <- page$shape
    Hh   <- max(10, min(Hc, round(Hc * (sh$height %||% 1))))
    inside <- if (shape == "heart") heart_mask(Hh, Wc, sh) else shape_mask(shape, Hh, Wc, isTRUE(sh$stretch))
    want <- round((Hc - Hh) / 2 + cm_px(sh$shift_cm, dpi) / s / K)   # top row, before clamping
    y0   <- min(max(0, want), Hc - Hh)
    if (y0 != want) message("shape$shift_cm reached the edge of the shape's space; the shape stops there.")
    full <- matrix(FALSE, Hc, Wc)
    full[y0 + seq_len(Hh), ] <- inside
    blocked <- !full
  }

  # Keep birds off the corner flourishes: their silhouettes, at pack scale,
  # mapped into the bird box's cells and grown by one cell for a little air.
  if (corners) {
    cl   <- corner_layout(cut, page, scale = 1 / s)
    pg   <- matrix(FALSE, pack_h, pack_w)
    for (q in 1:4) {
      a  <- alpha_matrix(cl$imgs[[q]])
      ys <- cl$xy[q, 2] + seq_len(nrow(a)); xs <- cl$xy[q, 1] + seq_len(ncol(a))
      ok_y <- ys >= 1 & ys <= pack_h; ok_x <- xs >= 1 & xs <= pack_w
      pg[ys[ok_y], xs[ok_x]] <- pg[ys[ok_y], xs[ok_x]] | a[ok_y, ok_x]
    }
    box  <- pg[top + seq_len(min(box_h, pack_h - top)), mpx + seq_len(min(box_w, pack_w - mpx)), drop = FALSE]
    cov  <- pool(box) > 0
    cov2 <- matrix(FALSE, Hc, Wc)
    nr <- seq_len(min(Hc, nrow(cov))); nc <- seq_len(min(Wc, ncol(cov)))
    cov2[nr, nc] <- cov[nr, nc]
    cov2 <- dilate_box(cov2, 1)
    blocked <- if (is.null(blocked)) cov2 else blocked | cov2
  }

  # Keep birds off the bottom subtitle's lettering, with a little air round it
  if (!is.null(sub_plan)) {
    if (is.null(blocked)) blocked <- matrix(FALSE, Hc, Wc)
    for (i in seq_len(nrow(sub_plan))) {
      p   <- sub_plan[i, ]
      w   <- measure_text(p$text, title_font, p$size)[["w"]]
      pad <- 0.4 * p$size
      x0p <- (p$x - w / 2 - pad) / s;           x1p <- (p$x + w / 2 + pad) / s
      y0p <- (p$y - cap_t * p$size - pad) / s;  y1p <- (p$y + 0.3 * p$size + pad) / s
      r0 <- max(1, floor((y0p - top) / K) + 1); r1 <- min(Hc, ceiling((y1p - top) / K))
      c0 <- max(1, floor((x0p - mpx) / K) + 1); c1 <- min(Wc, ceiling((x1p - mpx) / K))
      if (r1 >= r0 && c1 >= c0) blocked[r0:r1, c0:c1] <- TRUE
    }
  }
  share <- if (is.null(blocked)) 1 else mean(!blocked)   # of the box the birds may use

  # Mass weights centred on the set's geometric mean, times the box span ratio
  m   <- vapply(birds, `[[`, 0, "mass")
  wts <- (m / exp(mean(log(m))))^SIZE_EXPONENT * vapply(birds, `[[`, 0, "ratio")
  order <- order(-wts)
  base  <- min(sqrt(pack_w * pack_h * share * 1.5 / sum(wts^2)), short * MAX_SHARE / max(wts))
  label_out <- pt_px(page$number_pt, dpi)     # number size, output px (fixed; birds shrink to fit)
  label_px  <- label_out / s                  # ... in pack px

  attempt <- function(shrink, with_names) {
    gap <- round(label_px * 0.35)
    sprites <- lapply(order, function(i) {
      dim <- max(24L, as.integer(base * shrink * wts[i]))
      art <- art_mask(birds[[i]], dim)
      s <- if (with_names && nzchar(birds[[i]]$label))
             with_label(art, ceiling(birds[[i]]$text_w * label_px / 100), ceiling(ref_h * label_px / 100), gap)
           else list(mask = art, art_at = c(0, 0), label_at = NULL, lw = 0)
      s$index <- i; s$dim <- dim; s$cells <- pool(s$mask); s
    })
    pos <- pack(lapply(sprites, `[[`, "cells"), Hc, Wc, layout, blocked)
    if (is.null(pos)) return(NULL)
    # centre the packed cluster's bounding box in the box (a heart is already
    # centred, and shifting it would push birds over its edge)
    if (is.null(blocked)) {
      x1 <- max(pos[, "x"] + vapply(sprites, function(s) ncol(s$cells), 0) - 1)
      y1 <- max(pos[, "y"] + vapply(sprites, function(s) nrow(s$cells), 0) - 1)
      pos[, "x"] <- pos[, "x"] + floor((Wc - (x1 - min(pos[, "x"]) + 1)) / 2) - (min(pos[, "x"]) - 1)
      pos[, "y"] <- pos[, "y"] + floor((Hc - (y1 - min(pos[, "y"]) + 1)) / 2) - (min(pos[, "y"]) - 1)
    }
    list(sprites = sprites, pos = pos)
  }

  search <- function(with_names) {
    fit <- NULL; failed <- NULL; shrink <- 1
    for (step in 0:(ATTEMPTS - 1)) {
      shrink <- 0.9^step
      fit <- attempt(shrink, with_names)
      if (!is.null(fit)) break
      failed <- shrink
    }
    if (is.null(fit) || is.null(failed)) return(fit)
    small <- shrink; large <- failed      # bisect back toward the size that failed
    # a shape gets extra steps: its birds end up as large as the outline allows
    for (r in seq_len(if (is.null(blocked)) REFINE else REFINE + 3)) {
      mid <- (small + large) / 2
      got <- attempt(mid, with_names)
      if (is.null(got)) large <- mid else { fit <- got; small <- mid }
    }
    fit
  }

  message("Packing ", length(birds), " birds (", layout, ")...")
  fit <- search(names_on)
  if (is.null(fit) && names_on) { warning("No layout fits with numbers; drawing without."); fit <- search(FALSE) }
  if (is.null(fit)) stop("Could not fit the birds on the page.")

  # ---- draw at output resolution ----
  feather <- cm_px(cfg$halo_feather_cm %||% 0.15, dpi)   # blur of the paper ring's edge, px
  pad     <- ceiling(3 * feather) + 2
  canvas  <- paper_texture(W, H)

  message("Drawing...")
  for (j in seq_along(fit$sprites)) {
    sp <- fit$sprites[[j]]; b <- birds[[sp$index]]
    ox <- mpx + (fit$pos[j, "x"] - 1) * K
    oy <- top + (fit$pos[j, "y"] - 1) * K
    tgt <- round(sp$dim * s)
    img <- image_resize(image_trim(image_read(b$path)), sprintf("%dx%d", tgt, tgt), filter = "Lanczos")
    if (b$flip) img <- image_flop(img)
    at  <- c(round((ox + sp$art_at[1]) * s) - pad, round((oy + sp$art_at[2]) * s) - pad)
    img <- process_sprite(img, feather, pad, halo = b$halo, at = at)
    canvas <- image_composite(canvas, img, operator = "over", offset = sprintf("%+d%+d", at[1], at[2]))
    if (j %% 10 == 0) invisible(gc())     # free the earlier canvases ImageMagick is still holding
    if (!is.null(sp$label_at))
      # baseline = top of the reserved box + the numerals' height
      canvas <- draw_text(canvas, b$label, nf, label_out, INK, (ox + sp$label_at[1] + sp$lw / 2) * s,
                          (oy + sp$label_at[2]) * s + ref_h * label_out / 100, align = "center")
  }

  if (corners) {
    cl <- corner_layout(cut, page)
    for (q in 1:4) {
      at     <- cl$xy[q, ] - 2
      piece  <- process_sprite(cl$imgs[[q]], 0.6, 2, halo = FALSE, at = at)   # hairline soften of the cut
      canvas <- image_composite(canvas, piece, operator = "over", offset = sprintf("%+d%+d", at[1], at[2]))
    }
  }

  if (!is.null(key)) canvas <- draw_key(canvas, key, page, (top + box_h + key_gap) * s)

  canvas <- draw_title(canvas, page, round(mpx * s), with_sub = !bottom_sub)
  for (i in seq_len(NROW(sub_plan)))
    canvas <- draw_text(canvas, sub_plan$text[i], title_font, sub_plan$size[i], KEY_INK,
                        sub_plan$x[i], sub_plan$y[i], align = "center")

  image_write(canvas, out_file, format = "png", density = sprintf("%dx%d", dpi, dpi))
  message("Wrote ", out_file)
  invisible(canvas)
}


# ---- 9. Companion page: the full species list --------------------------------
# Same paper, title and fonts as the print. Two sections, "Pictured" and "Also
# recorded", each in number order, set in columns (top-to-bottom, then across)
# that share one grid so the sections line up. Each name is followed by its
# count (checklists or individuals, per cfg$rank_by) in paler ink. The type is
# the largest size at which everything fits the page.

LIST_HEADS <- c(pictured = "Pictured", "not pictured" = "Also recorded")

render_species_list <- function(species, out_file, page) {
  W <- page$W; H <- page$H; dpi <- page$dpi; short <- min(W, H)
  font    <- page$font
  margin  <- round(MARGIN * short)
  title_h <- title_block_px(page, with_sub = TRUE) + (if (has_title()) round(0.02 * short) else 0)
  avail_w <- W - 2 * margin
  avail_h <- H - 2 * margin - title_h

  ent <- data.frame(list  = species$list,
                    num   = as.character(species$number),
                    name  = if (cfg$labels == "scientific") species$sciName else species$comName,
                    count = if (isTRUE(page$counts)) as.character(species$n) else "",
                    stringsAsFactors = FALSE)
  message("Measuring the species list...")
  ent$num_w   <- vapply(ent$num,   function(t) measure_text(t, font)[["w"]], 0)
  ent$name_w  <- vapply(ent$name,  function(t) measure_text(t, font)[["w"]], 0)
  ent$count_w <- vapply(ent$count, function(t) if (nzchar(t)) measure_text(t, font)[["w"]] else 0, 0)
  groups <- split(ent, factor(ent$list, levels = names(LIST_HEADS)))
  groups <- groups[vapply(groups, nrow, 0) > 0]

  # Columns and type size, chosen together: for each column count, the largest
  # size at which the widest entry fits its column and every section fits the
  # page height at tight leading. "auto" keeps whichever count gives the
  # largest type (fewer columns on a tie); a number forces that count.
  sep    <- function(lead) (length(groups) - 1) * 1.2 * lead   # space between sections
  widest <- max(max(ent$num_w) + 0.4 * 100 + ent$name_w +
                ifelse(ent$count_w > 0, 1.2 * 0.4 * 100 + ent$count_w, 0))   # at size 100
  fits <- function(nc, size) {
    rows <- vapply(groups, function(g) ceiling(nrow(g) / nc), 0)
    nc * (widest * size / 100 + 2.5 * size) - 2.5 * size <= avail_w &&
      length(groups) * 2.4 * size + sum(rows) * 1.3 * size + sep(1.3 * size) <= avail_h
  }
  opt  <- page$columns %||% "auto"
  cand <- if (identical(opt, "auto")) 1:4 else as.integer(opt)
  sizes <- seq(0.10, 0.006, by = -0.0005) * short
  best  <- c(ncol = cand[1], size = min(sizes))
  for (nc in cand) {
    ok <- sizes[vapply(sizes, function(sz) fits(nc, sz), TRUE)]
    if (length(ok) && max(ok) > best[["size"]] + 1e-9) best <- c(ncol = nc, size = max(ok))
  }
  ncol <- best[["ncol"]]; size <- best[["size"]]
  if (!fits(ncol, size)) warning("The species list is too long for the page; raise list_page$height_in.")
  message(sprintf("Species list: %d columns, %.1f pt", ncol, size * 72 / dpi))

  k       <- size / 100
  head_h  <- 2.4 * size                       # section heading plus space below it
  num_col <- max(ent$num_w) * k
  gap     <- 0.4 * size
  gutter  <- 2.5 * size
  rows    <- vapply(groups, function(g) ceiling(nrow(g) / ncol), 0)

  # Fill the page: open the leading until the lists reach the bottom margin
  # (capped, so a short list doesn't float apart), and spread the columns
  # across the full width.
  lead   <- min((avail_h - length(groups) * head_h) / (sum(rows) + 1.2 * (length(groups) - 1)),
                2.4 * size)
  lead   <- max(lead, 1.3 * size)
  height <- length(groups) * head_h + sum(rows) * lead + sep(lead)
  col_w  <- (avail_w + gutter) / ncol

  canvas <- paper_texture(W, H)
  canvas <- draw_title(canvas, page, margin)

  base    <- baseline_of(font) * k
  block_w <- ncol * col_w - gutter
  x0 <- (W - block_w) / 2
  y  <- margin + title_h + (avail_h - height) / 2       # centre the block vertically
  for (g in names(groups)) {
    e <- groups[[g]]
    canvas <- draw_text(canvas, LIST_HEADS[[g]], font, 1.5 * size, INK, W / 2, y + 1.5 * base, align = "center")
    y  <- y + head_h
    nr <- ceiling(nrow(e) / ncol)
    for (i in seq_len(nrow(e))) {
      col <- (i - 1) %/% nr; row <- (i - 1) %% nr
      x  <- x0 + col * col_w
      yb <- y + row * lead + base
      canvas <- draw_text(canvas, e$num[i], font, size, INK, x + num_col - e$num_w[i] * k, yb)
      nx <- x + num_col + gap
      canvas <- draw_text(canvas, e$name[i], font, size, INK, nx, yb)
      if (nzchar(e$count[i]))
        canvas <- draw_text(canvas, e$count[i], font, size, KEY_INK, nx + e$name_w[i] * k + 1.2 * gap, yb)
    }
    y <- y + nr * lead + 1.2 * lead
  }

  image_write(canvas, out_file, format = "png", density = sprintf("%dx%d", dpi, dpi))
  message("Wrote ", out_file)
  invisible(canvas)
}


# ---- 10. Run -----------------------------------------------------------------

# A page from its settings: pixel size, and font names turned into files
page_of <- function(p, ...) {
  p$W <- round(p$width_in * p$dpi); p$H <- round(p$height_in * p$dpi)
  for (f in intersect(c("number_font", "key_font", "font"), names(p))) p[[f]] <- get_font(p[[f]])
  utils::modifyList(p, list(...))
}
out <- function(name) file.path(cfg$out_dir, paste0("sonoma_wedding_", name, ".png"))

# 1. Landscape print: numbers by the birds, the names key underneath
if ("print" %in% cfg$outputs)
  render_collage(birds, out("birds"), page_of(cfg$print, key = TRUE))

# 2. The jigsaw puzzle: portrait, numbers only, the subtitle at the foot
if ("puzzle" %in% cfg$outputs) {
  pz <- page_of(cfg$puzzle, key = FALSE)
  message("Puzzle: ", pz$width_in, " x ", pz$height_in, " in at ", pz$dpi, " dpi (", pz$W, " x ", pz$H, " px)")
  render_collage(birds, out("puzzle"), pz)
}

# 3. The species-list card for the puzzle box: every species, pictured and also recorded
if ("list" %in% cfg$outputs)
  render_species_list(species, out("species_list"), page_of(cfg$list_page))

# Credits for the back of the frame
credits <- draw |> transmute(comName, sciName, source, picture = url, reference = art_ref)
utils::write.csv(credits, file.path(cfg$out_dir, "credits.csv"), row.names = FALSE)
src <- unique(draw$source)
writeLines(c(
  sprintf("Birds reported in Sonoma County on %s, from eBird (ebird.org).",
          trimws(format(cfg$wedding_date, "%e %B %Y"))),
  if (any(!(src %in% c("avianvisitors", "huashu", "custom"))))
    c("Illustrations: hand-coloured 1800s plates cut by the fugleramme project",
      "(github.com/arnegiacomo/fugleramme), CC BY-SA 4.0. Per-plate sources in credits.csv."),
  if ("avianvisitors" %in% src)
    c("Kacho-e style illustrations: AvianVisitors by Teddy Warner (github.com/Twarner491/AvianVisitors),",
      "AI-generated with Gemini, CC BY-NC-SA 4.0 (non-commercial)."),
  if ("huashu" %in% src)
    c("Bird stickers: huashu-bird-sticker by Huashu (https://github.com/alchaincyf/huashu-bird-sticker),",
      "AI-drawn from reference photos, PolyForm Shield 1.0.0. Per-sticker references in credits.csv."),
  "Body mass: AVONET (Tobias et al. 2022, Ecology Letters), CC BY 4.0."
), file.path(cfg$out_dir, "credits.txt"))