#!/usr/bin/env bats

# Load test helpers
BATS_TEST_DIRNAME="${BATS_TEST_DIRNAME:-$(dirname "$BATS_TEST_FILENAME")}"
load test_helper/bats-support/load
load test_helper/bats-assert/load
load test_helper/bats-file/load

# Source the functions to test
source "${BATS_TEST_DIRNAME}/../gwtmux.sh"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Global timeout for condition waits (in 0.1s increments)
# Default: 100 iterations = 10 seconds. Override via environment for CI.
WAIT_TIMEOUT="${GWTMUX_TEST_TIMEOUT:-100}"

# Real tmux, resolved before the stub dir shadows it on PATH.
TMUX_BIN="$(command -v tmux)"

# Generic wait helper - polls until condition succeeds or timeout
# Usage: wait_until "condition command"
# Returns: 0 if condition succeeded, 1 if timed out
wait_until() {
  local condition="$1"
  local elapsed=0
  while ! eval "$condition" && [ "$elapsed" -lt "$WAIT_TIMEOUT" ]; do
    sleep 0.1
    elapsed=$((elapsed + 1))
  done
  eval "$condition"
}

# Convenience wrappers for common conditions
wait_for_dir_deleted() { wait_until "[ ! -d '$1' ]"; }
wait_for_dir_exists() { wait_until "[ -d '$1' ]"; }
wait_for_window_exists() { wait_until "get_tmux_windows | grep -Fxq '$1'"; }
wait_for_window_closed() { wait_until "! get_tmux_windows | grep -Fxq '$1'"; }

# Send a command to a tmux pane, tagged so we can tell when it has FINISHED.
#
# Waiting on a side effect (a directory appearing, a window appearing) only
# proves the command reached the step that produces it. gwtmux does several
# things per invocation - --rename moves the directory first and only then
# pushes, deletes the old remote branch and sets upstream - so a test that
# resumes on the directory races the remaining steps: it passes on a fast
# machine and fails on a loaded one. Pair send_cmd with wait_cmd_done, after
# answering any prompts, to wait for the command itself.
_CMD_SEQ=0
send_cmd() {
  local target="$1" cmd="$2"
  _CMD_SEQ=$((_CMD_SEQ + 1))
  CMD_MARKER="$TEST_TEMP_DIR/cmd_done_$_CMD_SEQ"
  # Resolve the target to a concrete pane id up front. Several gwtmux
  # invocations kill the window they run in, so the trailing marker write never
  # happens and wait_cmd_done has to fall back to "the pane is gone". A session
  # or window name cannot express that: it just re-resolves to whatever is
  # active now, and stays valid as long as the session has any window left.
  #
  # Fail loudly if it does not resolve. tmux reports a missing target by
  # printing nothing and still exiting 0, and "send-keys -t ''" then falls
  # back to the server's *current* pane - as does "list-panes -t ''", so
  # wait_cmd_done would not notice either. The suite shares the default tmux
  # server with whatever else is running on it, so an unresolved target would
  # type this command into an unrelated pane.
  CMD_TARGET="$(tmux display-message -p -t "$target" '#{pane_id}')"
  if [[ ! "$CMD_TARGET" =~ ^%[0-9]+$ ]]; then
    echo "send_cmd: target '$target' did not resolve to a pane id" >&2
    return 1
  fi
  rm -f "$CMD_MARKER"
  tmux send-keys -t "$CMD_TARGET" "$cmd; echo \$? > '$CMD_MARKER'" Enter
}

# Wait for the last send_cmd to finish. Some gwtmux invocations kill the window
# they run in, so the trailing marker write can never happen; treat the target
# disappearing as completion too.
wait_cmd_done() {
  wait_until "[ -f '$CMD_MARKER' ] || ! tmux list-panes -t '$CMD_TARGET' >/dev/null 2>&1"
}

# Confirm new branch creation prompt (sends "y" when prompt appears)
confirm_branch_creation() {
  local target="${1:-$TEST_SESSION}"
  wait_until "tmux capture-pane -t '$target' -p | grep -q 'Create new branch'"
  tmux send-keys -t "$target" "y" Enter
}

# Confirm or deny nested worktree removal prompt
confirm_nested_worktree_removal() {
  local target="${1:-$TEST_SESSION}"
  wait_until "tmux capture-pane -t '$target' -p | grep -q 'Remove nested worktrees'"
  tmux send-keys -t "$target" "y" Enter
}
deny_nested_worktree_removal() {
  local target="${1:-$TEST_SESSION}"
  wait_until "tmux capture-pane -t '$target' -p | grep -q 'Remove nested worktrees'"
  tmux send-keys -t "$target" "n" Enter
}

# Setup a basic git repository with a bare remote
setup_git_repos() {
  # Create bare "remote" repository
  REMOTE_REPO="$TEST_TEMP_DIR/remote.git"
  git init --bare "$REMOTE_REPO" >/dev/null 2>&1

  # Create main repository
  MAIN_REPO="$TEST_TEMP_DIR/repo"
  git clone "$REMOTE_REPO" "$MAIN_REPO" >/dev/null 2>&1

  cd "$MAIN_REPO"

  # Configure git user for commits
  git config user.name "Test User"
  git config user.email "test@example.com"

  # Create initial commit on main branch
  git checkout -b main >/dev/null 2>&1
  echo "initial" >README.md
  git add README.md
  git commit -m "Initial commit" >/dev/null 2>&1
  git push -u origin main >/dev/null 2>&1

  # Set symbolic-ref for origin/HEAD
  cd "$REMOTE_REPO"
  git symbolic-ref HEAD refs/heads/main
  cd "$MAIN_REPO"
  git remote set-head origin main >/dev/null 2>&1
}

# Setup worktree structure: <repo-name>/default/.git layout
setup_worktree_structure() {
  local repo_name="${1:-testrepo}"

  # Create directory structure
  WORKTREE_PARENT="$TEST_TEMP_DIR/$repo_name"
  mkdir -p "$WORKTREE_PARENT"

  # Move repo to be the default worktree
  mv "$MAIN_REPO" "$WORKTREE_PARENT/default"
  MAIN_REPO="$WORKTREE_PARENT/default"
}

# Setup a flat repo: a plain clone at $TEST_TEMP_DIR/flat/<name> with its own
# bare remote and no default/ wrapper, so the repo root directory is what gwtmux
# names the window after.
setup_flat_repo() {
  local repo_name="${1:-flatrepo}"

  FLAT_REMOTE="$TEST_TEMP_DIR/flat-remote-$repo_name.git"
  git init --bare "$FLAT_REMOTE" >/dev/null 2>&1
  git -C "$FLAT_REMOTE" symbolic-ref HEAD refs/heads/main

  FLAT_PARENT="$TEST_TEMP_DIR/flat"
  mkdir -p "$FLAT_PARENT"
  FLAT_REPO="$FLAT_PARENT/$repo_name"
  git clone "$FLAT_REMOTE" "$FLAT_REPO" >/dev/null 2>&1

  git -C "$FLAT_REPO" config user.name "Test User"
  git -C "$FLAT_REPO" config user.email "test@example.com"
  git -C "$FLAT_REPO" checkout -b main >/dev/null 2>&1
  echo "initial" >"$FLAT_REPO/README.md"
  git -C "$FLAT_REPO" add README.md
  git -C "$FLAT_REPO" commit -m "Initial commit" >/dev/null 2>&1
  git -C "$FLAT_REPO" push -u origin main >/dev/null 2>&1
  git -C "$FLAT_REPO" remote set-head origin main >/dev/null 2>&1
}

# Setup a git repo that CONTAINS other repos, the way a dotfiles repo in $HOME
# or a monorepo above ~/repos does. Nothing below it is tracked; it exists so
# that the repo resolver can reach it from any directory underneath, which is
# what made no-arg mode pick the wrong repo. Its own worktree gives the windows
# it must NOT open a name to assert against ("ancestor", "ancestor/ancestor-wt").
setup_ancestor_repo() {
  ANCESTOR_REPO="$TEST_TEMP_DIR/ancestor"
  mkdir -p "$ANCESTOR_REPO"
  git init "$ANCESTOR_REPO" >/dev/null 2>&1
  git -C "$ANCESTOR_REPO" config user.name "Test User"
  git -C "$ANCESTOR_REPO" config user.email "test@example.com"
  echo "dotfiles" >"$ANCESTOR_REPO/profile"
  git -C "$ANCESTOR_REPO" add profile
  git -C "$ANCESTOR_REPO" commit -m "Initial commit" >/dev/null 2>&1
  git -C "$ANCESTOR_REPO" worktree add -b ancestor-wt \
    "$TEST_TEMP_DIR/ancestor-wt" >/dev/null 2>&1
}

# Create a fake gh command that returns a PR branch name
stub_gh_pr() {
  local pr_number="$1"
  local branch_name="$2"

  cat >"$STUB_DIR/gh" <<EOF
#!/bin/bash
if [[ "\$1" == "pr" && "\$2" == "view" && "\$3" == "$pr_number" ]]; then
  echo "$branch_name"
  exit 0
fi
exit 1
EOF
  chmod +x "$STUB_DIR/gh"
}

# Create a fake gh command that always fails
stub_gh_fail() {
  cat >"$STUB_DIR/gh" <<EOF
#!/bin/bash
exit 1
EOF
  chmod +x "$STUB_DIR/gh"
}

stub_gh_pr_multi() {
  # Usage: stub_gh_pr_multi "123" "branch-a" "456" "branch-b"
  local script='#!/bin/bash\n'
  while [[ $# -ge 2 ]]; do
    script+="if [[ \"\$1\" == \"pr\" && \"\$2\" == \"view\" && \"\$3\" == \"$1\" ]]; then echo \"$2\"; exit 0; fi\n"
    shift 2
  done
  script+='exit 1'
  printf "$script" > "$STUB_DIR/gh"
  chmod +x "$STUB_DIR/gh"
}

# Get tmux windows for test session
get_tmux_windows() {
  tmux list-windows -t "$TEST_SESSION" -F "#W" 2>/dev/null || true
}

# Count tmux windows in the test session.
#
# Not "| wc -l": BSD wc right-pads its output to width 8, so on macOS a count
# reads "       4". bats' assert_equal is a string comparison, so a padded
# count never matches the unpadded result of "$((count + 1))" even when the
# two numbers are equal. GNU wc does not pad, which is why CI never saw this.
get_window_count() {
  local -a windows=()
  local line
  while IFS= read -r line; do
    windows+=("$line")
  done < <(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" 2>/dev/null)
  echo "${#windows[@]}"
}

# Check if tmux window exists
tmux_window_exists() {
  local window_name="$1"
  get_tmux_windows | grep -Fxq "$window_name"
}

# Get current tmux window name
get_current_window() {
  tmux display-message -t "$TEST_SESSION" -p '#W' 2>/dev/null || true
}

# ============================================================================
# SETUP / TEARDOWN
# ============================================================================

setup() {
  # Use bats built-in temp directory, resolved to its physical path.
  #
  # On macOS $BATS_TEST_TMPDIR sits under /var/folders, and /var is a symlink
  # to /private/var. git reports worktree paths physically ("/private/var/..."),
  # while $PWD in a tmux pane keeps the logical "/var/..." form. gwtmux's no-arg
  # mode opens only the worktrees whose parent directory equals $PWD, so under
  # the logical path it matched nothing, created no windows and still exited 0.
  # Linux CI has no such symlink, so the suite was green there.
  TEST_TEMP_DIR="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"

  # Isolate git from the developer's global/system config. Without this, a
  # global "commit.gpgsign = true" makes every git commit below try to sign,
  # which fails non-interactively: the commit fails, then the push, then
  # "remote set-head", and setup_git_repos exits 128 so every test errors in
  # setup. CI only passes because its global config happens to be empty.
  TEST_GITCONFIG="$TEST_TEMP_DIR/gitconfig"
  cat >"$TEST_GITCONFIG" <<'GITCONFIG'
[user]
	name = Test User
	email = test@example.com
[init]
	defaultBranch = main
[commit]
	gpgsign = false
[tag]
	gpgsign = false
GITCONFIG
  export GIT_CONFIG_GLOBAL="$TEST_GITCONFIG"
  export GIT_CONFIG_SYSTEM=/dev/null

  # Create unique tmux session name for this test
  TEST_SESSION="bats_test_$$_${BATS_TEST_NUMBER}"

  # Setup PATH for stubs
  STUB_DIR="$TEST_TEMP_DIR/stubs"
  mkdir -p "$STUB_DIR"

  # Create a temporary bashrc that sources gwtmux - this ensures gwtmux is available
  # in all new tmux windows, not just the first one
  # Run every test against its own private tmux SERVER, never the developer's.
  #
  # The suite calls bare "tmux", which by default talks to the server the
  # developer is attached to: test sessions show up in their session list, and a
  # gwtmux call whose target fails to resolve falls back to that server's current
  # pane, so windows get created and killed in the developer's own session. Runs
  # have leaked windows and sessions into a live session this way.
  #
  # TMUX_TMPDIR is NOT enough. A tmux client takes its socket from $TMUX when that
  # is set, ignoring TMUX_TMPDIR - and $TMUX is set whenever the suite is run from
  # inside tmux, which is the normal case for this project. So the socket is
  # forced with an explicit "-S" through a stub on PATH, which cannot be
  # overridden by inherited environment.
  #
  # The socket lives in a short directory of its own rather than under
  # $BATS_TEST_TMPDIR: a unix socket path is capped near 104 bytes and the bats
  # temp dir already spends ~75 of them.
  TEST_TMUX_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gwtmux-tmux-XXXXXX")"
  TEST_TMUX_SOCKET="$TEST_TMUX_DIR/s"
  cat > "$STUB_DIR/tmux" <<EOF
#!/bin/bash
exec "$TMUX_BIN" -S "$TEST_TMUX_SOCKET" "\$@"
EOF
  chmod +x "$STUB_DIR/tmux"

  TEST_BASHRC="$TEST_TEMP_DIR/test_bashrc"
  cat > "$TEST_BASHRC" <<EOF
source "${BATS_TEST_DIRNAME}/../gwtmux.sh"
export PATH="$STUB_DIR:\$PATH"
export GIT_CONFIG_GLOBAL="$TEST_GITCONFIG"
export GIT_CONFIG_SYSTEM=/dev/null
EOF

  # Put the stubs (including the socket-pinning tmux) on PATH before the first
  # tmux call in this process.
  export PATH="$STUB_DIR:$PATH"

  # Create detached tmux session with our custom shell init
  # Use bash -i to ensure it's interactive and reads our rc file
  tmux new-session -d -s "$TEST_SESSION" -c "$TEST_TEMP_DIR" "bash --rcfile '$TEST_BASHRC' -i" 2>/dev/null
  sleep 0.1  # Wait for shell to start

  # Configure new windows to also use our bashrc
  tmux set-option -t "$TEST_SESSION" default-command "bash --rcfile '$TEST_BASHRC' -i"

  # Set TMUX variable so functions think we're in tmux (for direct calls in test
  # process). The first field must be the private server's socket, or these calls
  # would reach the developer's default server instead.
  export TMUX="$TEST_TMUX_SOCKET,$TEST_SESSION,0"

  # Setup git repos
  setup_git_repos
}

teardown() {
  # Scoped to this test's own socket by the tmux stub. Never "kill-server":
  # if the socket were ever unset or wrong, that would take down the developer's
  # tmux server along with everything running in it.
  tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true

  # The socket dir lives outside BATS_TEST_TMPDIR, so remove it explicitly.
  if [[ -n "$TEST_TMUX_DIR" && "$TEST_TMUX_DIR" == */gwtmux-tmux-* ]]; then
    rm -rf "$TEST_TMUX_DIR"
  fi

  # Stubs are automatically cleaned up when BATS_TEST_TMPDIR is removed
}


# ============================================================================
# TESTS: gwtmux
# ============================================================================

# ----------------------------------------------------------------------------
# Basic functionality
# ----------------------------------------------------------------------------

@test "gwtmux: creates worktree and window for new branch" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  send_cmd "$TEST_SESSION" "cd $MAIN_REPO && gwtmux new-feature 2>&1; echo EXIT_CODE:\$?"
  confirm_branch_creation "$TEST_SESSION"
  wait_for_dir_exists "$WORKTREE_PARENT/new-feature"
  wait_cmd_done

  # Check what happened in tmux
  run tmux capture-pane -t "$TEST_SESSION" -p
  echo "Tmux pane output:"
  echo "$output"

  assert_dir_exists "$WORKTREE_PARENT/new-feature"
  run get_tmux_windows
  assert_output --partial "myrepo/new-feature"

  # Verify new branch is based on origin/main, not local main
  local origin_head local_head branch_head
  origin_head="$(git -C "$MAIN_REPO" rev-parse origin/main)"
  local_head="$(git -C "$MAIN_REPO" rev-parse main)"
  branch_head="$(git -C "$WORKTREE_PARENT/new-feature" rev-parse HEAD)"
  # In this setup local and remote are the same, so also check the diverged case below
  assert_equal "$branch_head" "$origin_head"
}

@test "gwtmux: new branch bases off origin/main, not local main" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Advance origin/main beyond local main
  git -C "$BARE_REPO" commit --allow-empty -m "remote-only-commit"
  git -C "$MAIN_REPO" fetch origin

  local origin_head local_head
  origin_head="$(git -C "$MAIN_REPO" rev-parse origin/main)"
  local_head="$(git -C "$MAIN_REPO" rev-parse main)"
  # Confirm they actually diverged
  assert_not_equal "$origin_head" "$local_head"

  send_cmd "$TEST_SESSION" "cd $MAIN_REPO && gwtmux remote-branch 2>&1; echo EXIT_CODE:\$?"
  confirm_branch_creation "$TEST_SESSION"
  wait_for_dir_exists "$WORKTREE_PARENT/remote-branch"
  wait_cmd_done

  local branch_head
  branch_head="$(git -C "$WORKTREE_PARENT/remote-branch" rev-parse HEAD)"
  assert_equal "$branch_head" "$origin_head"
}

@test "gwtmux: new branch has no upstream tracking" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  send_cmd "$TEST_SESSION" "cd $MAIN_REPO && gwtmux no-track-test 2>&1; echo EXIT_CODE:\$?"
  confirm_branch_creation "$TEST_SESSION"
  wait_for_dir_exists "$WORKTREE_PARENT/no-track-test"
  wait_cmd_done

  # New branches should not track origin/main
  run git -C "$WORKTREE_PARENT/no-track-test" config branch.no-track-test.remote
  assert_failure
  run git -C "$WORKTREE_PARENT/no-track-test" config branch.no-track-test.merge
  assert_failure
}

@test "gwtmux: creates worktree from existing local branch" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create a local branch
  git checkout -b existing-branch >/dev/null 2>&1
  git checkout main >/dev/null 2>&1

  send_cmd "$TEST_SESSION" "cd $MAIN_REPO && gwtmux existing-branch"
  wait_for_dir_exists "$WORKTREE_PARENT/existing-branch"
  wait_cmd_done

  assert_dir_exists "$WORKTREE_PARENT/existing-branch"
  run get_tmux_windows
  assert_output --partial "myrepo/existing-branch"
}

@test "gwtmux: creates worktree as sibling of repo root when run from a subdirectory" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Nested subdirectory of the main repo
  mkdir -p "$MAIN_REPO/src/deep"

  send_cmd "$TEST_SESSION" "cd $MAIN_REPO/src/deep && gwtmux subdir-branch 2>&1"
  confirm_branch_creation "$TEST_SESSION"
  wait_for_dir_exists "$WORKTREE_PARENT/subdir-branch"
  wait_cmd_done

  # Sibling of the repo root, not nested inside the repo
  assert_dir_exists "$WORKTREE_PARENT/subdir-branch"
  refute [ -d "$MAIN_REPO/src/subdir-branch" ]
  refute [ -d "$MAIN_REPO/subdir-branch" ]
  run get_tmux_windows
  assert_output --partial "myrepo/subdir-branch"
}

@test "gwtmux: creates worktree as sibling when run from a subdirectory of a worktree" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add -b first-branch "$WORKTREE_PARENT/first-branch" >/dev/null 2>&1
  mkdir -p "$WORKTREE_PARENT/first-branch/src/deep"

  send_cmd "$TEST_SESSION" "cd $WORKTREE_PARENT/first-branch/src/deep && gwtmux second-branch 2>&1"
  confirm_branch_creation "$TEST_SESSION"
  wait_for_dir_exists "$WORKTREE_PARENT/second-branch"
  wait_cmd_done

  assert_dir_exists "$WORKTREE_PARENT/second-branch"
  refute [ -d "$WORKTREE_PARENT/first-branch/src/second-branch" ]
  refute [ -d "$WORKTREE_PARENT/first-branch/second-branch" ]
}

@test "gwtmux: creates worktree from existing remote branch" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create a remote branch (simulate another developer's branch)
  git checkout -b remote-feature >/dev/null 2>&1
  echo "remote work" >remote.txt
  git add remote.txt
  git commit -m "Remote work" >/dev/null 2>&1
  git push -u origin remote-feature >/dev/null 2>&1
  git checkout main >/dev/null 2>&1
  git branch -D remote-feature >/dev/null 2>&1

  # Fetch to update remote refs
  git fetch >/dev/null 2>&1

  send_cmd "$TEST_SESSION" "cd $MAIN_REPO && gwtmux remote-feature"
  wait_for_dir_exists "$WORKTREE_PARENT/remote-feature"
  wait_cmd_done

  assert_dir_exists "$WORKTREE_PARENT/remote-feature"
  run get_tmux_windows
  assert_output --partial "myrepo/remote-feature"
}

@test "gwtmux: handles PR number via gh CLI" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  stub_gh_pr "123" "pr-123-feature"

  send_cmd "$TEST_SESSION" "cd $MAIN_REPO && gwtmux 123"
  confirm_branch_creation "$TEST_SESSION"
  wait_for_dir_exists "$WORKTREE_PARENT/pr-123-feature"
  wait_cmd_done

  assert_dir_exists "$WORKTREE_PARENT/pr-123-feature"
  run get_tmux_windows
  assert_output --partial "myrepo/pr-123-feature"
}

@test "gwtmux: falls back to branch name when gh fails" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  stub_gh_fail

  send_cmd "$TEST_SESSION" "cd $MAIN_REPO && gwtmux not-a-pr"
  confirm_branch_creation "$TEST_SESSION"
  wait_for_dir_exists "$WORKTREE_PARENT/not-a-pr"
  wait_cmd_done

  # Should create worktree with "not-a-pr" as branch name
  assert_dir_exists "$WORKTREE_PARENT/not-a-pr"
}

@test "gwtmux: selects existing window if already exists" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create worktree first
  git worktree add -b existing "$WORKTREE_PARENT/existing" main >/dev/null 2>&1

  # Create tmux window for it
  tmux new-window -t "$TEST_SESSION" -n "myrepo/existing" -c "$WORKTREE_PARENT/existing" 2>/dev/null

  # Try to create again - should just select the window
  local first_window=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)
  send_cmd "$first_window" "cd $MAIN_REPO && gwtmux existing"
  wait_for_window_exists "myrepo/existing"
  wait_cmd_done
  # Without this the claim holds just as well when gwtmux fails outright: a
  # command that does nothing also creates no duplicate window.
  assert_equal "$(cat "$CMD_MARKER")" "0"

  # Should have selected the window (not created a duplicate)
  run get_tmux_windows
  refute_output --partial "myrepo/existing
myrepo/existing"
}

@test "gwtmux: opens existing worktree via relative path" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create a worktree
  git worktree add -b existing-wt "$WORKTREE_PARENT/existing-wt" main >/dev/null 2>&1

  # Open the other worktree via relative path from default worktree
  send_cmd "$TEST_SESSION" "cd $WORKTREE_PARENT/default && gwtmux ../existing-wt"
  wait_for_window_exists "myrepo/existing-wt"
  wait_cmd_done

  # Window should exist
  run get_tmux_windows
  assert_output --partial "myrepo/existing-wt"
}

@test "gwtmux: opens existing worktree via absolute path" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create a worktree
  git worktree add -b existing-wt "$WORKTREE_PARENT/existing-wt" main >/dev/null 2>&1

  # Open via absolute path
  send_cmd "$TEST_SESSION" "cd $MAIN_REPO && gwtmux $WORKTREE_PARENT/existing-wt"
  wait_for_window_exists "myrepo/existing-wt"
  wait_cmd_done

  # Window should exist
  run get_tmux_windows
  assert_output --partial "myrepo/existing-wt"
}

@test "gwtmux: opens worktree from different repo via path" {
  setup_worktree_structure "myrepo"

  # Create a second repo with worktree structure
  local OTHER_REPO_PARENT="$TEST_TEMP_DIR/otherrepo"
  mkdir -p "$OTHER_REPO_PARENT/default"
  git init "$OTHER_REPO_PARENT/default" >/dev/null 2>&1
  git -C "$OTHER_REPO_PARENT/default" config user.name "Test"
  git -C "$OTHER_REPO_PARENT/default" config user.email "test@test.com"
  echo "test" >"$OTHER_REPO_PARENT/default/file.txt"
  git -C "$OTHER_REPO_PARENT/default" add .
  git -C "$OTHER_REPO_PARENT/default" commit -m "init" >/dev/null 2>&1

  # Create a worktree in the other repo
  git -C "$OTHER_REPO_PARENT/default" worktree add -b feature "$OTHER_REPO_PARENT/feature" >/dev/null 2>&1

  # From myrepo, open the other repo's worktree via relative path
  send_cmd "$TEST_SESSION" "cd $WORKTREE_PARENT/default && gwtmux ../../otherrepo/feature"
  wait_for_window_exists "otherrepo/feature"
  wait_cmd_done

  # Window should have correct repo name from the OTHER repo
  run get_tmux_windows
  assert_output --partial "otherrepo/feature"
}

@test "gwtmux: opens default worktree of different repo via path" {
  setup_worktree_structure "myrepo"

  # Create a second repo with worktree structure (default/.git is main repo)
  local OTHER_REPO_PARENT="$TEST_TEMP_DIR/otherrepo"
  mkdir -p "$OTHER_REPO_PARENT/default"
  git init "$OTHER_REPO_PARENT/default" >/dev/null 2>&1
  git -C "$OTHER_REPO_PARENT/default" config user.name "Test"
  git -C "$OTHER_REPO_PARENT/default" config user.email "test@test.com"
  echo "test" >"$OTHER_REPO_PARENT/default/file.txt"
  git -C "$OTHER_REPO_PARENT/default" add .
  git -C "$OTHER_REPO_PARENT/default" commit -m "init" >/dev/null 2>&1

  # From myrepo, open the other repo's default worktree via relative path
  # This tests the .git case where git-common-dir returns ".git"
  send_cmd "$TEST_SESSION" "cd $WORKTREE_PARENT/default && gwtmux ../../otherrepo/default"
  wait_until "get_tmux_windows | grep -q 'otherrepo/default'"
  wait_cmd_done

  # Window should use directory name "default" (not the branch name)
  run get_tmux_windows
  assert_output --partial "otherrepo/default"
}

# ----------------------------------------------------------------------------
# Path arguments from outside any git repo
# ----------------------------------------------------------------------------

@test "gwtmux: opens existing worktree via absolute path from outside any git repo" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create a worktree
  git worktree add -b feature-wt "$WORKTREE_PARENT/feature-wt" main >/dev/null 2>&1

  # Create a non-git directory to run from
  local OUTSIDE_DIR="$TEST_TEMP_DIR/not-a-repo"
  mkdir -p "$OUTSIDE_DIR"

  # Open worktree via absolute path from outside any git repo
  send_cmd "$TEST_SESSION" "cd $OUTSIDE_DIR && gwtmux $WORKTREE_PARENT/feature-wt"
  wait_for_window_exists "myrepo/feature-wt"
  wait_cmd_done

  # Window should exist with correct repo/branch name
  run get_tmux_windows
  assert_output --partial "myrepo/feature-wt"
}

@test "gwtmux: opens existing worktree via relative path from outside any git repo" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create a worktree
  git worktree add -b feature-wt "$WORKTREE_PARENT/feature-wt" main >/dev/null 2>&1

  # Create a non-git directory to run from
  local OUTSIDE_DIR="$TEST_TEMP_DIR/not-a-repo"
  mkdir -p "$OUTSIDE_DIR"

  # Open worktree via relative path from outside any git repo
  send_cmd "$TEST_SESSION" "cd $OUTSIDE_DIR && gwtmux ../myrepo/feature-wt"
  wait_for_window_exists "myrepo/feature-wt"
  wait_cmd_done

  # Window should exist with correct repo/branch name
  run get_tmux_windows
  assert_output --partial "myrepo/feature-wt"
}

@test "gwtmux: errors with branch arg from outside any git repo" {
  # Create a non-git directory
  local OUTSIDE_DIR="$TEST_TEMP_DIR/not-a-repo"
  mkdir -p "$OUTSIDE_DIR"
  cd "$OUTSIDE_DIR"

  run gwtmux some-branch
  assert_failure
  assert_output --partial "not in a git repo or parent of default/.git"
}

# ----------------------------------------------------------------------------
# Path argument detection
# ----------------------------------------------------------------------------

@test "gwtmux: branch with slash is not hijacked by a matching directory" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  stub_gh_fail

  # A directory named exactly like the branch. The arg is not path-shaped, so
  # it must stay a branch name instead of opening that directory.
  mkdir -p "$MAIN_REPO/feature/auth"

  send_cmd "$TEST_SESSION" "cd $MAIN_REPO && gwtmux feature/auth"
  confirm_branch_creation "$TEST_SESSION"
  wait_for_dir_exists "$WORKTREE_PARENT/feature_auth"
  wait_cmd_done

  # Worktree directory uses underscores; branch keeps the slash
  assert_dir_exists "$WORKTREE_PARENT/feature_auth"
  run git -C "$WORKTREE_PARENT/feature_auth" branch --show-current
  assert_output "feature/auth"

  run get_tmux_windows
  assert_output --partial "myrepo/feature/auth"
}

@test "gwtmux: errors on relative path that is not a worktree root" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  mkdir -p "$MAIN_REPO/src"

  local before_count="$(get_window_count)"
  run gwtmux ./src
  assert_failure
  assert_output --partial "Error: './src' is not a worktree root (did you mean '$MAIN_REPO'?)"
  assert_equal "$(get_window_count)" "$before_count"
}

@test "gwtmux: errors on absolute path that is not a worktree root" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add -b sub-wt "$WORKTREE_PARENT/sub-wt" main >/dev/null 2>&1
  mkdir -p "$WORKTREE_PARENT/sub-wt/nested/deep"

  local before_count="$(get_window_count)"
  run gwtmux "$WORKTREE_PARENT/sub-wt/nested/deep"
  assert_failure
  assert_output --partial "is not a worktree root"
  assert_output --partial "$WORKTREE_PARENT/sub-wt"
  assert_equal "$(get_window_count)" "$before_count"
}

# D15: a path-shaped arg that resolves to no worktree must fail in place. It
# used to fall through to branch handling, which folded the whole path into a
# branch name and created a branch plus a worktree for it. Driven through tmux,
# not "run": on a regression gwtmux asks "Create new branch ...?" on /dev/tty,
# which would hang the test instead of failing it.
@test "gwtmux: errors on an absolute path outside any worktree" {
  setup_worktree_structure "myrepo"
  mkdir -p "$TEST_TEMP_DIR/plain/empty"

  local before_list="$(git -C "$MAIN_REPO" worktree list --porcelain)"
  local before_count="$(get_window_count)"

  # Errors go to a file, not the pane: a pane wraps long paths at its width, so
  # a captured path never matches as one substring.
  send_cmd "$TEST_SESSION" "cd $MAIN_REPO && gwtmux $TEST_TEMP_DIR/plain/empty 2>$TEST_TEMP_DIR/err"
  wait_cmd_done

  assert_not_equal "$(cat "$CMD_MARKER")" "0"
  run cat "$TEST_TEMP_DIR/err"
  assert_output --partial "Error: '$TEST_TEMP_DIR/plain/empty' is not a worktree root"
  run tmux capture-pane -t "$CMD_TARGET" -p
  refute_output --partial "Create new branch"

  # Nothing created: no branch named after the path, no worktree, no window
  assert_equal "$(git -C "$MAIN_REPO" worktree list --porcelain)" "$before_list"
  run git -C "$MAIN_REPO" branch --format='%(refname:short)'
  refute_output --partial "empty"
  assert_equal "$(get_window_count)" "$before_count"
}

@test "gwtmux: errors on a relative path that does not exist" {
  setup_worktree_structure "myrepo"

  local before_list="$(git -C "$MAIN_REPO" worktree list --porcelain)"
  local before_count="$(get_window_count)"

  send_cmd "$TEST_SESSION" "cd $MAIN_REPO && gwtmux ./nope 2>$TEST_TEMP_DIR/err"
  wait_cmd_done

  assert_not_equal "$(cat "$CMD_MARKER")" "0"
  run cat "$TEST_TEMP_DIR/err"
  assert_output --partial "Error: './nope' is not a worktree root"
  run tmux capture-pane -t "$CMD_TARGET" -p
  refute_output --partial "Create new branch"

  assert_equal "$(git -C "$MAIN_REPO" worktree list --porcelain)" "$before_list"
  run git -C "$MAIN_REPO" branch --format='%(refname:short)'
  refute_output --partial "nope"
  assert_equal "$(get_window_count)" "$before_count"
}

# ----------------------------------------------------------------------------
# Window naming: detached HEAD
# ----------------------------------------------------------------------------

@test "gwtmux: names detached HEAD worktree window after its directory" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Worktree with no current branch
  local commit_hash=$(git -C "$MAIN_REPO" rev-parse HEAD)
  git worktree add --detach "$WORKTREE_PARENT/detached-wt" "$commit_hash" >/dev/null 2>&1

  send_cmd "$TEST_SESSION" "cd $MAIN_REPO && gwtmux $WORKTREE_PARENT/detached-wt"
  wait_for_window_exists "myrepo/detached-wt"
  wait_cmd_done

  run get_tmux_windows
  assert_output --partial "myrepo/detached-wt"
  # Not the trailing-slash name an empty branch used to produce
  refute tmux_window_exists "myrepo/"
}

@test "gwtmux: no args names detached HEAD worktree after its directory" {
  setup_worktree_structure "myrepo"
  cd "$WORKTREE_PARENT"

  local commit_hash=$(git -C "$MAIN_REPO" rev-parse HEAD)
  git -C default worktree add -b feature-1 "$WORKTREE_PARENT/feature-1" main >/dev/null 2>&1
  git -C default worktree add --detach "$WORKTREE_PARENT/detached-wt" "$commit_hash" >/dev/null 2>&1

  send_cmd "$TEST_SESSION" "cd $WORKTREE_PARENT && gwtmux"
  wait_for_window_exists "myrepo/detached-wt"
  wait_cmd_done

  run get_tmux_windows
  assert_output --partial "myrepo/default"
  assert_output --partial "myrepo/feature-1"
  assert_output --partial "myrepo/detached-wt"
  refute tmux_window_exists "myrepo/"
}

@test "gwtmux -d: closes window of detached HEAD worktree" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  local commit_hash=$(git -C "$MAIN_REPO" rev-parse HEAD)
  git worktree add --detach "$WORKTREE_PARENT/detached-wt" "$commit_hash" >/dev/null 2>&1

  # Run from the session's first window, so the new window stays untouched
  local main_window=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)
  tmux new-window -t "$TEST_SESSION" -n "myrepo/detached-wt" -c "$WORKTREE_PARENT/detached-wt" >/dev/null 2>&1

  run get_tmux_windows
  assert_output --partial "myrepo/detached-wt"

  send_cmd "$main_window" "cd $MAIN_REPO && gwtmux -dw detached-wt"
  wait_for_window_closed "myrepo/detached-wt"
  wait_cmd_done

  run get_tmux_windows
  refute_output --partial "myrepo/detached-wt"
  refute [ -d "$WORKTREE_PARENT/detached-wt" ]
}

@test "gwtmux -d: refuses a worktree whose window name is not unique" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Two detached worktrees, one window name ("myrepo/det")
  local commit_hash=$(git rev-parse HEAD)
  mkdir -p "$WORKTREE_PARENT/one" "$WORKTREE_PARENT/two"
  git worktree add --detach "$WORKTREE_PARENT/one/det" "$commit_hash" >/dev/null 2>&1
  git worktree add --detach "$WORKTREE_PARENT/two/det" "$commit_hash" >/dev/null 2>&1

  # The open window belongs to one/det. Killing by name while deleting two/det
  # would close the wrong worktree's window.
  tmux new-window -t "$TEST_SESSION" -n "myrepo/det" -c "$WORKTREE_PARENT/one/det" >/dev/null 2>&1

  run gwtmux -dw ../two/det
  assert_failure
  assert_output --partial "is not unique"

  # Refused in validation: nothing deleted, no window closed
  assert_dir_exists "$WORKTREE_PARENT/two/det"
  assert_dir_exists "$WORKTREE_PARENT/one/det"
  assert tmux_window_exists "myrepo/det"
}

# ----------------------------------------------------------------------------
# Multi-worktree mode (no arguments)
# ----------------------------------------------------------------------------

@test "gwtmux: no args opens all worktrees in windows" {
  setup_worktree_structure "myrepo"
  cd "$WORKTREE_PARENT"

  # Create multiple worktrees
  git -C default worktree add -b feature-1 "$WORKTREE_PARENT/feature-1" main >/dev/null 2>&1
  git -C default worktree add -b feature-2 "$WORKTREE_PARENT/feature-2" main >/dev/null 2>&1

  # Run gwtmux without arguments from parent directory
  send_cmd "$TEST_SESSION" "cd $WORKTREE_PARENT && gwtmux"
  wait_for_window_exists "myrepo/feature-2"
  wait_cmd_done

  # Should create windows for all worktrees
  run get_tmux_windows
  assert_output --partial "myrepo/default"
  assert_output --partial "myrepo/feature-1"
  assert_output --partial "myrepo/feature-2"
}

@test "gwtmux: no args errors if not in parent of default/.git" {
  cd "$TEST_TEMP_DIR"

  run gwtmux
  assert_failure
  assert_output --partial "branch or PR number required"
}

# ----------------------------------------------------------------------------
# Slash handling (branch names with slashes)
# ----------------------------------------------------------------------------

@test "gwtmux: converts slashes to underscores in directory name" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  send_cmd "$TEST_SESSION" "cd $MAIN_REPO && gwtmux feature/with/slashes"
  confirm_branch_creation "$TEST_SESSION"
  wait_for_dir_exists "$WORKTREE_PARENT/feature_with_slashes"
  wait_cmd_done

  # Directory should use underscores
  assert_dir_exists "$WORKTREE_PARENT/feature_with_slashes"
  refute [ -d "$WORKTREE_PARENT/feature/with/slashes" ]

  # Window name should keep slashes
  run get_tmux_windows
  assert_output --partial "myrepo/feature/with/slashes"
}

# ----------------------------------------------------------------------------
# Shell window reuse logic
# ----------------------------------------------------------------------------

@test "gwtmux: reuses single-pane shell window" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Use the actual shell name that gwtmux expects
  local shell_name=$(basename "${SHELL:-zsh}")

  # Rename the initial window to shell name with single pane
  local first_window=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)
  tmux rename-window -t "$first_window" "$shell_name"

  local initial_window_count=$(get_window_count)

  send_cmd "$first_window" "cd $MAIN_REPO && gwtmux new-branch"
  confirm_branch_creation "$first_window"
  wait_for_dir_exists "$WORKTREE_PARENT/new-branch"
  wait_cmd_done

  # Window should have been renamed (not created new)
  local final_window_count=$(get_window_count)
  assert_equal "$initial_window_count" "$final_window_count"

  # Window should now be named after the worktree
  run get_tmux_windows
  assert_output --partial "myrepo/new-branch"
  refute_output --partial "$shell_name"
}

@test "gwtmux: creates new window if shell window has multiple panes" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  local shell_name=$(basename "${SHELL:-zsh}")

  # Rename window to shell name and split it
  local first_window=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)
  tmux rename-window -t "$first_window" "$shell_name"
  tmux split-window -t "$first_window"

  local initial_window_count=$(get_window_count)

  # Get the first pane of the window
  local first_pane=$(tmux list-panes -t "$first_window" -F "#{pane_id}" | head -1)
  send_cmd "$first_pane" "cd $MAIN_REPO && gwtmux new-branch"
  confirm_branch_creation "$first_pane"
  wait_for_dir_exists "$WORKTREE_PARENT/new-branch"
  wait_cmd_done

  # Should have created a new window (not reused)
  local final_window_count=$(get_window_count)
  assert [ "$final_window_count" -gt "$initial_window_count" ]

  # Both windows should exist
  run get_tmux_windows
  assert_output --partial "$shell_name"
  assert_output --partial "myrepo/new-branch"
}

@test "gwtmux: creates new window if current window is not named after shell" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Rename window to something other than "zsh"
  local first_window=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)
  tmux rename-window -t "$first_window" "other-window"

  local initial_window_count=$(get_window_count)

  send_cmd "$first_window" "cd $MAIN_REPO && gwtmux new-branch"
  confirm_branch_creation "$first_window"
  wait_for_dir_exists "$WORKTREE_PARENT/new-branch"
  wait_cmd_done

  # Should have created a new window
  local final_window_count=$(get_window_count)
  assert [ "$final_window_count" -gt "$initial_window_count" ]
}

# ----------------------------------------------------------------------------
# Multiple arguments
# ----------------------------------------------------------------------------

@test "gwtmux: creates multiple worktrees from multiple arguments" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  local initial_window=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)
  send_cmd "$initial_window" "cd $MAIN_REPO && gwtmux feature-1 feature-2 feature-3"
  confirm_branch_creation "$initial_window"
  confirm_branch_creation "$initial_window"
  confirm_branch_creation "$initial_window"
  wait_for_dir_exists "$WORKTREE_PARENT/feature-3"
  wait_cmd_done

  # All worktrees should be created
  assert_dir_exists "$WORKTREE_PARENT/feature-1"
  assert_dir_exists "$WORKTREE_PARENT/feature-2"
  assert_dir_exists "$WORKTREE_PARENT/feature-3"

  # All windows should exist
  run get_tmux_windows
  assert_output --partial "myrepo/feature-1"
  assert_output --partial "myrepo/feature-2"
  assert_output --partial "myrepo/feature-3"
}

@test "gwtmux: continues on error when one argument fails" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create a file where one worktree would be created (will cause failure)
  touch "$WORKTREE_PARENT/conflict"

  local initial_window=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)
  send_cmd "$initial_window" "cd $MAIN_REPO && gwtmux good-1 conflict good-2"
  confirm_branch_creation "$initial_window"
  confirm_branch_creation "$initial_window"
  confirm_branch_creation "$initial_window"
  wait_for_dir_exists "$WORKTREE_PARENT/good-2"
  wait_cmd_done

  # Should create the valid worktrees
  assert_dir_exists "$WORKTREE_PARENT/good-1"
  assert_dir_exists "$WORKTREE_PARENT/good-2"

  # Should have windows for successful ones
  run get_tmux_windows
  assert_output --partial "myrepo/good-1"
  assert_output --partial "myrepo/good-2"

  # Conflict worktree should NOT be created
  refute [ -d "$WORKTREE_PARENT/conflict" ] || assert [ -f "$WORKTREE_PARENT/conflict" ]
}

@test "gwtmux: selects existing windows when worktrees already exist" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create worktrees first
  git worktree add -b existing-1 "$WORKTREE_PARENT/existing-1" main >/dev/null 2>&1
  git worktree add -b existing-2 "$WORKTREE_PARENT/existing-2" main >/dev/null 2>&1

  # Create windows for them
  tmux new-window -t "$TEST_SESSION" -n "myrepo/existing-1" -c "$WORKTREE_PARENT/existing-1" 2>/dev/null
  tmux new-window -t "$TEST_SESSION" -n "myrepo/existing-2" -c "$WORKTREE_PARENT/existing-2" 2>/dev/null

  local window_count_before=$(get_window_count)

  # Try to create both plus a new one
  local first_window=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)
  send_cmd "$first_window" "cd $MAIN_REPO && gwtmux existing-1 existing-2 new-one"
  confirm_branch_creation "$first_window"
  wait_for_dir_exists "$WORKTREE_PARENT/new-one"
  wait_cmd_done

  # Should have one more window (new-one), not duplicates
  local window_count_after=$(get_window_count)
  assert_equal "$((window_count_before + 1))" "$window_count_after"

  # new-one worktree should be created
  assert_dir_exists "$WORKTREE_PARENT/new-one"
}

@test "gwtmux: reuses shell window for first success, creates new for rest" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  local shell_name=$(basename "${SHELL:-zsh}")

  # Rename window to shell name
  local first_window=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)
  tmux rename-window -t "$first_window" "$shell_name"

  local initial_window_count=$(get_window_count)

  send_cmd "$first_window" "cd $MAIN_REPO && gwtmux feat-a feat-b"
  confirm_branch_creation "$first_window"
  confirm_branch_creation "$first_window"
  wait_for_dir_exists "$WORKTREE_PARENT/feat-b"
  wait_cmd_done

  # Should have 2 windows total (reused one, created one new)
  local final_window_count=$(get_window_count)
  assert_equal "$((initial_window_count + 1))" "$final_window_count"

  # Should not have shell window anymore
  run get_tmux_windows
  refute_output --partial "$shell_name"

  # Should have both feature windows
  assert_output --partial "myrepo/feat-a"
  assert_output --partial "myrepo/feat-b"
}

# ----------------------------------------------------------------------------
# Default branch detection
# ----------------------------------------------------------------------------

@test "gwtmux: detects default branch from symbolic-ref" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Verify symbolic-ref is set
  run git symbolic-ref refs/remotes/origin/HEAD
  assert_output "refs/remotes/origin/main"

  # Create new branch (should be based on main)
  send_cmd "$TEST_SESSION" "cd $MAIN_REPO && gwtmux test-branch"
  confirm_branch_creation "$TEST_SESSION"
  wait_for_dir_exists "$WORKTREE_PARENT/test-branch"
  wait_cmd_done

  # Verify the branch was created
  assert_dir_exists "$WORKTREE_PARENT/test-branch"
}

@test "gwtmux: falls back to main when symbolic-ref not set" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Remove symbolic-ref
  git remote set-head origin -d >/dev/null 2>&1

  # Create new branch (should still find main)
  send_cmd "$TEST_SESSION" "cd $MAIN_REPO && gwtmux test-branch"
  confirm_branch_creation "$TEST_SESSION"
  wait_for_dir_exists "$WORKTREE_PARENT/test-branch"
  wait_cmd_done

  assert_dir_exists "$WORKTREE_PARENT/test-branch"
}

@test "gwtmux: uses master if main doesn't exist" {
  # Create repo with master branch instead of main
  local master_remote="$TEST_TEMP_DIR/remote-master.git"
  git init --bare "$master_remote" >/dev/null 2>&1

  local master_repo="$TEST_TEMP_DIR/repo-master"
  git clone "$master_remote" "$master_repo" >/dev/null 2>&1
  cd "$master_repo"

  git config user.name "Test User"
  git config user.email "test@example.com"
  git checkout -b master >/dev/null 2>&1
  echo "initial" >README.md
  git add README.md
  git commit -m "Initial commit" >/dev/null 2>&1
  git push -u origin master >/dev/null 2>&1

  # Override MAIN_REPO for setup_worktree_structure
  MAIN_REPO="$master_repo"
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Remove symbolic-ref to force fallback
  git remote set-head origin -d >/dev/null 2>&1

  send_cmd "$TEST_SESSION" "cd $MAIN_REPO && gwtmux test-branch"
  confirm_branch_creation "$TEST_SESSION"
  wait_for_dir_exists "$WORKTREE_PARENT/test-branch"
  wait_cmd_done

  assert_dir_exists "$WORKTREE_PARENT/test-branch"
}

# ----------------------------------------------------------------------------
# Error cases
# ----------------------------------------------------------------------------

@test "gwtmux: errors when not in tmux" {
  unset TMUX
  cd "$MAIN_REPO"

  run gwtmux new-branch
  assert_failure
  assert_output --partial "not in tmux"
}

@test "gwtmux: errors when not in git repo" {
  cd "$TEST_TEMP_DIR"
  mkdir -p not-a-repo
  cd not-a-repo

  run gwtmux test
  assert_failure
  assert_output --partial "not in a git repo"
}

@test "gwtmux: errors when worktree creation fails" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create a file where worktree dir would be created
  touch "$WORKTREE_PARENT/conflict"

  send_cmd "$TEST_SESSION" "cd $MAIN_REPO && gwtmux conflict"
  confirm_branch_creation "$TEST_SESSION"
  wait_until "tmux capture-pane -t '$TEST_SESSION' -p | grep -q 'failed to create worktree'"
  wait_cmd_done

  # Should see error about failed worktree creation
  run tmux capture-pane -t "$TEST_SESSION" -p
  assert_output --partial "failed to create worktree"
}

# ----------------------------------------------------------------------------
# Confirmation prompt
# ----------------------------------------------------------------------------

@test "gwtmux: skips branch creation when user declines confirmation" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  send_cmd "$TEST_SESSION" "cd $MAIN_REPO && gwtmux declined-branch"
  wait_until "tmux capture-pane -t '$TEST_SESSION' -p | grep -q 'Create new branch'"
  tmux send-keys -t "$TEST_SESSION" "n" Enter
  wait_until "tmux capture-pane -t '$TEST_SESSION' -p | grep -q 'Skipping'"
  wait_cmd_done

  # Worktree should NOT be created
  refute [ -d "$WORKTREE_PARENT/declined-branch" ]

  # Should see skip message
  run tmux capture-pane -t "$TEST_SESSION" -p
  assert_output --partial "Skipping 'declined-branch'"
}

# ----------------------------------------------------------------------------
# Path-based branch creation (repo-parent paths)
# ----------------------------------------------------------------------------

@test "gwtmux: creates worktree from repo-parent path with new branch" {
  setup_worktree_structure "myrepo"

  # Create a second repo with worktree structure
  local OTHER_REMOTE="$TEST_TEMP_DIR/other-remote.git"
  git init --bare "$OTHER_REMOTE" >/dev/null 2>&1

  local OTHER_REPO_PARENT="$TEST_TEMP_DIR/otherrepo"
  mkdir -p "$OTHER_REPO_PARENT"
  git clone "$OTHER_REMOTE" "$OTHER_REPO_PARENT/default" >/dev/null 2>&1
  git -C "$OTHER_REPO_PARENT/default" config user.name "Test"
  git -C "$OTHER_REPO_PARENT/default" config user.email "test@test.com"
  git -C "$OTHER_REPO_PARENT/default" checkout -b main >/dev/null 2>&1
  echo "test" >"$OTHER_REPO_PARENT/default/file.txt"
  git -C "$OTHER_REPO_PARENT/default" add .
  git -C "$OTHER_REPO_PARENT/default" commit -m "init" >/dev/null 2>&1
  git -C "$OTHER_REPO_PARENT/default" push -u origin main >/dev/null 2>&1
  git -C "$OTHER_REPO_PARENT/default" remote set-head origin main >/dev/null 2>&1

  # From myrepo, create a new branch in otherrepo via path
  send_cmd "$TEST_SESSION" "cd $WORKTREE_PARENT/default && gwtmux ../../otherrepo/new-branch"
  confirm_branch_creation "$TEST_SESSION"
  wait_for_dir_exists "$OTHER_REPO_PARENT/new-branch"
  wait_cmd_done

  # Worktree should be created in otherrepo
  assert_dir_exists "$OTHER_REPO_PARENT/new-branch"

  # Window should have otherrepo name
  run get_tmux_windows
  assert_output --partial "otherrepo/new-branch"
}

@test "gwtmux: creates worktree with slashes in branch via repo-parent path" {
  setup_worktree_structure "myrepo"

  # Create a non-git directory to run from
  local OUTSIDE_DIR="$TEST_TEMP_DIR/not-a-repo"
  mkdir -p "$OUTSIDE_DIR"

  # Branch name itself contains a slash. The repo parent must be found by
  # walking up past the branch components (myrepo is the repo parent, the
  # branch is demo/test-branch).
  send_cmd "$TEST_SESSION" "cd $OUTSIDE_DIR && gwtmux ../myrepo/demo/test-branch"
  confirm_branch_creation "$TEST_SESSION"
  wait_for_dir_exists "$WORKTREE_PARENT/demo_test-branch"
  wait_cmd_done

  # Directory uses underscores; branch keeps the slash
  assert_dir_exists "$WORKTREE_PARENT/demo_test-branch"
  run git -C "$WORKTREE_PARENT/demo_test-branch" branch --show-current
  assert_output "demo/test-branch"

  # Window name is repo/branch (slash preserved)
  run get_tmux_windows
  assert_output --partial "myrepo/demo/test-branch"
}

@test "gwtmux: creates worktree from repo-parent path outside any git repo" {
  setup_worktree_structure "myrepo"

  # Create a non-git directory
  local OUTSIDE_DIR="$TEST_TEMP_DIR/not-a-repo"
  mkdir -p "$OUTSIDE_DIR"

  # From outside any git repo, create a new branch in myrepo via path
  send_cmd "$TEST_SESSION" "cd $OUTSIDE_DIR && gwtmux ../myrepo/new-branch"
  confirm_branch_creation "$TEST_SESSION"
  wait_for_dir_exists "$WORKTREE_PARENT/new-branch"
  wait_cmd_done

  # Worktree should be created in myrepo
  assert_dir_exists "$WORKTREE_PARENT/new-branch"

  # Window should have myrepo name
  run get_tmux_windows
  assert_output --partial "myrepo/new-branch"
}

@test "gwtmux: opens existing worktree via repo-parent path without confirmation" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create a worktree
  git worktree add -b existing-wt "$WORKTREE_PARENT/existing-wt" main >/dev/null 2>&1

  # Create a non-git directory
  local OUTSIDE_DIR="$TEST_TEMP_DIR/not-a-repo"
  mkdir -p "$OUTSIDE_DIR"

  # Open existing worktree via repo-parent path - should NOT prompt
  send_cmd "$TEST_SESSION" "cd $OUTSIDE_DIR && gwtmux ../myrepo/existing-wt"
  wait_for_window_exists "myrepo/existing-wt"
  wait_cmd_done

  # Window should exist (path_matched handled it, no prompt)
  run get_tmux_windows
  assert_output --partial "myrepo/existing-wt"
}

@test "gwtmux: opens multiple existing worktrees via repo-parent paths from outside git" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create two worktrees
  git worktree add -b feat-one "$WORKTREE_PARENT/feat-one" main >/dev/null 2>&1
  git worktree add -b feat-two "$WORKTREE_PARENT/feat-two" main >/dev/null 2>&1

  # Go outside any git repo
  local OUTSIDE_DIR="$TEST_TEMP_DIR/not-a-repo"
  mkdir -p "$OUTSIDE_DIR"

  # Rename window to shell name so can_reuse_window=1 — this triggers the cd
  # on the first arg that was breaking relative path resolution for subsequent args
  local shell_name=$(basename "${SHELL:-zsh}")
  local first_window=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)
  tmux rename-window -t "$first_window" "$shell_name"

  # Open both worktrees via repo-parent paths
  send_cmd "$TEST_SESSION" "cd $OUTSIDE_DIR && gwtmux ../myrepo/feat-one ../myrepo/feat-two"
  wait_for_window_exists "myrepo/feat-one"
  wait_for_window_exists "myrepo/feat-two"
  wait_cmd_done

  run get_tmux_windows
  assert_output --partial "myrepo/feat-one"
  assert_output --partial "myrepo/feat-two"
}

@test "gwtmux: repo-parent path does not affect subsequent args" {
  setup_worktree_structure "myrepo"

  # Create a second repo with worktree structure
  local OTHER_REMOTE="$TEST_TEMP_DIR/other-remote2.git"
  git init --bare "$OTHER_REMOTE" >/dev/null 2>&1

  local OTHER_REPO_PARENT="$TEST_TEMP_DIR/otherrepo"
  mkdir -p "$OTHER_REPO_PARENT"
  git clone "$OTHER_REMOTE" "$OTHER_REPO_PARENT/default" >/dev/null 2>&1
  git -C "$OTHER_REPO_PARENT/default" config user.name "Test"
  git -C "$OTHER_REPO_PARENT/default" config user.email "test@test.com"
  git -C "$OTHER_REPO_PARENT/default" checkout -b main >/dev/null 2>&1
  echo "test" >"$OTHER_REPO_PARENT/default/file.txt"
  git -C "$OTHER_REPO_PARENT/default" add .
  git -C "$OTHER_REPO_PARENT/default" commit -m "init" >/dev/null 2>&1
  git -C "$OTHER_REPO_PARENT/default" push -u origin main >/dev/null 2>&1
  git -C "$OTHER_REPO_PARENT/default" remote set-head origin main >/dev/null 2>&1

  # From myrepo, create a branch in otherrepo AND a local branch
  local initial_window=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)
  send_cmd "$initial_window" "cd $WORKTREE_PARENT/default && gwtmux ../../otherrepo/other-feat local-feat"
  confirm_branch_creation "$initial_window"
  confirm_branch_creation "$initial_window"
  wait_for_dir_exists "$WORKTREE_PARENT/local-feat"
  wait_cmd_done

  # otherrepo branch should be in otherrepo
  assert_dir_exists "$OTHER_REPO_PARENT/other-feat"

  # local branch should be in myrepo
  assert_dir_exists "$WORKTREE_PARENT/local-feat"

  # Windows should show correct repo names
  run get_tmux_windows
  assert_output --partial "otherrepo/other-feat"
  assert_output --partial "myrepo/local-feat"
}

@test "gwtmux: resolves PR number in repo-parent path" {
  setup_worktree_structure "myrepo"
  stub_gh_pr "456" "pr-456-feature"

  local OUTSIDE_DIR="$TEST_TEMP_DIR/not-a-repo"
  mkdir -p "$OUTSIDE_DIR"

  send_cmd "$TEST_SESSION" "cd $OUTSIDE_DIR && gwtmux ../myrepo/456"
  confirm_branch_creation "$TEST_SESSION"
  wait_for_dir_exists "$WORKTREE_PARENT/pr-456-feature"
  wait_cmd_done

  assert_dir_exists "$WORKTREE_PARENT/pr-456-feature"
  run get_tmux_windows
  assert_output --partial "myrepo/pr-456-feature"
}

@test "gwtmux: resolves multiple PR numbers in repo-parent paths" {
  setup_worktree_structure "myrepo"
  stub_gh_pr_multi "123" "pr-123-feat" "456" "pr-456-fix"

  local OUTSIDE_DIR="$TEST_TEMP_DIR/not-a-repo"
  mkdir -p "$OUTSIDE_DIR"

  local shell_name=$(basename "${SHELL:-zsh}")
  local first_window=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)
  tmux rename-window -t "$first_window" "$shell_name"

  send_cmd "$TEST_SESSION" "cd $OUTSIDE_DIR && gwtmux ../myrepo/123 ../myrepo/456"
  confirm_branch_creation "$TEST_SESSION"
  wait_for_dir_exists "$WORKTREE_PARENT/pr-123-feat"
  confirm_branch_creation "$TEST_SESSION"
  wait_for_dir_exists "$WORKTREE_PARENT/pr-456-fix"
  wait_cmd_done

  run get_tmux_windows
  assert_output --partial "myrepo/pr-123-feat"
  assert_output --partial "myrepo/pr-456-fix"

  # Verify first window (reused shell) ended up in correct worktree dir
  local first_wt_pane_path
  first_wt_pane_path=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_name} #{pane_current_path}" | grep "pr-123-feat" | awk '{print $2}')
  [[ "$first_wt_pane_path" == *"/pr-123-feat" ]]
}

# ============================================================================
# TESTS: gwtmux --rename
# ============================================================================

# ----------------------------------------------------------------------------
# Basic functionality
# ----------------------------------------------------------------------------

@test "gwtmux --rename: renames directory, branch, and window (no remote)" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create a worktree
  git worktree add -b old-name "$WORKTREE_PARENT/old-name" main >/dev/null 2>&1

  # Switch to the worktree
  cd "$WORKTREE_PARENT/old-name"
  git config user.name "Test User"
  git config user.email "test@example.com"

  # Make a commit so we're on a proper branch
  echo "test" >test.txt
  git add test.txt
  git commit -m "Test commit" >/dev/null 2>&1

  # Create tmux window
  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/old-name" -c "$WORKTREE_PARENT/old-name" -P -F "#{window_id}")

  # Rename (run from the worktree's own window - gwtmux targets the invoking window)
  send_cmd "$new_window" "cd $WORKTREE_PARENT/old-name && gwtmux --rename new-name"
  wait_for_dir_exists "$WORKTREE_PARENT/new-name"
  wait_cmd_done

  # Verify directory renamed
  assert_dir_exists "$WORKTREE_PARENT/new-name"
  refute [ -d "$WORKTREE_PARENT/old-name" ]

  # Verify branch renamed
  run git -C "$WORKTREE_PARENT/new-name" branch --show-current
  assert_output "new-name"

  # Verify window renamed
  run get_tmux_windows
  assert_output --partial "myrepo/new-name"
  refute_output --partial "myrepo/old-name"
}

@test "gwtmux --rename: works from a subdirectory of the worktree" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add -b old-name "$WORKTREE_PARENT/old-name" main >/dev/null 2>&1

  cd "$WORKTREE_PARENT/old-name"
  git config user.name "Test User"
  git config user.email "test@example.com"
  mkdir -p src/deep
  echo "test" >src/deep/test.txt
  git add src/deep/test.txt
  git commit -m "Test commit" >/dev/null 2>&1

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/old-name" -c "$WORKTREE_PARENT/old-name" -P -F "#{window_id}")

  # Invoked from a nested subdir - should still act on the worktree root
  send_cmd "$new_window" "cd $WORKTREE_PARENT/old-name/src/deep && gwtmux --rename new-name"
  wait_for_dir_exists "$WORKTREE_PARENT/new-name"
  wait_cmd_done

  assert_dir_exists "$WORKTREE_PARENT/new-name"
  refute [ -d "$WORKTREE_PARENT/old-name" ]
  run git -C "$WORKTREE_PARENT/new-name" branch --show-current
  assert_output "new-name"
  run get_tmux_windows
  assert_output --partial "myrepo/new-name"
}

@test "gwtmux --rename: renames with remote tracking branch" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create a worktree with remote tracking
  git worktree add "$WORKTREE_PARENT/old-name" -b old-name main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/old-name"
  git config user.name "Test User"
  git config user.email "test@example.com"

  echo "test" >test.txt
  git add test.txt
  git commit -m "Test commit" >/dev/null 2>&1
  git push -u origin old-name >/dev/null 2>&1

  # Create tmux window
  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/old-name" -c "$WORKTREE_PARENT/old-name" -P -F "#{window_id}")

  # Rename
  send_cmd "$new_window" "cd $WORKTREE_PARENT/old-name && gwtmux --rename new-name"
  wait_for_dir_exists "$WORKTREE_PARENT/new-name"
  wait_cmd_done

  # Verify remote branch was renamed
  run git -C "$MAIN_REPO" branch -r
  assert_output --partial "origin/new-name"
  refute_output --partial "origin/old-name"

  # Verify tracking is set correctly
  run git -C "$WORKTREE_PARENT/new-name" rev-parse --abbrev-ref --symbolic-full-name @{u}
  assert_output "origin/new-name"
}

@test "gwtmux --rename: converts slashes to underscores in directory name" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add -b old-name "$WORKTREE_PARENT/old-name" main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/old-name"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Test" >/dev/null 2>&1

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/old-name" -c "$WORKTREE_PARENT/old-name" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $WORKTREE_PARENT/old-name && gwtmux --rename feature/new-name"
  wait_for_dir_exists "$WORKTREE_PARENT/feature_new-name"
  wait_cmd_done

  # Directory should use underscores
  assert_dir_exists "$WORKTREE_PARENT/feature_new-name"

  # Branch name should keep slashes
  run git -C "$WORKTREE_PARENT/feature_new-name" branch --show-current
  assert_output "feature/new-name"

  # Window name should keep slashes
  run get_tmux_windows
  assert_output --partial "myrepo/feature/new-name"
}

# ----------------------------------------------------------------------------
# Unify semantics: converge dir, branch, and remote branch to one name
# ----------------------------------------------------------------------------

@test "gwtmux --rename: to current branch name renames dir only, keeps remote branch" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Dir name differs from branch name
  git worktree add "$WORKTREE_PARENT/wrong-dir" -b feat-x main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/wrong-dir"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Test" >/dev/null 2>&1
  git push -u origin feat-x >/dev/null 2>&1

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/feat-x" -c "$WORKTREE_PARENT/wrong-dir" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $WORKTREE_PARENT/wrong-dir && gwtmux --rename feat-x"
  wait_for_dir_exists "$WORKTREE_PARENT/feat-x"
  wait_cmd_done

  assert_dir_exists "$WORKTREE_PARENT/feat-x"
  refute [ -d "$WORKTREE_PARENT/wrong-dir" ]

  # Remote branch must survive (regression: it used to be deleted)
  run git -C "$REMOTE_REPO" branch
  assert_output --partial "feat-x"

  # Tracking intact
  run git -C "$WORKTREE_PARENT/feat-x" rev-parse --abbrev-ref --symbolic-full-name @{u}
  assert_output "origin/feat-x"
}

@test "gwtmux --rename: unifies mismatched dir, branch, and upstream names" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/somewhere" -b foo main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/somewhere"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Test" >/dev/null 2>&1
  # Upstream branch name differs from local branch name
  git push origin foo:bar >/dev/null 2>&1
  git branch -u origin/bar >/dev/null 2>&1

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/foo" -c "$WORKTREE_PARENT/somewhere" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $WORKTREE_PARENT/somewhere && gwtmux --rename baz"
  wait_for_dir_exists "$WORKTREE_PARENT/baz"
  wait_cmd_done

  run git -C "$WORKTREE_PARENT/baz" branch --show-current
  assert_output "baz"

  # Old upstream branch deleted, new one created
  run git -C "$REMOTE_REPO" branch
  assert_output --partial "baz"
  refute_output --partial "bar"

  run git -C "$WORKTREE_PARENT/baz" rev-parse --abbrev-ref --symbolic-full-name @{u}
  assert_output "origin/baz"

  run get_tmux_windows
  assert_output --partial "myrepo/baz"
}

@test "gwtmux --rename: to upstream branch name renames local only, remote untouched" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/somewhere" -b foo main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/somewhere"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Test" >/dev/null 2>&1
  git push origin foo:bar >/dev/null 2>&1
  git branch -u origin/bar >/dev/null 2>&1

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/foo" -c "$WORKTREE_PARENT/somewhere" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $WORKTREE_PARENT/somewhere && gwtmux --rename bar"
  wait_for_dir_exists "$WORKTREE_PARENT/bar"
  wait_cmd_done

  run git -C "$WORKTREE_PARENT/bar" branch --show-current
  assert_output "bar"

  # Remote branch kept as-is
  run git -C "$REMOTE_REPO" branch
  assert_output --partial "bar"

  run git -C "$WORKTREE_PARENT/bar" rev-parse --abbrev-ref --symbolic-full-name @{u}
  assert_output "origin/bar"
}

@test "gwtmux --rename: succeeds as no-op when everything already matches" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/baz" -b baz main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/baz"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Test" >/dev/null 2>&1
  git push -u origin baz >/dev/null 2>&1

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/baz" -c "$WORKTREE_PARENT/baz" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $WORKTREE_PARENT/baz && gwtmux --rename baz 2>&1; echo EXIT_CODE:\$?"
  wait_until "tmux capture-pane -t '$new_window' -p | grep -qE 'EXIT_CODE:[0-9]'"
  wait_cmd_done

  run tmux capture-pane -t "$new_window" -p
  assert_output --partial "EXIT_CODE:0"

  assert_dir_exists "$WORKTREE_PARENT/baz"
  run git -C "$WORKTREE_PARENT/baz" branch --show-current
  assert_output "baz"
  run git -C "$REMOTE_REPO" branch
  assert_output --partial "baz"
  run git -C "$WORKTREE_PARENT/baz" rev-parse --abbrev-ref --symbolic-full-name @{u}
  assert_output "origin/baz"
}

@test "gwtmux --rename: renames branch when dir already matches target" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/baz" -b old-branch main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/baz"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Test" >/dev/null 2>&1

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/old-branch" -c "$WORKTREE_PARENT/baz" -P -F "#{window_id}")

  # Must not fail with "already exists" - the target dir is this worktree
  send_cmd "$new_window" "cd $WORKTREE_PARENT/baz && gwtmux --rename baz 2>&1; echo EXIT_CODE:\$?"
  wait_until "tmux capture-pane -t '$new_window' -p | grep -qE 'EXIT_CODE:[0-9]'"
  wait_cmd_done

  run tmux capture-pane -t "$new_window" -p
  assert_output --partial "EXIT_CODE:0"
  refute_output --partial "already exists"

  run git -C "$WORKTREE_PARENT/baz" branch --show-current
  assert_output "baz"
  run get_tmux_windows
  assert_output --partial "myrepo/baz"
}

@test "gwtmux --rename: warns and continues when old remote branch already deleted" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/foo" -b foo main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/foo"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Test" >/dev/null 2>&1
  git push -u origin foo >/dev/null 2>&1

  # Delete the branch on the remote out-of-band (stale tracking ref)
  git -C "$REMOTE_REPO" branch -D foo >/dev/null 2>&1

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/foo" -c "$WORKTREE_PARENT/foo" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $WORKTREE_PARENT/foo && gwtmux --rename baz 2>&1; echo EXIT_CODE:\$?"
  wait_until "tmux capture-pane -t '$new_window' -p | grep -qE 'EXIT_CODE:[0-9]'"
  wait_cmd_done

  run tmux capture-pane -t "$new_window" -p
  assert_output --partial "Warning: could not delete"
  assert_output --partial "EXIT_CODE:0"

  # New remote branch pushed and tracked
  run git -C "$REMOTE_REPO" branch
  assert_output --partial "baz"
  run git -C "$WORKTREE_PARENT/baz" rev-parse --abbrev-ref --symbolic-full-name @{u}
  assert_output "origin/baz"
}

@test "gwtmux --rename: allows rename without remote delete when latest commit is not yours" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Worktree on a teammate's branch: latest commit authored by someone else,
  # upstream already has the target name - only the dir needs fixing
  git worktree add "$WORKTREE_PARENT/review-dir" -b feat-y main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/review-dir"
  git config user.name "Other User"
  git config user.email "other@example.com"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Test" >/dev/null 2>&1
  git push -u origin feat-y >/dev/null 2>&1
  git config user.email "test@example.com"

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/feat-y" -c "$WORKTREE_PARENT/review-dir" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $WORKTREE_PARENT/review-dir && gwtmux --rename feat-y"
  wait_for_dir_exists "$WORKTREE_PARENT/feat-y"
  wait_cmd_done

  assert_dir_exists "$WORKTREE_PARENT/feat-y"
  run git -C "$REMOTE_REPO" branch
  assert_output --partial "feat-y"
}

# ----------------------------------------------------------------------------
# Error cases and rollback
# ----------------------------------------------------------------------------

@test "gwtmux --rename: errors when not in tmux" {
  unset TMUX
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add -b test-wt "$WORKTREE_PARENT/test-wt" main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"

  run gwtmux --rename new-name
  assert_failure
  assert_output --partial "not in tmux"
}

@test "gwtmux --rename: errors when no name provided" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add -b test-wt "$WORKTREE_PARENT/test-wt" main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"

  run gwtmux --rename
  assert_failure
  assert_output --partial "new name required"
}

@test "gwtmux --rename: errors when not in git repo" {
  cd "$TEST_TEMP_DIR"
  mkdir -p not-a-repo
  cd not-a-repo

  run gwtmux --rename new-name
  assert_failure
  assert_output --partial "not in a git repo"
}

@test "gwtmux --rename: errors when in main repo (not worktree)" {
  cd "$MAIN_REPO"

  run gwtmux --rename new-name
  assert_failure
  assert_output --partial "in main repo, not a worktree"
}

@test "gwtmux --rename: errors when in a subdirectory of main repo" {
  cd "$MAIN_REPO"
  mkdir -p "$MAIN_REPO/src/deep"
  cd "$MAIN_REPO/src/deep"

  run gwtmux --rename new-name
  assert_failure
  assert_output --partial "in main repo, not a worktree"
}

@test "gwtmux --rename: errors when not on a branch" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add -b test-wt "$WORKTREE_PARENT/test-wt" main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"

  # Detach HEAD
  git checkout HEAD~0 >/dev/null 2>&1

  run gwtmux --rename new-name
  assert_failure
  assert_output --partial "not on a branch"
}

@test "gwtmux --rename: errors when target path already exists" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add -b old-name "$WORKTREE_PARENT/old-name" main >/dev/null 2>&1
  mkdir -p "$WORKTREE_PARENT/new-name"

  cd "$WORKTREE_PARENT/old-name"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Test" >/dev/null 2>&1

  run gwtmux --rename new-name
  assert_failure
  assert_output --partial "already exists"
}

@test "gwtmux --rename: errors when commit author doesn't match and remote delete is needed" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add -b test-wt "$WORKTREE_PARENT/test-wt" main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"

  # Latest commit authored by someone else, branch tracks origin/test-wt
  git config user.name "Other User"
  git config user.email "other@example.com"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Test" >/dev/null 2>&1
  git push -u origin test-wt >/dev/null 2>&1

  git config user.email "test@example.com"

  # Renaming to a different name would delete origin/test-wt - refused
  run gwtmux --rename new-name
  assert_failure
  assert_output --partial "not authored by you"

  # Nothing changed
  assert_dir_exists "$WORKTREE_PARENT/test-wt"
  run git -C "$REMOTE_REPO" branch
  assert_output --partial "test-wt"
}

# ============================================================================
# TESTS: gwtmux -d
# ============================================================================

# ----------------------------------------------------------------------------
# Basic functionality
# ----------------------------------------------------------------------------

@test "gwtmux -d: kills window only (no flags)" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/test-wt" -b test-branch main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"
  git config user.name "Test User"
  git config user.email "test@example.com"

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/test-branch" -c "$WORKTREE_PARENT/test-wt" -P -F "#{window_id}")
  local window_count_before=$(get_window_count)

  send_cmd "$new_window" "cd $WORKTREE_PARENT/test-wt && gwtmux -d"
  wait_for_window_closed "myrepo/test-branch"
  wait_cmd_done

  # Worktree should still exist
  assert [ -d "$WORKTREE_PARENT/test-wt" ]

  # Branch should still exist
  run git -C "$MAIN_REPO" branch
  assert_output --partial "test-branch"

  # Window should be killed
  local window_count_after=$(get_window_count)
  assert [ "$window_count_after" -lt "$window_count_before" ]
}

@test "gwtmux -d: safe delete with -wb flag (merged branch)" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create and merge a branch
  git worktree add "$WORKTREE_PARENT/test-wt" -b test-branch main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Test" >/dev/null 2>&1

  # Merge into main
  cd "$MAIN_REPO"
  git checkout main >/dev/null 2>&1
  git merge test-branch >/dev/null 2>&1

  cd "$WORKTREE_PARENT/test-wt"
  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/test-branch" -c "$WORKTREE_PARENT/test-wt" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $WORKTREE_PARENT/test-wt && gwtmux -d -wb"
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"
  wait_cmd_done

  # Both worktree and branch should be removed
  refute [ -d "$WORKTREE_PARENT/test-wt" ]
  run git -C "$MAIN_REPO" branch
  refute_output --partial "test-branch"
}

@test "gwtmux -d: -wB works from a subdirectory of the worktree" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/test-wt" -b test-branch main >/dev/null 2>&1
  mkdir -p "$WORKTREE_PARENT/test-wt/src/deep"

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/test-branch" -c "$WORKTREE_PARENT/test-wt" -P -F "#{window_id}")

  # Invoked from a nested subdir - should still remove the whole worktree
  send_cmd "$new_window" "cd $WORKTREE_PARENT/test-wt/src/deep && gwtmux -d -wB"
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"
  wait_cmd_done

  refute [ -d "$WORKTREE_PARENT/test-wt" ]
  run git -C "$MAIN_REPO" branch
  refute_output --partial "test-branch"
}

@test "gwtmux -d: safe delete fails on unmerged branch" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/test-wt" -b test-branch main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Unmerged commit" >/dev/null 2>&1

  run gwtmux -d -b
  assert_failure
  assert_output --partial "not merged"

  # Worktree should still exist
  assert_dir_exists "$WORKTREE_PARENT/test-wt"
}

@test "gwtmux -d: force delete with -wB flag" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/test-wt" -b test-branch main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Unmerged commit" >/dev/null 2>&1

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/test-branch" -c "$WORKTREE_PARENT/test-wt" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $WORKTREE_PARENT/test-wt && gwtmux -d -wB"
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"
  wait_cmd_done

  # Both should be removed despite not being merged
  refute [ -d "$WORKTREE_PARENT/test-wt" ]
  run git -C "$MAIN_REPO" branch
  refute_output --partial "test-branch"
}

@test "gwtmux -d: deletes remote branch with -wbr flag" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/test-wt" -b test-branch main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Test" >/dev/null 2>&1
  git push -u origin test-branch >/dev/null 2>&1

  # Merge into main
  cd "$MAIN_REPO"
  git checkout main >/dev/null 2>&1
  git merge test-branch >/dev/null 2>&1

  cd "$WORKTREE_PARENT/test-wt"
  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/test-branch" -c "$WORKTREE_PARENT/test-wt" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $WORKTREE_PARENT/test-wt && gwtmux -d -wbr"
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"
  wait_cmd_done

  # Local and remote should be deleted
  refute [ -d "$WORKTREE_PARENT/test-wt" ]
  run git -C "$MAIN_REPO" branch -r
  refute_output --partial "origin/test-branch"
}

@test "gwtmux -d: force deletes remote with -wBr flag" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/test-wt" -b test-branch main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Unmerged commit" >/dev/null 2>&1
  git push -u origin test-branch >/dev/null 2>&1

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/test-branch" -c "$WORKTREE_PARENT/test-wt" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $WORKTREE_PARENT/test-wt && gwtmux -d -wBr"
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"
  wait_cmd_done

  # Everything should be deleted
  refute [ -d "$WORKTREE_PARENT/test-wt" ]
  run git -C "$MAIN_REPO" branch -r
  refute_output --partial "origin/test-branch"
}

@test "gwtmux -d: handles combined -wbr flags in either order" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/test-wt" -b test-branch main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Test" >/dev/null 2>&1
  git push -u origin test-branch >/dev/null 2>&1

  cd "$MAIN_REPO"
  git checkout main >/dev/null 2>&1
  git merge test-branch >/dev/null 2>&1

  cd "$WORKTREE_PARENT/test-wt"
  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/test-branch" -c "$WORKTREE_PARENT/test-wt" -P -F "#{window_id}")

  # Try -rbw instead of -wbr
  send_cmd "$new_window" "cd $WORKTREE_PARENT/test-wt && gwtmux -d -rbw"
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"
  wait_cmd_done

  # Should work the same
  refute [ -d "$WORKTREE_PARENT/test-wt" ]
  run git -C "$MAIN_REPO" branch -r
  refute_output --partial "origin/test-branch"
}

@test "gwtmux -d: only deletes remote if remote ref exists" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create branch without pushing
  git worktree add "$WORKTREE_PARENT/test-wt" -b test-branch main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Test" >/dev/null 2>&1

  # Merge into main (so -b will work)
  cd "$MAIN_REPO"
  git checkout main >/dev/null 2>&1
  git merge test-branch >/dev/null 2>&1

  cd "$WORKTREE_PARENT/test-wt"
  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/test-branch" -c "$WORKTREE_PARENT/test-wt" -P -F "#{window_id}")

  # Try to delete with -wbr (should succeed even though no remote)
  send_cmd "$new_window" "cd $WORKTREE_PARENT/test-wt && gwtmux -d -wbr"
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"
  wait_cmd_done

  # Should complete without error. No marker to check - gwtmux kills its own
  # window - so the window being gone stands in for the exit code: a gwtmux that
  # stopped on the missing remote ref would leave it open.
  refute [ -d "$WORKTREE_PARENT/test-wt" ]
  refute tmux_window_exists "myrepo/test-branch"
}

# ----------------------------------------------------------------------------
# Default branch detection for merge check
# ----------------------------------------------------------------------------

@test "gwtmux -d: uses symbolic-ref for merge check" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Verify symbolic-ref is set to main
  run git symbolic-ref refs/remotes/origin/HEAD
  assert_output "refs/remotes/origin/main"

  # Create and merge branch
  git worktree add "$WORKTREE_PARENT/test-wt" -b test-branch main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Test" >/dev/null 2>&1

  cd "$MAIN_REPO"
  git checkout main >/dev/null 2>&1
  git merge test-branch >/dev/null 2>&1

  cd "$WORKTREE_PARENT/test-wt"
  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/test-branch" -c "$WORKTREE_PARENT/test-wt" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $WORKTREE_PARENT/test-wt && gwtmux -d -wb"
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"
  wait_cmd_done

  # Should succeed
  refute [ -d "$WORKTREE_PARENT/test-wt" ]
}

@test "gwtmux -d: falls back to master for merge check" {
  # Create repo with master branch
  local master_remote="$TEST_TEMP_DIR/remote-master2.git"
  git init --bare "$master_remote" >/dev/null 2>&1

  local master_repo="$TEST_TEMP_DIR/repo-master2"
  git clone "$master_remote" "$master_repo" >/dev/null 2>&1
  cd "$master_repo"

  git config user.name "Test User"
  git config user.email "test@example.com"
  git checkout -b master >/dev/null 2>&1
  echo "initial" >README.md
  git add README.md
  git commit -m "Initial" >/dev/null 2>&1
  git push -u origin master >/dev/null 2>&1

  # Override MAIN_REPO for setup_worktree_structure
  MAIN_REPO="$master_repo"
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Remove symbolic-ref
  git remote set-head origin -d >/dev/null 2>&1

  # Create and merge branch
  git worktree add "$WORKTREE_PARENT/test-wt" -b test-branch master >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Test" >/dev/null 2>&1

  cd "$MAIN_REPO"
  git checkout master >/dev/null 2>&1
  git merge test-branch >/dev/null 2>&1

  cd "$WORKTREE_PARENT/test-wt"
  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/test-branch" -c "$WORKTREE_PARENT/test-wt" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $WORKTREE_PARENT/test-wt && gwtmux -d -wb"
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"
  wait_cmd_done

  # Should succeed using master
  refute [ -d "$WORKTREE_PARENT/test-wt" ]
}

# ----------------------------------------------------------------------------
# Error cases
# ----------------------------------------------------------------------------

@test "gwtmux -d: errors when in main repo with destructive flags" {
  cd "$MAIN_REPO"

  run gwtmux -d -w
  assert_failure
  assert_output --partial "in main repo, not a worktree"
}

@test "gwtmux -d: errors when in a subdirectory of main repo with destructive flags" {
  cd "$MAIN_REPO"
  mkdir -p "$MAIN_REPO/src/deep"
  cd "$MAIN_REPO/src/deep"

  run gwtmux -d -w
  assert_failure
  assert_output --partial "in main repo, not a worktree"
}

@test "gwtmux -d: works in main repo without destructive flags" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create a second window so we have multiple
  tmux new-window -t "$TEST_SESSION" -n "test-window" -c "$MAIN_REPO" 2>/dev/null
  local window_count_before=$(get_window_count)
  assert [ "$window_count_before" -gt 1 ]

  # Get the second window ID and run gwtmux -d from it
  local second_window=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | tail -1)
  send_cmd "$second_window" "cd $MAIN_REPO && gwtmux -d"
  wait_for_window_closed "test-window"
  wait_cmd_done

  # Window should be killed (since we have multiple windows)
  local window_count_after=$(get_window_count)
  assert [ "$window_count_after" -lt "$window_count_before" ]
}

@test "gwtmux -d: errors on unknown flag" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add -b test-wt "$WORKTREE_PARENT/test-wt" main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"

  run gwtmux -d -x
  assert_failure
  assert_output --partial "unknown option"
}

# ----------------------------------------------------------------------------
# New window handling functionality
# ----------------------------------------------------------------------------

@test "gwtmux -d: deletes worktree with -w flag" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/test-wt" -b test-branch main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"
  git config user.name "Test User"
  git config user.email "test@example.com"

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/test-branch" -c "$WORKTREE_PARENT/test-wt" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $WORKTREE_PARENT/test-wt && gwtmux -d -w"
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"
  wait_cmd_done

  # Worktree should be removed
  refute [ -d "$WORKTREE_PARENT/test-wt" ]

  # Branch should still exist
  run git -C "$MAIN_REPO" branch
  assert_output --partial "test-branch"
}

@test "gwtmux -d: renames last window instead of killing" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/test-wt" -b test-branch main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"
  git config user.name "Test User"
  git config user.email "test@example.com"

  # Ensure we only have one window
  local window_count_before=$(get_window_count)
  assert [ "$window_count_before" -eq 1 ]

  # Get the actual window ID and expected shell name
  local window_id=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)
  local expected_shell=$(basename "${SHELL:-zsh}")

  send_cmd "$window_id" "cd $WORKTREE_PARENT/test-wt && gwtmux -d"
  wait_until "[ \"\$(tmux display-message -t '$window_id' -p '#W')\" = '$expected_shell' ]"
  wait_cmd_done

  # Window should still exist
  local window_count_after=$(get_window_count)
  assert [ "$window_count_after" -eq 1 ]

  # Window should be renamed to shell name
  run tmux display-message -t "$window_id" -p '#W'
  assert_output "$expected_shell"
}

@test "gwtmux -d: navigates to parent when renaming last window" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/test-wt" -b test-branch main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"
  git config user.name "Test User"
  git config user.email "test@example.com"

  # Ensure we only have one window
  local window_count=$(get_window_count)
  assert [ "$window_count" -eq 1 ]

  # Get the actual window ID
  local window_id=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)

  # Execute gwtmux -d and capture PWD after
  # Marker lives in the per-test dir, not /tmp: keyed on the bats PID it
  # outlives an interrupted run, and a later run that is given the same PID
  # would read the previous run's path and assert against a temp dir that no
  # longer exists. bats removes this directory for us.
  local done_pwd="$TEST_TEMP_DIR/done_pwd"
  send_cmd "$window_id" "cd $WORKTREE_PARENT/test-wt && gwtmux -d && pwd > '$done_pwd'"
  wait_until "[ -f '$done_pwd' ]"
  wait_cmd_done

  # Verify we're in the parent directory
  run cat "$done_pwd"
  assert_output "$WORKTREE_PARENT"
}

@test "gwtmux -d: kills window when multiple windows exist" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/test-wt" -b test-branch main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"
  git config user.name "Test User"
  git config user.email "test@example.com"

  # Create a second window so we have multiple
  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/test-branch" -c "$WORKTREE_PARENT/test-wt" -P -F "#{window_id}")
  local window_count_before=$(get_window_count)
  assert [ "$window_count_before" -gt 1 ]

  send_cmd "$new_window" "cd $WORKTREE_PARENT/test-wt && gwtmux -d"
  wait_for_window_closed "myrepo/test-branch"
  wait_cmd_done

  # Window should be killed
  local window_count_after=$(get_window_count)
  assert [ "$window_count_after" -lt "$window_count_before" ]
}

@test "gwtmux -d: kills invoking window even when another window is active" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/test-wt" -b test-branch main >/dev/null 2>&1

  local wt_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/test-branch" -c "$WORKTREE_PARENT/test-wt" -P -F "#{window_id}")
  local bystander=$(tmux new-window -t "$TEST_SESSION" -n "bystander" -c "$MAIN_REPO" -P -F "#{window_id}")

  # Focus a different window - gwtmux must still act on the window it runs in
  tmux select-window -t "$bystander"

  send_cmd "$wt_window" "cd $WORKTREE_PARENT/test-wt && gwtmux -d"
  wait_for_window_closed "myrepo/test-branch"
  wait_cmd_done

  # The worktree's window is gone, the focused bystander window survives
  run get_tmux_windows
  refute_output --partial "myrepo/test-branch"
  assert_output --partial "bystander"
}

# ----------------------------------------------------------------------------
# Multiple arguments for -d mode
# ----------------------------------------------------------------------------

@test "gwtmux -d: deletes multiple worktrees with -wB flags" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create multiple worktrees (matching dir and branch names, as gwtmux does)
  git worktree add "$WORKTREE_PARENT/wt-1" -b wt-1 main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/wt-1"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "test1" >test1.txt
  git add test1.txt
  git commit -m "Test 1" >/dev/null 2>&1

  cd "$MAIN_REPO"
  git worktree add "$WORKTREE_PARENT/wt-2" -b wt-2 main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/wt-2"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "test2" >test2.txt
  git add test2.txt
  git commit -m "Test 2" >/dev/null 2>&1

  # Create windows for them
  tmux new-window -t "$TEST_SESSION" -n "myrepo/wt-1" -c "$WORKTREE_PARENT/wt-1" 2>/dev/null
  tmux new-window -t "$TEST_SESSION" -n "myrepo/wt-2" -c "$WORKTREE_PARENT/wt-2" 2>/dev/null

  # Run from main repo (not using tmux send-keys - run directly)
  cd "$MAIN_REPO"

  # Run directly in this shell (not via tmux send-keys)
  run gwtmux -dwB wt-1 wt-2

  # Check if it worked
  echo "gwtmux exit code: $status"
  echo "gwtmux output: $output"

  # Both worktrees should be removed
  refute [ -d "$WORKTREE_PARENT/wt-1" ]
  refute [ -d "$WORKTREE_PARENT/wt-2" ]

  # Both branches should be deleted
  run git -C "$MAIN_REPO" branch
  refute_output --partial "wt-1"
  refute_output --partial "wt-2"
}

@test "gwtmux -d: validates all branches before deleting any (safe mode)" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create two worktrees - we'll try to delete both with safe delete
  # One will be "merged" (actually we'll just use force delete for merged one separately)
  git worktree add "$WORKTREE_PARENT/wt-good" -b wt-good main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/wt-good"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "good" >good.txt
  git add good.txt
  git commit -m "Good" >/dev/null 2>&1

  # Create second worktree
  cd "$MAIN_REPO"
  git worktree add "$WORKTREE_PARENT/wt-bad" -b wt-bad main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/wt-bad"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "bad" >bad.txt
  git add bad.txt
  git commit -m "Bad" >/dev/null 2>&1

  # Try to delete both with safe delete - should fail because neither is merged
  cd "$MAIN_REPO"
  run gwtmux -dwb wt-good wt-bad
  assert_failure
  assert_output --partial "not merged"

  # Both worktrees should still exist (atomic operation - neither deleted)
  assert_dir_exists "$WORKTREE_PARENT/wt-good"
  assert_dir_exists "$WORKTREE_PARENT/wt-bad"

  # Both branches should still exist
  run git -C "$MAIN_REPO" branch
  assert_output --partial "wt-good"
  assert_output --partial "wt-bad"
}

@test "gwtmux -d: closes windows for all specified worktrees" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create multiple worktrees (using same name for dir and branch, as gwtmux normal mode does)
  git worktree add "$WORKTREE_PARENT/wt-a" -b wt-a main >/dev/null 2>&1
  git worktree add "$WORKTREE_PARENT/wt-b" -b wt-b main >/dev/null 2>&1

  # Create windows for them (named after branches, as gwtmux does)
  tmux new-window -t "$TEST_SESSION" -n "myrepo/wt-a" -c "$WORKTREE_PARENT/wt-a" 2>/dev/null
  tmux new-window -t "$TEST_SESSION" -n "myrepo/wt-b" -c "$WORKTREE_PARENT/wt-b" 2>/dev/null

  # Verify windows exist
  run get_tmux_windows
  assert_output --partial "myrepo/wt-a"
  assert_output --partial "myrepo/wt-b"

  # Delete both (without worktree/branch deletion, just window management)
  # Get a window to run from (needs proper tmux context for display-message)
  local window_id=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)

  # Execute via tmux send-keys so gwtmux has proper tmux context
  send_cmd "$window_id" "cd $MAIN_REPO && gwtmux -d wt-a wt-b"

  # Windows should be closed (wait for async command)
  wait_for_window_closed "myrepo/wt-a"
  wait_for_window_closed "myrepo/wt-b"
  wait_cmd_done
  run get_tmux_windows
  refute_output --partial "myrepo/wt-a"
  refute_output --partial "myrepo/wt-b"
}

@test "gwtmux -d: errors if any worktree doesn't exist" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create only one worktree
  git worktree add "$WORKTREE_PARENT/exists" -b exists-branch main >/dev/null 2>&1

  # Try to delete one that exists and one that doesn't
  run gwtmux -d exists nonexistent
  assert_failure
  assert_output --partial "does not exist"
  assert_output --partial "nonexistent"

  # Should not delete the one that exists (atomic operation)
  assert_dir_exists "$WORKTREE_PARENT/exists"
}

@test "gwtmux -d: handles slash conversion in worktree names" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create worktree with slash in branch name
  git worktree add "$WORKTREE_PARENT/feature_fix" -b feature/fix main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/feature_fix"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Test" >/dev/null 2>&1

  # Delete using original branch name with slash (use force delete)
  cd "$MAIN_REPO"
  run gwtmux -dwB feature/fix
  assert_success

  # Worktree should be deleted
  refute [ -d "$WORKTREE_PARENT/feature_fix" ]

  # Branch should be deleted
  run git -C "$MAIN_REPO" branch
  refute_output --partial "feature/fix"
}

@test "gwtmux -d: backward compatibility - no args uses current worktree" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/test-wt" -b test-branch main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Test" >/dev/null 2>&1

  # Merge for safe delete
  cd "$MAIN_REPO"
  git checkout main >/dev/null 2>&1
  git merge test-branch >/dev/null 2>&1

  cd "$WORKTREE_PARENT/test-wt"
  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/test-branch" -c "$WORKTREE_PARENT/test-wt" -P -F "#{window_id}")
  sleep 0.1  # Wait for shell to be ready

  # Run without arguments (original behavior)
  send_cmd "$new_window" "cd $WORKTREE_PARENT/test-wt && gwtmux -dwb"

  # Should delete current worktree (wait for async tmux command)
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"
  wait_cmd_done
  refute [ -d "$WORKTREE_PARENT/test-wt" ]
  run git -C "$MAIN_REPO" branch
  refute_output --partial "test-branch"
}

@test "gwtmux -d: stays in worktree when deletion fails with uncommitted changes" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/test-wt" -b test-branch main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"
  git config user.name "Test User"
  git config user.email "test@example.com"

  # Create uncommitted changes
  echo "uncommitted" >uncommitted.txt
  git add uncommitted.txt

  # Try to delete worktree (should fail)
  run gwtmux -dwB
  assert_failure
  assert_output --partial "modified or untracked files"

  # Should still be in the original worktree directory
  assert_equal "$PWD" "$WORKTREE_PARENT/test-wt"

  # Worktree should still exist
  assert_dir_exists "$WORKTREE_PARENT/test-wt"

  # Branch should still exist
  run git -C "$MAIN_REPO" branch
  assert_output --partial "test-branch"
}

@test "gwtmux -d: stays in current worktree when deleting a different worktree" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create two worktrees
  git worktree add "$WORKTREE_PARENT/wt-stay" -b wt-stay main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/wt-stay"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "stay" >stay.txt
  git add stay.txt
  git commit -m "Stay commit" >/dev/null 2>&1

  cd "$MAIN_REPO"
  git worktree add "$WORKTREE_PARENT/wt-delete" -b wt-delete main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/wt-delete"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "delete" >delete.txt
  git add delete.txt
  git commit -m "Delete commit" >/dev/null 2>&1

  # Go to wt-stay and delete wt-delete from there
  cd "$WORKTREE_PARENT/wt-stay"

  # Delete the OTHER worktree (not the one we're in)
  run gwtmux -dwB wt-delete
  assert_success

  # The deleted worktree should be gone
  refute [ -d "$WORKTREE_PARENT/wt-delete" ]

  # The deleted branch should be gone
  run git -C "$MAIN_REPO" branch
  refute_output --partial "wt-delete"

  # We should still be in our original worktree, NOT the parent directory
  assert_equal "$PWD" "$WORKTREE_PARENT/wt-stay"

  # Our worktree should still exist
  assert_dir_exists "$WORKTREE_PARENT/wt-stay"
}

@test "gwtmux -d: deletes worktree when run from parent directory" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create a worktree
  git worktree add "$WORKTREE_PARENT/wt-from-parent" -b wt-from-parent main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/wt-from-parent"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "test" >test.txt
  git add test.txt
  git commit -m "Test commit" >/dev/null 2>&1

  # Go to the parent directory (not in any git repo)
  cd "$WORKTREE_PARENT"

  # Verify we're not in a git repo
  run git rev-parse --git-dir
  assert_failure

  # Delete the worktree from parent directory by specifying its name
  run gwtmux -dwB wt-from-parent
  assert_success

  # The worktree should be deleted
  refute [ -d "$WORKTREE_PARENT/wt-from-parent" ]

  # The branch should be deleted
  run git -C "$MAIN_REPO" branch
  refute_output --partial "wt-from-parent"
}

@test "gwtmux -d: deletes multiple worktrees when run from parent directory" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create multiple worktrees
  git worktree add "$WORKTREE_PARENT/wt-p1" -b wt-p1 main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/wt-p1"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "1" >file1.txt
  git add file1.txt
  git commit -m "Commit 1" >/dev/null 2>&1

  cd "$MAIN_REPO"
  git worktree add "$WORKTREE_PARENT/wt-p2" -b wt-p2 main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/wt-p2"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "2" >file2.txt
  git add file2.txt
  git commit -m "Commit 2" >/dev/null 2>&1

  cd "$MAIN_REPO"
  git worktree add "$WORKTREE_PARENT/wt-p3" -b wt-p3 main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/wt-p3"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "3" >file3.txt
  git add file3.txt
  git commit -m "Commit 3" >/dev/null 2>&1

  # Go to the parent directory (not in any git repo)
  cd "$WORKTREE_PARENT"

  # Verify we're not in a git repo
  run git rev-parse --git-dir
  assert_failure

  # Delete all three worktrees from parent directory
  run gwtmux -dwB wt-p1 wt-p2 wt-p3
  assert_success

  # All worktrees should be deleted
  refute [ -d "$WORKTREE_PARENT/wt-p1" ]
  refute [ -d "$WORKTREE_PARENT/wt-p2" ]
  refute [ -d "$WORKTREE_PARENT/wt-p3" ]

  # All branches should be deleted
  run git -C "$MAIN_REPO" branch
  refute_output --partial "wt-p1"
  refute_output --partial "wt-p2"
  refute_output --partial "wt-p3"
}

@test "gwtmux -d: fails in parent directory without specifying worktree name" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create a worktree
  git worktree add "$WORKTREE_PARENT/wt-test" -b wt-test main >/dev/null 2>&1

  # Go to the parent directory (not in any git repo)
  cd "$WORKTREE_PARENT"

  # Running gwtmux -d without specifying a worktree should fail
  run gwtmux -dwB
  assert_failure
  assert_output --partial "not in a git repository"

  # The worktree should still exist
  assert_dir_exists "$WORKTREE_PARENT/wt-test"
}

@test "gwtmux -d: deletes multiple worktrees including current one" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create three worktrees
  git worktree add "$WORKTREE_PARENT/wt-1" -b wt-1 main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/wt-1"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "1" >file1.txt
  git add file1.txt
  git commit -m "Commit 1" >/dev/null 2>&1

  cd "$MAIN_REPO"
  git worktree add "$WORKTREE_PARENT/wt-2" -b wt-2 main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/wt-2"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "2" >file2.txt
  git add file2.txt
  git commit -m "Commit 2" >/dev/null 2>&1

  cd "$MAIN_REPO"
  git worktree add "$WORKTREE_PARENT/wt-3" -b wt-3 main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/wt-3"
  git config user.name "Test User"
  git config user.email "test@example.com"
  echo "3" >file3.txt
  git add file3.txt
  git commit -m "Commit 3" >/dev/null 2>&1

  # Create tmux windows for all three
  tmux new-window -t "$TEST_SESSION" -n "myrepo/wt-1" -c "$WORKTREE_PARENT/wt-1" 2>/dev/null
  tmux new-window -t "$TEST_SESSION" -n "myrepo/wt-2" -c "$WORKTREE_PARENT/wt-2" 2>/dev/null
  tmux new-window -t "$TEST_SESSION" -n "myrepo/wt-3" -c "$WORKTREE_PARENT/wt-3" 2>/dev/null

  # Get window ID for wt-3 (we'll run the command from there)
  local wt3_window=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id} #W" |
    awk '/myrepo\/wt-3/ {print $1}')

  # From wt-3, delete wt-2 and wt-3 (current worktree is included)
  # Use a temp file to capture if the command completed
  # Per-test dir rather than /tmp keyed on the bats PID - see the -d PWD test.
  local marker_file="$TEST_TEMP_DIR/multi_delete"
  send_cmd "$wt3_window" "cd $WORKTREE_PARENT/wt-3 && gwtmux -dwB wt-2 wt-3 && echo done > '$marker_file'"

  # Wait for both worktrees to be deleted
  wait_for_dir_deleted "$WORKTREE_PARENT/wt-2"
  wait_for_dir_deleted "$WORKTREE_PARENT/wt-3"
  wait_cmd_done

  # Both worktrees should be deleted
  refute [ -d "$WORKTREE_PARENT/wt-2" ]
  refute [ -d "$WORKTREE_PARENT/wt-3" ]

  # Both branches should be deleted
  run git -C "$MAIN_REPO" branch
  refute_output --partial "wt-2"
  refute_output --partial "wt-3"

  # wt-1 should still exist
  assert_dir_exists "$WORKTREE_PARENT/wt-1"
  run git -C "$MAIN_REPO" branch
  assert_output --partial "wt-1"

  rm -f "$marker_file"
}

# ----------------------------------------------------------------------------
# Nested worktree cleanup
# ----------------------------------------------------------------------------

@test "gwtmux -d: prompts and removes nested worktrees (single worktree, confirm)" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create parent worktree
  git worktree add "$WORKTREE_PARENT/parent-wt" -b parent-wt main >/dev/null 2>&1

  # Create nested worktrees inside parent
  git worktree add "$WORKTREE_PARENT/parent-wt/nested1" -b nested1 main >/dev/null 2>&1
  git worktree add "$WORKTREE_PARENT/parent-wt/nested2" -b nested2 main >/dev/null 2>&1

  # Open tmux window for parent
  local wt_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/parent-wt" -c "$WORKTREE_PARENT/parent-wt" -P -F "#{window_id}" 2>/dev/null)

  # Run delete from parent worktree
  send_cmd "$wt_window" "cd $WORKTREE_PARENT/parent-wt && gwtmux -d -wB"

  # Confirm nested removal
  confirm_nested_worktree_removal "$wt_window"

  # Wait for parent to be deleted
  wait_for_dir_deleted "$WORKTREE_PARENT/parent-wt"
  wait_cmd_done

  # All worktrees should be gone
  refute [ -d "$WORKTREE_PARENT/parent-wt" ]

  # All branches should be deleted
  run git -C "$MAIN_REPO" branch
  refute_output --partial "parent-wt"
  refute_output --partial "nested1"
  refute_output --partial "nested2"
}

@test "gwtmux -d: cancels when nested worktree removal denied (single worktree)" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create parent worktree
  git worktree add "$WORKTREE_PARENT/parent-wt" -b parent-wt main >/dev/null 2>&1

  # Create nested worktree
  git worktree add "$WORKTREE_PARENT/parent-wt/nested1" -b nested1 main >/dev/null 2>&1

  # Open tmux window for parent
  local wt_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/parent-wt" -c "$WORKTREE_PARENT/parent-wt" -P -F "#{window_id}" 2>/dev/null)

  # Run delete from parent worktree
  send_cmd "$wt_window" "cd $WORKTREE_PARENT/parent-wt && gwtmux -d -wB"

  # Deny nested removal
  deny_nested_worktree_removal "$wt_window"
  wait_cmd_done
  sleep 0.5

  # Everything should still exist
  assert_dir_exists "$WORKTREE_PARENT/parent-wt"
  assert_dir_exists "$WORKTREE_PARENT/parent-wt/nested1"

  # Branches should still exist
  run git -C "$MAIN_REPO" branch
  assert_output --partial "parent-wt"
  assert_output --partial "nested1"
}

@test "gwtmux -d: no prompt when no nested worktrees" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/test-wt" -b test-wt main >/dev/null 2>&1

  local wt_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/test-wt" -c "$WORKTREE_PARENT/test-wt" -P -F "#{window_id}" 2>/dev/null)

  # This should work without any prompt
  send_cmd "$wt_window" "cd $WORKTREE_PARENT/test-wt && gwtmux -d -wB"
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"
  wait_cmd_done

  refute [ -d "$WORKTREE_PARENT/test-wt" ]
  # gwtmux kills its own window last, so no exit-code marker is ever written.
  # The window being gone is what says it ran to the end instead of stopping on
  # a prompt it should never have printed.
  refute tmux_window_exists "myrepo/test-wt"
}

@test "gwtmux -d: removes nested worktrees with detached HEAD" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create parent worktree
  git worktree add "$WORKTREE_PARENT/parent-wt" -b parent-wt main >/dev/null 2>&1

  # Create nested worktree on detached HEAD (no branch)
  local commit_hash=$(git -C "$MAIN_REPO" rev-parse HEAD)
  git worktree add --detach "$WORKTREE_PARENT/parent-wt/tmp/abc123" "$commit_hash" >/dev/null 2>&1

  local wt_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/parent-wt" -c "$WORKTREE_PARENT/parent-wt" -P -F "#{window_id}" 2>/dev/null)

  send_cmd "$wt_window" "cd $WORKTREE_PARENT/parent-wt && gwtmux -d -wB"

  confirm_nested_worktree_removal "$wt_window"
  wait_for_dir_deleted "$WORKTREE_PARENT/parent-wt"
  wait_cmd_done

  refute [ -d "$WORKTREE_PARENT/parent-wt" ]

  # Parent branch should be deleted
  run git -C "$MAIN_REPO" branch
  refute_output --partial "parent-wt"
}

@test "gwtmux -d: multi-worktree removes nested worktrees (confirm)" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create two parent worktrees each with nested
  git worktree add "$WORKTREE_PARENT/wt-a" -b wt-a main >/dev/null 2>&1
  git worktree add "$WORKTREE_PARENT/wt-a/child" -b child-a main >/dev/null 2>&1
  git worktree add "$WORKTREE_PARENT/wt-b" -b wt-b main >/dev/null 2>&1
  git worktree add "$WORKTREE_PARENT/wt-b/child" -b child-b main >/dev/null 2>&1

  tmux new-window -t "$TEST_SESSION" -n "myrepo/wt-a" -c "$WORKTREE_PARENT/wt-a" 2>/dev/null
  tmux new-window -t "$TEST_SESSION" -n "myrepo/wt-b" -c "$WORKTREE_PARENT/wt-b" 2>/dev/null

  # Use a new window for running the delete command from main repo
  tmux new-window -t "$TEST_SESSION" -n "runner" -c "$MAIN_REPO" 2>/dev/null
  local runner_window="$TEST_SESSION:runner"

  send_cmd "$runner_window" "gwtmux -dwB wt-a wt-b"

  confirm_nested_worktree_removal "$runner_window"
  wait_for_dir_deleted "$WORKTREE_PARENT/wt-a"
  wait_for_dir_deleted "$WORKTREE_PARENT/wt-b"
  wait_cmd_done

  refute [ -d "$WORKTREE_PARENT/wt-a" ]
  refute [ -d "$WORKTREE_PARENT/wt-b" ]

  run git -C "$MAIN_REPO" branch
  refute_output --partial "wt-a"
  refute_output --partial "wt-b"
  refute_output --partial "child-a"
  refute_output --partial "child-b"
}

@test "gwtmux -d: multi-worktree cancels when nested denial" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/wt-a" -b wt-a main >/dev/null 2>&1
  git worktree add "$WORKTREE_PARENT/wt-a/child" -b child-a main >/dev/null 2>&1

  tmux new-window -t "$TEST_SESSION" -n "myrepo/wt-a" -c "$WORKTREE_PARENT/wt-a" 2>/dev/null

  # Use a new window for running the delete command from main repo
  tmux new-window -t "$TEST_SESSION" -n "runner" -c "$MAIN_REPO" 2>/dev/null
  local runner_window="$TEST_SESSION:runner"

  send_cmd "$runner_window" "gwtmux -dwB wt-a"

  deny_nested_worktree_removal "$runner_window"
  wait_cmd_done
  sleep 0.5

  # Everything should still exist
  assert_dir_exists "$WORKTREE_PARENT/wt-a"
  assert_dir_exists "$WORKTREE_PARENT/wt-a/child"

  run git -C "$MAIN_REPO" branch
  assert_output --partial "wt-a"
  assert_output --partial "child-a"
}

# ----------------------------------------------------------------------------
# Done mode: worktree name resolution
# ----------------------------------------------------------------------------

@test "gwtmux -d: resolves a worktree outside the repo parent by name" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Not a sibling of default/, so the old path guess could never find it
  mkdir -p "$TEST_TEMP_DIR/elsewhere"
  git worktree add "$TEST_TEMP_DIR/elsewhere/out-wt" -b out-wt main >/dev/null 2>&1

  run gwtmux -dwB out-wt
  assert_success

  refute [ -d "$TEST_TEMP_DIR/elsewhere/out-wt" ]
  run git -C "$MAIN_REPO" branch
  refute_output --partial "out-wt"
}

@test "gwtmux -d: resolves a worktree by its branch name" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Directory name and branch name deliberately differ
  git worktree add "$WORKTREE_PARENT/dir-x" -b br-y main >/dev/null 2>&1

  run gwtmux -dwB br-y
  assert_success

  refute [ -d "$WORKTREE_PARENT/dir-x" ]
  run git -C "$MAIN_REPO" branch
  refute_output --partial "br-y"
}

@test "gwtmux -d: directory name wins over another worktree's branch name" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # "target" is one worktree's directory and another worktree's branch
  git worktree add "$WORKTREE_PARENT/target" -b a-branch main >/dev/null 2>&1
  git worktree add "$WORKTREE_PARENT/b-dir" -b target main >/dev/null 2>&1

  run gwtmux -dwB target
  assert_success

  refute [ -d "$WORKTREE_PARENT/target" ]
  assert_dir_exists "$WORKTREE_PARENT/b-dir"
  run git -C "$MAIN_REPO" branch
  refute_output --partial "a-branch"
  assert_output --partial "target"
}

@test "gwtmux -d: errors on an ambiguous worktree name and deletes nothing" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  mkdir -p "$WORKTREE_PARENT/one" "$WORKTREE_PARENT/two"
  git worktree add "$WORKTREE_PARENT/one/same" -b same-one main >/dev/null 2>&1
  git worktree add "$WORKTREE_PARENT/two/same" -b same-two main >/dev/null 2>&1
  git worktree add "$WORKTREE_PARENT/keeper" -b keeper main >/dev/null 2>&1

  run gwtmux -dwB same keeper
  assert_failure
  assert_output --partial "worktree 'same' is ambiguous"
  assert_output --partial "$WORKTREE_PARENT/one/same"
  assert_output --partial "$WORKTREE_PARENT/two/same"

  # The whole invocation aborts, so the unambiguous name survives too
  assert_dir_exists "$WORKTREE_PARENT/one/same"
  assert_dir_exists "$WORKTREE_PARENT/two/same"
  assert_dir_exists "$WORKTREE_PARENT/keeper"
}

@test "gwtmux -d: resolves a worktree by explicit path" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  mkdir -p "$WORKTREE_PARENT/one" "$WORKTREE_PARENT/two"
  git worktree add "$WORKTREE_PARENT/one/same" -b same-one main >/dev/null 2>&1
  git worktree add "$WORKTREE_PARENT/two/same" -b same-two main >/dev/null 2>&1

  # A path picks one of the two worktrees the basename cannot tell apart
  run gwtmux -dwB ../two/same
  assert_success

  refute [ -d "$WORKTREE_PARENT/two/same" ]
  assert_dir_exists "$WORKTREE_PARENT/one/same"
  run git -C "$MAIN_REPO" branch
  refute_output --partial "same-two"
  assert_output --partial "same-one"
}

@test "gwtmux -d: finds the repo from a path argument outside any repo" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/far-wt" -b far-wt main >/dev/null 2>&1

  # Not in a git repo: the path's own .git file leads back to the repo
  cd "$TEST_TEMP_DIR"
  run git rev-parse --git-dir
  assert_failure

  run gwtmux -dwB ./myrepo/far-wt
  assert_success

  refute [ -d "$WORKTREE_PARENT/far-wt" ]
  run git -C "$MAIN_REPO" branch
  refute_output --partial "far-wt"
}

# ----------------------------------------------------------------------------
# Window name collisions
# ----------------------------------------------------------------------------

@test "gwtmux: errors on a path whose computed window name is not unique" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Detached worktrees are named after their directory, so these two really do
  # map to one window name ("myrepo/same"). Branch-named worktrees would not:
  # see the test below.
  local commit_hash=$(git rev-parse HEAD)
  mkdir -p "$WORKTREE_PARENT/one" "$WORKTREE_PARENT/two"
  git worktree add --detach "$WORKTREE_PARENT/one/same" "$commit_hash" >/dev/null 2>&1
  git worktree add --detach "$WORKTREE_PARENT/two/same" "$commit_hash" >/dev/null 2>&1

  local before_count="$(get_window_count)"
  run gwtmux "$WORKTREE_PARENT/two/same"
  assert_failure
  assert_output --partial "is not unique"
  assert_output --partial "$WORKTREE_PARENT/one/same"
  assert_output --partial "$WORKTREE_PARENT/two/same"
  assert_equal "$(get_window_count)" "$before_count"
}

@test "gwtmux: opens a path whose directory name repeats but whose window name does not" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Same directory basename, different branches: the window names are
  # "myrepo/same-one" and "myrepo/same-two" and cannot collide
  mkdir -p "$WORKTREE_PARENT/one" "$WORKTREE_PARENT/two"
  git worktree add "$WORKTREE_PARENT/one/same" -b same-one main >/dev/null 2>&1
  git worktree add "$WORKTREE_PARENT/two/same" -b same-two main >/dev/null 2>&1

  run gwtmux "$WORKTREE_PARENT/two/same"
  assert_success
  assert tmux_window_exists "myrepo/same-two"
  refute tmux_window_exists "myrepo/same-one"
}

@test "gwtmux: opens a path when only another repo shares the directory name" {
  setup_worktree_structure "myrepo"

  # Second repo with a worktree of the same directory basename
  local OTHER_PARENT="$TEST_TEMP_DIR/otherrepo"
  mkdir -p "$OTHER_PARENT/default"
  git init "$OTHER_PARENT/default" >/dev/null 2>&1
  git -C "$OTHER_PARENT/default" config user.name "Test"
  git -C "$OTHER_PARENT/default" config user.email "test@test.com"
  echo "test" >"$OTHER_PARENT/default/file.txt"
  git -C "$OTHER_PARENT/default" add .
  git -C "$OTHER_PARENT/default" commit -m "init" >/dev/null 2>&1
  git -C "$OTHER_PARENT/default" worktree add -b shared "$OTHER_PARENT/shared" >/dev/null 2>&1

  git -C "$MAIN_REPO" worktree add -b shared "$WORKTREE_PARENT/shared" main >/dev/null 2>&1

  send_cmd "$TEST_SESSION" "cd $MAIN_REPO && gwtmux $WORKTREE_PARENT/shared"
  wait_for_window_exists "myrepo/shared"
  wait_cmd_done

  run get_tmux_windows
  assert_output --partial "myrepo/shared"
}

# ----------------------------------------------------------------------------
# Done mode: the main repo root
# ----------------------------------------------------------------------------

@test "gwtmux -d: -dB in the main repo switches to the primary branch and deletes" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"
  git checkout -b feature-x >/dev/null 2>&1

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/default" -c "$MAIN_REPO" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $MAIN_REPO && gwtmux -dB"
  wait_for_window_closed "myrepo/default"
  wait_cmd_done

  # Checkout moved to the primary branch, the branch itself is gone
  run git -C "$MAIN_REPO" branch --show-current
  assert_output "main"
  run git -C "$MAIN_REPO" branch
  refute_output --partial "feature-x"

  refute tmux_window_exists "myrepo/default"
}

@test "gwtmux -d: -dw in the main repo errors and changes nothing" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"
  git checkout -b feature-x >/dev/null 2>&1

  local before_count="$(get_window_count)"
  run gwtmux -d -w
  assert_failure
  assert_output --partial "in main repo, not a worktree"

  # Aborted before anything destructive: branch, checkout and window intact
  run git -C "$MAIN_REPO" branch --show-current
  assert_output "feature-x"
  assert_equal "$(get_window_count)" "$before_count"
}

@test "gwtmux -d: -dB in the main repo errors while on the primary branch" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  run gwtmux -dB
  assert_failure
  assert_output --partial "is the primary branch"

  run git -C "$MAIN_REPO" branch --show-current
  assert_output "main"
}

@test "gwtmux -d: -dB in the main repo errors on an uncommitted change" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"
  git checkout -b feature-x >/dev/null 2>&1
  echo "dirty" >>README.md

  run gwtmux -dB
  assert_failure
  assert_output --partial "uncommitted changes"

  run git -C "$MAIN_REPO" branch --show-current
  assert_output "feature-x"
  run git -C "$MAIN_REPO" branch
  assert_output --partial "feature-x"
}

@test "gwtmux -d: -dB in the main repo ignores untracked files" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"
  git checkout -b feature-x >/dev/null 2>&1
  echo "scratch" >"$MAIN_REPO/untracked.txt"

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/default" -c "$MAIN_REPO" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $MAIN_REPO && gwtmux -dB"
  wait_for_window_closed "myrepo/default"
  wait_cmd_done

  run git -C "$MAIN_REPO" branch --show-current
  assert_output "main"
  run git -C "$MAIN_REPO" branch
  refute_output --partial "feature-x"

  # Untracked files belong to no branch, so the switch leaves them alone
  assert_file_exists "$MAIN_REPO/untracked.txt"
}

@test "gwtmux -d: -dbr in the main repo deletes the merged branch and its remote" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"
  git checkout -b feature-x >/dev/null 2>&1
  git push -u origin feature-x >/dev/null 2>&1

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/default" -c "$MAIN_REPO" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $MAIN_REPO && gwtmux -dbr"
  wait_for_window_closed "myrepo/default"
  wait_cmd_done

  run git -C "$MAIN_REPO" branch --show-current
  assert_output "main"
  run git -C "$MAIN_REPO" branch
  refute_output --partial "feature-x"
  run git -C "$MAIN_REPO" branch -r
  refute_output --partial "origin/feature-x"
}

@test "gwtmux -d: -db in the main repo errors on an unmerged branch" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"
  git checkout -b feature-x >/dev/null 2>&1
  echo "work" >work.txt
  git add work.txt
  git commit -m "Unmerged commit" >/dev/null 2>&1

  run gwtmux -db
  assert_failure
  assert_output --partial "not merged"

  run git -C "$MAIN_REPO" branch --show-current
  assert_output "feature-x"
}

@test "gwtmux -d: -dB in the main repo errors with no local main or master" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"
  git checkout -b feature-x >/dev/null 2>&1
  git branch -D main >/dev/null 2>&1

  run gwtmux -dB
  assert_failure
  assert_output --partial "cannot determine primary branch"

  run git -C "$MAIN_REPO" branch --show-current
  assert_output "feature-x"
}

@test "gwtmux -d: bare -d in the main repo leaves the branch checked out" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"
  git checkout -b feature-x >/dev/null 2>&1

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "myrepo/default" -c "$MAIN_REPO" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $MAIN_REPO && gwtmux -d"
  wait_for_window_closed "myrepo/default"
  wait_cmd_done
  # gwtmux kills its own window here, so no exit-code marker is ever written.
  # Assert the window is really gone: otherwise a gwtmux that failed before
  # doing anything would satisfy the branch assertion below too.
  refute tmux_window_exists "myrepo/default"

  # Nothing was deleted, so nothing was switched either
  run git -C "$MAIN_REPO" branch --show-current
  assert_output "feature-x"
}

@test "gwtmux -d: -dB in the main repo keeps the cwd when renaming the last window" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"
  git checkout -b feature-x >/dev/null 2>&1

  # Ensure we only have one window
  local window_count_before=$(get_window_count)
  assert [ "$window_count_before" -eq 1 ]

  local window_id=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)
  local expected_shell=$(basename "${SHELL:-zsh}")

  send_cmd "$window_id" "cd $MAIN_REPO && gwtmux -dB"
  wait_until "[ \"\$(tmux display-message -t '$window_id' -p '#W')\" = '$expected_shell' ]"
  wait_cmd_done

  # Renamed, not killed
  assert_equal "$(get_window_count)" "1"
  run tmux display-message -t "$window_id" -p '#W'
  assert_output "$expected_shell"

  # The main repo was never deleted, so the pane stays in it
  run tmux display-message -t "$window_id" -p '#{pane_current_path}'
  assert_output "$MAIN_REPO"

  run git -C "$MAIN_REPO" branch --show-current
  assert_output "main"
}

@test "gwtmux -d: -dB <name> switches and deletes when the name is the main repo" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"
  git checkout -b feature-x >/dev/null 2>&1

  run gwtmux -dB default
  assert_success

  run git -C "$MAIN_REPO" branch --show-current
  assert_output "main"
  run git -C "$MAIN_REPO" branch
  refute_output --partial "feature-x"
}

@test "gwtmux -d: -dw <name> refuses the main repo and aborts the whole invocation" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/keeper" -b keeper main >/dev/null 2>&1

  run gwtmux -dw keeper default
  assert_failure
  assert_output --partial "is the main repo"

  # Validation runs before any deletion, so the valid name survives too
  assert_dir_exists "$WORKTREE_PARENT/keeper"
  assert_dir_exists "$MAIN_REPO"
}

# ----------------------------------------------------------------------------
# Flat repos: normal mode
# ----------------------------------------------------------------------------

@test "gwtmux: opens a flat repo via absolute path and creates no worktree" {
  setup_flat_repo "j2"

  local before_list="$(git -C "$FLAT_REPO" worktree list --porcelain)"

  send_cmd "$TEST_SESSION" "cd $TEST_TEMP_DIR && gwtmux $FLAT_REPO"
  wait_for_window_exists "j2"
  wait_cmd_done

  # Named after the repo directory alone, with no parent prefix
  assert tmux_window_exists "j2"
  refute tmux_window_exists "flat/j2"

  # Window-only: nothing was added to the repo
  assert_equal "$(git -C "$FLAT_REPO" worktree list --porcelain)" "$before_list"
}

@test "gwtmux: opens a flat repo via relative path and creates no worktree" {
  setup_flat_repo "j2"

  local before_list="$(git -C "$FLAT_REPO" worktree list --porcelain)"

  send_cmd "$TEST_SESSION" "cd $FLAT_PARENT && gwtmux ./j2"
  wait_for_window_exists "j2"
  wait_cmd_done

  assert tmux_window_exists "j2"
  assert_equal "$(git -C "$FLAT_REPO" worktree list --porcelain)" "$before_list"
}

@test "gwtmux: names a flat repo's worktree after the repo and its directory" {
  setup_flat_repo "j2"
  git -C "$FLAT_REPO" worktree add "$FLAT_PARENT/j2-work" -b work main >/dev/null 2>&1

  send_cmd "$TEST_SESSION" "cd $FLAT_REPO && gwtmux $FLAT_PARENT/j2-work"
  wait_for_window_exists "j2/j2-work"
  wait_cmd_done

  # Directory basename, not the branch name
  assert tmux_window_exists "j2/j2-work"
  refute tmux_window_exists "j2/work"
}

@test "gwtmux: errors on a subdirectory path of a flat repo" {
  setup_flat_repo "j2"
  mkdir -p "$FLAT_REPO/src"
  cd "$FLAT_REPO"

  local before_count="$(get_window_count)"
  run gwtmux "$FLAT_REPO/src"
  assert_failure
  assert_output --partial "is not a worktree root"
  assert_output --partial "$FLAT_REPO"
  assert_equal "$(get_window_count)" "$before_count"
}

# The four refusal tests below run gwtmux inside a tmux pane and read its output
# from a file instead of calling it in the bats process. A regression that lets
# the argument through reaches "Create new branch? [y/N]", which reads from
# /dev/tty: in the bats process that blocks forever with no timeout, so the test
# hangs instead of failing. In a pane the same block is bounded by
# wait_cmd_done, the marker never appears, and the exit-code assertion fails.
# Output goes to a file, not capture-pane: these messages carry an absolute path
# and would wrap across pane lines.
@test "gwtmux: errors on a branch argument inside a flat repo" {
  setup_flat_repo "j2"
  stub_gh_fail
  cd "$FLAT_REPO"

  local before_list="$(git -C "$FLAT_REPO" worktree list --porcelain)"
  local before_count="$(get_window_count)"

  send_cmd "$TEST_SESSION" "cd $FLAT_REPO && gwtmux feature-x >$TEST_TEMP_DIR/out 2>&1"
  wait_cmd_done
  assert_equal "$(cat "$CMD_MARKER")" "1"

  run cat "$TEST_TEMP_DIR/out"
  assert_output --partial "'$FLAT_REPO' is a flat repo"
  assert_output --partial "cannot create worktree 'feature-x'"

  refute [ -d "$FLAT_PARENT/feature-x" ]
  assert_equal "$(git -C "$FLAT_REPO" worktree list --porcelain)" "$before_list"
  assert_equal "$(get_window_count)" "$before_count"
  run git -C "$FLAT_REPO" branch
  refute_output --partial "feature-x"
}

@test "gwtmux: errors on a PR number inside a flat repo before calling gh" {
  setup_flat_repo "j2"

  # Records the call instead of answering it: the refusal must come first
  cat >"$STUB_DIR/gh" <<EOF
#!/bin/bash
touch "$TEST_TEMP_DIR/gh_was_called"
echo "pr-branch"
EOF
  chmod +x "$STUB_DIR/gh"

  cd "$FLAT_REPO"
  send_cmd "$TEST_SESSION" "cd $FLAT_REPO && gwtmux 123 >$TEST_TEMP_DIR/out 2>&1"
  wait_cmd_done
  assert_equal "$(cat "$CMD_MARKER")" "1"

  run cat "$TEST_TEMP_DIR/out"
  assert_output --partial "'$FLAT_REPO' is a flat repo"
  assert_output --partial "cannot create worktree '123'"

  refute [ -f "$TEST_TEMP_DIR/gh_was_called" ]
}

@test "gwtmux: errors on a branch argument under a flat repo path" {
  setup_worktree_structure "myrepo"
  setup_flat_repo "j2"
  cd "$MAIN_REPO"

  send_cmd "$TEST_SESSION" "cd $MAIN_REPO && gwtmux $FLAT_REPO/feature-x >$TEST_TEMP_DIR/out 2>&1"
  wait_cmd_done
  assert_equal "$(cat "$CMD_MARKER")" "1"

  run cat "$TEST_TEMP_DIR/out"
  assert_output --partial "'$FLAT_REPO' is a flat repo"
  assert_output --partial "cannot create worktree 'feature-x'"

  # No branch named after a filesystem path in the repo we happened to stand in
  run git -C "$MAIN_REPO" branch
  refute_output --partial "feature-x"
  refute [ -d "$FLAT_REPO/feature-x" ]
}

@test "gwtmux: errors on a branch argument under a flat repo subdirectory path" {
  setup_worktree_structure "myrepo"
  setup_flat_repo "j2"
  mkdir -p "$FLAT_REPO/src"
  cd "$MAIN_REPO"

  send_cmd "$TEST_SESSION" "cd $MAIN_REPO && gwtmux $FLAT_REPO/src/feature-x >$TEST_TEMP_DIR/out 2>&1"
  wait_cmd_done
  assert_equal "$(cat "$CMD_MARKER")" "1"

  run cat "$TEST_TEMP_DIR/out"
  assert_output --partial "'$FLAT_REPO' is a flat repo"
  # The walk folds the prefix into the branch name, as it does for a repo parent
  assert_output --partial "cannot create worktree 'src/feature-x'"
}

@test "gwtmux: no args opens a flat repo and its worktrees" {
  setup_flat_repo "j2"
  git -C "$FLAT_REPO" worktree add "$FLAT_PARENT/j2-work" -b work main >/dev/null 2>&1

  local shell_name=$(basename "${SHELL:-zsh}")
  local first_window=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)
  tmux rename-window -t "$first_window" "$shell_name"

  send_cmd "$first_window" "cd $FLAT_REPO && gwtmux"
  wait_for_window_exists "j2/j2-work"
  wait_cmd_done

  assert tmux_window_exists "j2"
  assert tmux_window_exists "j2/j2-work"
  # The reusable single-pane shell window is killed, as in convention mode
  refute tmux_window_exists "$shell_name"
}

@test "gwtmux: no args works from a subdirectory of a flat repo" {
  setup_flat_repo "j2"
  mkdir -p "$FLAT_REPO/src/deep"

  local runner=$(tmux new-window -t "$TEST_SESSION" -n "runner" -c "$TEST_TEMP_DIR" -P -F "#{window_id}")

  send_cmd "$runner" "cd $FLAT_REPO/src/deep && gwtmux"
  wait_for_window_exists "j2"
  wait_cmd_done

  assert tmux_window_exists "j2"
}

@test "gwtmux: no args works from inside a flat repo's worktree" {
  setup_flat_repo "j2"
  git -C "$FLAT_REPO" worktree add "$FLAT_PARENT/j2-work" -b work main >/dev/null 2>&1

  local runner=$(tmux new-window -t "$TEST_SESSION" -n "runner" -c "$TEST_TEMP_DIR" -P -F "#{window_id}")

  send_cmd "$runner" "cd $FLAT_PARENT/j2-work && gwtmux"
  wait_for_window_exists "j2"
  wait_cmd_done

  assert tmux_window_exists "j2"
  assert tmux_window_exists "j2/j2-work"
}

@test "gwtmux: no args still errors in a directory that only contains repos" {
  setup_flat_repo "j2"
  cd "$FLAT_PARENT"

  run gwtmux
  assert_failure
  assert_output --partial "branch or PR number required"
}

@test "gwtmux: no args in a convention parent under an ancestor repo stays convention" {
  setup_worktree_structure "myrepo"
  setup_ancestor_repo

  # Move the whole convention parent under the ancestor repo, before any
  # worktree of it exists, so no worktree administrative path goes stale.
  # Step out of it first: setup leaves the cwd inside the directory that moves.
  cd "$TEST_TEMP_DIR"
  mkdir -p "$ANCESTOR_REPO/repos"
  mv "$WORKTREE_PARENT" "$ANCESTOR_REPO/repos/myrepo"
  WORKTREE_PARENT="$ANCESTOR_REPO/repos/myrepo"
  MAIN_REPO="$WORKTREE_PARENT/default"
  git -C "$MAIN_REPO" worktree add -b feature-1 "$WORKTREE_PARENT/feature-1" main >/dev/null 2>&1

  send_cmd "$TEST_SESSION" "cd $WORKTREE_PARENT && gwtmux"
  wait_for_window_exists "myrepo/feature-1"
  # The reusable shell window is killed, so the marker can never be written:
  # wait_cmd_done finishes on the pane disappearing instead.
  wait_cmd_done

  # The repo standing right here wins, not the one the cwd happens to belong to
  assert tmux_window_exists "myrepo/default"
  assert tmux_window_exists "myrepo/feature-1"
  refute tmux_window_exists "ancestor"
  refute tmux_window_exists "ancestor/ancestor-wt"
}

@test "gwtmux: no args inside a flat repo under an ancestor repo opens the inner repo" {
  setup_flat_repo "j2"
  setup_ancestor_repo

  mv "$FLAT_PARENT" "$ANCESTOR_REPO/flat"
  FLAT_PARENT="$ANCESTOR_REPO/flat"
  FLAT_REPO="$FLAT_PARENT/j2"
  git -C "$FLAT_REPO" worktree add "$FLAT_PARENT/j2-work" -b work main >/dev/null 2>&1

  local runner=$(tmux new-window -t "$TEST_SESSION" -n "runner" -c "$TEST_TEMP_DIR" -P -F "#{window_id}")

  send_cmd "$runner" "cd $FLAT_REPO && gwtmux"
  wait_for_window_exists "j2/j2-work"
  wait_cmd_done
  assert_equal "$(cat "$CMD_MARKER")" "0"

  # The innermost repo, not the ancestor the resolver could also reach
  assert tmux_window_exists "j2"
  assert tmux_window_exists "j2/j2-work"
  refute tmux_window_exists "ancestor"
  refute tmux_window_exists "ancestor/ancestor-wt"
}

@test "gwtmux: selects the existing window of a flat repo instead of a second one" {
  setup_flat_repo "j2"

  local first_window=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)
  tmux new-window -t "$TEST_SESSION" -n "j2" -c "$FLAT_REPO" >/dev/null 2>&1
  local before_count="$(get_window_count)"

  send_cmd "$first_window" "cd $TEST_TEMP_DIR && gwtmux $FLAT_REPO"
  wait_cmd_done
  # An outright failure also leaves the window count alone, so the count means
  # nothing unless gwtmux succeeded.
  assert_equal "$(cat "$CMD_MARKER")" "0"

  assert_equal "$(get_window_count)" "$before_count"
}

# D19: flat mode never fetches. The path-argument tests below cannot prove this
# on their own - a path argument suppresses the pre-loop fetch in either layout,
# so deleting the flat-repo half of the guard leaves them green. Only a
# non-path argument reaches the flat half, and the refusal for it comes after
# the pre-loop fetch, so the fetch is observable.
@test "gwtmux: refuses a branch in a flat repo without fetching origin first" {
  setup_flat_repo "j2"
  stub_gh_fail

  # A branch that exists on origin and has never been fetched here. Any fetch
  # would create its remote-tracking ref, so the ref's absence afterwards is
  # proof that no fetch ran.
  git -C "$FLAT_REPO" push -q origin main:remote-only
  git -C "$FLAT_REPO" update-ref -d refs/remotes/origin/remote-only
  refute git -C "$FLAT_REPO" show-ref --verify --quiet refs/remotes/origin/remote-only

  send_cmd "$TEST_SESSION" "cd $FLAT_REPO && gwtmux feature-x >$TEST_TEMP_DIR/out 2>&1"
  wait_cmd_done
  assert_equal "$(cat "$CMD_MARKER")" "1"

  run cat "$TEST_TEMP_DIR/out"
  assert_output --partial "'$FLAT_REPO' is a flat repo"

  refute git -C "$FLAT_REPO" show-ref --verify --quiet refs/remotes/origin/remote-only
}

# Proves the unreachable remote costs nothing here; it does NOT prove the
# flat-repo half of the no-fetch guard (see the test above).
@test "gwtmux: opens a flat repo path without fetching from an unreachable origin" {
  setup_flat_repo "j2"
  git -C "$FLAT_REPO" remote set-url origin "$TEST_TEMP_DIR/gone.git"
  cd "$FLAT_REPO"

  run gwtmux "$FLAT_REPO"
  assert_success
  refute_output --partial "does not appear to be a git repository"
  assert tmux_window_exists "j2"
}

@test "gwtmux: opens a path in a convention repo without fetching" {
  setup_worktree_structure "myrepo"
  git -C "$MAIN_REPO" worktree add -b existing-wt "$WORKTREE_PARENT/existing-wt" main >/dev/null 2>&1
  git -C "$MAIN_REPO" remote set-url origin "$TEST_TEMP_DIR/gone.git"
  cd "$MAIN_REPO"

  # Every argument is a path, so nothing needs the remote
  run gwtmux "$WORKTREE_PARENT/existing-wt"
  assert_success
  refute_output --partial "does not appear to be a git repository"
  assert tmux_window_exists "myrepo/existing-wt"
}

# ----------------------------------------------------------------------------
# Flat repos: done mode
# ----------------------------------------------------------------------------

@test "gwtmux -d: closes a flat repo's window and leaves the branch alone" {
  setup_flat_repo "j2"
  git -C "$FLAT_REPO" checkout -b feature-x >/dev/null 2>&1

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "j2" -c "$FLAT_REPO" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $FLAT_REPO && gwtmux -d"
  wait_for_window_closed "j2"
  wait_cmd_done
  # No marker: gwtmux kills its own window. Assert the close happened, or a
  # gwtmux that failed immediately would pass the branch assertion below.
  refute tmux_window_exists "j2"

  # Nothing was deleted, so nothing was switched either
  run git -C "$FLAT_REPO" branch --show-current
  assert_output "feature-x"
}

@test "gwtmux -d: -dw in a flat repo root errors and changes nothing" {
  setup_flat_repo "j2"
  git -C "$FLAT_REPO" checkout -b feature-x >/dev/null 2>&1
  cd "$FLAT_REPO"

  local before_count="$(get_window_count)"
  run gwtmux -d -w
  assert_failure
  assert_output --partial "in main repo, not a worktree"

  run git -C "$FLAT_REPO" branch --show-current
  assert_output "feature-x"
  assert_dir_exists "$FLAT_REPO"
  assert_equal "$(get_window_count)" "$before_count"
}

@test "gwtmux -d: -dB in a flat repo root switches to the primary branch and deletes" {
  setup_flat_repo "j2"
  git -C "$FLAT_REPO" checkout -b feature-x >/dev/null 2>&1

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "j2" -c "$FLAT_REPO" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $FLAT_REPO && gwtmux -dB"
  wait_for_window_closed "j2"
  wait_cmd_done

  run git -C "$FLAT_REPO" branch --show-current
  assert_output "main"
  run git -C "$FLAT_REPO" branch
  refute_output --partial "feature-x"
}

@test "gwtmux -d: -dB in a flat repo root errors while on the primary branch" {
  setup_flat_repo "j2"
  cd "$FLAT_REPO"

  run gwtmux -dB
  assert_failure
  assert_output --partial "is the primary branch"

  run git -C "$FLAT_REPO" branch --show-current
  assert_output "main"
}

@test "gwtmux -d: -dB in a flat repo root errors on an uncommitted change" {
  setup_flat_repo "j2"
  git -C "$FLAT_REPO" checkout -b feature-x >/dev/null 2>&1
  echo "dirty" >>"$FLAT_REPO/README.md"
  cd "$FLAT_REPO"

  run gwtmux -dB
  assert_failure
  assert_output --partial "uncommitted changes"

  run git -C "$FLAT_REPO" branch --show-current
  assert_output "feature-x"
  run git -C "$FLAT_REPO" branch
  assert_output --partial "feature-x"
}

@test "gwtmux -d: -dB in a flat repo root ignores untracked files" {
  setup_flat_repo "j2"
  git -C "$FLAT_REPO" checkout -b feature-x >/dev/null 2>&1
  echo "scratch" >"$FLAT_REPO/untracked.txt"

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "j2" -c "$FLAT_REPO" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $FLAT_REPO && gwtmux -dB"
  wait_for_window_closed "j2"
  wait_cmd_done

  run git -C "$FLAT_REPO" branch --show-current
  assert_output "main"
  assert_file_exists "$FLAT_REPO/untracked.txt"
}

@test "gwtmux -d: -dbr in a flat repo root deletes the merged branch and its remote" {
  setup_flat_repo "j2"
  git -C "$FLAT_REPO" checkout -b feature-x >/dev/null 2>&1
  git -C "$FLAT_REPO" push -u origin feature-x >/dev/null 2>&1

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "j2" -c "$FLAT_REPO" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $FLAT_REPO && gwtmux -dbr"
  wait_for_window_closed "j2"
  wait_cmd_done

  run git -C "$FLAT_REPO" branch --show-current
  assert_output "main"
  run git -C "$FLAT_REPO" branch
  refute_output --partial "feature-x"
  run git -C "$FLAT_REPO" branch -r
  refute_output --partial "origin/feature-x"
}

@test "gwtmux -d: -db in a flat repo root errors on an unmerged branch" {
  setup_flat_repo "j2"
  git -C "$FLAT_REPO" checkout -b feature-x >/dev/null 2>&1
  echo "work" >"$FLAT_REPO/work.txt"
  git -C "$FLAT_REPO" add work.txt
  git -C "$FLAT_REPO" commit -m "Unmerged commit" >/dev/null 2>&1
  cd "$FLAT_REPO"

  run gwtmux -db
  assert_failure
  assert_output --partial "not merged"

  run git -C "$FLAT_REPO" branch --show-current
  assert_output "feature-x"
}

@test "gwtmux -d: -dB in a flat repo root errors with no local main or master" {
  setup_flat_repo "j2"
  git -C "$FLAT_REPO" checkout -b feature-x >/dev/null 2>&1
  git -C "$FLAT_REPO" branch -D main >/dev/null 2>&1
  cd "$FLAT_REPO"

  run gwtmux -dB
  assert_failure
  assert_output --partial "cannot determine primary branch"

  run git -C "$FLAT_REPO" branch --show-current
  assert_output "feature-x"
}

@test "gwtmux -d: -dB in a flat repo root keeps the cwd when renaming the last window" {
  setup_flat_repo "j2"
  git -C "$FLAT_REPO" checkout -b feature-x >/dev/null 2>&1

  local window_count_before=$(get_window_count)
  assert [ "$window_count_before" -eq 1 ]

  local window_id=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)
  local expected_shell=$(basename "${SHELL:-zsh}")

  send_cmd "$window_id" "cd $FLAT_REPO && gwtmux -dB"
  wait_until "[ \"\$(tmux display-message -t '$window_id' -p '#W')\" = '$expected_shell' ]"
  wait_cmd_done

  assert_equal "$(get_window_count)" "1"

  # Nothing was deleted, so the pane stays where it was
  run tmux display-message -t "$window_id" -p '#{pane_current_path}'
  assert_output "$FLAT_REPO"

  run git -C "$FLAT_REPO" branch --show-current
  assert_output "main"
}

@test "gwtmux -d: -dwB reaches a flat repo's worktree by name and closes its window" {
  setup_flat_repo "j2"
  mkdir -p "$TEST_TEMP_DIR/elsewhere"
  git -C "$FLAT_REPO" worktree add "$TEST_TEMP_DIR/elsewhere/out-wt" -b out-wt main >/dev/null 2>&1

  local runner=$(tmux new-window -t "$TEST_SESSION" -n "runner" -c "$FLAT_REPO" -P -F "#{window_id}")
  tmux new-window -t "$TEST_SESSION" -n "j2/out-wt" -c "$TEST_TEMP_DIR/elsewhere/out-wt" >/dev/null 2>&1

  send_cmd "$runner" "cd $FLAT_REPO && gwtmux -dwB out-wt"
  wait_for_window_closed "j2/out-wt"
  wait_cmd_done

  refute [ -d "$TEST_TEMP_DIR/elsewhere/out-wt" ]
  run git -C "$FLAT_REPO" branch
  refute_output --partial "out-wt"
}

# ----------------------------------------------------------------------------
# Flat repos: rename mode
# ----------------------------------------------------------------------------

@test "gwtmux --rename: renames a flat repo's worktree in its own parent" {
  setup_flat_repo "j2"
  git -C "$FLAT_REPO" worktree add "$FLAT_PARENT/old-name" -b old-name main >/dev/null 2>&1

  local new_window=$(tmux new-window -t "$TEST_SESSION" -n "j2/old-name" -c "$FLAT_PARENT/old-name" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $FLAT_PARENT/old-name && gwtmux --rename new-name"
  wait_for_dir_exists "$FLAT_PARENT/new-name"
  wait_cmd_done

  assert_dir_exists "$FLAT_PARENT/new-name"
  refute [ -d "$FLAT_PARENT/old-name" ]

  run git -C "$FLAT_PARENT/new-name" branch --show-current
  assert_output "new-name"

  # Named after the repo, not after the directory that holds the worktree
  run tmux display-message -t "$new_window" -p '#W'
  assert_output "j2/new-name"
}

@test "gwtmux --rename: refuses a flat repo root" {
  setup_flat_repo "j2"
  cd "$FLAT_REPO"

  run gwtmux --rename new-name
  assert_failure
  assert_output --partial "in main repo, not a worktree"

  assert_dir_exists "$FLAT_REPO"
  run git -C "$FLAT_REPO" branch --show-current
  assert_output "main"
}

# ----------------------------------------------------------------------------
# Pre-existing defects (independent of the flat-repo work)
# ----------------------------------------------------------------------------

@test "gwtmux -d: -dwb deletes a merged branch checked out in another worktree" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/test-wt" -b test-branch main >/dev/null 2>&1
  git -C "$WORKTREE_PARENT/test-wt" config user.name "Test User"
  git -C "$WORKTREE_PARENT/test-wt" config user.email "test@example.com"
  echo "test" >"$WORKTREE_PARENT/test-wt/test.txt"
  git -C "$WORKTREE_PARENT/test-wt" add test.txt
  git -C "$WORKTREE_PARENT/test-wt" commit -m "Test" >/dev/null 2>&1
  git -C "$MAIN_REPO" merge test-branch >/dev/null 2>&1

  # git marks a branch checked out in ANOTHER worktree with "+", never "*" or a
  # space - which is every branch this code path is asked to delete.
  run git -C "$MAIN_REPO" branch --merged main
  assert_output --partial "+ test-branch"

  run gwtmux -dwb test-branch
  assert_success
  refute_output --partial "not merged"

  refute [ -d "$WORKTREE_PARENT/test-wt" ]
  run git -C "$MAIN_REPO" branch
  refute_output --partial "test-branch"
}

@test "gwtmux -d: -dbr keeps the remote branch when the local delete fails" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/test-wt" -b test-branch main >/dev/null 2>&1
  git -C "$WORKTREE_PARENT/test-wt" config user.name "Test User"
  git -C "$WORKTREE_PARENT/test-wt" config user.email "test@example.com"
  echo "test" >"$WORKTREE_PARENT/test-wt/test.txt"
  git -C "$WORKTREE_PARENT/test-wt" add test.txt
  git -C "$WORKTREE_PARENT/test-wt" commit -m "Test" >/dev/null 2>&1
  git -C "$WORKTREE_PARENT/test-wt" push -u origin test-branch >/dev/null 2>&1
  git -C "$MAIN_REPO" merge test-branch >/dev/null 2>&1

  # No -w, so the worktree stays and git refuses to delete the branch it has
  # checked out. The remote copy is then the only one left: it must survive.
  run gwtmux -dbr test-branch
  assert_output --partial "failed to delete branch 'test-branch'"

  run git -C "$MAIN_REPO" branch
  assert_output --partial "test-branch"
  run git -C "$REMOTE_REPO" branch
  assert_output --partial "test-branch"
  run git -C "$MAIN_REPO" branch -r
  assert_output --partial "origin/test-branch"
}

@test "gwtmux: no args opens worktrees when the parent is reached through a symlink" {
  setup_worktree_structure "myrepo"
  git -C "$MAIN_REPO" worktree add -b feature-1 \
    "$WORKTREE_PARENT/feature-1" main >/dev/null 2>&1

  # Reaching the parent through a symlink keeps $PWD logical while git keeps
  # reporting worktree paths physically.
  ln -s "$WORKTREE_PARENT" "$TEST_TEMP_DIR/link"

  # Deliberately not named after the shell: no-arg mode would kill it, and this
  # test is about the windows it opens.
  local new_window
  new_window=$(tmux new-window -t "$TEST_SESSION" -n "probe" \
    -c "$TEST_TEMP_DIR" -P -F "#{window_id}")

  send_cmd "$new_window" "cd $TEST_TEMP_DIR/link && gwtmux"
  wait_for_window_exists "myrepo/feature-1"
  wait_cmd_done

  run cat "$CMD_MARKER"
  assert_output "0"

  run get_tmux_windows
  assert_output --partial "myrepo/default"
  assert_output --partial "myrepo/feature-1"
}

# Set up a submodule inside the convention repo's default/ worktree. Needs
# "protocol.file.allow": git refuses a file:// submodule by default.
# Sets SUBMODULE_DIR.
setup_submodule() {
  SUB_REMOTE="$TEST_TEMP_DIR/sub-remote.git"
  git init --bare "$SUB_REMOTE" >/dev/null 2>&1
  git -C "$SUB_REMOTE" symbolic-ref HEAD refs/heads/main

  local seed="$TEST_TEMP_DIR/sub-seed"
  git clone "$SUB_REMOTE" "$seed" >/dev/null 2>&1
  git -C "$seed" checkout -b main >/dev/null 2>&1
  echo "sub" >"$seed/sub.txt"
  git -C "$seed" add sub.txt
  git -C "$seed" commit -m "Sub initial" >/dev/null 2>&1
  git -C "$seed" push -u origin main >/dev/null 2>&1

  git -C "$MAIN_REPO" -c protocol.file.allow=always \
    submodule add -q "$SUB_REMOTE" sub >/dev/null 2>&1
  git -C "$MAIN_REPO" commit -m "Add submodule" >/dev/null 2>&1
  SUBMODULE_DIR="$MAIN_REPO/sub"
}

# A submodule's --git-common-dir is "<super>/.git/modules/<name>", so gwtmux's
# "git root = dirname(--git-common-dir)" lands on "<super>/.git/modules" - a
# path git resolves back to the SUPERPROJECT. Every done-mode lookup keyed on it
# therefore aims at the superproject: the -d name resolver listed the
# superproject's worktrees, so this invocation removed "$WORKTREE_PARENT/feature-1"
# and deleted its branch while the user was standing in the submodule. Submodules
# were never part of the design, so done mode refuses inside one.
@test "gwtmux -d: refuses inside a submodule instead of hitting the superproject" {
  setup_worktree_structure "myrepo"
  git -C "$MAIN_REPO" worktree add -b feature-1 \
    "$WORKTREE_PARENT/feature-1" main >/dev/null 2>&1
  setup_submodule
  cd "$SUBMODULE_DIR"

  local before_count="$(get_window_count)"
  run gwtmux -d -wB feature-1
  assert_failure
  assert_output --partial "is inside a submodule"
  assert_output --partial "$MAIN_REPO"

  # The superproject's worktree and branch are both untouched
  assert_dir_exists "$WORKTREE_PARENT/feature-1"
  run git -C "$MAIN_REPO" branch
  assert_output --partial "feature-1"
  assert_equal "$(get_window_count)" "$before_count"
}

# Same guard on the no-name path: there the branch delete runs against the
# submodule but the primary branch to switch to is read from the superproject,
# so the two halves of the operation disagree about which repo they are in.
@test "gwtmux -d: refuses a bare -dB inside a submodule" {
  setup_worktree_structure "myrepo"
  setup_submodule
  cd "$SUBMODULE_DIR"
  git checkout -b sub-feature >/dev/null 2>&1

  run gwtmux -d -B
  assert_failure
  assert_output --partial "is inside a submodule"

  run git -C "$SUBMODULE_DIR" branch --show-current
  assert_output "sub-feature"
}

# ----------------------------------------------------------------------------
# No-arg dispatch: "$PWD/default" has to be a repo ROOT, not just a directory
# inside some repo
# ----------------------------------------------------------------------------

# "git rev-parse --git-dir" succeeds for every directory under a repo, so a repo
# that merely contained a plain subdirectory named "default" was read as a
# convention repo. The convention loop then matched none of its worktrees -
# their parent is the repo's parent, never $PWD - opened no window, and killed
# the reusable shell window anyway, taking the whole session with it.
@test "gwtmux: no args in a flat repo holding a plain default/ subdir opens the repo" {
  setup_flat_repo "j2"
  mkdir -p "$FLAT_REPO/default"
  echo "cfg" >"$FLAT_REPO/default/cfg"
  git -C "$FLAT_REPO" add default/cfg >/dev/null 2>&1
  git -C "$FLAT_REPO" commit -m "add default dir" >/dev/null 2>&1
  git -C "$FLAT_REPO" worktree add "$FLAT_PARENT/j2-work" -b work main >/dev/null 2>&1

  local runner=$(tmux new-window -t "$TEST_SESSION" -n "runner" -c "$TEST_TEMP_DIR" -P -F "#{window_id}")

  send_cmd "$runner" "cd $FLAT_REPO && gwtmux"
  wait_for_window_exists "j2/j2-work"
  wait_cmd_done
  assert_equal "$(cat "$CMD_MARKER")" "0"

  assert tmux_window_exists "j2"
  assert tmux_window_exists "j2/j2-work"
  # The session is still here: nothing was killed after matching nothing
  assert tmux has-session -t "$TEST_SESSION"
}

# Second reachable shape of the same probe: a plain directory holding a non-repo
# "default/", sitting under a git repo. The directory is a subdirectory of that
# repo, so D13 answers it - open the repo it belongs to. What the "default/"
# name used to do instead was send gwtmux down the convention branch, which
# matched nothing, opened nothing, and killed the shell window anyway.
@test "gwtmux: no args in a subdir holding a non-repo default/ opens the repo it belongs to" {
  setup_ancestor_repo
  mkdir -p "$ANCESTOR_REPO/proj/default"
  echo "notarepo" >"$ANCESTOR_REPO/proj/default/file"

  local runner=$(tmux new-window -t "$TEST_SESSION" -n "runner" -c "$TEST_TEMP_DIR" -P -F "#{window_id}")

  send_cmd "$runner" "cd $ANCESTOR_REPO/proj && gwtmux"
  wait_for_window_exists "ancestor/ancestor-wt"
  wait_cmd_done
  assert_equal "$(cat "$CMD_MARKER")" "0"

  assert tmux_window_exists "ancestor"
  assert tmux_window_exists "ancestor/ancestor-wt"
  assert tmux has-session -t "$TEST_SESSION"
}

# Normal mode resolved the repo from the cwd's --git-common-dir before it ever
# considered "$PWD/default", so a branch argument typed in a convention parent
# that sits inside another repo aimed at the ANCESTOR repo. Convention wins,
# the same rule the no-arg dispatch follows.
@test "gwtmux: branch arg from a convention parent under an ancestor repo uses the inner repo" {
  setup_worktree_structure "myrepo"
  setup_ancestor_repo

  mkdir -p "$ANCESTOR_REPO/repos"
  mv "$WORKTREE_PARENT" "$ANCESTOR_REPO/repos/myrepo"
  WORKTREE_PARENT="$ANCESTOR_REPO/repos/myrepo"
  MAIN_REPO="$WORKTREE_PARENT/default"

  send_cmd "$TEST_SESSION" "cd $WORKTREE_PARENT && gwtmux feature-x"
  confirm_branch_creation "$TEST_SESSION"
  wait_cmd_done
  assert_equal "$(cat "$CMD_MARKER")" "0"

  # Created in the repo standing right here, not in the ancestor
  assert_dir_exists "$WORKTREE_PARENT/feature-x"
  refute [ -d "$ANCESTOR_REPO/feature-x" ]
  assert tmux_window_exists "myrepo/feature-x"

  run git -C "$ANCESTOR_REPO" branch
  refute_output --partial "feature-x"
}

