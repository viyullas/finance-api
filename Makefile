SHELL := /bin/bash
.DEFAULT_GOAL := help

# ─── Configuration ───────────────────────────────────────────────
SPAIN_REGION   := eu-south-2
MEXICO_REGION  := us-east-1
SPAIN_CLUSTER  := pluxee-spain-eks
MEXICO_CLUSTER := pluxee-mexico-eks

TF_BASE    := 4_infrastructure/terraform
TF_SPAIN   := $(TF_BASE)/environments/spain
TF_MEXICO  := $(TF_BASE)/environments/mexico
HELM_CHART := 2_application/helm-charts/payment-latency-api
ARGOCD_DIR := 3_gitops/argocd
NAMESPACE  := payment-api
IMAGE_TAG  ?= latest

# ─── Helpers ─────────────────────────────────────────────────────
define header
	@printf '\n\033[1;36m━━━ %s ━━━\033[0m\n\n' '$(1)'
endef

define ok
	@printf '\033[0;32m✔ %s\033[0m\n' '$(1)'
endef

# Terraform output helpers (lazy-evaluated)
spain_tf  = $(shell cd $(TF_SPAIN) && terraform output -raw $(1) 2>/dev/null)
mexico_tf = $(shell cd $(TF_MEXICO) && terraform output -raw $(1) 2>/dev/null)

# ClusterSecretStore YAML template
define CSS_YAML
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: __REGION__
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
            namespace: external-secrets
endef
export CSS_YAML

# ═════════════════════════════════════════════════════════════════
#  LIFECYCLE
# ═════════════════════════════════════════════════════════════════

.PHONY: up
up: ## Deploy everything (Spain + Mexico)
	$(call header,PHASE 1/7 — Terraform)
	$(MAKE) tf-spain
	$(MAKE) tf-mexico
	$(call header,PHASE 2/7 — Kubeconfig)
	$(MAKE) kubeconfig
	$(call header,PHASE 3/7 — Docker build and push)
	$(MAKE) docker-build-push
	$(call header,PHASE 4/7 — Helm dependencies)
	$(MAKE) helm-deps
	$(call header,PHASE 5/7 — Secrets)
	$(MAKE) secrets
	$(call header,PHASE 6/7 — ArgoCD)
	$(MAKE) argocd
	$(call header,PHASE 7/7 — Deploy applications)
	$(MAKE) apps
	@echo ""
	$(call ok,All regions deployed successfully)
	$(MAKE) status

.PHONY: down
down: ## Destroy everything (Spain + Mexico)
	$(call header,PHASE 1/4 — Delete ArgoCD applications)
	-$(MAKE) delete-apps
	$(call header,PHASE 2/4 — Uninstall Helm releases)
	-$(MAKE) uninstall-helm
	$(call header,PHASE 3/4 — Terraform destroy Mexico)
	$(MAKE) down-tf-mexico
	$(call header,PHASE 4/4 — Terraform destroy Spain)
	$(MAKE) down-tf-spain
	@echo ""
	$(call ok,All resources destroyed)

# ═════════════════════════════════════════════════════════════════
#  TERRAFORM
# ═════════════════════════════════════════════════════════════════

.PHONY: tf-init-spain
tf-init-spain: ## Terraform init Spain
	cd $(TF_SPAIN) && terraform init

.PHONY: tf-init-mexico
tf-init-mexico: ## Terraform init Mexico
	cd $(TF_MEXICO) && terraform init

.PHONY: tf-spain
tf-spain: tf-init-spain ## Terraform apply Spain (eu-south-2)
	cd $(TF_SPAIN) && terraform apply -auto-approve

.PHONY: tf-mexico
tf-mexico: tf-init-mexico ## Terraform apply Mexico (us-east-1)
	cd $(TF_MEXICO) && terraform apply -auto-approve

.PHONY: tf-plan-spain
tf-plan-spain: tf-init-spain ## Terraform plan Spain
	cd $(TF_SPAIN) && terraform plan

.PHONY: tf-plan-mexico
tf-plan-mexico: tf-init-mexico ## Terraform plan Mexico
	cd $(TF_MEXICO) && terraform plan

.PHONY: down-tf-spain
down-tf-spain: ## Terraform destroy Spain (retries on VPC dependency race conditions)
	cd $(TF_SPAIN) && terraform init && \
		terraform destroy -auto-approve || \
		(echo "Retrying after 30s (waiting for AWS to release dependencies)..." && sleep 30 && terraform destroy -auto-approve)

.PHONY: down-tf-mexico
down-tf-mexico: ## Terraform destroy Mexico (retries on VPC dependency race conditions)
	cd $(TF_MEXICO) && terraform init && \
		terraform destroy -auto-approve || \
		(echo "Retrying after 30s (waiting for AWS to release dependencies)..." && sleep 30 && terraform destroy -auto-approve)

# ═════════════════════════════════════════════════════════════════
#  KUBECONFIG
# ═════════════════════════════════════════════════════════════════

.PHONY: kubeconfig
kubeconfig: kubeconfig-spain kubeconfig-mexico ## Update kubeconfig for both clusters

.PHONY: kubeconfig-spain
kubeconfig-spain: ## Update kubeconfig for Spain
	aws eks update-kubeconfig --region $(SPAIN_REGION) --name $(SPAIN_CLUSTER) --alias spain

.PHONY: kubeconfig-mexico
kubeconfig-mexico: ## Update kubeconfig for Mexico
	aws eks update-kubeconfig --region $(MEXICO_REGION) --name $(MEXICO_CLUSTER) --alias mexico

# ═════════════════════════════════════════════════════════════════
#  DOCKER
# ═════════════════════════════════════════════════════════════════

.PHONY: docker-build-push
docker-build-push: ## Build and push image to both ECR repos
	$(eval SPAIN_ECR := $(call spain_tf,ecr_repository_url))
	$(eval MEXICO_ECR := $(call mexico_tf,ecr_repository_url))
	docker build -t payment-latency-api:$(IMAGE_TAG) .
	@echo "--- Pushing to Spain ECR ---"
	aws ecr get-login-password --region $(SPAIN_REGION) | \
		docker login --username AWS --password-stdin $$(echo $(SPAIN_ECR) | cut -d/ -f1)
	docker tag payment-latency-api:$(IMAGE_TAG) $(SPAIN_ECR):$(IMAGE_TAG)
	docker push $(SPAIN_ECR):$(IMAGE_TAG)
	@echo "--- Pushing to Mexico ECR ---"
	aws ecr get-login-password --region $(MEXICO_REGION) | \
		docker login --username AWS --password-stdin $$(echo $(MEXICO_ECR) | cut -d/ -f1)
	docker tag payment-latency-api:$(IMAGE_TAG) $(MEXICO_ECR):$(IMAGE_TAG)
	docker push $(MEXICO_ECR):$(IMAGE_TAG)
	$(call ok,Image pushed to both ECR repos)

# ═════════════════════════════════════════════════════════════════
#  HELM DEPENDENCIES (ALB Controller + External Secrets Operator)
# ═════════════════════════════════════════════════════════════════

.PHONY: helm-deps
helm-deps: helm-deps-spain helm-deps-mexico ## Install ALB Controller + ESO on both clusters

.PHONY: helm-deps-spain
helm-deps-spain: ## Install ALB Controller + ESO on Spain
	$(eval LB_ROLE  := $(call spain_tf,lb_controller_role_arn))
	$(eval ESO_ROLE := $(call spain_tf,external_secrets_role_arn))
	$(eval VPC_ID   := $(call spain_tf,vpc_id))
	helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
	helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
	helm repo update
	helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
		--namespace kube-system --kube-context spain \
		--set clusterName=$(SPAIN_CLUSTER) \
		--set serviceAccount.create=true \
		--set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(LB_ROLE) \
		--set region=$(SPAIN_REGION) \
		--set vpcId=$(VPC_ID) \
		--wait
	helm upgrade --install external-secrets external-secrets/external-secrets \
		--namespace external-secrets --create-namespace --kube-context spain \
		--set serviceAccount.create=true \
		--set serviceAccount.name=external-secrets-sa \
		--set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(ESO_ROLE) \
		--wait
	@echo "$$CSS_YAML" | sed 's/__REGION__/$(SPAIN_REGION)/' | kubectl --context spain apply -f -
	$(call ok,Spain helm deps installed)

.PHONY: helm-deps-mexico
helm-deps-mexico: ## Install ALB Controller + ESO on Mexico
	$(eval LB_ROLE  := $(call mexico_tf,lb_controller_role_arn))
	$(eval ESO_ROLE := $(call mexico_tf,external_secrets_role_arn))
	$(eval VPC_ID   := $(call mexico_tf,vpc_id))
	helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
	helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
	helm repo update
	helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
		--namespace kube-system --kube-context mexico \
		--set clusterName=$(MEXICO_CLUSTER) \
		--set serviceAccount.create=true \
		--set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(LB_ROLE) \
		--set region=$(MEXICO_REGION) \
		--set vpcId=$(VPC_ID) \
		--wait
	helm upgrade --install external-secrets external-secrets/external-secrets \
		--namespace external-secrets --create-namespace --kube-context mexico \
		--set serviceAccount.create=true \
		--set serviceAccount.name=external-secrets-sa \
		--set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(ESO_ROLE) \
		--wait
	@echo "$$CSS_YAML" | sed 's/__REGION__/$(MEXICO_REGION)/' | kubectl --context mexico apply -f -
	$(call ok,Mexico helm deps installed)

# ═════════════════════════════════════════════════════════════════
#  SECRETS
# ═════════════════════════════════════════════════════════════════

.PHONY: secrets
secrets: secrets-spain secrets-mexico ## Seed initial secrets in Secrets Manager

.PHONY: secrets-spain
secrets-spain: ## Seed API_SECRET_KEY for Spain
	$(eval SECRET_ID := $(call spain_tf,app_secret_id))
	@aws secretsmanager put-secret-value \
		--secret-id "$(SECRET_ID)" --region $(SPAIN_REGION) \
		--secret-string '{"API_SECRET_KEY":"'$$(openssl rand -hex 32)'"}' 2>/dev/null \
		&& echo "Spain secret seeded" \
		|| echo "Spain secret already set or not found, skipping"

.PHONY: secrets-mexico
secrets-mexico: ## Seed API_SECRET_KEY for Mexico
	$(eval SECRET_ID := $(call mexico_tf,app_secret_id))
	@aws secretsmanager put-secret-value \
		--secret-id "$(SECRET_ID)" --region $(MEXICO_REGION) \
		--secret-string '{"API_SECRET_KEY":"'$$(openssl rand -hex 32)'"}' 2>/dev/null \
		&& echo "Mexico secret seeded" \
		|| echo "Mexico secret already set or not found, skipping"

# ═════════════════════════════════════════════════════════════════
#  ARGOCD
# ═════════════════════════════════════════════════════════════════

.PHONY: argocd
argocd: ## Install ArgoCD on Spain and register Mexico as remote cluster
	helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
	helm upgrade --install argocd argo/argo-cd \
		--namespace argocd --create-namespace --kube-context spain \
		--set server.service.type=ClusterIP \
		--wait
	@echo "--- Registering Mexico cluster in ArgoCD ---"
	kubectl --context spain -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' | base64 -d > /tmp/.argocd-pass
	kubectl --context spain -n argocd port-forward svc/argocd-server 8443:443 &
	@sleep 3
	argocd login localhost:8443 --insecure --username admin \
		--password "$$(cat /tmp/.argocd-pass)"
	argocd cluster add mexico --name pluxee-mexico-eks --yes
	@kill %1 2>/dev/null || true
	@rm -f /tmp/.argocd-pass
	$(call ok,ArgoCD installed and Mexico cluster registered)

# ═════════════════════════════════════════════════════════════════
#  APPLICATIONS (ArgoCD)
# ═════════════════════════════════════════════════════════════════

.PHONY: apps
apps: apps-spain apps-mexico ## Deploy ArgoCD Applications

.PHONY: apps-spain
apps-spain: ## Apply ArgoCD Application for Spain
	$(eval ECR_REG    := $(call spain_tf,ecr_registry))
	$(eval ACM_ARN    := $(call spain_tf,acm_certificate_arn))
	$(eval RDS_SECRET := $(call spain_tf,rds_master_secret_arn))
	$(eval RDS_EP     := $(call spain_tf,db_connection_endpoint))
	$(eval APP_SECRET := $(call spain_tf,app_secret_id))
	sed \
		-e 's|ECR_REGISTRY_SPAIN|$(ECR_REG)|' \
		-e 's|ACM_ARN_SPAIN|$(ACM_ARN)|' \
		-e 's|RDS_SECRET_ARN_SPAIN|$(RDS_SECRET)|' \
		-e 's|RDS_ENDPOINT_SPAIN|$(RDS_EP)|' \
		-e 's|APP_SECRET_ID_SPAIN|$(APP_SECRET)|' \
		$(ARGOCD_DIR)/application-spain.yaml | kubectl --context spain apply -f -
	$(call ok,Spain ArgoCD Application deployed)

.PHONY: apps-mexico
apps-mexico: ## Apply ArgoCD Application for Mexico (via Spain ArgoCD)
	$(eval ECR_REG    := $(call mexico_tf,ecr_registry))
	$(eval ACM_ARN    := $(call mexico_tf,acm_certificate_arn))
	$(eval RDS_SECRET := $(call mexico_tf,rds_master_secret_arn))
	$(eval RDS_EP     := $(call mexico_tf,db_connection_endpoint))
	$(eval APP_SECRET := $(call mexico_tf,app_secret_id))
	$(eval MEX_URL    := $(call mexico_tf,eks_cluster_endpoint))
	sed \
		-e 's|ECR_REGISTRY_MEXICO|$(ECR_REG)|' \
		-e 's|ACM_ARN_MEXICO|$(ACM_ARN)|' \
		-e 's|RDS_SECRET_ARN_MEXICO|$(RDS_SECRET)|' \
		-e 's|RDS_ENDPOINT_MEXICO|$(RDS_EP)|' \
		-e 's|APP_SECRET_ID_MEXICO|$(APP_SECRET)|' \
		-e 's|CLUSTER_URL_MEXICO|$(MEX_URL)|' \
		$(ARGOCD_DIR)/application-mexico.yaml | kubectl --context spain apply -f -
	$(call ok,Mexico ArgoCD Application deployed)

# ═════════════════════════════════════════════════════════════════
#  TEARDOWN (idempotent — safe to re-run after partial failures)
# ═════════════════════════════════════════════════════════════════

# Check if a kubectl context is reachable (5s timeout)
define check_cluster
$(shell kubectl --context $(1) --request-timeout=5s cluster-info &>/dev/null && echo yes || echo no)
endef

.PHONY: delete-apps
delete-apps: ## Delete ArgoCD Applications (both managed from Spain)
	@if [ "$(call check_cluster,spain)" = "yes" ]; then \
		echo "Spain cluster reachable, deleting ArgoCD apps..."; \
		kubectl --context spain delete application -n argocd payment-latency-api-spain --wait=false 2>/dev/null || true; \
		kubectl --context spain delete application -n argocd payment-latency-api-mexico --wait=false 2>/dev/null || true; \
		echo "Waiting for ArgoCD to clean up resources..."; \
		sleep 15; \
		kubectl --context spain delete namespace $(NAMESPACE) --wait=false 2>/dev/null || true; \
	else \
		echo "Spain cluster not reachable, skipping app deletion"; \
	fi
	@if [ "$(call check_cluster,mexico)" = "yes" ]; then \
		kubectl --context mexico delete namespace $(NAMESPACE) --wait=false 2>/dev/null || true; \
	fi

.PHONY: uninstall-helm
uninstall-helm: ## Uninstall all Helm releases (ALB Controller last, waits for ALB cleanup)
	@if [ "$(call check_cluster,spain)" = "yes" ]; then \
		echo "Spain cluster reachable, uninstalling helm releases..."; \
		helm uninstall argocd -n argocd --kube-context spain 2>/dev/null || true; \
		helm uninstall external-secrets -n external-secrets --kube-context spain 2>/dev/null || true; \
		echo "Deleting any remaining Ingress resources in Spain..."; \
		kubectl --context spain delete ingress --all-namespaces --all 2>/dev/null || true; \
		echo "Waiting for ALB Controller to clean up ALBs and security groups..."; \
		for i in 1 2 3 4 5 6; do \
			REMAINING=$$(aws elbv2 describe-load-balancers --region $(SPAIN_REGION) \
				--query "LoadBalancers[?VpcId=='$$(cd $(TF_SPAIN) && terraform output -raw vpc_id 2>/dev/null)'].LoadBalancerArn" \
				--output text 2>/dev/null); \
			if [ -z "$$REMAINING" ] || [ "$$REMAINING" = "None" ]; then \
				echo "  No ALBs remaining in Spain VPC"; \
				break; \
			fi; \
			echo "  ALBs still being deleted, waiting 15s... (attempt $$i/6)"; \
			sleep 15; \
		done; \
		helm uninstall aws-load-balancer-controller -n kube-system --kube-context spain 2>/dev/null || true; \
		kubectl --context spain delete namespace argocd external-secrets --wait=false 2>/dev/null || true; \
	else \
		echo "Spain cluster not reachable, skipping helm uninstall"; \
	fi
	@if [ "$(call check_cluster,mexico)" = "yes" ]; then \
		echo "Mexico cluster reachable, uninstalling helm releases..."; \
		helm uninstall external-secrets -n external-secrets --kube-context mexico 2>/dev/null || true; \
		echo "Deleting any remaining Ingress resources in Mexico..."; \
		kubectl --context mexico delete ingress --all-namespaces --all 2>/dev/null || true; \
		echo "Waiting for ALB Controller to clean up ALBs and security groups..."; \
		for i in 1 2 3 4 5 6; do \
			REMAINING=$$(aws elbv2 describe-load-balancers --region $(MEXICO_REGION) \
				--query "LoadBalancers[?VpcId=='$$(cd $(TF_MEXICO) && terraform output -raw vpc_id 2>/dev/null)'].LoadBalancerArn" \
				--output text 2>/dev/null); \
			if [ -z "$$REMAINING" ] || [ "$$REMAINING" = "None" ]; then \
				echo "  No ALBs remaining in Mexico VPC"; \
				break; \
			fi; \
			echo "  ALBs still being deleted, waiting 15s... (attempt $$i/6)"; \
			sleep 15; \
		done; \
		helm uninstall aws-load-balancer-controller -n kube-system --kube-context mexico 2>/dev/null || true; \
		kubectl --context mexico delete namespace external-secrets --wait=false 2>/dev/null || true; \
	else \
		echo "Mexico cluster not reachable, skipping helm uninstall"; \
	fi

# ═════════════════════════════════════════════════════════════════
#  STATUS
# ═════════════════════════════════════════════════════════════════

.PHONY: status
status: ## Show status of both clusters
	@printf '\n\033[1;33m═══ SPAIN (eu-south-2) ═══\033[0m\n'
	@kubectl --context spain get nodes 2>/dev/null || echo "  Cluster not reachable"
	@echo ""
	@kubectl --context spain get pods -n $(NAMESPACE) 2>/dev/null || true
	@printf '\n\033[1;33m═══ MEXICO (us-east-1) ═══\033[0m\n'
	@kubectl --context mexico get nodes 2>/dev/null || echo "  Cluster not reachable"
	@echo ""
	@kubectl --context mexico get pods -n $(NAMESPACE) 2>/dev/null || true

# ═════════════════════════════════════════════════════════════════
#  HELP
# ═════════════════════════════════════════════════════════════════

.PHONY: help
help: ## Show available targets
	@printf '\n\033[1mPayment Platform — Multi-Region Management\033[0m\n\n'
	@printf '  \033[1mLifecycle:\033[0m\n'
	@printf '  \033[36m%-25s\033[0m %s\n' "up" "Deploy everything (Spain + Mexico)"
	@printf '  \033[36m%-25s\033[0m %s\n' "down" "Destroy everything (Spain + Mexico)"
	@printf '  \033[36m%-25s\033[0m %s\n' "status" "Show status of both clusters"
	@echo ""
	@printf '  \033[1mTerraform:\033[0m\n'
	@printf '  \033[36m%-25s\033[0m %s\n' "tf-spain / tf-mexico" "Apply infrastructure"
	@printf '  \033[36m%-25s\033[0m %s\n' "tf-plan-spain / tf-plan-mexico" "Plan changes"
	@printf '  \033[36m%-25s\033[0m %s\n' "down-tf-spain / down-tf-mexico" "Destroy infrastructure"
	@echo ""
	@printf '  \033[1mKubernetes:\033[0m\n'
	@printf '  \033[36m%-25s\033[0m %s\n' "kubeconfig" "Update kubeconfig (both)"
	@printf '  \033[36m%-25s\033[0m %s\n' "helm-deps" "Install ALB + ESO (both)"
	@printf '  \033[36m%-25s\033[0m %s\n' "argocd" "Install ArgoCD (Spain) + register Mexico"
	@printf '  \033[36m%-25s\033[0m %s\n' "apps" "Deploy ArgoCD Applications"
	@echo ""
	@printf '  \033[1mOther:\033[0m\n'
	@printf '  \033[36m%-25s\033[0m %s\n' "docker-build-push" "Build & push to both ECR"
	@printf '  \033[36m%-25s\033[0m %s\n' "secrets" "Seed Secrets Manager"
	@echo ""
