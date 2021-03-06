# Treatment rule(s)
alwaysTreated0 <- function(L0){
  1
}

# Functions to be used later
logit <- function(x){
  log(x/(1-x))
}

expit<-function(x){
  result<-exp(x)/(1+exp(x))
  result[is.nan(result)]<-1
  result
}

g_to_g_delta<-function(delta, g){
  (g<delta)*delta+(g>=delta)*g
}

loss <- function(coefficients, outcome, covariates, boolean_subset, offset=0){
  Q_k <- as.vector(expit(covariates %*% coefficients + offset))
  sum(-boolean_subset * (outcome * log(Q_k) + (1 - outcome) * log(1 - Q_k)))
}

# Data generation
generate_data <- function(R, alpha0, beta0, beta1, beta2, n){
  L0 <- runif(n, min=-R, max=R)
  g00 <- expit(alpha0*L0)
  A0 <- rbinom(n, 1, g00)
  PL1givenA0L0 <- expit(beta0+beta1*A0+beta2*L0)
  L1 <- rbinom(n, 1, PL1givenA0L0)
  list(L0 = L0, A0 = A0, L1 = L1)
}

# C-TMLE_truncation
C_TMLE_truncation <- function(observed_data, d0, deltas, Q_misspecified = F){
  
  L0 <- observed_data$L0; A0 <- observed_data$A0; L1 <- observed_data$L1
  n <- length(L0)
  deltas <- sort(deltas, decreasing  = T)
  
  # 0. Fit models for g_{n,k=0}
  initial_model_for_A0 <- glm(A0 ~ 1 + L0, family=binomial)
  initial_model_for_A0$coefficients[is.na(initial_model_for_A0$coefficients)] <- 0
  gn0 <- as.vector(predict(initial_model_for_A0, type="response"))
  
  # 1.a Fit initial model Q^1_{d,n} of Q^1_{0,d}
  if(Q_misspecified == FALSE){
    coeffs_Q1d_bar_0n <- optim(par=c(0,0,0), fn=loss, outcome=L1, 
                               covariates=cbind(1,L0,A0), 
                               boolean_subset=(A0==d0(L0)))$par
    offset_vals_Q1d_bar_0n <- as.vector(cbind(1, L0, d0(L0)) %*% coeffs_Q1d_bar_0n)
  }else{
    offset_vals_Q1d_bar_0n <- logit(mean(L1[A0==d0(L0)]))
  }
  Q1d_bar_0n <- expit(offset_vals_Q1d_bar_0n)
  
  # Targeting steps: iterate targeting until either no likelihood gain is obtained,
  # or we run out of deltas.
  deltas_indices_used <- vector() # Sequence of deltas that will index the TMLES
  current_Q1d_bar_n <- Q1d_bar_0n
  
  test_set_indices <- sample(1:n, floor(n/5), replace = F)
  training_set_indices <- setdiff(1:n, test_set_indices)
  current_loss <- mean(((L1 - current_Q1d_bar_n)^2 * (A0 == d0(L0)))[test_set_indices])
  
  while(length(deltas_indices_used) < length(deltas)){
    
    test_set_indices <- sample(1:n, floor(n/5), replace = F)
    training_set_indices <- setdiff(1:n, test_set_indices)
    remaining_deltas_indices <- setdiff(1:length(deltas), deltas_indices_used)
    
    best_loss <- Inf
    for(i in remaining_deltas_indices){
      gn0_delta <- g_to_g_delta(deltas[i], gn0)
      H_delta <- (A0 == d0(L0)) / gn0_delta
      H_delta_setting_A_to_d <- 1 / gn0_delta
      
      # Fit parametric submodel to training set
      epsilon <- sum((((L1 - current_Q1d_bar_n) * H_delta) * (A0 == d0(L0)))[training_set_indices]) /
        sum((H_delta^2 * (A0 == d0(L0)))[training_set_indices])
      candidate_Q1d_bar_n <- current_Q1d_bar_n + epsilon * H_delta_setting_A_to_d
      # Compute loss of the candidate on training set
      candidate_loss <- mean(((L1 - candidate_Q1d_bar_n)^2 * (A0 == d0(L0)))[test_set_indices])
      
      if(candidate_loss < best_loss){
        best_loss <- candidate_loss
        index_best_candidate <- i
        best_candidate_Q1d_bar_n <- candidate_Q1d_bar_n
      }
    }
    
    if(best_loss < current_loss){
      deltas_indices_used <- c(deltas_indices_used, index_best_candidate)
      current_Q1d_bar_n <- best_candidate_Q1d_bar_n
      current_loss <- best_loss
    }else{
      break
    }
  }
  # End of iterative targeting
  
  # Compute estimate
  Utgtd_Psi_n <- mean(Q1d_bar_0n)
  Psi_n <- mean(current_Q1d_bar_n)
  list(Utgtd_Psi_n = Utgtd_Psi_n, Psi_n = Psi_n, delta_sequence = deltas[deltas_indices_used])
}


# Simulations -------------------------------------------------------------
set.seed(0)
deltas <- c(1e-4, 5e-4, (1:9)*1e-3, (1:9)*1e-2, (1:4)*1e-1)

# Compute true value of EY^d
compute_Psi_d_MC <- function(R, alpha0, beta0, beta1, beta2, d0, M){
  # Monte-Carlo estimation of the true value of mean of Yd
  L0_MC <- runif(M, min=-R, max=R)
  A0_MC <- d0(L0_MC)
  g0_MC <- expit(alpha0 * L0_MC)
  PL1givenA0L0_MC <- expit(beta0 + beta1 * A0_MC + beta2 * L0_MC)
  mean(PL1givenA0L0_MC)
}

Psi_d0 <- compute_Psi_d_MC(R = 4, alpha0 = 2, beta0 = -3, beta1 = -1.5, beta2 = -2, alwaysTreated0, M = 1e6)

# Specify the jobs. A job is the computation of a batch. 
# It is fully characterized by the parameters_tuple_id that the batch corresponds to.
ns <- c((1:9)*100, c(1:10)*1000)
parameters_grid <- expand.grid(R = 4, alpha0 = 2, beta0 = -3, beta1 = -1.5, beta2 = -2, n = ns)
batch_size <- 20; nb_batchs <- 32
jobs <- kronecker(1:nrow(parameters_grid), rep(1, nb_batchs))

# Perform the jobs in parallel
library(Rmpi); library(doMPI)

cl <- startMPIcluster(32)
registerDoMPI(cl)

results <- foreach(i=1:length(jobs)) %dopar% { #job is a parameter_tuple_id
  job <- jobs[i]
  results_batch <- matrix(0, nrow = batch_size, ncol = 3)
  colnames(results_batch) <- c("parameters_tuple_id", "Utgtd", "C-TMLE")
  for(i in 1:batch_size){
    observed_data <- generate_data(R = parameters_grid[job,]$R, alpha0 = parameters_grid[job,]$alpha0, 
                                   beta0 = parameters_grid[job,]$beta0, beta1 = parameters_grid[job,]$beta1, 
                                   beta2 = parameters_grid[job,]$beta2, n = parameters_grid[job,]$n)
    result_C_TMLE <- list(Utgtd_Psi_n = NA, Psi_n = NA)
    try(result_C_TMLE <- C_TMLE_truncation(observed_data, alwaysTreated0, deltas, Q_misspecified = T))
    results_batch[i, ] <- c(job, result_C_TMLE$Utgtd_Psi_n, result_C_TMLE$Psi_n)
  }
  results_batch
}

closeCluster(cl)
mpi.quit()

# Combine the results together
full_results_matrix <- results[[1]]
for(i in 2:length(results)){
  full_results_matrix <- rbind(full_results_matrix, results[[i]])
}

# Compute the MSEs for each parameter tuple id
MSEs <- matrix(NA, nrow = nrow(parameters_grid), ncol = 4)
for(i in 1:nrow(parameters_grid)){
  MSE_utgtd <- mean((full_results_matrix[full_results_matrix[,"parameters_tuple_id"] == i, "Utgtd"] - Psi_d0)^2)
  MSE_C_TMLE <- mean((full_results_matrix[full_results_matrix[,"parameters_tuple_id"] == i, "C-TMLE"] - Psi_d0)^2)
  MSEs[i, ] <- c(i, parameters_grid[i,]$n, MSE_utgtd, MSE_C_TMLE)
}
colnames(MSEs) <- c("parameter_tuple_id", "n", "MSE_utgtd", "MSE_C-TMLE")


# Save results and plots
pdf("plots.pdf")
plot(MSEs[, "n"],  MSEs[, "n"]* MSEs[,"MSE_utgtd"])
lines(MSEs[, "n"],  MSEs[, "n"]* MSEs[,"MSE_C-TMLE"])
dev.off()

save(full_results_matrix, MSEs, parameters_grid, file="C-TMLE_truncation-results")