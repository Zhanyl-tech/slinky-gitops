CLUSTER  ?= slinky
NS_SLURM ?= slurm
NS_OP    ?= slinky
# How long to wait for a compute node to register. Generous, because pulling
# the Slurm images on a cold runner dominates.
REGISTER_TIMEOUT ?= 600

# ── Pinned versions ──────────────────────────────────────────────────────────
# `make up` and CI install exactly these. Slinky 1.2.0 and the Kubernetes
# v1.32.2 node image are what the README says this was built and tested
# against; the digest is the one published in the kind v0.27.0 release notes
# (https://github.com/kubernetes-sigs/kind/releases/tag/v0.27.0), and kind
# applies --image to every node in the config. cert-manager 1.20 is the newest
# line whose supported-releases table includes Kubernetes 1.32
# (https://cert-manager.io/docs/releases/); the version the original runs
# installed was never recorded.
#
# Setting any of these to empty (e.g. `make up SLINKY_VERSION=`) installs the
# latest instead, which is what the scheduled drift job in CI does.
SLINKY_VERSION       ?= 1.2.0
CERT_MANAGER_VERSION ?= v1.20.4
KIND_NODE_IMAGE      ?= kindest/node:v1.32.2@sha256:f226345927d7e348497136874b6d207e0b32cc52154ad8323129352923a3142f
KIND_CONFIG          ?= kind/cluster.yaml

# Extra flags for the rotation script, e.g. `make rotate ROTATE_ARGS=--jwt`.
ROTATE_ARGS ?=

version_flag = $(if $(strip $(1)),--version $(1))

.PHONY: help up down cluster operator slurm status versions job rotate rotate-dry rollback cleanup-backups test lint clean

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "};{printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

up: cluster operator slurm status ## Full bring-up: KinD -> operator -> Slurm cluster

cluster: ## Create the KinD cluster
	@kind get clusters 2>/dev/null | grep -qx $(CLUSTER) \
		|| kind create cluster --name $(CLUSTER) --config $(KIND_CONFIG) \
			$(if $(strip $(KIND_NODE_IMAGE)),--image $(KIND_NODE_IMAGE))
	@kubectl config use-context kind-$(CLUSTER) >/dev/null

operator: ## Install cert-manager, CRDs and the Slinky operator
	helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
		$(call version_flag,$(CERT_MANAGER_VERSION)) \
		--namespace cert-manager --create-namespace --set crds.enabled=true \
		--wait --timeout 6m
	helm upgrade --install slurm-operator-crds \
		oci://ghcr.io/slinkyproject/charts/slurm-operator-crds \
		$(call version_flag,$(SLINKY_VERSION)) --wait --timeout 4m
	helm upgrade --install slurm-operator \
		oci://ghcr.io/slinkyproject/charts/slurm-operator \
		$(call version_flag,$(SLINKY_VERSION)) \
		--namespace $(NS_OP) --create-namespace --wait --timeout 5m

slurm: ## Deploy the Slurm cluster and wait for a node to register
	helm upgrade --install slurm oci://ghcr.io/slinkyproject/charts/slurm \
		$(call version_flag,$(SLINKY_VERSION)) \
		--values values/slurm.yaml \
		--namespace $(NS_SLURM) --create-namespace --timeout 8m
	@./scripts/wait-node-registered.sh $(NS_SLURM) $(REGISTER_TIMEOUT)

status: ## Show cluster state
	@echo; kubectl -n $(NS_SLURM) get pods -o wide
	@echo; kubectl -n $(NS_SLURM) get nodesets.slinky.slurm.net
	@echo; kubectl -n $(NS_SLURM) exec slurm-controller-0 -c slurmctld -- sinfo

# Not the kind node image or its digest: nothing here reads it. On the pinned
# track that is KIND_NODE_IMAGE above; on CI's latest track it is whatever the
# kind release defaults to, and only the kubelet version below hints at it.
versions: ## Record what is actually installed (charts, app versions, kubelet and runtime per node)
	@helm list -A
	@echo; kubectl get nodes -o custom-columns=NODE:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion

# A plain `srun` queues and waits forever when no node is available, which
# turns "the cluster is broken" into an indefinite hang with no output: that
# is what hung the first two CI runs for 27 and 43 minutes. `--immediate=N`
# gives up if the allocation cannot be granted in N seconds. (Not `--wait`,
# which is the grace period after the first task exits.)
JOB_WAIT ?= 120

job: ## Run a job end to end
	@# Wait for the controller first. Exec'ing into a restarting pod fails with
	@# `container not found ("slurmctld")`, which looks like a broken cluster and
	@# is really just an impatient client.
	@kubectl -n $(NS_SLURM) wait --for=condition=ready pod \
		-l app.kubernetes.io/component=controller --timeout=180s >/dev/null 2>&1 || true
	@kubectl -n $(NS_SLURM) exec slurm-controller-0 -c slurmctld -- \
		bash -lc 'srun --partition=all --ntasks=1 --time=1 --immediate=$(JOB_WAIT) hostname' && exit 0; \
	echo "  job did not start within $(JOB_WAIT)s:"; \
	kubectl -n $(NS_SLURM) exec slurm-controller-0 -c slurmctld -- sinfo -N -l 2>/dev/null || true; \
	kubectl -n $(NS_SLURM) exec slurm-controller-0 -c slurmctld -- squeue -l 2>/dev/null || true; \
	exit 1

rotate-dry: ## Preview an auth key rotation (checks and plan only)
	@./scripts/rotate-auth-key.sh -n $(NS_SLURM) --dry-run $(ROTATE_ARGS)

rotate: ## Rotate the Slurm auth key (drains, verifies, rolls back on failure)
	@./scripts/rotate-auth-key.sh -n $(NS_SLURM) $(ROTATE_ARGS)

rollback: ## Restore the key(s) the last rotation changed, cycle slurmd, verify
	@./scripts/rotate-auth-key.sh -n $(NS_SLURM) --rollback $(ROTATE_ARGS)

cleanup-backups: ## Delete the backup Secrets (they hold the previous key)
	@./scripts/rotate-auth-key.sh -n $(NS_SLURM) --cleanup

test: ## Offline tests of the rotation script against a fake kubectl (no cluster)
	@bash tests/run.sh

SHELL_SCRIPTS := $(wildcard scripts/*.sh scripts/lib/*.sh scripts/ci/*.sh tests/*.sh)
SHELLCHECK ?= shellcheck

lint: ## shellcheck and bash -n on every shell script
	@for f in $(SHELL_SCRIPTS); do bash -n "$$f" || exit 1; done
	$(SHELLCHECK) $(SHELL_SCRIPTS)

down: ## Delete the KinD cluster
	kind delete cluster --name $(CLUSTER)

clean: down ## Alias for down

print-%: ## Print a variable (used by CI and scripts/ci/validate-manifests.sh)
	@echo '$($*)'
