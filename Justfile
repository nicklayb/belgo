# The version comes from VERSION; the image goes to Docker Hub (log in first with
# `docker login`; BELGO_DOCKER_REPOSITORY overrides the repository).
version := trim(read("VERSION"))
docker_image := "belgo:" + version
docker_repository := env("BELGO_DOCKER_REPOSITORY", "nboisvert/belgo")
# OCI repository of the Helm chart (log in first with `helm registry login ghcr.io`)
chart_repository := env("BELGO_CHART_REPOSITORY", "oci://ghcr.io/nicklayb/charts")

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

# Packages the Helm chart and pushes it to its OCI repository (what CI does when the
# chart version is new; log in first with `helm registry login ghcr.io`)
release-chart:
	#!/usr/bin/env bash
	set -euo pipefail
	chart_version="$(sed -n 's/^version: //p' charts/belgo/Chart.yaml | tr -d '"')"
	helm package charts/belgo --destination _build/chart
	helm push "_build/chart/belgo-$chart_version.tgz" {{chart_repository}}

# Fails when charts/belgo changed since `base` without a new chart version (published
# versions are never replaced, an unchanged version would not be published)
chart-version-bumped base="origin/main":
	#!/usr/bin/env bash
	set -euo pipefail
	if git diff --quiet {{base}} -- charts/belgo; then
		echo "charts/belgo is unchanged since {{base}}"
		exit 0
	fi
	read_version() { sed -n 's/^version: //p' | tr -d '"'; }
	if ! base_chart="$(git show {{base}}:charts/belgo/Chart.yaml 2>/dev/null)"; then
		echo "charts/belgo is new since {{base}}"
		exit 0
	fi
	base_version="$(read_version <<< "$base_chart")"
	current_version="$(read_version < charts/belgo/Chart.yaml)"
	if [ "$base_version" = "$current_version" ]; then
		echo "charts/belgo changed since {{base}}: bump its version (still $current_version) in charts/belgo/Chart.yaml"
		exit 1
	fi
	echo "Chart version $base_version -> $current_version"

# Bumps VERSION by a semver level (patch | minor | major), with the chart's
# appVersion and its version (same level, a new app version is a chart change)
bump level:
	#!/usr/bin/env bash
	set -euo pipefail
	app_version="$(just _next-version {{level}} "$(tr -d '[:space:]' < VERSION)")"
	chart_version="$(just _next-version {{level}} "$(sed -n 's/^version: //p' charts/belgo/Chart.yaml | tr -d '"')")"
	echo "$app_version" > VERSION
	sed -i "s/^appVersion: .*/appVersion: \"$app_version\"/; s/^version: .*/version: $chart_version/" charts/belgo/Chart.yaml
	echo "Belgo $app_version, chart $chart_version"

# Bumps only the chart version by a semver level, for a change of the chart alone
bump-chart level:
	#!/usr/bin/env bash
	set -euo pipefail
	chart_version="$(just _next-version {{level}} "$(sed -n 's/^version: //p' charts/belgo/Chart.yaml | tr -d '"')")"
	sed -i "s/^version: .*/version: $chart_version/" charts/belgo/Chart.yaml
	echo "Chart $chart_version"

# Prints the version following `current` at a semver level (lower parts reset)
_next-version level current:
	#!/usr/bin/env bash
	set -euo pipefail
	if [[ ! "{{current}}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
		echo "Not a MAJOR.MINOR.PATCH version: {{current}}" >&2
		exit 1
	fi
	major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"
	case "{{level}}" in
		patch) echo "$major.$minor.$((patch + 1))" ;;
		minor) echo "$major.$((minor + 1)).0" ;;
		major) echo "$((major + 1)).0.0" ;;
		*) echo "Unknown level {{level}}: patch, minor or major" >&2; exit 1 ;;
	esac

# Lints the Helm chart, runs its unit tests and validates every example against the
# Kubernetes schemas (CRDs from the datree catalog); its appVersion follows VERSION
chart-check:
	test "$(helm show chart charts/belgo | sed -n 's/^appVersion: //p' | tr -d '\"')" = "{{version}}" || (echo "charts/belgo/Chart.yaml appVersion is not {{version}}" && exit 1)
	helm lint --strict charts/belgo --values charts/belgo/ci/default-values.yaml
	helm unittest charts/belgo
	for values in charts/belgo/ci/*-values.yaml; do \
		helm template belgo charts/belgo --namespace belgo --values "$values" \
			| kubeconform -strict -summary -schema-location default \
				-schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{{{.Group}}/{{{{.ResourceKind}}_{{{{.ResourceAPIVersion}}.json' \
			|| exit 1; \
	done
