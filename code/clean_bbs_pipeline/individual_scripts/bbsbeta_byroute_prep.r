# Beta-diversity calculation for breeding bird survey data
# Run in parallel on HPCC (array job with a different radius for each task)
# QDR, 07 Mar 2017
# Project: NASABioXGeo

# Forked version created in aqua repo on 31 Jan 2018: Pool the same years (2001-2011) as are used for everything else. Also get rid of by stop stuff because it is so big.
# Delete everything else that is unnecessary.

# 1. Define community either as aggregated route or by stop

# Start with by-stop diversity.

# 2. Load community matrix.

bbsspp <- read.csv('/mnt/research/aquaxterra/DATA/raw_data/bird_traits/specieslist.csv', stringsAsFactors = FALSE)
load('/mnt/research/aquaxterra/DATA/raw_data/BBS/bbsmatconsolidated2016.r') # Load fixed bbsmat. This loads both byroute and bystop.
# Quick correction to fix two birds that aren't in the phylogeny. Just get rid of the eastern yellow wagtail since it's probably only in Alaska anyway.
fixedbbsmat_byroute[, which(sppids == 5739)] <- fixedbbsmat_byroute[, which(sppids == 5738)] + fixedbbsmat_byroute[, which(sppids == 5739)]
fixedbbsmat_byroute[, which(sppids == 5738)] <- 0
fixedbbsmat_byroute[, which(sppids == 6960)] <- 0

# 3. Project lat-long to Albers.

bbsalbers <- read.csv('/mnt/research/nasabio/data/bbs/bbs_correct_route_centroids.csv')

# 4. Create cophenetic distance matrix from bird phylogeny. Use consensus tree calculatd from 1000 trees randomly sampled from the posterior distribution of 10000 trees.
# (Update 22 sep 2017)

library(ape)
eric_cons_tree <- read.tree('/mnt/research/nasabio/data/bbs/ericson_cons.tre')
ericdist <- cophenetic(eric_cons_tree)

# 5. Create trait distance matrix (Gower) from bird traits.

birdtrait <- read.csv('/mnt/research/aquaxterra/DATA/raw_data/bird_traits/birdtraitmerged.csv', stringsAsFactors = FALSE)

library(FD)

birdtrait[birdtrait == -999] <- NA
nocturnalbirdAOUs <- birdtrait$AOU[birdtrait$Nocturnal == 1]
birdtrait_diurnal <- subset(birdtrait, Nocturnal != 1 | is.na(Nocturnal))
traitnames <- names(birdtrait)[c(15:24, 29:36, 46:50, 53, 55:59)]

birdtraitdist <- as.matrix(gowdis(birdtrait_diurnal[, traitnames]))
dimnames(birdtraitdist)[[1]] <- dimnames(birdtraitdist)[[2]] <- birdtrait_diurnal$Latin_Name

# 5b. Perform any last data cleaning that is necessary.

# Remove stops that don't have coordinates from the dataset.
# Here check why some of the coordinates are missing.

library(dplyr)

bbsgrps_byroute <- bbsgrps_byroute %>% mutate(rteNo=as.numeric(rteNo)) %>% left_join(bbsalbers, by = 'rteNo')
has_coords <- !is.na(bbsgrps_byroute$lon)

# Set dimnames of community matrix, trait distance matrix, and phylogenetic distance matrix to match.

dimnames_matrix <- rep(NA, length(sppids))
for (i in 1:length(sppids)) {
	names_i <- bbsspp[bbsspp$AOU == sppids[i], c('Latin_Name')]
	if (length(names_i)>0) dimnames_matrix[i] <- names_i[1]
}

dimnames(fixedbbsmat_byroute)[[2]] <- dimnames_matrix

tlabel1 <- eric_cons_tree$tip.label
tlabel1 <- gsub('_', ' ', tlabel1)

phymatchidx <- rep(NA,length(tlabel1))

for (i in 1:length(tlabel1)) {
	phymatchidx[i] <- c(which(bbsspp$Latin_Name_clean == tlabel1[i] | bbsspp$Latin_Name_synonym == tlabel1[i] | bbsspp$Latin_Name_synonym2 == tlabel1[i]), NA)[1]
}
tlabelaou <- bbsspp$AOU[phymatchidx]

dimnames_tlabel <- rep(NA, length(tlabelaou))
for (i in 1:length(tlabelaou)) {
	names_i <- bbsspp[bbsspp$AOU == tlabelaou[i], c('Latin_Name')]
	if (length(names_i)>0) dimnames_tlabel[i] <- names_i[1]
}

dimnames(ericdist)[[1]] <- dimnames(ericdist)[[2]] <- dimnames_tlabel

save(ericdist, birdtraitdist, file = '/mnt/research/nasabio/data/bbs/bbspdfddist.r')

# Remove nocturnal species, rows without coordinates, and rows and columns with zero sum.
ns <- colSums(fixedbbsmat_byroute)
rs <- rowSums(fixedbbsmat_byroute)
nocturnalbirds <- birdtrait$Latin_Name[birdtrait$Nocturnal == 1]
fixedbbsmat_byroute <- fixedbbsmat_byroute[has_coords & rs != 0, !(dimnames(fixedbbsmat_byroute)[[2]] %in% nocturnalbirds) & ns != 0]

bbsgrps_byroute <- bbsgrps_byroute[has_coords & rs != 0, ]

# 6. For the given radius, get pairwise distances among stops and the list of all neighbors.

# Fast function to get neighbor distances
# Refer to http://gis.stackexchange.com/questions/132384/distance-to-nearest-point-for-every-point-same-spatialpointsdataframe-in-r
getNeighbors <- function(dat, radius) {
  library(spdep)
  coords <- cbind(dat$lon_aea, dat$lat_aea)
  idlist <- dnearneigh(coords, 0, radius)
  distlist <- nbdists(idlist, coords)
  dflist <- list()
  for (i in 1:length(idlist)) {
    if (any(distlist[[i]] <= radius)) {
      dflist[[i]] <- data.frame(idx = idlist[[i]], rteNo = dat$rteNo[idlist[[i]]], dist = distlist[[i]][distlist[[i]] <= radius])
    }
    else {
      dflist[[i]] <- NA
    }
  }
  dflist
}

# Calculate distances and identities of all neighbors within the maximum radius
names(bbsgrps_byroute) <- c('year','rteNo','lon','lat','lon_aea','lat_aea')
bbscov <- bbsgrps_byroute

######
# Combine 2001-2011 into a single year.

consolidate_years <- function(x) {
	mat_x <- fixedbbsmat_byroute[x$rowidx, , drop = FALSE]
	as.numeric(apply(mat_x, 2, sum) > 0)
}

bbs_consol <- bbscov %>%
	mutate(rowidx = 1:nrow(bbscov)) %>%
	filter(year >= 2001 & year <= 2011) %>%
	group_by(rteNo, lon, lat, lon_aea, lat_aea) %>%
	do(x = consolidate_years(.))
	
bbsmat_byroute_oneyear <- do.call('rbind', bbs_consol$x)
dimnames(bbsmat_byroute_oneyear)[[2]] <- dimnames(fixedbbsmat_byroute)[[2]]

bbscov_oneyear <- bbs_consol %>% select(-x)
bbscovmat_oneyear <- as.matrix(bbscov_oneyear)

bbsnhb_list_oneyear <- getNeighbors(dat = as.data.frame(bbscovmat_oneyear), radius = 5e5)

# Include another matrix in the workspace with all the migratory birds removed.
migrantbirds <- birdtrait$Latin_Name[birdtrait$migrant_status == TRUE]
bbsmat_byroute_oneyear_residents <- bbsmat_byroute_oneyear[, !dimnames(bbsmat_byroute_oneyear)[[2]] %in% migrantbirds]

save(bbsnhb_list_oneyear, bbscov_oneyear, bbscovmat_oneyear, bbsmat_byroute_oneyear, bbsmat_byroute_oneyear_residents, file = '/mnt/research/aquaxterra/DATA/raw_data/BBS/bbsworkspace_singleyear.r')


