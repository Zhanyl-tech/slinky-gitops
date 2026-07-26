CLUSTER  ?= slinky
NS_SLURM ?= slurm
NS_OP    ?= slinky

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
	@until kubectl -n $(NS_SLURM) exec slurm-controller-0 -c slurmctld -- \
		sinfo --noheader 2>/dev/null | grep -qE 'idle|alloc|mix'; do sleep 10; done

status: ## Show cluster state
	@echo; kubectl -n $(NS_SLURM) get pods
	@echo; kubectl -n $(NS_SLURM) get nodesets.slinky.slurm.net
	@echo; kubectl -n $(NS_SLURM) exec slurm-controller-0 -c slurmctld -- sinfo

job: ## Run a job end to end
	@kubectl -n $(NS_SLURM) exec slurm-controller-0 -c slurmctld -- \
		bash -lc 'srun --partition=all --ntasks=1 --time=1 hostname'

rotate-dry: ## Preview an auth key rotation
	@./scripts/rotate-auth-key.sh -n $(NS_SLURM) --dry-run

rotate: ## Rotate the Slurm auth key (drains, verifies, rolls back on failure)
	@./scripts/rotate-auth-key.sh -n $(NS_SLURM)

rollback: ## Restore the previous auth key
	@./scripts/rotate-auth-key.sh -n $(NS_SLURM) --rollback

down: ## Delete the KinD cluster
	kind delete cluster --name $(CLUSTER)

clean: down ## Alias for down
