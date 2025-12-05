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

# Get tmux windows for test session
get_tmux_windows() {
  tmux list-windows -t "$TEST_SESSION" -F "#W" 2>/dev/null || true
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
  # Use bats built-in temp directory
  TEST_TEMP_DIR="$BATS_TEST_TMPDIR"

  # Create unique tmux session name for this test
  TEST_SESSION="bats_test_$$_${BATS_TEST_NUMBER}"

  # Setup PATH for stubs
  STUB_DIR="$TEST_TEMP_DIR/stubs"
  mkdir -p "$STUB_DIR"

  # Create a temporary bashrc that sources gwtmux - this ensures gwtmux is available
  # in all new tmux windows, not just the first one
  TEST_BASHRC="$TEST_TEMP_DIR/test_bashrc"
  cat > "$TEST_BASHRC" <<EOF
source "${BATS_TEST_DIRNAME}/../gwtmux.sh"
export PATH="$STUB_DIR:\$PATH"
EOF

  # Create detached tmux session with our custom shell init
  # Use bash -i to ensure it's interactive and reads our rc file
  tmux new-session -d -s "$TEST_SESSION" -c "$TEST_TEMP_DIR" "bash --rcfile '$TEST_BASHRC' -i" 2>/dev/null
  sleep 0.1  # Wait for shell to start

  # Configure new windows to also use our bashrc
  tmux set-option -t "$TEST_SESSION" default-command "bash --rcfile '$TEST_BASHRC' -i"

  # Set TMUX variable so functions think we're in tmux (for direct calls in test process)
  export TMUX="/tmp/tmux-$(id -u)/default,$TEST_SESSION,0"
  export PATH="$STUB_DIR:$PATH"

  # Setup git repos
  setup_git_repos
}

teardown() {
  # Kill test tmux session if it exists
  if tmux has-session -t "$TEST_SESSION" 2>/dev/null; then
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
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

  tmux send-keys -t "$TEST_SESSION" "cd $MAIN_REPO && gwtmux new-feature 2>&1; echo EXIT_CODE:\$?" Enter
  wait_for_dir_exists "$WORKTREE_PARENT/new-feature"

  # Check what happened in tmux
  run tmux capture-pane -t "$TEST_SESSION" -p
  echo "Tmux pane output:"
  echo "$output"

  assert_dir_exists "$WORKTREE_PARENT/new-feature"
  run get_tmux_windows
  assert_output --partial "myrepo/new-feature"
}

@test "gwtmux: creates worktree from existing local branch" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create a local branch
  git checkout -b existing-branch >/dev/null 2>&1
  git checkout main >/dev/null 2>&1

  tmux send-keys -t "$TEST_SESSION" "cd $MAIN_REPO && gwtmux existing-branch" Enter
  wait_for_dir_exists "$WORKTREE_PARENT/existing-branch"

  assert_dir_exists "$WORKTREE_PARENT/existing-branch"
  run get_tmux_windows
  assert_output --partial "myrepo/existing-branch"
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

  tmux send-keys -t "$TEST_SESSION" "cd $MAIN_REPO && gwtmux remote-feature" Enter
  wait_for_dir_exists "$WORKTREE_PARENT/remote-feature"

  assert_dir_exists "$WORKTREE_PARENT/remote-feature"
  run get_tmux_windows
  assert_output --partial "myrepo/remote-feature"
}

@test "gwtmux: handles PR number via gh CLI" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  stub_gh_pr "123" "pr-123-feature"

  tmux send-keys -t "$TEST_SESSION" "cd $MAIN_REPO && gwtmux 123" Enter
  wait_for_dir_exists "$WORKTREE_PARENT/pr-123-feature"

  assert_dir_exists "$WORKTREE_PARENT/pr-123-feature"
  run get_tmux_windows
  assert_output --partial "myrepo/pr-123-feature"
}

@test "gwtmux: falls back to branch name when gh fails" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  stub_gh_fail

  tmux send-keys -t "$TEST_SESSION" "cd $MAIN_REPO && gwtmux not-a-pr" Enter
  wait_for_dir_exists "$WORKTREE_PARENT/not-a-pr"

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
  tmux send-keys -t "$first_window" "cd $MAIN_REPO && gwtmux existing" Enter
  wait_for_window_exists "myrepo/existing"

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
  tmux send-keys -t "$TEST_SESSION" "cd $WORKTREE_PARENT/default && gwtmux ../existing-wt" Enter
  wait_for_window_exists "myrepo/existing-wt"

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
  tmux send-keys -t "$TEST_SESSION" "cd $MAIN_REPO && gwtmux $WORKTREE_PARENT/existing-wt" Enter
  wait_for_window_exists "myrepo/existing-wt"

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
  tmux send-keys -t "$TEST_SESSION" "cd $WORKTREE_PARENT/default && gwtmux ../../otherrepo/feature" Enter
  wait_for_window_exists "otherrepo/feature"

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
  tmux send-keys -t "$TEST_SESSION" "cd $WORKTREE_PARENT/default && gwtmux ../../otherrepo/default" Enter
  wait_until "get_tmux_windows | grep -E 'otherrepo/(master|main)'"

  # Window should have correct repo name "otherrepo" (not "default")
  run get_tmux_windows
  assert_output --regexp "otherrepo/(master|main)"
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
  tmux send-keys -t "$TEST_SESSION" "cd $WORKTREE_PARENT && gwtmux" Enter
  wait_for_window_exists "myrepo/feature-2"

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

  tmux send-keys -t "$TEST_SESSION" "cd $MAIN_REPO && gwtmux feature/with/slashes" Enter
  wait_for_dir_exists "$WORKTREE_PARENT/feature_with_slashes"

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

  local initial_window_count=$(tmux list-windows -t "$TEST_SESSION" | wc -l)

  tmux send-keys -t "$first_window" "cd $MAIN_REPO && gwtmux new-branch" Enter
  wait_for_dir_exists "$WORKTREE_PARENT/new-branch"

  # Window should have been renamed (not created new)
  local final_window_count=$(tmux list-windows -t "$TEST_SESSION" | wc -l)
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

  local initial_window_count=$(tmux list-windows -t "$TEST_SESSION" | wc -l)

  # Get the first pane of the window
  local first_pane=$(tmux list-panes -t "$first_window" -F "#{pane_id}" | head -1)
  tmux send-keys -t "$first_pane" "cd $MAIN_REPO && gwtmux new-branch" Enter
  wait_for_dir_exists "$WORKTREE_PARENT/new-branch"

  # Should have created a new window (not reused)
  local final_window_count=$(tmux list-windows -t "$TEST_SESSION" | wc -l)
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

  local initial_window_count=$(tmux list-windows -t "$TEST_SESSION" | wc -l)

  tmux send-keys -t "$first_window" "cd $MAIN_REPO && gwtmux new-branch" Enter
  wait_for_dir_exists "$WORKTREE_PARENT/new-branch"

  # Should have created a new window
  local final_window_count=$(tmux list-windows -t "$TEST_SESSION" | wc -l)
  assert [ "$final_window_count" -gt "$initial_window_count" ]
}

# ----------------------------------------------------------------------------
# Multiple arguments
# ----------------------------------------------------------------------------

@test "gwtmux: creates multiple worktrees from multiple arguments" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  tmux send-keys -t "$TEST_SESSION" "cd $MAIN_REPO && gwtmux feature-1 feature-2 feature-3" Enter
  wait_for_dir_exists "$WORKTREE_PARENT/feature-3"

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

  tmux send-keys -t "$TEST_SESSION" "cd $MAIN_REPO && gwtmux good-1 conflict good-2" Enter
  wait_for_dir_exists "$WORKTREE_PARENT/good-2"

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

  local window_count_before=$(tmux list-windows -t "$TEST_SESSION" | wc -l)

  # Try to create both plus a new one
  local first_window=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)
  tmux send-keys -t "$first_window" "cd $MAIN_REPO && gwtmux existing-1 existing-2 new-one" Enter
  wait_for_dir_exists "$WORKTREE_PARENT/new-one"

  # Should have one more window (new-one), not duplicates
  local window_count_after=$(tmux list-windows -t "$TEST_SESSION" | wc -l)
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

  local initial_window_count=$(tmux list-windows -t "$TEST_SESSION" | wc -l)

  tmux send-keys -t "$first_window" "cd $MAIN_REPO && gwtmux feat-a feat-b" Enter
  wait_for_dir_exists "$WORKTREE_PARENT/feat-b"

  # Should have 2 windows total (reused one, created one new)
  local final_window_count=$(tmux list-windows -t "$TEST_SESSION" | wc -l)
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
  tmux send-keys -t "$TEST_SESSION" "cd $MAIN_REPO && gwtmux test-branch" Enter
  wait_for_dir_exists "$WORKTREE_PARENT/test-branch"

  # Verify the branch was created
  assert_dir_exists "$WORKTREE_PARENT/test-branch"
}

@test "gwtmux: falls back to main when symbolic-ref not set" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Remove symbolic-ref
  git remote set-head origin -d >/dev/null 2>&1

  # Create new branch (should still find main)
  tmux send-keys -t "$TEST_SESSION" "cd $MAIN_REPO && gwtmux test-branch" Enter
  wait_for_dir_exists "$WORKTREE_PARENT/test-branch"

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

  tmux send-keys -t "$TEST_SESSION" "cd $MAIN_REPO && gwtmux test-branch" Enter
  wait_for_dir_exists "$WORKTREE_PARENT/test-branch"

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

  tmux send-keys -t "$TEST_SESSION" "cd $MAIN_REPO && gwtmux conflict" Enter
  wait_until "tmux capture-pane -t '$TEST_SESSION' -p | grep -q 'failed to create worktree'"

  # Should see error about failed worktree creation
  run tmux capture-pane -t "$TEST_SESSION" -p
  assert_output --partial "failed to create worktree"
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
  tmux new-window -t "$TEST_SESSION" -n "myrepo/old-name" -c "$WORKTREE_PARENT/old-name" 2>/dev/null

  # Rename
  tmux send-keys -t "$TEST_SESSION:1" "cd $WORKTREE_PARENT/old-name && gwtmux --rename new-name" Enter
  wait_for_dir_exists "$WORKTREE_PARENT/new-name"

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
  tmux new-window -t "$TEST_SESSION" -n "myrepo/old-name" -c "$WORKTREE_PARENT/old-name" 2>/dev/null

  # Rename
  tmux send-keys -t "$TEST_SESSION:1" "cd $WORKTREE_PARENT/old-name && gwtmux --rename new-name" Enter
  wait_for_dir_exists "$WORKTREE_PARENT/new-name"

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

  tmux new-window -t "$TEST_SESSION" -n "myrepo/old-name" -c "$WORKTREE_PARENT/old-name" 2>/dev/null

  tmux send-keys -t "$TEST_SESSION:1" "cd $WORKTREE_PARENT/old-name && gwtmux --rename feature/new-name" Enter
  wait_for_dir_exists "$WORKTREE_PARENT/feature_new-name"

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

@test "gwtmux --rename: errors when commit author doesn't match current user" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add -b test-wt "$WORKTREE_PARENT/test-wt" main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"

  # Configure different user
  git config user.name "Other User"
  git config user.email "other@example.com"

  # Make commit
  echo "test" >test.txt
  git add test.txt
  git commit -m "Test" >/dev/null 2>&1

  # Change user back
  git config user.email "test@example.com"

  run gwtmux --rename new-name
  assert_failure
  assert_output --partial "not authored by you"
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

  tmux new-window -t "$TEST_SESSION" -n "myrepo/test-branch" -c "$WORKTREE_PARENT/test-wt" 2>/dev/null
  local window_count_before=$(tmux list-windows -t "$TEST_SESSION" | wc -l)

  tmux send-keys -t "$TEST_SESSION:1" "cd $WORKTREE_PARENT/test-wt && gwtmux -d" Enter
  wait_for_window_closed "myrepo/test-branch"

  # Worktree should still exist
  assert [ -d "$WORKTREE_PARENT/test-wt" ]

  # Branch should still exist
  run git -C "$MAIN_REPO" branch
  assert_output --partial "test-branch"

  # Window should be killed
  local window_count_after=$(tmux list-windows -t "$TEST_SESSION" 2>/dev/null | wc -l)
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

  tmux send-keys -t "$new_window" "cd $WORKTREE_PARENT/test-wt && gwtmux -d -wb" Enter
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"

  # Both worktree and branch should be removed
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

  tmux new-window -t "$TEST_SESSION" -n "myrepo/test-branch" -c "$WORKTREE_PARENT/test-wt" 2>/dev/null

  tmux send-keys -t "$TEST_SESSION:1" "cd $WORKTREE_PARENT/test-wt && gwtmux -d -wB" Enter
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"

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

  tmux send-keys -t "$new_window" "cd $WORKTREE_PARENT/test-wt && gwtmux -d -wbr" Enter
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"

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

  tmux new-window -t "$TEST_SESSION" -n "myrepo/test-branch" -c "$WORKTREE_PARENT/test-wt" 2>/dev/null

  tmux send-keys -t "$TEST_SESSION:1" "cd $WORKTREE_PARENT/test-wt && gwtmux -d -wBr" Enter
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"

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
  tmux send-keys -t "$new_window" "cd $WORKTREE_PARENT/test-wt && gwtmux -d -rbw" Enter
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"

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
  tmux send-keys -t "$new_window" "cd $WORKTREE_PARENT/test-wt && gwtmux -d -wbr" Enter
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"

  # Should complete without error
  refute [ -d "$WORKTREE_PARENT/test-wt" ]
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

  tmux send-keys -t "$new_window" "cd $WORKTREE_PARENT/test-wt && gwtmux -d -wb" Enter
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"

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

  tmux send-keys -t "$new_window" "cd $WORKTREE_PARENT/test-wt && gwtmux -d -wb" Enter
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"

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

@test "gwtmux -d: works in main repo without destructive flags" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  # Create a second window so we have multiple
  tmux new-window -t "$TEST_SESSION" -n "test-window" -c "$MAIN_REPO" 2>/dev/null
  local window_count_before=$(tmux list-windows -t "$TEST_SESSION" | wc -l)
  assert [ "$window_count_before" -gt 1 ]

  # Get the second window ID and run gwtmux -d from it
  local second_window=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | tail -1)
  tmux send-keys -t "$second_window" "cd $MAIN_REPO && gwtmux -d" Enter
  wait_for_window_closed "test-window"

  # Window should be killed (since we have multiple windows)
  local window_count_after=$(tmux list-windows -t "$TEST_SESSION" 2>/dev/null | wc -l)
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

  tmux new-window -t "$TEST_SESSION" -n "myrepo/test-branch" -c "$WORKTREE_PARENT/test-wt" 2>/dev/null

  tmux send-keys -t "$TEST_SESSION:1" "cd $WORKTREE_PARENT/test-wt && gwtmux -d -w" Enter
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"

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
  local window_count_before=$(tmux list-windows -t "$TEST_SESSION" | wc -l)
  assert [ "$window_count_before" -eq 1 ]

  # Get the actual window ID and expected shell name
  local window_id=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)
  local expected_shell=$(basename "${SHELL:-zsh}")

  tmux send-keys -t "$window_id" "cd $WORKTREE_PARENT/test-wt && gwtmux -d" Enter
  wait_until "[ \"\$(tmux display-message -t '$window_id' -p '#W')\" = '$expected_shell' ]"

  # Window should still exist
  local window_count_after=$(tmux list-windows -t "$TEST_SESSION" | wc -l)
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
  local window_count=$(tmux list-windows -t "$TEST_SESSION" | wc -l)
  assert [ "$window_count" -eq 1 ]

  # Get the actual window ID
  local window_id=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_id}" | head -1)

  # Execute gwtmux -d and capture PWD after
  tmux send-keys -t "$window_id" "cd $WORKTREE_PARENT/test-wt && gwtmux -d && pwd > /tmp/gwtmux_done_pwd_$$" Enter
  wait_until "[ -f /tmp/gwtmux_done_pwd_$$ ]"

  # Verify we're in the parent directory
  run cat "/tmp/gwtmux_done_pwd_$$"
  assert_output "$WORKTREE_PARENT"
  rm -f "/tmp/gwtmux_done_pwd_$$"
}

@test "gwtmux -d: kills window when multiple windows exist" {
  setup_worktree_structure "myrepo"
  cd "$MAIN_REPO"

  git worktree add "$WORKTREE_PARENT/test-wt" -b test-branch main >/dev/null 2>&1
  cd "$WORKTREE_PARENT/test-wt"
  git config user.name "Test User"
  git config user.email "test@example.com"

  # Create a second window so we have multiple
  tmux new-window -t "$TEST_SESSION" -n "myrepo/test-branch" -c "$WORKTREE_PARENT/test-wt" 2>/dev/null
  local window_count_before=$(tmux list-windows -t "$TEST_SESSION" | wc -l)
  assert [ "$window_count_before" -gt 1 ]

  tmux send-keys -t "$TEST_SESSION:1" "cd $WORKTREE_PARENT/test-wt && gwtmux -d" Enter
  wait_for_window_closed "myrepo/test-branch"

  # Window should be killed
  local window_count_after=$(tmux list-windows -t "$TEST_SESSION" 2>/dev/null | wc -l)
  assert [ "$window_count_after" -lt "$window_count_before" ]
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
  tmux send-keys -t "$window_id" "cd $MAIN_REPO && gwtmux -d wt-a wt-b" Enter

  # Windows should be closed (wait for async command)
  wait_for_window_closed "myrepo/wt-a"
  wait_for_window_closed "myrepo/wt-b"
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
  tmux send-keys -t "$new_window" "cd $WORKTREE_PARENT/test-wt && gwtmux -dwb" Enter

  # Should delete current worktree (wait for async tmux command)
  wait_for_dir_deleted "$WORKTREE_PARENT/test-wt"
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
