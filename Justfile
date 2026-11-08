# The version comes from VERSION; the image goes to Docker Hub (log in first with
# `docker login`; BELGO_DOCKER_REPOSITORY overrides the repository).
version := trim(read("VERSION"))
docker_image := "belgo:" + version
docker_repository := env("BELGO_DOCKER_REPOSITORY", "nboisvert/belgo")

# Starts the dev environment by default
default: dev

# Fetches dependencies and builds assets
setup: deps
	mix assets.build

# Copies the example inventory to ./data (never overwrites)
seed:
	test -e data || cp -r examples/inventory data

# Starts an iex session with the Phoenix server
dev: deps
	iex -S mix phx.server

# Starts an iex session
iex:
	iex -S mix

# Runs the tests
test:
	mix test

# Formats, compiles without warnings, lints and tests
check:
	mix format --check-formatted
	mix compile --warnings-as-errors
	mix credo
	mix test
	just chart-check

# Installs dependencies
deps:
	mix deps.get

# Cleans up dependencies and build artifacts
clean:
	rm -rf _build deps

# Builds the release with Nix
release:
	nix build .#belgo

# Builds the Docker image with Nix and loads it
docker-build:
	nix build .#dockerImage -o result-image
	docker load < result-image

# Tags the built image for Docker Hub, with its version and as latest
docker-tag:
	docker tag {{docker_image}} {{docker_repository}}:{{version}}
	docker tag {{docker_image}} {{docker_repository}}:latest

# Pushes both tags to Docker Hub
docker-push:
	docker push {{docker_repository}}:{{version}}
	docker push {{docker_repository}}:latest

# Builds, tags and pushes the image of the current VERSION (what CI does on release)
release-docker: docker-build docker-tag docker-push

# Runs the image against ./data, trusting a fake Authelia user header is up to you
docker-run:
	docker run --rm \
		-e SECRET_KEY_BASE=$SECRET_KEY_BASE \
		-e LIVE_VIEW_SALT=$LIVE_VIEW_SALT \
		-v $PWD/data:/data \
		-p 4001:4000 \
		{{docker_image}}

# Lints the Helm chart, runs its unit tests and validates every example against the
# Kubernetes schemas (CRDs from the datree catalog); the chart follows VERSION
chart-check:
	test "$(helm show chart charts/belgo | sed -n 's/^version: //p')" = "{{version}}" || (echo "charts/belgo/Chart.yaml version is not {{version}}" && exit 1)
	test "$(helm show chart charts/belgo | sed -n 's/^appVersion: //p' | tr -d '\"')" = "{{version}}" || (echo "charts/belgo/Chart.yaml appVersion is not {{version}}" && exit 1)
	helm lint --strict charts/belgo --values charts/belgo/ci/default-values.yaml
	helm unittest charts/belgo
	for values in charts/belgo/ci/*-values.yaml; do \
		helm template belgo charts/belgo --namespace belgo --values "$values" \
			| kubeconform -strict -summary -schema-location default \
				-schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{{{.Group}}/{{{{.ResourceKind}}_{{{{.ResourceAPIVersion}}.json' \
			|| exit 1; \
	done
