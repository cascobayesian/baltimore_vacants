# 30_maps.R — static PNG maps of the parcel index (Portland rent-control style).
# Run after 20_build_index.R:  Rscript scripts/30_maps.R
suppressPackageStartupMessages({library(sf); library(data.table); library(ggplot2)})
sf_use_s2(FALSE)
OUT <- "output"; FIG <- file.path(OUT, "maps"); dir.create(FIG, showWarnings = FALSE)
g <- st_read(file.path(OUT, "parcel_index.gpkg"), quiet = TRUE)
g <- g[!duplicated(g$geo_id), ]                       # one footprint per stacked condo building
CAT <- c(VACANT_BUILDING = "#c0392b", VACANT_LOT = "#eb6834", COMMUNITY_OPEN_SPACE = "#b8a51f",
         PARK = "#2e8b57", PROTECTED_GREENSPACE = "#0f5c3a", TRANSPORTATION = "#2a78d6", NOT_VACANT = "#e4e4e4")
LAB <- c(VACANT_BUILDING = "Vacant building", VACANT_LOT = "Vacant lot", COMMUNITY_OPEN_SPACE = "Community-managed open space",
         PARK = "Rec & Parks land", PROTECTED_GREENSPACE = "Baltimore Green Space protected", TRANSPORTATION = "Transportation land",
         NOT_VACANT = "No vacancy evidence")
g$category <- factor(g$category, levels = names(CAT))
g$alpha <- c(high = 1, medium = 0.65, low = 0.35)[g$certainty]
th <- theme_void(base_size = 11) + theme(legend.position = c(0.86, 0.2), plot.title = element_text(face = "bold"),
                                         plot.background = element_rect(fill = "white", colour = NA))
lines0 <- function() geom_sf(data = g[g$category == "NOT_VACANT", ], fill = CAT["NOT_VACANT"], colour = NA)
p1 <- ggplot() + lines0() +
  geom_sf(data = g[g$category != "NOT_VACANT", ], aes(fill = category, alpha = alpha), colour = NA) +
  scale_fill_manual(values = CAT, labels = LAB, drop = FALSE, name = NULL) + scale_alpha_identity() +
  labs(title = "Baltimore City parcels: vacancy and protected or public land",
       subtitle = "Shade = certainty (solid high, lighter medium, faint low). Sources and rules: output/sources.csv, rules.csv",
       caption = paste("Parcels:", format(nrow(g), big.mark = ","), "footprints. Built", Sys.Date())) + th
ggsave(file.path(FIG, "01_category_map.png"), p1, width = 11, height = 12, dpi = 200)

for (cc in c("VACANT_BUILDING", "VACANT_LOT")) {
  p <- ggplot() + geom_sf(data = g, fill = "#eeeeee", colour = NA) +
    geom_sf(data = g[g$category == cc, ], aes(fill = certainty), colour = NA) +
    scale_fill_manual(values = c(high = "#7f1d1d", medium = "#e0662f", low = "#f6c28b"), name = "Certainty") +
    labs(title = paste0(LAB[cc], "s by certainty"), subtitle = "Rules: output/rules.csv") + th
  ggsave(file.path(FIG, paste0("02_", tolower(cc), "_certainty.png")), p, width = 11, height = 12, dpi = 200)
}
p3 <- ggplot() + geom_sf(data = g, fill = "#eeeeee", colour = NA) +
  geom_sf(data = g[g$conflict_flag, ], fill = "#8e44ad", colour = NA) +
  labs(title = "Parcels where sources disagree", subtitle = "See conflict_note in output/parcel_index.csv") + th
ggsave(file.path(FIG, "03_conflicts.png"), p3, width = 11, height = 12, dpi = 200)
cat("maps written to", FIG, "\n")
