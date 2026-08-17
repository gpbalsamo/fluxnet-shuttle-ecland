#!/usr/bin/env Rscript
# Install FluxnetLSM (aukkola/FluxnetLSM) and its R dependencies.
#
# This is the exact recipe validated on 2026-08-17 against a fresh macOS/
# Homebrew R install (R 4.6.1). Three things needed a workaround that a plain
# `remotes::install_github("aukkola/FluxnetLSM")` will NOT hit on every
# platform, but did here -- kept as explicit steps rather than hidden inside
# a single install_github() call so a future failure is easier to diagnose:
#
#  1. `remotes::install_github()` calls the GitHub API directly
#     (api.github.com), which was rate-limited/blocked in this environment.
#     Worked around by `git clone`-ing the source and using
#     `remotes::install_local()` instead.
#
#  2. FluxnetLSM imports `lutz` (timezone-from-coordinates lookup, used only
#     for a cosmetic NetCDF `time_zone` attribute), which pulls in `sf`. On
#     this R 4.6.1/Homebrew/macOS toolchain, `sf` 1.1-2's source build
#     produces a broken, unparseable generated `R/init.R` (`CPL_gdal_init`
#     left as a bare symbol -- a real, reproducible sf/R-4.6.1 build bug,
#     unrelated to FluxnetLSM). Rather than chase that toolchain bug, this
#     script patches FluxnetLSM's two `lutz::tz_lookup_coords(...)` call
#     sites (in R/Handlers_NetCDF.R) with a `tryCatch(..., error=function(e)
#     "unknown")` wrapper before installing, so a missing/broken `sf` only
#     costs a cosmetic "unknown" time_zone attribute instead of aborting the
#     whole conversion.
#
#  3. `convert_fluxnet_to_netcdf()`'s documented `site_csv_file` argument is
#     dead code in FluxnetLSM 1.1: it's never forwarded to the internal
#     `get_site_metadata()` call (R/ConvertSpreadsheetToNcdf.R), so passing a
#     custom metadata CSV (e.g. scripts/build_site_metadata.py's merged
#     output, needed for any site outside FluxnetLSM's bundled ~874-site
#     table) silently has no effect -- confirmed 2026-08-17 by observing the
#     "Loading metadata... from csv_data cache" message still naming
#     FluxnetLSM's own packaged path regardless of --site-csv. This script
#     patches that one call site to actually forward site_csv_file through.
#
# System prerequisites (install separately, not handled by this script):
#   brew install r netcdf gdal
#
# Usage:
#   Rscript scripts/install_fluxnetlsm.R
#   Rscript scripts/install_fluxnetlsm.R --patch-lutz=false   # skip the sf/lutz patch,
#     e.g. if you've confirmed sf installs cleanly on your platform.

args <- commandArgs(trailingOnly = TRUE)
patch_lutz <- !("--patch-lutz=false" %in% args)

repos <- "https://cloud.r-project.org"

deps <- c("remotes", "ncdf4", "akima", "zoo", "R.utils", "lutz", "rvest", "jsonlite")
to_install <- deps[!deps %in% rownames(installed.packages())]
if (length(to_install) > 0) {
  cat("Installing R package dependencies:", paste(to_install, collapse = ", "), "\n")
  install.packages(to_install, repos = repos)
}

src_dir <- file.path(tempdir(), "FluxnetLSM_src")
if (dir.exists(src_dir)) unlink(src_dir, recursive = TRUE)

cat("Cloning aukkola/FluxnetLSM (plain git clone -- avoids the GitHub API "
    , "rate limit remotes::install_github() hits)...\n", sep = "")
status <- system2("git", c("clone", "--depth", "1",
                            "https://github.com/aukkola/FluxnetLSM.git", src_dir))
if (status != 0) stop("git clone of FluxnetLSM failed")

if (patch_lutz) {
  handlers_path <- file.path(src_dir, "R", "Handlers_NetCDF.R")
  content <- readLines(handlers_path)
  content <- gsub(
    'lutz::tz_lookup_coords(siteInfo$SiteLatitude, ',
    'tryCatch(lutz::tz_lookup_coords(siteInfo$SiteLatitude, ',
    content, fixed = TRUE
  )
  content <- gsub(
    'siteInfo$SiteLongitude, method="accurate"), prec="text")',
    'siteInfo$SiteLongitude, method="accurate"), error=function(e) "unknown"), prec="text")',
    content, fixed = TRUE
  )
  writeLines(content, handlers_path)
  cat("Patched lutz::tz_lookup_coords() call sites with a tryCatch fallback ",
      "(see script header for why).\n", sep = "")
}

# Fix #3: thread site_csv_file through to get_site_metadata() so a custom
# metadata CSV (--site-csv) actually takes effect.
convert_path <- file.path(src_dir, "R", "ConvertSpreadsheetToNcdf.R")
convert_content <- readLines(convert_path)
before <- sum(grepl(
  "site_info <- get_site_metadata(site_code, model=conv_opts$model)",
  convert_content, fixed = TRUE))
if (before != 1) {
  stop("Expected exactly 1 occurrence of the get_site_metadata() call site to patch, found ",
       before, " -- FluxnetLSM's source may have changed; update this script's patch.")
}
convert_content <- gsub(
  "site_info <- get_site_metadata(site_code, model=conv_opts$model)",
  "site_info <- get_site_metadata(site_code, model=conv_opts$model, site_csv_file=site_csv_file)",
  convert_content, fixed = TRUE
)
writeLines(convert_content, convert_path)
cat("Patched convert_fluxnet_to_netcdf() to forward site_csv_file to get_site_metadata() ",
    "(see script header for why).\n", sep = "")

cat("Installing FluxnetLSM from local source...\n")
remotes::install_local(src_dir, dependencies = FALSE, upgrade = "never", force = TRUE)

cat("\nDone. Verify with: Rscript -e 'library(FluxnetLSM); packageVersion(\"FluxnetLSM\")'\n")
