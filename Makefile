SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# ── Configuration ────────────────────────────────────────────────────────────
PROJECT       ?= musclequant
REGION        ?= us-east-1
TF_DIR        := infra/terraform
K8S_DIR       := infra/k8s
RENDERED_DIR  := infra/k8s/.rendered
IMAGE_TAG     ?= $(shell date -u +%Y%m%d%H%M%S)
DOCKER_PLATFORM ?= linux/amd64

# Colors
B := \033[1m
G := \033[32m
Y := \033[33m
N := \033[0m

.PHONY: help
help: ## Show this help.
	@grep -E '^[a-zA-Z_/.-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  $(G)%-22s$(N) %s\n", $$1, $$2}'

# ── Lifecycle ────────────────────────────────────────────────────────────────
.PHONY: up
up: tf/apply images/push manifests/apply ## Provision everything end-to-end.
	@echo -e "$(G)✔ Cluster up. ALB URL:$(N)"
	@$(MAKE) --no-print-directory app/url

.PHONY: down
down: manifests/delete tf/destroy ## Tear everything down.
	@echo -e "$(G)✔ Everything destroyed.$(N)"

# ── Terraform ────────────────────────────────────────────────────────────────
.PHONY: tf/init
tf/init: ## terraform init.
	cd $(TF_DIR) && terraform init -upgrade

.PHONY: tf/plan
tf/plan: tf/init ## terraform plan.
	cd $(TF_DIR) && terraform plan

.PHONY: tf/apply
tf/apply: tf/init ## terraform apply (auto-approve).
	cd $(TF_DIR) && terraform apply -auto-approve
	@$(MAKE) --no-print-directory kubeconfig

.PHONY: tf/destroy
tf/destroy: ## terraform destroy (auto-approve). Removes the entire stack.
	cd $(TF_DIR) && terraform destroy -auto-approve

.PHONY: tf/output
tf/output: ## Show terraform outputs.
	cd $(TF_DIR) && terraform output

.PHONY: kubeconfig
kubeconfig: ## Update local kubeconfig for the EKS cluster.
	aws eks update-kubeconfig --region $(REGION) --name $(PROJECT)-eks

# ── Container images ─────────────────────────────────────────────────────────
.PHONY: images/push
images/push: ## Build & push api + report-gen images to ECR.
	@bash -ec '\
	  cd $(TF_DIR); \
	  REGISTRY=$$(terraform output -raw ecr_registry); \
	  API_REPO=$$(terraform output -raw ecr_api_repo_url); \
	  REPORT_REPO=$$(terraform output -raw ecr_report_gen_repo_url); \
	  cd ../..; \
	  TAG=$(IMAGE_TAG); \
	  echo -e "$(B)Logging in to ECR $$REGISTRY ...$(N)"; \
	  aws ecr get-login-password --region $(REGION) | docker login --username AWS --password-stdin "$$REGISTRY"; \
	  echo -e "$(B)Building api → $$API_REPO:$$TAG$(N)"; \
	  docker build --platform $(DOCKER_PLATFORM) -t "$$API_REPO:$$TAG" -t "$$API_REPO:latest" services/api; \
	  docker push "$$API_REPO:$$TAG"; \
	  docker push "$$API_REPO:latest"; \
	  echo -e "$(B)Building report-gen → $$REPORT_REPO:$$TAG$(N)"; \
	  docker build --platform $(DOCKER_PLATFORM) -t "$$REPORT_REPO:$$TAG" -t "$$REPORT_REPO:latest" services/report-gen; \
	  docker push "$$REPORT_REPO:$$TAG"; \
	  docker push "$$REPORT_REPO:latest"; \
	  echo "$$TAG" > .image_tag; \
	  echo -e "$(G)✔ Images pushed at tag $$TAG$(N)" \
	'

# ── Manifests ────────────────────────────────────────────────────────────────
.PHONY: manifests/render
manifests/render: ## Render K8s manifests from Terraform outputs (envsubst).
	@bash -ec '\
	  command -v envsubst >/dev/null || { echo "envsubst not found — install gettext"; exit 1; }; \
	  mkdir -p $(RENDERED_DIR); \
	  cd $(TF_DIR); \
	  export AWS_REGION=$$(terraform output -raw region); \
	  export APP_NAMESPACE=musclequant; \
	  export APP_IRSA_ROLE=$$(terraform output -raw app_irsa_role_arn); \
	  export APP_SECRET_NAME=$$(terraform output -raw app_secret_arn | awk -F: "{print \$$NF}" | sed "s/-[A-Za-z0-9]*\$$//"); \
	  export ECR_API_REPO=$$(terraform output -raw ecr_api_repo_url); \
	  export ECR_REPORT_REPO=$$(terraform output -raw ecr_report_gen_repo_url); \
	  cd ../..; \
	  export IMAGE_TAG=$$(cat .image_tag 2>/dev/null || echo latest); \
	  export ACM_CERT_ARN=$$(cat .acm_cert_arn 2>/dev/null || echo ""); \
	  for f in $(K8S_DIR)/[0-9]*.yaml; do \
	    envsubst "\$$AWS_REGION \$$APP_NAMESPACE \$$APP_IRSA_ROLE \$$APP_SECRET_NAME \$$ECR_API_REPO \$$ECR_REPORT_REPO \$$IMAGE_TAG \$$ACM_CERT_ARN" \
	      < "$$f" > "$(RENDERED_DIR)/$$(basename $$f)"; \
	  done; \
	  echo -e "$(G)✔ Rendered manifests to $(RENDERED_DIR)/$(N)" \
	'

.PHONY: tls/import
tls/import: ## Import the cert-manager-issued cert into ACM and write the ARN.
	@bash -ec '\
	  kubectl -n musclequant wait --for=condition=Ready certificate/musclequant-tls --timeout=120s; \
	  CRT_FILE=$$(mktemp); KEY_FILE=$$(mktemp); \
	  kubectl -n musclequant get secret musclequant-tls -o jsonpath="{.data.tls\.crt}" | base64 -d > "$$CRT_FILE"; \
	  kubectl -n musclequant get secret musclequant-tls -o jsonpath="{.data.tls\.key}" | base64 -d > "$$KEY_FILE"; \
	  ARN=$$(aws acm import-certificate --region $(REGION) --certificate fileb://$$CRT_FILE --private-key fileb://$$KEY_FILE --query CertificateArn --output text); \
	  rm -f "$$CRT_FILE" "$$KEY_FILE"; \
	  echo "$$ARN" > .acm_cert_arn; \
	  echo -e "$(G)✔ Imported ACM cert: $$ARN$(N)" \
	'

.PHONY: manifests/apply
manifests/apply: ## Apply manifests in order. Idempotent.
	@$(MAKE) --no-print-directory manifests/render
	@bash -ec '\
	  kubectl apply -f $(RENDERED_DIR)/00-namespace.yaml; \
	  kubectl apply -f $(RENDERED_DIR)/01-serviceaccount.yaml; \
	  kubectl apply -f $(RENDERED_DIR)/02-rbac.yaml; \
	  kubectl apply -f $(RENDERED_DIR)/03-clustersecretstore.yaml; \
	  kubectl apply -f $(RENDERED_DIR)/04-externalsecret.yaml; \
	  kubectl apply -f $(RENDERED_DIR)/05-issuer.yaml; \
	  kubectl apply -f $(RENDERED_DIR)/06-certificate.yaml; \
	  echo "Waiting for the application secret to sync from Secrets Manager..."; \
	  for i in $$(seq 1 30); do \
	    kubectl -n musclequant get secret musclequant-app >/dev/null 2>&1 && break; \
	    sleep 4; \
	  done; \
	  kubectl apply -f $(RENDERED_DIR)/07-deployment-api.yaml; \
	  kubectl apply -f $(RENDERED_DIR)/08-deployment-report-gen.yaml; \
	  kubectl apply -f $(RENDERED_DIR)/09-services.yaml; \
	  kubectl apply -f $(RENDERED_DIR)/11-networkpolicy.yaml; \
	  echo "Waiting for deployments to roll out..."; \
	  kubectl -n musclequant rollout status deploy/api --timeout=180s; \
	  kubectl -n musclequant rollout status deploy/report-gen --timeout=180s \
	'
	@$(MAKE) --no-print-directory tls/import
	@$(MAKE) --no-print-directory manifests/render
	kubectl apply -f $(RENDERED_DIR)/10-ingress.yaml

.PHONY: manifests/delete
manifests/delete: ## Delete the application + red-team namespaces.
	-kubectl delete namespace musclequant --wait=false 2>/dev/null || true
	-kubectl delete namespace red-team --wait=false 2>/dev/null || true
	-kubectl delete clustersecretstore aws-secretsmanager 2>/dev/null || true
	-kubectl delete clusterissuer selfsigned 2>/dev/null || true

# ── Convenience ──────────────────────────────────────────────────────────────
.PHONY: app/url
app/url: ## Print the ALB URL.
	@bash -ec '\
	  HOST=$$(kubectl -n musclequant get ingress musclequant -o jsonpath="{.status.loadBalancer.ingress[0].hostname}" 2>/dev/null); \
	  if [[ -n "$$HOST" ]]; then \
	    echo -e "  HTTP : http://$$HOST"; \
	    echo -e "  HTTPS: https://$$HOST  (self-signed; expect a browser warning)"; \
	  else \
	    echo -e "$(Y)Ingress address not yet provisioned — re-run in a minute.$(N)"; \
	  fi \
	'

.PHONY: pods
pods: ## kubectl get pods across the namespaces we care about.
	@bash -ec '\
	  for ns in musclequant red-team external-secrets cert-manager kube-system; do \
	    echo -e "\n$(B)── $$ns ──$(N)"; \
	    kubectl -n $$ns get pods -o wide 2>/dev/null || true; \
	  done \
	'

.PHONY: logs/api
logs/api: ## Tail api logs.
	kubectl -n musclequant logs -f -l component=api --max-log-requests=10

.PHONY: logs/report
logs/report: ## Tail report-gen logs.
	kubectl -n musclequant logs -f -l component=report-gen --max-log-requests=10

.PHONY: threat/run
threat/run: ## Run both threat-simulation scenarios; output → docs/threat-sim-output.txt.
	./threat-sims/run.sh

.PHONY: clean
clean: ## Remove rendered manifests and local cache.
	rm -rf $(RENDERED_DIR) .image_tag .acm_cert_arn
