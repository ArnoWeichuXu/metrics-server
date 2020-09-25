# Common User-Settable Flags
# --------------------------
REGISTRY?=gcr.io/k8s-staging-metrics-server
ARCH?=amd64

# Release variables
# ------------------
GIT_COMMIT?=$(shell git rev-parse "HEAD^{commit}" 2>/dev/null)
GIT_TAG?=$(shell git describe --abbrev=0 --tags 2>/dev/null)
BUILD_DATE:=$(shell date -u +'%Y-%m-%dT%H:%M:%SZ')

# Consts
# ------
ALL_ARCHITECTURES=amd64 arm arm64 ppc64le s390x
export DOCKER_CLI_EXPERIMENTAL=enabled

# Computed variables
# ------------------
HAS_GOLANGCI:=$(shell which golangci-lint)
GOPATH:=$(shell go env GOPATH)
REPO_DIR:=$(shell pwd)
LDFLAGS=-w $(VERSION_LDFLAGS)

.PHONY: all
all: _output/$(ARCH)/metrics-server

# Build Rules
# -----------

src_deps=$(shell find pkg cmd -type f -name "*.go")
LDFLAGS:=-X sigs.k8s.io/metrics-server/pkg/version.gitVersion=$(GIT_TAG) -X sigs.k8s.io/metrics-server/pkg/version.gitCommit=$(GIT_COMMIT) -X sigs.k8s.io/metrics-server/pkg/version.buildDate=$(BUILD_DATE)
_output/%/metrics-server: $(src_deps) _output pkg/scraper/types_easyjson.go
	GOARCH=$* CGO_ENABLED=0 go build -mod=readonly -ldflags "$(LDFLAGS)" -o _output/$*/metrics-server sigs.k8s.io/metrics-server/cmd/metrics-server

pkg/scraper/types_easyjson.go: pkg/scraper/types.go
	go get github.com/mailru/easyjson/...
	$(GOPATH)/bin/easyjson -all pkg/scraper/types.go

_output:
	mkdir -p _output

# Image Rules
# -----------

.PHONY: container
container: container-$(ARCH)

.PHONY: container-*
container-%: pkg/scraper/types_easyjson.go
	docker build --pull -t $(REGISTRY)/metrics-server-$*:$(GIT_COMMIT) --build-arg GOARCH=$* --build-arg LDFLAGS='$(LDFLAGS)' .

# Official Container Push Rules
# -----------------------------

.PHONY: push
push: $(addprefix sub-push-,$(ALL_ARCHITECTURES)) push-multi-arch;

.PHONY: sub-push-*
sub-push-%: container-% do-push-% ;

.PHONY: do-push-*
do-push-%:
	docker tag $(REGISTRY)/metrics-server-$*:$(GIT_COMMIT) $(REGISTRY)/metrics-server-$*:$(GIT_TAG)
	docker push $(REGISTRY)/metrics-server-$*:$(GIT_TAG)

.PHONY: push-multi-arch
push-multi-arch:
	docker manifest create --amend $(REGISTRY)/metrics-server:$(GIT_TAG) $(shell echo $(ALL_ARCHITECTURES) | sed -e "s~[^ ]*~$(REGISTRY)/metrics-server\-&:$(GIT_TAG)~g")
	@for arch in $(ALL_ARCHITECTURES); do docker manifest annotate --arch $${arch} $(REGISTRY)/metrics-server:$(GIT_TAG) $(REGISTRY)/metrics-server-$${arch}:${GIT_TAG}; done
	docker manifest push --purge $(REGISTRY)/metrics-server:$(GIT_TAG)


# Release rules
# -------------

.PHONY: release-tag
release-tag:
	git tag $(GIT_TAG)
	git push origin $(GIT_TAG)

.PHONY: release-manifests
release-manifests:
	kubectl kustomize manifests/release > _output/components.yaml
	echo "Please upload file _output/components.yaml to GitHub release"

# Unit tests
# ----------

.PHONY: test-unit
test-unit:
ifeq ($(ARCH),amd64)
	GO111MODULE=on GOARCH=$(ARCH) go test -mod=readonly --test.short -race ./pkg/... ./cmd/...
else
	GO111MODULE=on GOARCH=$(ARCH) go test -mod=readonly --test.short ./pkg/... ./cmd/...
endif

# Binary tests
# ------------

.PHONY: test-version
test-version: container
	IMAGE=$(REGISTRY)/metrics-server-$(ARCH):$(GIT_COMMIT) EXPECTED_VERSION=$(GIT_TAG) ./test/version.sh

# E2e tests
# -----------

.PHONY: test-e2e
test-e2e: test-e2e-1.19

.PHONY: test-e2e-all
test-e2e-all: test-e2e-1.19 test-e2e-1.18 test-e2e-1.17

.PHONY: test-e2e-1.19
test-e2e-1.19: container-amd64
	KUBERNETES_VERSION=v1.19.1@sha256:98cf5288864662e37115e362b23e4369c8c4a408f99cbc06e58ac30ddc721600 IMAGE=$(REGISTRY)/metrics-server-amd64:$(GIT_COMMIT) ./test/e2e.sh

.PHONY: test-e2e-1.18
test-e2e-1.18: container-amd64
	KUBERNETES_VERSION=v1.18.8@sha256:f4bcc97a0ad6e7abaf3f643d890add7efe6ee4ab90baeb374b4f41a4c95567eb IMAGE=$(REGISTRY)/metrics-server-amd64:$(GIT_COMMIT) ./test/e2e.sh

.PHONY: test-e2e-1.17
test-e2e-1.17: container-amd64
	KUBERNETES_VERSION=v1.17.11@sha256:5240a7a2c34bf241afb54ac05669f8a46661912eab05705d660971eeb12f6555 IMAGE=$(REGISTRY)/metrics-server-amd64:$(GIT_COMMIT) ./test/e2e.sh


# Static analysis
# ---------------

.PHONY: verify
verify:
ifndef HAS_GOLANGCI
	curl -sfL https://install.goreleaser.com/github.com/golangci/golangci-lint.sh | sh -s -- -b $(GOPATH)/bin latest
endif
	golangci-lint run --timeout 10m --modules-download-mode=readonly

# Deprecated
.PHONY: lint
lint: verify

.PHONY: fmt
fmt:
	find pkg cmd -type f -name "*.go" | xargs gofmt -s -w

# Clean
# -----

.PHONY: clean
clean:
	rm -rf _output
