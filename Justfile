docker_registry := "nboisvert"
version := "0.1.0"
docker_image := "belgo:" + version
docker_remote_image := docker_registry / docker_image

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

docker-tag:
	docker tag {{docker_image}} {{docker_remote_image}}

docker-push:
	docker push {{docker_remote_image}}

release-docker: docker-build docker-tag docker-push

# Runs the image against ./data, trusting a fake Authelia user header is up to you
docker-run:
	docker run --rm \
		-e SECRET_KEY_BASE=$SECRET_KEY_BASE \
		-e LIVE_VIEW_SALT=$LIVE_VIEW_SALT \
		-v $PWD/data:/data \
		-p 4001:4000 \
		{{docker_image}}
