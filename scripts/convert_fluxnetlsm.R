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
# Gapfilling defaults to "statistical" rather than FluxnetLSM's "ERAinterim"
# option: the Shuttle ships ERA5 reanalysis files (AMF_..._ERA5_HH_....csv /
# EUF_..._ERA5_HH_....csv), not the older ERA-Interim product FluxnetLSM's
# ERAinterim gapfill path expects -- untested compatibility, so statistical
# gapfilling is the safe default here. Pass --gapfill=erainterim
# --era-file=<path> to try ERA5 gapfilling if you've verified the column
# format matches.
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
site_code   <- parse_flag(args, "site")
infile      <- parse_flag(args, "infile")
out_path    <- parse_flag(args, "outdir", "fluxnetlsm_out")
gapfill     <- parse_flag(args, "gapfill", "statistical")
era_file    <- parse_flag(args, "era-file", NA)
min_years   <- as.integer(parse_flag(args, "min-years", "2"))
site_csv    <- parse_flag(args, "site-csv", NA)

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
if (identical(gapfill, "erainterim") && is.na(era_file)) {
  cat("ERROR: --gapfill=erainterim requires --era-file=PATH\n")
  quit(status = 2)
}

opts <- get_default_conversion_options()
opts$met_gapfill <- gapfill
opts$flux_gapfill <- gapfill
opts$min_yrs <- min_years

convert_args <- list(
  site_code = site_code,
  infile = infile,
  era_file = if (identical(gapfill, "erainterim")) era_file else NA,
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
