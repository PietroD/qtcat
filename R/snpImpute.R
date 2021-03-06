#' @title Impute allele in formation to SNPs with missing data
#'
#' @description Uses neighbor SNPs from the clustering hierarchy to impute alleles to
#' positions with missing values.
#'
#' @param snp an object of class \linkS4class{snpMatrix}.
#' @param snpClust an object of class \code{\link{qtcatClust}}.
#' @param min.absCor a minimum value of correlation. If missing values still exist if this
#' point in the hierarchy is reached, imputing is done via allele frequencies.
#' @param mc.cores a number of cores for parallelising. Theoretical maximum is
#' \code{'B'}. For details see \code{\link[parallel]{mclapply}}.
#'
#' @examples
#' # file containing example data for SNP data
#' gfile <- system.file("extdata/snpdata.csv", package = "qtcat")
#' snp1 <- read.snpData(gfile, sep = ",")
#' # delete SNP information from Matrix, 33.33% NAs (-> 66.67% SNP info)
#' snp2 <- snp1
#' nainx <- sample(1:length(snp2@snpData), length(snp2@snpData) / 3)
#' snp2@snpData[nainx] <- as.raw(0)
#' # clustering
#' snp2clust <- qtcatClust(snp2)
#'
#' # imputing
#' snp3 <- imputeSnpMatrix(snp2, snp2clust)
#' # comparison of the full and the imputed data set
#' snpmat1 <- as.matrix(snp1)
#' snpmat3 <- as.matrix(snp3)
#' (1 - sum(abs(snpmat1- snpmat3)) / length(snpmat1)) * 100
#'
#' @importFrom hit as.hierarchy
#' @export
imputeSnpMatrix <- function(snp, snpClust, min.absCor = .1, mc.cores = 1) {
  stopifnot(is(snp, "snpMatrix"))
  stopifnot(is(snpClust, "qtcatClust"))
  snpnames <- colnames(snp)
  hier <- as.hierarchy(snpClust$dendrogram, names = snpnames)
  snp <- imputeMedoids(snp, snpClust, hier, min.absCor, mc.cores)
  # impute non medoid SNPs (if exist)
  nonMedo <- which(!(names(snpClust$clusters) %in% snpClust$medoids))
  if (length(nonMedo)) {
    flipAlleles <- as.numeric(alleleFreq(snp, FALSE) <= .5)
    snpList <- list()
    for (i in 1:ncol(snp)) {
      snpList[[i]] <- snp@snpData[, i]
      if (i %in% nonMedo) {
        m <- which(snpClust$medoids[snpClust$clusters[i]] == snpnames)
        js <- which(snpList[[i]] == is.raw(0))
        jAllele <- snp@snpData[js, m]
        if (flipAlleles[i] != flipAlleles[m]) {
          j1 <- which(jAllele == as.raw(1))
          j3 <- which(jAllele == as.raw(3))
          jAllele[j1] <- as.raw(3)
          jAllele[j3] <- as.raw(1)
        }
        snpList[[i]][js] <- jAllele
      }
    }
    snp@snpData <- do.call(cbind, snpList)
  }
  snp
}


#' @title Impute missing information at medoid SNPs
#'
#' @description Uses neighboring SNPs in the clustering hierarchy to impute alleles to
#' positions with missing values at medoid SNPs.
#'
#' @param snp an object of class \linkS4class{snpMatrix}.
#' @param snpClust an object of class \code{\link{qtcatClust}}.
#' @param hier an object of class hierarchy.
#' @param min.absCor a minimum value of correlation. If missing values still exist if this
#' point in the hierarchy is reached, imputing is done via allele frequencies.
#' @param mc.cores a number of cores for parallelising. Theoretical maximum is
#' \code{'B'}. For details see \code{\link[parallel]{mclapply}}.
#'
#' @importFrom parallel mclapply
#' @keywords internal
imputeMedoids <- function(snp, snpClust, hier, min.absCor = .25, mc.cores = 1) {
  hierLeafs <- which(sapply(hier, function(x) is.null(attr(x, which = "subset"))))
  naSnps <- which(naFreq(snp, 2) > 0 & colnames(snp) %in% labels(hier))
  medoSnps <- names(snpClust$clusters) %in% snpClust$medoids
  flipAlleles <- as.numeric(alleleFreq(snp, FALSE) <= .5)
  # run thru all SNPs
  snpList <- mclapply(1:ncol(snp), imputeSnp,
                      snp, hier, hierLeafs, snpClust$clusters, medoSnps,
                      naSnps, flipAlleles, min.absCor,
                      mc.cores = mc.cores)
  snp@snpData <- do.call(cbind, snpList)
  snp
}


#' @title Impute missing information at a medoid SNPs from a group of neighbors
#'
#' @description Uses neighboring SNPs in the clustering hierarchy to impute as many as
#' possible alleles to positions with missing values at medoid SNPs.
#'
#' @param inxSnpOfInt a vertor of the snp of interest.
#' @param snp an object of class \linkS4class{snpMatrix}.
#' @param hier an object of class hierarchy.
#' @param hierLeafs a vector of leafs of the hierarchy.
#' @param clust a named vector of clusters.
#' @param medoSnps a vector of medo turue o false.
#' @param naSnps a vector of NA indeces.
#' @param flipAlleles a vertor of telling for each SNP if allele one has allele freq. > 0.5
#' or not.
#' @param min.absCor a minimum value of correlation. If missing values still exist if this
#' point in the hierarchy is reached, imputing is done via allele frequencies.
#'
#' @keywords internal
imputeSnp <- function(inxSnpOfInt, snp, hier, hierLeafs, clust, medoSnps, naSnps,
                      flipAlleles, min.absCor) {
  snpOfInt <- snp@snpData[, inxSnpOfInt]
  if (medoSnps[inxSnpOfInt] && (inxSnpOfInt %in% naSnps)) {
    unsolved <- TRUE
    inxSnpsNotComp <- inxSnpOfInt
    # check in clusters of identicals
    inxSnpGrp <- which(clust == clust[inxSnpOfInt])
    inxSnpsNotComp <- inxSnpGrp[!(inxSnpGrp %in% inxSnpsNotComp)]
    if (length(inxSnpsNotComp)) {
      temp <- imputeSnpIter(snp, snpOfInt, inxSnpsNotComp,
                        flipAlleles[inxSnpOfInt], flipAlleles)
      snpOfInt <- temp[[1L]]
      unsolved <- temp[[2L]]
    }
    if (unsolved) {
      # run thru the heirarchy until NAs of the SNP are filled with information or the
      # height threshold is reached
      hierSnpOfInt <- hierLeafs[sapply(hier[hierLeafs], function(x) any(x == inxSnpOfInt))]
      super <- attr(hier[[hierSnpOfInt]], "superset")
      inxSnpGrp <- hier[[super]]
      h <- attr(inxSnpGrp, "height")
      while (unsolved && h <= (1 - min.absCor)) {
        inxSnpsNotComp <- c(inxSnpsNotComp, inxSnpsNotComp)
        inxSnpsNotComp <- inxSnpGrp[!(inxSnpGrp %in% inxSnpsNotComp)]
        if (length(inxSnpsNotComp)) {
          temp <- imputeSnpIter(snp, snpOfInt, inxSnpsNotComp,
                            flipAlleles[inxSnpOfInt], flipAlleles)
          snpOfInt <- temp[[1L]]
          unsolved <- temp[[2L]]
        }
        super <- attr(hier[[super]], "superset")
        if (is.null(super))
          break
        inxSnpGrp <- hier[[super]]
        h <- attr(inxSnpGrp, "height")
      }
    }
    # if height threshold is reached use alle frequency for random imputing
    if (unsolved) {
      js <- which(snpOfInt == as.raw(0L))
      alleleNo <- table(as.integer(snpOfInt), exclude = 0L)
      alleles <- as.raw(names(alleleNo))
      prob <- alleleNo / sum(alleleNo)
      snpOfInt[js] <- sample(alleles, length(js), TRUE, prob)
    }
  }
  snpOfInt
}


#' @title Impute missing information at a medoid SNPs from a group of neighbors
#'
#' @description Uses neighboring SNPs in the clustering hierarchy to impute as many as
#' possible alleles to positions with missing values at medoid SNPs.
#'
#' @param snp an object of class \linkS4class{snpMatrix}.
#' @param snpOfInt a vertor of the snp of interest.
#' @param inxSnpsToComp a index of neighbors.
#' @param snpOfIntFlip flip status of the snp of interest.
#' @param flipAlleles a vertor of telling for each SNP if allele one has allele freq. > 0.5
#' or not.
#' @param min.absCor a minimum value of correlation. If missing values still exist if this
#' point in the hierarchy is reached, imputing is done via allele frequencies.
#'
#' @keywords internal
imputeSnpIter <- function(snp, snpOfInt, inxSnpsToComp, snpOfIntFlip, flipAlleles) {
  unsolved <- TRUE
  n <- length(inxSnpsToComp)
  i <- 1L
  while (unsolved && i <= n) {
    js <- which(snpOfInt == as.raw(0L))
    jAllele <- snp@snpData[js, inxSnpsToComp[i]]
    if (snpOfIntFlip != flipAlleles[inxSnpsToComp[i]]) {
      j1 <- which(jAllele == as.raw(1L))
      j3 <- which(jAllele == as.raw(3L))
      jAllele[j1] <- as.raw(3L)
      jAllele[j3] <- as.raw(1L)
    }
    snpOfInt[js] <- jAllele
    unsolved <- any(jAllele == as.raw(0L))
    i <- i + 1L
  }
  list(snpOfInt, unsolved)
}
