# Clones the data repository into /data, once: a repository with commits is left
# untouched (Belgo commits and pushes on its own afterwards, it never pulls).
set -eu

data=/data
git="${BELGO_GIT_PATH:-git}"

run_git() {
  "$git" -C "$data" -c "safe.directory=$data" "$@"
}

if [ -e "$data/.git" ]; then
  if run_git rev-parse --verify --quiet HEAD > /dev/null; then
    echo "$data is already a repository, nothing to clone"
    exit 0
  fi
  # A previous attempt failed after `git init` (the init container is retried).
  echo "$data has a repository without commit, cloning again"
  rm -rf "$data/.git"
fi

token="${BELGO_GIT_TOKEN:-}"
if [ -z "$token" ] && [ -n "${BELGO_GIT_TOKEN_FILE:-}" ]; then
  token="$(cat "$BELGO_GIT_TOKEN_FILE")"
fi

# Same credentials as Belgo: a basic authorization header from the environment,
# never in a command line nor in the repository configuration.
if [ -n "$token" ]; then
  username="${BELGO_GIT_USERNAME:-x-access-token}"
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0=http.extraHeader
  export GIT_CONFIG_VALUE_0="Authorization: Basic $(printf '%s:%s' "$username" "$token" | base64 -w 0)"
fi
export GIT_TERMINAL_PROMPT=0

run_git init --quiet --initial-branch="$CLONE_TARGET_BRANCH"
if [ -n "$CLONE_SOURCE_BRANCH" ]; then
  run_git fetch --quiet "$CLONE_REMOTE" "refs/heads/$CLONE_SOURCE_BRANCH"
else
  run_git fetch --quiet "$CLONE_REMOTE"
fi
# Fails instead of overwriting files already in the volume.
run_git checkout --quiet -B "$CLONE_TARGET_BRANCH" FETCH_HEAD
echo "Cloned $CLONE_REMOTE into $data on branch $CLONE_TARGET_BRANCH"
