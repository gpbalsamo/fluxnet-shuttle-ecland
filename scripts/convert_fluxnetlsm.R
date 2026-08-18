#!/usr/bin/env Rscript
# Convert one site's downloaded fluxnet-shuttle FLUXMET CSV to ALMA-CF NetCDF
# via FluxnetLSM, producing Met/ and Flux/ files ready for
# scripts/regenerate_forcing.sh.
#
# Run scripts/install_fluxnetlsm.R first.
#
# Validated 2026-08-17 end-to-end on a real ES-LJu (ICOS) download: the
# output variables/dims are byte-identical to an existing PLUMBER2-170 Met
# file, and scripts/regenerate_forcing.sh converts the output to ecLand's
# forcing convention unmodified. Of ES-LJu's real 21-year record, only 2
# years survived PLUMBER2-style QC screening under statistical gapfilling --
# expect similar attrition on other Shuttle-sourced sites; this is a real
# finding about the expanded site pool, not a bug in this script.
#
# Gapfilling: --gapfill=erainterim (case-insensitive) uses FluxnetLSM's
# ERAinterim path against the Shuttle's ERA5 file. Confirmed 2026-08-18 this
# is actually fully compatible despite the ERA5-vs-ERA-Interim product-name
# difference: the Shuttle's *_ERA5_HH_*.csv columns (TA_ERA, SW_IN_ERA,
# LW_IN_ERA, VPD_ERA, PA_ERA, P_ERA, WS_ERA) are byte-identical to the
# ERAinterim_variable names FluxnetLSM's own Output_variables_FLUXNET2015_
# FULLSET.csv schema expects, and TIMESTAMP_START values/half-hour boundaries
# line up exactly for the exact-match join read_era() (Handlers_csv.R) does.
# Defaults to "statistical" only because it needs no extra --era-file arg.
# flux_gapfill is always forced to "statistical" (or NA) regardless of the
# met gapfill choice: FluxnetLSM only supports "statistical"/NA for flux
# variables (Qle/Qh/NEE aren't in the ERA5 file, there's no ERA fallback for
# them) -- passing "ERAinterim" through for flux_gapfill would be invalid.
#
# --site-csv: FluxnetLSM's own bundled Site_metadata.csv only covers ~874
# sites (mostly pre-2017) -- most Shuttle-only sites aren't in it, and
# FluxnetLSM silently proceeds with NA lat/lon/IGBP rather than erroring (see
# build_site_metadata.py's header). Pass the merged CSV from
# scripts/build_site_metadata.py here for any site outside the original
# FLUXNET2015 pool.
#
# Usage:
#   Rscript scripts/convert_fluxnetlsm.R \
#     --site=ES-LJu \
#     --infile=downloads/ES-LJu/EUF_ES-LJu_FLUXNET_FLUXMET_HH_2004-2024_v1.3_r1.csv \
#     --outdir=fluxnetlsm_out
#
#   Rscript scripts/convert_fluxnetlsm.R \
#     --site=ID-PaB \
#     --infile=downloads/ID-PaB/EUF_ID-PaB_FLUXNET_FLUXMET_HH_2004-2016_v1.3_r1.csv \
#     --outdir=fluxnetlsm_out \
#     --site-csv=reference/site_metadata_merged.csv \
#     --min-years=1

suppressMessages(library(FluxnetLSM))

parse_flag <- function(args, name, default = NA) {
  pattern <- paste0("^--", name, "=")
  hit <- grep(pattern, args, value = TRUE)
  if (length(hit) == 0) return(default)
  sub(pattern, "", hit[1])
}

args <- commandArgs(trailingOnly = TRUE)
site_code    <- parse_flag(args, "site")
infile       <- parse_flag(args, "infile")
out_path     <- parse_flag(args, "outdir", "fluxnetlsm_out")
gapfill_arg  <- parse_flag(args, "gapfill", "statistical")
era_file     <- parse_flag(args, "era-file", NA)
min_years    <- as.integer(parse_flag(args, "min-years", "2"))
site_csv     <- parse_flag(args, "site-csv", NA)

if (is.na(site_code) || is.na(infile)) {
  cat("Usage: Rscript convert_fluxnetlsm.R --site=SITE --infile=PATH.csv ",
      "[--outdir=DIR] [--gapfill=statistical|erainterim] [--era-file=PATH] ",
      "[--min-years=N] [--site-csv=PATH]\n", sep = "")
  quit(status = 2)
}
if (!is.na(site_csv) && !file.exists(site_csv)) {
  cat("ERROR: --site-csv not found:", site_csv, "\n")
  quit(status = 1)
}
if (!file.exists(infile)) {
  cat("ERROR: infile not found:", infile, "\n")
  quit(status = 1)
}

# FluxnetLSM's met_gapfill check is case-sensitive and expects the exact
# strings "ERAinterim"/"statistical" -- normalize case-insensitively here so
# --gapfill=erainterim (or any casing) resolves to what FluxnetLSM actually
# checks for, rather than silently failing its own "Cannot ascertain
# met_gapfill method" validation.
is_era <- identical(tolower(gapfill_arg), "erainterim")
met_gapfill <- if (is_era) "ERAinterim" else gapfill_arg

if (is_era && is.na(era_file)) {
  cat("ERROR: --gapfill=erainterim requires --era-file=PATH\n")
  quit(status = 2)
}

opts <- get_default_conversion_options()
opts$met_gapfill <- met_gapfill
opts$flux_gapfill <- if (is_era) "statistical" else met_gapfill
opts$min_yrs <- min_years

convert_args <- list(
  site_code = site_code,
  infile = infile,
  era_file = if (is_era) era_file else NA,
  out_path = out_path,
  conv_opts = opts,
  plot = NA
)
if (!is.na(site_csv)) {
  convert_args$site_csv_file <- site_csv
}

result <- tryCatch({
  do.call(convert_fluxnet_to_netcdf, convert_args)
}, error = function(e) {
  cat("ERROR:", conditionMessage(e), "\n")
  NULL
})

if (is.null(result)) {
  quit(status = 1)
}

cat("\nMet : ", result$met, "\n", sep = "")
cat("Flux: ", result$flux, "\n", sep = "")
