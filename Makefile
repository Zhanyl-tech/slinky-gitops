CLUSTER  ?= slinky
NS_SLURM ?= slurm
NS_OP    ?= slinky
# How long to wait for a compute node to register. Generous, because pulling
# the Slurm images on a cold runner dominates.
REGISTER_TIMEOUT ?= 600

.PHONY: help up down cluster operator slurm status job rotate rotate-dry rollback clean

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "};{printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2}'

up: cluster operator slurm status ## Full bring-up: KinD -> operator -> Slurm cluster

cluster: ## Create the KinD cluster
	@kind get clusters 2>/dev/null | grep -qx $(CLUSTER) \
		|| kind create cluster --config kind/cluster.yaml
	@kubectl config use-context kind-$(CLUSTER) >/dev/null

operator: ## Install cert-manager, CRDs and the Slinky operator
	helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
		--namespace cert-manager --create-namespace --set crds.enabled=true \
		--wait --timeout 6m
	helm upgrade --install slurm-operator-crds \
		oci://ghcr.io/slinkyproject/charts/slurm-operator-crds --wait --timeout 4m
	helm upgrade --install slurm-operator \
		oci://ghcr.io/slinkyproject/charts/slurm-operator \
		--namespace $(NS_OP) --create-namespace --wait --timeout 5m

slurm: ## Deploy the Slurm cluster
	helm upgrade --install slurm oci://ghcr.io/slinkyproject/charts/slurm \
		--values values/slurm.yaml \
		--namespace $(NS_SLURM) --create-namespace --timeout 8m
	@echo "waiting for a node to register with the controller…"
	@# Bounded, and noisy on failure. An unbounded wait here hangs CI until the
	@# job timeout and reports nothing useful about why.
	@deadline=$$(( $$(date +%s) + $(REGISTER_TIMEOUT) )); \
	while [ $$(date +%s) -lt $$deadline ]; do \
		if kubectl -n $(NS_SLURM) exec slurm-controller-0 -c slurmctld -- \
			sinfo --noheader 2>/dev/null | grep -qE 'idle|alloc|mix'; then \
			echo "  node registered"; exit 0; \
		fi; sleep 10; \
	done; \
	echo "  no node registered within $(REGISTER_TIMEOUT)s — dumping state:"; \
	kubectl -n $(NS_SLURM) get pods -o wide; \
	kubectl -n $(NS_SLURM) get nodesets.slinky.slurm.net; \
	kubectl -n $(NS_SLURM) describe pods -l app.kubernetes.io/name=slurmd | tail -40; \
	exit 1

status: ## Show cluster state
	@echo; kubectl -n $(NS_SLURM) get pods
	@echo; kubectl -n $(NS_SLURM) get nodesets.slinky.slurm.net
	@echo; kubectl -n $(NS_SLURM) exec slurm-controller-0 -c slurmctld -- sinfo

# A plain `srun` queues and waits forever when no node is available, which
# turns "the cluster is broken" into an indefinite hang with no output.
# `--immediate=N` gives up if the allocation cannot be granted in N seconds.
# (Not `--wait`, which is the grace period after the first task exits.)
JOB_WAIT ?= 120

job: ## Run a job end to end
	@kubectl -n $(NS_SLURM) exec slurm-controller-0 -c slurmctld -- \
		bash -lc 'srun --partition=all --ntasks=1 --time=1 --immediate=$(JOB_WAIT) hostname' && exit 0; \
	echo "  job did not start within $(JOB_WAIT)s:"; \
	kubectl -n $(NS_SLURM) exec slurm-controller-0 -c slurmctld -- sinfo -N -l 2>/dev/null || true; \
	kubectl -n $(NS_SLURM) exec slurm-controller-0 -c slurmctld -- squeue -l 2>/dev/null || true; \
	exit 1

rotate-dry: ## Preview an auth key rotation
	@./scripts/rotate-auth-key.sh -n $(NS_SLURM) --dry-run

rotate: ## Rotate the Slurm auth key (drains, verifies, rolls back on failure)
	@./scripts/rotate-auth-key.sh -n $(NS_SLURM)

rollback: ## Restore the previous auth key
	@./scripts/rotate-auth-key.sh -n $(NS_SLURM) --rollback

down: ## Delete the KinD cluster
	kind delete cluster --name $(CLUSTER)

clean: down ## Alias for down
