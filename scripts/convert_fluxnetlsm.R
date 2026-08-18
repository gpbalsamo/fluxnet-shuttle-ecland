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
# --preset: named bundle of FluxnetLSM's own acceptance thresholds
# (gapfill_met_tier1/2, missing_flux, min_yrs, check_range_action), tuned to
# trade off strictness against site/period coverage. Individually significant
# because tightening any of these can only ever *remove* candidate years
# (gapfilling always runs first, unconditionally -- the threshold only
# decides what gets written out -- see run_forcing_pipeline.sh's header), so
# for a *fixed* gapfill method, going from a stricter to a looser preset is a
# strict superset. check_range_action matters most in practice: FluxnetLSM's
# default "stop" aborts the ENTIRE site if even one implausible value occurs
# anywhere in the whole multi-year record (confirmed 2026-08-18: this alone
# killed SN-Dhr and US-ICt over a single bad PA/VPD value from an ERA5
# extraction edge case) -- "truncate" clips it to the valid range and keeps
# going instead. Explicit --min-years/--check-range-action still override
# the preset's value if given. Presets, and the matching post-hoc
# classification bands scripts/qc_classify.py applies to the real recorded
# Gap-filled_% once processing is done, are defined together below.
#
# Usage:
#   Rscript scripts/convert_fluxnetlsm.R \
#     --site=ES-LJu \
#     --infile=downloads/ES-LJu/EUF_ES-LJu_FLUXNET_FLUXMET_HH_2004-2024_v1.3_r1.csv \
#     --outdir=fluxnetlsm_out
#
#   Rscript scripts/convert_fluxnetlsm.R \
#     --site=SN-Dhr \
#     --infile=downloads/SN-Dhr/EUF_SN-Dhr_FLUXNET_FLUXMET_HH_2010-2022_v1.3_r1.csv \
#     --outdir=fluxnetlsm_out \
#     --era-file=downloads/SN-Dhr/EUF_SN-Dhr_FLUXNET_ERA5_HH_1981-2024_v1.3_r1.csv \
#     --gapfill=erainterim --preset=heavy --site-csv=reference/site_metadata_merged.csv

suppressMessages(library(FluxnetLSM))

# Acceptance-threshold presets. gapfill_met_tier1 covers Tair/SWdown/VPD/
# Precip/RH/Qair (FluxnetLSM's Essential_met==1 set); tier2 (LWdown/Psurf/
# Wind, Essential_met==2) is left permissive throughout since those are
# already lower-priority in FluxnetLSM's own schema. min_yrs is the min
# *consecutive* years required for a block to be written out at all (does
# NOT limit how many disjoint blocks a site can produce -- see
# run_forcing_pipeline.sh). check_range_action="stop" is FluxnetLSM's
# default and is the only setting that can lose an entire multi-year record
# over one bad value.
PRESETS <- list(
  mild     = list(gapfill_met_tier1 = 10, missing_flux = 20,  min_yrs = 2, check_range_action = "stop"),
  medium   = list(gapfill_met_tier1 = 25, missing_flux = 30,  min_yrs = 1, check_range_action = "warn"),
  heavy    = list(gapfill_met_tier1 = 50, missing_flux = 50,  min_yrs = 1, check_range_action = "truncate"),
  complete = list(gapfill_met_tier1 = 100, missing_flux = 100, min_yrs = 1, check_range_action = "truncate")
)

parse_flag <- function(args, name, default = NA) {
  pattern <- paste0("^--", name, "=")
  hit <- grep(pattern, args, value = TRUE)
  if (length(hit) == 0) return(default)
  sub(pattern, "", hit[1])
}

args <- commandArgs(trailingOnly = TRUE)
site_code     <- parse_flag(args, "site")
infile        <- parse_flag(args, "infile")
out_path      <- parse_flag(args, "outdir", "fluxnetlsm_out")
gapfill_arg   <- parse_flag(args, "gapfill", "statistical")
era_file      <- parse_flag(args, "era-file", NA)
preset_arg    <- parse_flag(args, "preset", "medium")
min_years_arg <- parse_flag(args, "min-years", NA)
range_arg     <- parse_flag(args, "check-range-action", NA)
site_csv      <- parse_flag(args, "site-csv", NA)

if (is.na(site_code) || is.na(infile)) {
  cat("Usage: Rscript convert_fluxnetlsm.R --site=SITE --infile=PATH.csv ",
      "[--outdir=DIR] [--gapfill=statistical|erainterim] [--era-file=PATH] ",
      "[--preset=mild|medium|heavy|complete] [--min-years=N] ",
      "[--check-range-action=stop|warn|truncate] [--site-csv=PATH]\n", sep = "")
  quit(status = 2)
}
if (!preset_arg %in% names(PRESETS)) {
  cat("ERROR: --preset must be one of:", paste(names(PRESETS), collapse = ", "), "\n")
  quit(status = 2)
}
preset <- PRESETS[[preset_arg]]
min_years <- if (!is.na(min_years_arg)) as.integer(min_years_arg) else preset$min_yrs
check_range_action <- if (!is.na(range_arg)) range_arg else preset$check_range_action
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
opts$gapfill_met_tier1 <- preset$gapfill_met_tier1
opts$missing_flux <- preset$missing_flux
opts$check_range_action <- check_range_action

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
