# Treatment rule(s)
alwaysTreated0 <- function(L0){
  1
}

# Functions to be used later
logit <- function(x){
  log(x/(1-x))
}

expit<-function(x){
  result <- exp(x)/(1+exp(x))
  result[is.nan(result)] <- 1
  result
}

g_to_g_delta<-function(delta, g){
  (g<delta) * delta + (g>=delta) * g
}

loss <- function(coefficients, outcome, covariates, boolean_subset, offset=0){
  Q_k <- as.vector(expit(covariates %*% coefficients + offset))
  sum(-boolean_subset * (outcome * log(Q_k) + (1 - outcome) * log(1 - Q_k)))
}

# Data generation
generate_data <- function(type = "L0_unif", positivity_parameter, alpha0, beta0, beta1, beta2, n){
  if(type == "L0_unif") 
    L0 <- runif(n, min= -positivity_parameter, max= positivity_parameter)
  else 
    L0 <- rexp(n, rate = 1 / positivity_parameter) * (1 - 2 * rbinom(n, 1, prob = 0.5))
  L0 <- runif(n, min = -positivity_parameter, max = positivity_parameter)
  g00 <- expit(alpha0*L0)
  A0 <- rbinom(n, 1, g00)
  PL1givenA0L0 <- expit(beta0+beta1*A0+beta2*L0)
  L1 <- rbinom(n, 1, PL1givenA0L0)
  list(L0 = L0, A0 = A0, L1 = L1)
}

# Compute a(delta0) (as defined in write up)
compute_a_delta0 <- function(delta0, order, n_points = 9, diff_step = NULL, verbose = F){
  
  #   cat("delta0 = ", delta0, " and order = ", order, "\n")
  
  if(order <= 0) return(list(a_delta0 = 1, deltas = delta0))
  
  if(n_points %% 2 == 0) n_points <- n_points + 1
  
  if(is.null(diff_step)){
    if(delta0 - (n_points-1)/2*1e-3 > 0){ diff_step=1e-3 }else{ diff_step = delta0/(n_points-1) }
  }
  bw <- diff_step * 2
  deltas <- delta0 + (1:n_points-1-(n_points-1) / 2)*diff_step
  weights <- exp(-(deltas-delta0)^2 / (2*bw^2)) / sqrt(2*pi*bw^2)
  
  X <- outer(deltas - delta0, 0:order, "^")
  
  A <- apply(diag(nrow(X)), 2, function(C) lm.wfit(X, C, weights)$coefficients)
  a_delta0 <- (-delta0)^(0:order) %*% A
  list(a_delta0 = a_delta0, differentiator = A, deltas = deltas)
}

# debug(compute_a_delta0)

# TMLE of truncated target parameter
TMLE_truncated_target <- function(observed_data, d0, delta, Q_misspecified = F){
  
  L0 <- observed_data$L0; A0 <- observed_data$A0; L1 <- observed_data$L1
  n <- length(L0)
  
  # 0. Fit models for g_{n,k=0}
  initial_model_for_A0 <- glm(A0 ~ 1 + L0, family=binomial)
  initial_model_for_A0$coefficients[is.na(initial_model_for_A0$coefficients)] <- 0
  gn0 <- as.vector(predict(initial_model_for_A0, type="response"))
  
  # 1.a Fit initial model Q^1_{d,n} of Q^1_{0,d}
  if(Q_misspecified == FALSE){
    coeffs_Q1d_bar_0n <- optim(par=c(0,0,0), fn=loss, outcome=L1, 
                               covariates=cbind(1,L0,A0), 
                               boolean_subset = (A0==d0(L0)))$par
    offset_vals_Q1d_bar_0n <- as.vector(cbind(1, L0, d0(L0)) %*% coeffs_Q1d_bar_0n)
  }else{
    offset_vals_Q1d_bar_0n <- rep(logit(mean(L1[A0==d0(L0)])), n)
  }
  Q1d_bar_0n <- expit(offset_vals_Q1d_bar_0n)
  
  # Compute clever covariate
  gn0_delta <- g_to_g_delta(delta, gn0)
  H_delta <- (A0 == d0(L0)) / gn0_delta
  H_delta_setting_A_to_d <- 1 / gn0_delta
  
  # Fit parametric submodel to training set
  epsilon <- glm(L1 ~ H_delta - 1, family = binomial, offset = offset_vals_Q1d_bar_0n,
                 subset = which(A0 == d0(L0)))$coefficients[1]
  Q1d_bar_star_n <- expit(logit(Q1d_bar_0n) + epsilon * H_delta_setting_A_to_d)
  
  # Return estimator
  mean(gn0 / gn0_delta * Q1d_bar_star_n)
}

# Untargeted extrapolation
untargeted_extrapolation <- function(observed_data, d0, order, delta0, Q_misspecified = F,
                                     n_points = 11, diff_step = NULL){
  # Compute a_delta0 as defined in write-up
  result_compute_a_delta0 <- compute_a_delta0(delta0, order = order, n_points, diff_step, verbose=F)
  a_delta0 <- result_compute_a_delta0$a_delta0
  deltas <- result_compute_a_delta0$deltas
  
  # Get the Psi(delta) for each deltas
  Psi_deltas <- sapply(deltas, function(delta) TMLE_truncated_target(observed_data, d0, delta, Q_misspecified = F))
  
  # Extrapolate
  a_delta0 %*% Psi_deltas
}

# TMLE of extrapolation
TMLE_extrapolation <- function(observed_data, training_set, test_set, d0, order, delta0, Q_misspecified = F, 
                               n_points = 11, diff_step = NULL){
  
  L0 <- observed_data$L0; A0 <- observed_data$A0; L1 <- observed_data$L1
  n <- length(L0)
  
  # Fit models for g_{n,k=0}
  initial_model_for_A0 <- glm(A0 ~ 1 + L0, family=binomial, subset = training_set)
  initial_model_for_A0$coefficients[is.na(initial_model_for_A0$coefficients)] <- 0
  gn0 <- as.vector(predict(initial_model_for_A0, type="response"))
  
  # Compute a_delta0 as defined in write-up
  result_compute_a_delta0 <- compute_a_delta0(delta0, order = order, n_points, diff_step, verbose=F)
  a_delta0 <- result_compute_a_delta0$a_delta0
  deltas <- result_compute_a_delta0$deltas
  
  # Compute clever covariate
  gn0_delta0 <- g_to_g_delta(delta0, gn0)
  gn0_deltas <- sapply(deltas, g_to_g_delta, g=gn0)
  H_delta <- (A0==d0(L0)) / gn0 * (outer(gn0, rep(1, length(deltas))) / gn0_deltas) %*% t(a_delta0)
  H_delta_setting_A_to_d <- 1 / gn0 * (outer(gn0, rep(1, length(deltas))) / gn0_deltas) %*% t(a_delta0)
  
  # Fit initial model Q^1_{d,n} of Q^1_{0,d}
  if(Q_misspecified == FALSE){
    coeffs_Q1d_bar_0n <- optim(par = c(0,0,0), fn=loss, outcome=L1, 
                               covariates = cbind(1,L0,A0), 
                               boolean_subset = intersect(which(A0 == d0(L0)), training_set))$par
    offset_vals_Q1d_bar_0n <- as.vector(cbind(1, L0, d0(L0)) %*% coeffs_Q1d_bar_0n)
  }else{
    offset_vals_Q1d_bar_0n <- rep(logit(mean(L1[intersect(which(A0 == d0(L0)), training_set)])), n)
  }
  Q1d_bar_0n <- expit(offset_vals_Q1d_bar_0n)
  
  # Fit parametric submodel to training set
  epsilon <- glm(L1 ~ H_delta - 1, family = binomial, offset = offset_vals_Q1d_bar_0n,
                 subset = intersect(which(A0 == d0(L0)), training_set))$coefficients[1]
  Q1d_bar_star_n <- expit(logit(Q1d_bar_0n) + epsilon * H_delta_setting_A_to_d)
  
  # Compute estimator and influence curve
  Psi_n <- mean(Q1d_bar_star_n * (outer(gn0, rep(1, length(deltas))) / gn0_deltas) %*% t(a_delta0))
  D_star_n <- H_delta + (1 / gn0_deltas) %*% t(a_delta0) * gn0 * Q1d_bar_star_n #It's actually D_star_n plus its mean
  var_D_star_n <- var(D_star_n)
  var_D_star_n_test <- var(D_star_n[test_set])
  
  # Return estimator, and Q_bar
  list(Psi_n = Psi_n, Q_bar = Q1d_bar_star_n, var_D_star_n = var_D_star_n, var_D_star_n_test = var_D_star_n_test)
}


# C-TMLE_truncation
C_TMLE_truncation <- function(observed_data, d0, orders, delta0s, Q_misspecified = F,
                              use_true_variance = F,
                              true_var_IC_extrapolations = NULL,
                              n_points = 11, diff_step = NULL, K = 5){
  
  L0 <- observed_data$L0; A0 <- observed_data$A0; L1 <- observed_data$L1
  n <- length(L0)
  
  # Define splits
  split_sizes <- rep(floor(n / K), K)
  if(n %% K != 0) for(i in 1:(n - floor(n / K) * K)) split_sizes[i] <- split_sizes[i] + 1
  splits <- list(); splits_Comp <- list()
  for(i in 1:K) splits[[i]] <- sum(split_sizes[0:(i-1)]):sum(split_sizes[0:i])
  for(i in 1:K) splits_Comp[[i]] <- setdiff(1:n, splits[i])
  
  # Compute TMLEs and their cross validated losses
  CV_losses <- matrix(0, nrow = length(orders), ncol = length(delta0s))
  for(i in 1:length(orders)){
    for(j in 1:length(delta0s)){
      Q1d_bar <- list()
      for(k in 1:K){ # Repeat the fitting procedure for the K splits
        #         cat("i = ", i, ", j = ", j, ", k =", k, "\n")
        result_TMLE_extrapolation <- TMLE_extrapolation(observed_data, splits_Comp[[k]], 
                                                        splits[[k]], d0, orders[i], delta0s[j])
        Q1d_bar <- result_TMLE_extrapolation$Q_bar
        var_IC_test <- result_TMLE_extrapolation$var_D_star_n_test
        if(is.na(sum((A0[splits[[k]]] == d0(L0[splits[[k]]])) * 
                       (L1[splits[[k]]] - Q1d_bar[splits[[k]]])^2))) browser()
        
        if(use_true_variance){
          var_IC <- true_var_IC_extrapolations[orders[i] + 1, j]
        }else{ 
          var_IC <- var_IC_test
        }
        CV_losses[i, j] <- CV_losses[i, j] + 
          sum((A0[splits[[k]]] == d0(L0[splits[[k]]])) * 
                (L1[splits[[k]]] - Q1d_bar[splits[[k]]])^2) + 1 / K * var_IC
      }
    }
  }
  
  # Compute estimate: pick the TMLE with lowest cross validated loss
  # First recompute deltas, a_delta0, deltas and gn0_deltas for the pair of best indices
  best_indices <- which(CV_losses == min(CV_losses), arr.ind = T)[1,]
  best_order <- orders[best_indices[1]]; best_delta0 <- delta0s[best_indices[2]]
  Psi_n <- TMLE_extrapolation(observed_data, 1:n, 1:n, d0, best_order, best_delta0)$Psi_n
  
  # Return output
  list(Psi_n = Psi_n, CV_losses = CV_losses, tp_indices = list(order = best_order, delta0 = best_delta0))
}

# debug(C_TMLE_truncation)

# Simulations -------------------------------------------------------------
# Compute true value of EY^d
compute_Psi_d_MC <- function(type, positivity_parameter, alpha0, beta0, beta1, beta2, d0, M){
  # Monte-Carlo estimation of the true value of mean of Yd
  if(type == "L0_unif") 
    L0_MC <- runif(M, min= -positivity_parameter, max= positivity_parameter)
  else 
    L0_MC <- rexp(M, rate = 1 / positivity_parameter) * (1 - 2 * rbinom(M, 1, prob = 0.5))
  A0_MC <- d0(L0_MC)
  g0_MC <- expit(alpha0 * L0_MC)
  PL1givenA0L0_MC <- expit(beta0 + beta1 * A0_MC + beta2 * L0_MC)
  mean(PL1givenA0L0_MC)
}

# Compute true value of truncation induced target parameter by numerical integration
compute_Psi_0_delta <- function(type, positivity_parameter, alpha0, beta0, beta1, beta2, d0, delta){
  #g0_dw_w is g0(d(w)|w)
  g0_dw_w <- Vectorize(function(w) d0(w) * expit(alpha0 * w) + (1 - d0(w)) * (1 - expit(alpha0 * w)))
  
  # Q0_dw_w is \bar{Q}_0(d(w)| w)
  Q0_dw_w <- function(w) expit(beta0 + beta1 * d0(w) + beta2 * w)
  
  # q_w is q_w(w)
  if(type == "L0_exp"){
    q_w <- function(w) 1 / 2 * 1 / positivity_parameter * exp(-abs(w) / positivity_parameter)
  }else{
    q_w <- Vectorize(function(w) 1 / (2 * positivity_parameter) * (abs(w) <= positivity_parameter))
  }
  
  # Define integrand such that \int integrand(w) dw = Psi_0(\delta) and integrate it
  integrand <- Vectorize(function(w) q_w(w) * g0_dw_w(w) / max(delta, g0_dw_w(w)) * Q0_dw_w(w))
  integrate(integrand, lower = -5 * positivity_parameter, upper = 5 * positivity_parameter)$value
}

# Compute the true variance of the influence curve of an extrapolated target parameter by
# numerical integration
true_variance_IC <- function(type, positivity_parameter, alpha0, beta0, beta1, beta2, d0, 
                             delta0, order, n_points = 11, diff_step = NULL){
  
  # Compute a_delta0 as defined in write-up
  result_compute_a_delta0 <- compute_a_delta0(delta0, order = order, n_points, diff_step, verbose=F)
  a_delta0 <- result_compute_a_delta0$a_delta0
  deltas <- result_compute_a_delta0$deltas
  
  # Compute the truncation induced target parameters at truncation levels deltas
  Psi_0_deltas <- sapply(deltas, Vectorize(function(delta) compute_Psi_0_delta(type, 
                                                                               positivity_parameter, 
                                                                               alpha0, beta0, beta1, 
                                                                               beta2, d0,
                                                                               delta)))
  # Define factors of the squared IC components
  #g0_dw_w is g0(d(w)|w)
  g0_dw_w <- Vectorize(function(w) d0(w) * expit(alpha0 * w) + (1 - d0(w)) * (1 - expit(alpha0 * w)))
  
  # Q0_dw_w is \bar{Q}_0(d(w)| w)
  Q0_dw_w <- function(w) expit(beta0 + beta1 * d0(w) + beta2 * w)
  
  # q_w is q_w(w)
  if(type == "L0_exp"){
    q_w <- function(w) 1 / 2 * 1 / positivity_parameter * exp(-abs(w) / positivity_parameter)
  }else{
    q_w <- Vectorize(function(w) 1 / (2 * positivity_parameter) * (abs(w) <= positivity_parameter))
  }
  
  # a_dot_inv_g_deltas is \sum_i a_i / g0_{delta_i}(d(w), w)
  a_dot_inv_g_deltas <- Vectorize(function(w)
    sum(a_delta0 * 1 / ((g0_dw_w(w) < deltas) * deltas + (deltas <= g0_dw_w(w)) * g0_dw_w(w))))
  
  # Define integrand and return its integral
  integrand <- Vectorize(function(w) q_w(w) * (Q0_dw_w(w) - Q0_dw_w(w)^2) * a_dot_inv_g_deltas(w)^2 +
                           q_w(w) * a_dot_inv_g_deltas(w)^2 * g0_dw_w(w)^2 * Q0_dw_w(w)^2)
  var_IC <- integrate(integrand, lower = -10 * positivity_parameter, upper = 10 * positivity_parameter)$value -
    sum(a_delta0 * Psi_0_deltas)^2
  
  if(var_IC < 0){
    return(Inf)
  }else{
    return(var_IC)
  }
}

# Compute true variance of influence curve of an extrapolated target parameter by Monte Carlo
true_variance_IC_MC <- function(type, positivity_parameter, alpha0, beta0, beta1, beta2, d0, 
                                delta0, order, n_points = 11, diff_step = NULL, M = 1e6){
  
  # Compute a_delta0 as defined in write-up
  result_compute_a_delta0 <- compute_a_delta0(delta0, order = order, n_points, diff_step, verbose=F)
  a_delta0 <- result_compute_a_delta0$a_delta0
  deltas <- result_compute_a_delta0$deltas
  
  # Compute the truncation induced target parameters at truncation levels deltas
  Psi_0_deltas <- sapply(deltas, Vectorize(function(delta) compute_Psi_0_delta(type, 
                                                                               positivity_parameter, 
                                                                               alpha0, beta0, beta1, 
                                                                               beta2, d0,
                                                                               delta)))
  
  # Sample a large number of observations from the true data generating mechanism
  if(type == "L0_unif"){
    L0 <- runif(M, min = -positivity_parameter, max = positivity_parameter)
  }else{
    L0 <- rexp(M, rate = 1 / positivity_parameter) * (1 - 2 * rbinom(M, 1, prob = 0.5))
  }
  g0 <- expit(alpha0 * L0)
  A0 <- rbinom(n, 1, prob = expit(g0))
  g0_dw_w <- d0(L0) * g0 + (1 - d0(L0)) * (1 - g0)
  Q_bar_dw_w <- expit(beta0 + beta1 * d0(L0) + beta2 * L0)
  Q_bar <- expit(beta0 + beta1 * A0 + beta2 * L0)
  L1 <- rbinom(n, 1, prob = Q_bar)
  
  # Define truncated gs
  g0_dw_w_deltas <- sapply(deltas, function(delta) (g0_dw_w > delta) * g0_dw_w + (g0_dw_w <= delta) * delta)
  a_dot_inv_g0_deltas <- (1 / g0_dw_w_deltas) %*% t(a_delta0)
  var_semi_plug_in <-  mean((Q_bar_dw_w - Q_bar_dw_w^2) * g0_dw_w * a_dot_inv_g0_deltas^2 +
                              a_dot_inv_g0_deltas^2 * Q_bar_dw_w^2 * g0_dw_w^2) - sum(a_delta0 * Psi_0_deltas)^2

  IC_plus_constant <- (A0 == d0(L0)) * a_dot_inv_g0_deltas * (L1 - Q_bar) + 
    a_dot_inv_g0_deltas * g0_dw_w * Q_bar_dw_w
  
  var_MC <- var(IC_plus_constant)
  
  if(var_semi_plug_in < 0) var_semi_plug_in <- Inf
  if(var_MC < 0) var_MC <- Inf
  
  list(var_MC = var_MC, var_semi_plug_in = var_semi_plug_in)
}

# Specify the jobs. A job is the computation of a batch. 
# It is fully characterized by the parameters_tuple_id that the batch corresponds to.
# ns <- c((1:9)*100, c(1:9)*1000, 2*c(1:5)*1e4)
ns <- c(50, 100, 150, 200, 250, (3:10) * 100)
parameters_grid <- rbind(expand.grid(type = "L0_unif", positivity_parameter = c(2, 4), 
                                     alpha0 = 2, beta0 = -3, beta1 = +1.5, beta2 = 1, n = ns, orders_set_id = 1:4),
                         expand.grid(type = "L0_exp", positivity_parameter = c(2, 4), 
                                     alpha0 = 2, beta0 = -3, beta1 = +1.5, beta2 = 1, n = ns, orders_set_id = 1:4))
# parameters_grid <- expand.grid(type = "L0_unif", positivity_parameter = 4,
#                                alpha0 = 1, beta0 = -3, beta1 = +1.5, beta2 = 1, n = ns, orders_set_id = 1:3)

batch_size <- 20; nb_batchs <- 1000

jobs <- kronecker(1:nrow(parameters_grid), rep(1, nb_batchs))
first_seed_batch <- 1:length(jobs) * batch_size
jobs_permutation <- sample(1:length(jobs))
jobs <- jobs[jobs_permutation]
first_seed_batch <- first_seed_batch[jobs_permutation]

# Define libraries of orders and delta0s
# set.seed(0)
delta0s <- c(1e-4, 5e-4, 1e-3, 5e-3, 1e-2, 5e-2, 1e-1, 2e-1)
# delta0s <- c(1e-4, 5e-4, (1:9)*1e-3, (1:9)*1e-2, (1:4)*1e-1)
# delta0s <- 1e-4
# orders <- 0:8
max_order <- 5
orders_sets <- list(0, 1, 2, 3)
# orders <- 9


# # Compute target parameter for each parameters tuple id
target_parameters <- vector()
for(i in 1:nrow(parameters_grid)) #target_parameters[i] <- NA
  target_parameters[i] <- compute_Psi_d_MC(type = parameters_grid[i, "type"],
                                           positivity_parameter = parameters_grid[i, "positivity_parameter"],
                                           alpha0 = parameters_grid[i, "alpha0"], 
                                           beta0 = parameters_grid[i, "beta0"],
                                           beta1 = parameters_grid[i, "beta1"],
                                           beta2 = parameters_grid[i, "beta2"],
                                           d0 = alwaysTreated0, M = 1e6)

# Compute the variances of the influence curves of the extrapolation
# for each target parameter
library(Rmpi); library(doMPI)
cl <- startMPIcluster(72)
registerDoMPI(cl)

# library(foreach); library(doParallel)
# cl <- makeCluster(getOption("cl.cores", 2), outfile = "")
# registerDoParallel(cl)
# 
true_var_IC_extrapolations <- foreach(job = 1:nrow(parameters_grid), .inorder=TRUE) %dopar% {
# true_var_IC_extrapolations <- foreach(job = c(2,4,1,3), .inorder=TRUE) %dopar%  {
  true_var_IC_extrapolation <- matrix(Inf, nrow = max_order + 1, ncol = length(delta0s))
  for(order in 0:max_order)
    for(i in 1:length(delta0s))
      try(true_var_IC_extrapolation[order + 1, i] <-  true_variance_IC(type = parameters_grid[job, "type"],
                                                                       positivity_parameter = parameters_grid[job, "positivity_parameter"],
                                                                       alpha0 = parameters_grid[job, "alpha0"],
                                                                       beta0 = parameters_grid[job, "beta0"],
                                                                       beta1 = parameters_grid[job, "beta1"],
                                                                       beta2 = parameters_grid[job, "beta2"],
                                                                       d0 = alwaysTreated0,
                                                                       delta0 = delta0s[i],
                                                                       order = order))
  true_var_IC_extrapolation
}

save(true_var_IC_extrapolations, file = "true_var_IC_extrapolation.RData")
# load("true_var_IC_extrapolation.RData")
print(true_var_IC_extrapolations)

# Save the parameters' grid
write.table(parameters_grid, file = "parameters_grid.csv", append = F, row.names=F, col.names=T,  sep=",")

# Perform the jobs in parallel


results <- foreach(i = 1:length(jobs)) %dopar% { #job is a parameter_tuple_idS
#   # for(i in 1:length(jobs)){
#   job <- 1
  job <- jobs[i]
  results_batch <- matrix(0, nrow = batch_size, ncol = 8)
  colnames(results_batch) <- c("parameters_tuple_id", "EYd", "seed","Utgtd-untr","Utgtd-extr", "C-TMLE", "order", "delta0")
  for(j in 1:batch_size){
    seed <- first_seed_batch[i] + j - 1; #set.seed(seed)
    observed_data <- generate_data(type = parameters_grid[job,]$type, 
                                   positivity_parameter = parameters_grid[job,]$positivity_parameter, 
                                   alpha0 = parameters_grid[job,]$alpha0,
                                   beta0 = parameters_grid[job,]$beta0, beta1 = parameters_grid[job,]$beta1, 
                                   beta2 = parameters_grid[job,]$beta2, n = parameters_grid[job,]$n)
    
    result_C_TMLE <- list(Utgtd_Psi_n = NA, Psi_n = NA)
    try(result_C_TMLE <- C_TMLE_truncation(observed_data, alwaysTreated0, orders_sets[[parameters_grid[job,]$orders_set_id]], 
                                           delta0s, Q_misspecified = F,
                                           use_true_variance = TRUE,
                                           true_var_IC_extrapolations = true_var_IC_extrapolations[[job]]))
    Utgtd_untr_Psi_n <- TMLE_truncated_target(observed_data, alwaysTreated0, 0, Q_misspecified = F)
    Utgtd_extr_Psi_n <- untargeted_extrapolation(observed_data, alwaysTreated0,
                                                 result_C_TMLE$tp_indices$order,
                                                 result_C_TMLE$tp_indices$delta0, Q_misspecified = F)
    print(result_C_TMLE)
    cat("Utgtd_untr_Psi_n=", Utgtd_untr_Psi_n, "\n")
    cat("Utgtd_extr_Psi_n=", Utgtd_extr_Psi_n, "\n")
    
    results_batch[j, ] <- c(job, target_parameters[job], seed, Utgtd_untr_Psi_n, Utgtd_extr_Psi_n, result_C_TMLE$Psi_n,
                            result_C_TMLE$tp_indices$order, result_C_TMLE$tp_indices$delta0)
  }
  
  if(!file.exists("C-TMLE_multi_orders_intermediate_results.csv")){
    write.table(results_batch, file="C-TMLE_multi_orders_intermediate_results.csv", append=T, row.names=F, col.names=T,  sep=",")
  }else{
    write.table(results_batch, file="C-TMLE_multi_orders_intermediate_results.csv", append=T, row.names=F, col.names=F,  sep=",")
  }
  results_batch
}

save(results, parameters_grid, file = "C-TMLE_multi_orders_results")

closeCluster(cl)
mpi.quit()


# # Combine the results together
# full_results_matrix <- results[[1]]
# for(i in 2:length(results)){
#   full_results_matrix <- rbind(full_results_matrix, results[[i]])
# }
# 
# # Compute the MSEs for each parameter tuple id
# MSEs <- matrix(NA, nrow = nrow(parameters_grid), ncol = 4)
# for(i in 1:nrow(parameters_grid)){
#   MSE_utgtd <- mean((full_results_matrix[full_results_matrix[,"parameters_tuple_id"] == i, "Utgtd"] - Psi_d0)^2)
#   MSE_C_TMLE <- mean((full_results_matrix[full_results_matrix[,"parameters_tuple_id"] == i, "C-TMLE"] - Psi_d0)^2)
#   MSEs[i, ] <- c(i, parameters_grid[i,]$n, MSE_utgtd, MSE_C_TMLE)
# }
# colnames(MSEs) <- c("parameter_tuple_id", "n", "MSE_utgtd", "MSE_C-TMLE")
# 
# plot(MSEs[, "n"],  MSEs[, "n"]* MSEs[,"MSE_utgtd"])
# lines(MSEs[, "n"],  MSEs[, "n"]* MSEs[,"MSE_C-TMLE"])