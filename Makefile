SHELL:=/bin/bash
REQUIRED_BINARIES := ytt kubectl imgpkg kapp yq helm docker kubectx
WORKING_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
ROOT_DIR := $(shell git rev-parse --show-toplevel)
WORKLOAD_DIR := ${ROOT_DIR}/workloads
GITOPS_DIR := ${ROOT_DIR}/gitops
SCRIPTS_DIR := ${ROOT_DIR}/scripts
# Secrets

OPT_ARGS=""

# deploy vars
WORKLOADS_KAPP_APP_NAME=workloads
WORKLOADS_NAMESPACE=default
LOCAL_CLUSTER_NAME=rancher-el8000

# template vars
HARVESTER_CLUSTER_VALUES=$(WORKING_DIR)/templates/cluster/harvester/harvester_samplevalues.yaml

# harvester clusters
HARVESTER_CLUSTER_NAMES := services-shared dev-fluffymunchkin prod-green prod-blue sandbox-alpha
HARVESTER_API_OVERRIDE=https://10.10.0.4:6443

check-tools: ## Check to make sure you have the right tools
	$(foreach exec,$(REQUIRED_BINARIES),\
		$(if $(shell which $(exec)),,$(error "'$(exec)' not found. It is a dependency for this Makefile")))

fleet-patch: check-tools
	@printf "\n===> Patching Fleet Bug\n";
	@kubectx $(LOCAL_CLUSTER_NAME)
	@kubectl patch ClusterGroup -n fleet-local default --type=json -p='[{"op": "remove", "path": "/spec/selector/matchLabels/name"}]'
	@kubectx -

workloads-check: check-tools
	@printf "\n===> Synchronizing Workloads with Fleet (dry-run)\n";
	@kubectx $(LOCAL_CLUSTER_NAME)
	@ytt -f workloads | kapp deploy -a $(WORKLOADS_KAPP_APP_NAME) -n $(WORKLOADS_NAMESPACE) -f - 
	@kubectx -

workloads-yes: check-tools
	@printf "\n===> Synchronizing Workloads with Fleet\n";
	@kubectx $(LOCAL_CLUSTER_NAME)
	$(MAKE) _harvester_cloud_credentials
	@ytt -f $(WORKLOAD_DIR) | kapp deploy -a $(WORKLOADS_KAPP_APP_NAME) -n $(WORKLOADS_NAMESPACE) -f - -y 
	@kubectx -

workloads-delete: check-tools
	@printf "\n===> Deleting Workloads with Fleet\n";
	@kubectx $(LOCAL_CLUSTER_NAME)
	@kapp delete -a $(WORKLOADS_KAPP_APP_NAME) -n $(WORKLOADS_NAMESPACE)
	$(MAKE) _harvester_cloud_credentials_delete
	@kubectx -

status: check-tools
	@printf "\n===> Inspecting Running Workloads in Fleet\n";
	@kubectx $(LOCAL_CLUSTER_NAME)
	@kapp inspect -a $(WORKLOADS_KAPP_APP_NAME) -n $(WORKLOADS_NAMESPACE)
	@kubectx -

cluster-generate-harvester: check-tools
	@ytt -f templates/cluster/harvester/harvester_cluster_template.yaml -f $(HARVESTER_CLUSTER_VALUES)

_harvester_cloud_credentials:
	@for cluster in $(HARVESTER_CLUSTER_NAMES); do \
    kubectx harvester; \
    ${SCRIPTS_DIR}/create cloud-provider-$$cluster default $(HARVESTER_API_OVERRIDE); \
    kubectx -; \
    kubectl create secret generic cloud-provider-$$cluster --namespace fleet-default --from-file=credential=./harvester_creds.yaml --dry-run=client -o yaml | kubectl apply -f -; \
    kubectl annotate secret cloud-provider-$$cluster --namespace fleet-default v2prov-secret-authorized-for-cluster="$$cluster"; \
    rm harvester_creds.yaml; \
  done

_harvester_cloud_credentials_delete:
	@kubectx $(LOCAL_CLUSTER_NAME)
	@for cluster in $(HARVESTER_CLUSTER_NAMES); do \
    kubectl delete secret cloud-provider-$$cluster --namespace fleet-default; \
  done
