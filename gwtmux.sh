# gwtmux - Git worktree + tmux integration
# https://github.com/snapwich/gwtmux
#
# Create git worktrees from branches or PR numbers in new tmux windows.
# Manage worktree lifecycle with cleanup and rename operations.

# Dependency check helper
_gwtmux_check_deps() {
  local missing=()
  command -v git >/dev/null 2>&1 || missing+=("git")
  command -v tmux >/dev/null 2>&1 || missing+=("tmux")

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "gwtmux: missing required dependencies: ${missing[*]}" >&2
    echo "Install with: brew install ${missing[*]}" >&2
    return 1
  fi
}

# create a git worktree from branch or pr number in new tmux window
# with -d flag: clean up git worktree (delete worktree/branches, kill/rename tmux window)
# with --rename flag: rename worktree dir, branch, remote tracking branch, and tmux window
gwtmux() {
  # Check dependencies
  _gwtmux_check_deps || return 1

  # Help flag
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cat <<'EOF'
gwtmux - Git worktree + tmux integration

Create git worktrees from branches or PR numbers in new tmux windows.
Manage worktree lifecycle with cleanup and rename operations.

USAGE:
  gwtmux [<branch_or_pr>...]       Create worktree(s) and open in tmux window(s)
  gwtmux -d [flags] [worktree...]  Clean up worktree(s), branches, and tmux windows
  gwtmux --rename <new_name>       Rename current worktree, branch, and tmux window
  gwtmux -h, --help                Show this help message

NORMAL MODE:
  gwtmux <branch>          Create worktree for branch, open in new tmux window
  gwtmux <pr_number>       Create worktree for PR's branch (uses gh cli)
  gwtmux <path>            Open existing worktree path in new tmux window
  gwtmux branch1 branch2   Create multiple worktrees at once
  gwtmux                   (From parent dir) Open windows for all existing worktrees

  If window already exists for the branch, it will be selected instead.
  Branch names with slashes are converted to underscores for directory names.

DONE MODE (-d):
  gwtmux -d                Delete current worktree's tmux window only
  gwtmux -d -w             Also delete the worktree directory
  gwtmux -d -b             Also delete local branch (safe - must be merged)
  gwtmux -d -B             Also delete local branch (force - even if unmerged)
  gwtmux -d -r             Also delete remote branch (requires -b or -B)
  gwtmux -d -wbr           Combine flags: worktree + branch + remote
  gwtmux -d -wBr name...   Delete specific worktree(s) by name

  Flags can be combined: -dwbr, -dBrw, etc.
  If current window is last in session, renames to shell name instead of killing.

RENAME MODE (--rename):
  gwtmux --rename <name>   Rename worktree dir, branch, remote branch, and window

  Only works from within a worktree (not main repo).
  Validates that latest commit is authored by you before renaming remote.

EXAMPLES:
  gwtmux feature/auth      Create worktree for feature/auth branch
  gwtmux 123               Create worktree for PR #123
  gwtmux -dwbr             Clean up current worktree completely
  gwtmux -dw feat1 feat2   Delete worktrees for feat1 and feat2
  gwtmux --rename new-name Rename current branch to new-name

REQUIREMENTS:
  - git, tmux (required)
  - gh (optional, for PR number support)
  - Must be run inside tmux session

For more info: https://github.com/snapwich/gwtmux
EOF
    return 0
  fi

  # Detect mode based on flags
  local mode="normal"
  if [[ "$1" == "--rename" ]]; then
    mode="rename"
    shift
  elif [[ "$1" == -* ]] && [[ "$1" =~ d ]]; then
    mode="done"
  fi

  case "$mode" in
  done)
    # ========================================================================
    # DONE MODE: clean up git worktree
    # Usage: gwtmux -d [-w] [-b|-B] [-r] [worktree_name...]
    #   -d  Done mode (required)
    #   -w  Delete worktree
    #   -b  Safe delete local branch (only if merged)
    #   -B  Force delete local branch (even if unmerged)
    #   -r  Also delete remote branch (requires -b or -B)
    #   worktree_name  Optional worktree name(s) to delete (default: current)
    # ========================================================================

    # Parse flags and collect worktree names
    local delete_worktree=0
    local delete_local=0 # 0=no delete, 1=safe delete (-b), 2=force delete (-B)
    local delete_remote=0
    local -a worktree_names=()

    while [[ $# -gt 0 ]]; do
      case "$1" in
      -*)
        # Handle combined flags like -dwbr or -dBrw
        local flags="${1#-}"
        local i
        for ((i = 0; i < ${#flags}; i++)); do
          case "${flags:$i:1}" in
          d)
            # Skip 'd' flag as it's just the mode indicator
            ;;
          w)
            delete_worktree=1
            ;;
          b)
            if [[ $delete_local -eq 0 ]]; then
              delete_local=1
            fi
            ;;
          B)
            delete_local=2
            ;;
          r)
            delete_remote=1
            ;;
          *)
            echo >&2 "Error: unknown option '-${flags:$i:1}'"
            return 1
            ;;
          esac
        done
        shift
        ;;
      *)
        # Non-flag argument - treat as worktree name
        worktree_names+=("$1")
        shift
        ;;
      esac
    done

    # Find git root for all operations
    local git_common_dir
    if ! git_common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"; then
      # Not in a git repo - but if worktree names were provided, try to find git root from them
      if [[ ${#worktree_names[@]} -gt 0 ]]; then
        # Try to find git common dir from the first specified worktree
        # Use array index that works in both bash (0-indexed) and zsh (1-indexed)
        local first_wt_name="${worktree_names[*]:0:1}"
        [[ -z "$first_wt_name" ]] && first_wt_name="${worktree_names[1]}"
        local first_dir_name="${first_wt_name//\//_}"
        local first_wt_path="$PWD/$first_dir_name"
        if [[ -d "$first_wt_path" ]]; then
          git_common_dir="$(git -C "$first_wt_path" rev-parse --git-common-dir 2>/dev/null)"
          if [[ -n "$git_common_dir" && "$git_common_dir" != /* ]]; then
            git_common_dir="$first_wt_path/$git_common_dir"
          fi
        fi
      fi
      if [[ -z "$git_common_dir" ]]; then
        echo >&2 "Error: not in a git repository"
        return 1
      fi
    else
      # Convert to absolute path
      if [[ "$git_common_dir" != /* ]]; then
        git_common_dir="$PWD/$git_common_dir"
      fi
    fi

    # If no worktree names provided, use current worktree (backward compatibility)
    if [[ ${#worktree_names[@]} -eq 0 ]]; then
      # Original single-worktree behavior
      local branch="$(git branch --show-current)"
      local worktree_root="$(git rev-parse --show-toplevel)"

      # Check if we're in a worktree only when doing destructive operations
      if [[ $delete_worktree -eq 1 || $delete_local -gt 0 ]]; then
        local git_dir="$(git rev-parse --git-dir)"
        # Convert to absolute path for comparison
        if [[ "$git_dir" != /* ]]; then
          git_dir="$PWD/$git_dir"
        fi
        if [[ "$git_dir" == "$git_common_dir" ]]; then
          echo >&2 "Error: in main repo, not a worktree. Refusing to delete."
          return 1
        fi
      fi

      # Pre-flight checks: validate branch deletion before making any destructive changes
      if [[ -n "$branch" && $delete_local -eq 1 ]]; then
        # Safe delete - check if merged BEFORE removing worktree
        local default_branch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
        if [[ -z "$default_branch" ]]; then
          if git show-ref --verify --quiet refs/remotes/origin/main; then
            default_branch="main"
          elif git show-ref --verify --quiet refs/remotes/origin/master; then
            default_branch="master"
          else
            default_branch="main" # ultimate fallback
          fi
        fi

        if ! git branch --merged "$default_branch" | grep -Eq "^[* ] +$branch\$"; then
          echo >&2 "Error: branch '$branch' is not merged into '$default_branch'. Use -B to force delete."
          return 1
        fi
      fi

      # Remove worktree if requested
      if [[ $delete_worktree -eq 1 ]]; then
        local original_dir="$PWD"
        cd "$(dirname "$git_common_dir")"
        git worktree remove "$worktree_root" || {
          local rc=$?
          cd "$original_dir"
          return $rc
        }
      fi

      # Delete local branch if requested
      if [[ -n "$branch" && $delete_local -gt 0 ]]; then
        if [[ $delete_local -eq 1 ]]; then
          # Safe delete (already validated above)
          git branch -d "$branch" || return $?
        else
          # Force delete
          git branch -D "$branch" || return $?
        fi

        # Delete remote branch if requested
        if [[ $delete_remote -eq 1 ]]; then
          if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
            git push origin --delete "$branch" || {
              echo >&2 "Warning: failed to delete remote branch 'origin/$branch'"
            }
          fi
        fi
      fi

      # Smart window handling: rename if last window, otherwise kill
      if [[ -n "$TMUX" ]]; then
        local window_count=$(tmux list-windows | wc -l)
        if [[ $window_count -eq 1 ]]; then
          # Last window: navigate to parent and rename to shell name
          cd ..
          local shell_name=$(basename "${SHELL:-zsh}")
          tmux rename-window "$shell_name"
        else
          # Not last window: kill as usual
          tmux kill-window
        fi
      fi
    else
      # Multi-worktree mode: two-phase validation
      # Parent dir is the directory containing the main repo
      # e.g., if git_common_dir is /path/myrepo/default/.git, parent is /path/myrepo
      local git_root="$(dirname "$git_common_dir")"
      local parent_dir="$(dirname "$git_root")"
      local repo_name="$(basename "$parent_dir")"

      # Arrays to store validated data
      local -a worktree_paths=()
      local -a branch_names=()
      local -a window_names=()

      # Determine default branch for merge checking
      local default_branch="$(git -C "$git_root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
      if [[ -z "$default_branch" ]]; then
        if git -C "$git_root" show-ref --verify --quiet refs/remotes/origin/main; then
          default_branch="main"
        elif git -C "$git_root" show-ref --verify --quiet refs/remotes/origin/master; then
          default_branch="master"
        else
          default_branch="main" # ultimate fallback
        fi
      fi

      # ====================================================================
      # PHASE 1: VALIDATION - All must pass or abort entire operation
      # ====================================================================
      for wt_name in "${worktree_names[@]}"; do
        # Convert slashes to underscores (same as normal mode)
        local dir_name="${wt_name//\//_}"
        local wt_path="$parent_dir/$dir_name"

        # Check if worktree exists
        if ! git -C "$git_root" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}' | grep -Fxq "$wt_path"; then
          echo >&2 "Error: worktree '$wt_name' (path: $wt_path) does not exist"
          return 1
        fi

        # Get branch name for this worktree
        local wt_branch="$(git -C "$wt_path" branch --show-current 2>/dev/null)"

        # Check if we're trying to delete main repo
        if [[ $delete_worktree -eq 1 || $delete_local -gt 0 ]]; then
          local wt_git_dir="$(git -C "$wt_path" rev-parse --git-dir 2>/dev/null)"
          if [[ "$wt_git_dir" == "$git_common_dir" ]]; then
            echo >&2 "Error: worktree '$wt_name' is the main repo. Refusing to delete."
            return 1
          fi
        fi

        # Pre-flight check: validate branch merge status if safe delete requested
        if [[ -n "$wt_branch" && $delete_local -eq 1 ]]; then
          if ! git -C "$git_root" branch --merged "$default_branch" | grep -Eq "^[* ] +$wt_branch\$"; then
            echo >&2 "Error: branch '$wt_branch' (worktree '$wt_name') is not merged into '$default_branch'. Use -B to force delete."
            return 1
          fi
        fi

        # Store validated data
        worktree_paths+=("$wt_path")
        branch_names+=("$wt_branch")
        # Use branch name for window name to match normal mode behavior
        # (in normal mode, window name is based on branch which equals the argument)
        window_names+=("$repo_name/$wt_branch")
      done

      # ====================================================================
      # PHASE 2: EXECUTION - All validations passed, proceed with deletions
      # ====================================================================
      # Process each worktree (bash uses 0-indexed arrays, zsh uses 1-indexed)
      local start_idx=0
      [[ -n "${ZSH_VERSION:-}" ]] && start_idx=1

      # Get current window name to defer killing it until the end
      # (killing the current window terminates the shell running this script)
      local current_window_name=""
      local deferred_kill_window=""
      if [[ -n "$TMUX" ]]; then
        current_window_name="$(tmux display-message -p '#W')"
      fi

      local idx=$start_idx
      local end_idx=$((start_idx + ${#worktree_paths[@]}))
      while [[ $idx -lt $end_idx ]]; do
        local wt_path="${worktree_paths[$idx]}"
        local branch="${branch_names[$idx]}"
        local window_name="${window_names[$idx]}"

        # Remove worktree if requested
        if [[ $delete_worktree -eq 1 ]]; then
          local original_dir="$PWD"
          cd "$parent_dir"
          git -C "$git_root" worktree remove "$wt_path" || {
            echo >&2 "Warning: failed to remove worktree at '$wt_path'"
          }
          # Return to original directory if it still exists (i.e., we didn't delete our own worktree)
          if [[ -d "$original_dir" ]]; then
            cd "$original_dir"
          fi
        fi

        # Delete local branch if requested
        if [[ -n "$branch" && $delete_local -gt 0 ]]; then
          if [[ $delete_local -eq 1 ]]; then
            # Safe delete (already validated above)
            git -C "$git_root" branch -d "$branch" || {
              echo >&2 "Warning: failed to delete branch '$branch'"
            }
          else
            # Force delete
            git -C "$git_root" branch -D "$branch" || {
              echo >&2 "Warning: failed to force delete branch '$branch'"
            }
          fi

          # Delete remote branch if requested
          if [[ $delete_remote -eq 1 ]]; then
            if git -C "$git_root" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
              git -C "$git_root" push origin --delete "$branch" || {
                echo >&2 "Warning: failed to delete remote branch 'origin/$branch'"
              }
            fi
          fi
        fi

        # Close tmux window for this worktree (defer if it's the current window)
        if [[ -n "$TMUX" ]]; then
          if [[ "$window_name" == "$current_window_name" ]]; then
            # Defer killing the current window until all other deletions are complete
            deferred_kill_window="$window_name"
          else
            # Get the actual session name using tmux
            local tmux_session="$(tmux display-message -p '#S')"

            # Get window index by exact name match
            local window_index="$(tmux list-windows -t "$tmux_session" -F "#{window_index} #W" 2>/dev/null |
              awk -v name="$window_name" '{
                  win_name = substr($0, index($0, " ") + 1);
                  if (win_name == name) {print $1; exit}
                }')"

            if [[ -n "$window_index" ]]; then
              tmux kill-window -t "$tmux_session:$window_index" 2>/dev/null || true
            fi
          fi
        fi

        idx=$((idx + 1))
      done

      # Kill the current window last (if it was one of the worktrees we deleted)
      if [[ -n "$deferred_kill_window" && -n "$TMUX" ]]; then
        local tmux_session="$(tmux display-message -p '#S')"
        local window_count="$(tmux list-windows -t "$tmux_session" | wc -l)"
        if [[ $window_count -eq 1 ]]; then
          # Last window: navigate to parent and rename to shell name
          local shell_name=$(basename "${SHELL:-zsh}")
          tmux rename-window "$shell_name"
        else
          # Not last window: kill as usual
          tmux kill-window
        fi
      fi
    fi
    ;;

  rename)
    # ========================================================================
    # RENAME MODE: rename worktree dir, branch, remote tracking branch, tmux window
    # Usage: gwtmux --rename <new_name>
    # ========================================================================

    if [[ -z "$TMUX" ]]; then
      echo >&2 "Error: not in tmux"
      return 1
    fi

    if [[ -z "$1" ]]; then
      echo >&2 "Error: new name required"
      return 1
    fi

    local -r new_name="$1"
    local git_dir git_common_dir
    if ! git_dir="$(git rev-parse --git-dir 2>/dev/null)"; then
      echo >&2 "Error: not in a git repo"
      return 1
    fi

    git_common_dir="$(git rev-parse --git-common-dir)"
    if [[ "$git_dir" == "$git_common_dir" ]]; then
      echo >&2 "Error: in main repo, not a worktree. Refusing to rename."
      return 1
    fi

    local current_branch="$(git branch --show-current)"
    if [[ -z "$current_branch" ]]; then
      echo >&2 "Error: not on a branch"
      return 1
    fi

    # Check latest commit author matches current user to prevent renaming remote branch that is not yours
    local commit_author="$(git log -1 --format='%ae')"
    local current_user="$(git config user.email)"
    if [[ "$commit_author" != "$current_user" ]]; then
      echo >&2 "Error: latest commit not authored by you ($commit_author vs $current_user)"
      return 1
    fi

    local worktree_root="$(git rev-parse --show-toplevel)"
    local parent_dir="$(dirname "$worktree_root")"
    local repo_name="$(basename "$parent_dir")"

    # Convert slashes to underscores like gwtmux does
    local dir_new_name="${new_name//\//_}"
    local new_path="$parent_dir/$dir_new_name"

    if [[ -e "$new_path" ]]; then
      echo >&2 "Error: $new_path already exists"
      return 1
    fi

    # Check if has remote tracking
    local has_remote=0
    if git rev-parse --abbrev-ref --symbolic-full-name @{u} &>/dev/null; then
      has_remote=1
    fi

    # Rename directory
    git worktree move "$worktree_root" "$new_path" || return $?

    # cd into new directory
    cd "$new_path" || return $?

    # Rename branch
    git branch -m "$current_branch" "$new_name" || return $?

    # Update remote if exists
    if [[ $has_remote -eq 1 ]]; then
      if ! git push origin "$new_name"; then
        echo >&2 "Error: failed to push new branch. Reverting local changes..."
        git branch -m "$new_name" "$current_branch"
        git worktree move "$new_path" "$worktree_root"
        cd "$worktree_root"
        return 1
      fi
      git push origin --delete "$current_branch" || return $?
      git branch -u "origin/$new_name" || return $?
    fi

    # Update tmux window
    tmux rename-window "$repo_name/$new_name"
    ;;

  normal)
    # ========================================================================
    # NORMAL MODE: create a git worktree from branch or pr number in new tmux window
    # Usage: gwtmux [<branch_or_pr>...]
    # ========================================================================

    local -r git_cmd="git"
    if [[ -z "$TMUX" ]]; then
      echo >&2 "Error: not in tmux"
      return 1
    fi

    # Capture shell window to potentially reuse or kill (before any commands run)
    local current_window="$(tmux display-message -p '#W')"
    local current_window_id="$(tmux display-message -p '#{window_id}')"
    local pane_count="$(tmux display-message -p '#{window_panes}')"
    local shell_name=$(basename "${SHELL:-zsh}")
    local can_reuse_window=0
    if [[ "$current_window" == "$shell_name" && "$pane_count" == "1" ]]; then
      can_reuse_window=1
    fi

    if [[ $# -eq 0 ]]; then
      # Multi-worktree mode - only works from ../default
      if [[ ! -d "default/.git" ]]; then
        echo >&2 "Error: branch or PR number required"
        return 1
      fi

      $git_cmd -C "$PWD/default" fetch --prune --no-recurse-submodules --quiet
      local repo_name="$(basename "$PWD")"

      while IFS= read -r worktree_path; do
        # Only process worktrees in current directory
        if [[ "$(dirname -- "$worktree_path")" == "$PWD" ]]; then
          local window_name
          if [[ "$worktree_path" == "$PWD/default" ]]; then
            window_name="$repo_name/default"
          else
            local branch_name="$($git_cmd -C "$worktree_path" branch --show-current 2>/dev/null)"
            window_name="$repo_name/$branch_name"
          fi
          if [[ -n "$window_name" ]]; then
            # Check if window already exists
            if ! tmux list-windows -F "#W" | grep -Fxq -- "$window_name"; then
              tmux new-window -n "$window_name" -c "$worktree_path"
            fi
          fi
        fi
      done < <($git_cmd -C "$PWD/default" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}')

      # Kill original zsh window if it was single pane
      if [[ $can_reuse_window -eq 1 ]]; then
        tmux kill-window -t "$current_window_id"
      fi
      return 0
    fi

    # Find git root once for all arguments
    local git_common_dir git_root
    if $git_cmd rev-parse --git-dir &>/dev/null; then
      git_common_dir="$($git_cmd rev-parse --git-common-dir)"
      if [[ "$git_common_dir" == .git ]]; then
        git_root="$PWD"
      elif [[ "$git_common_dir" == /* ]]; then
        git_root="$(dirname -- "$git_common_dir")"
      else
        git_root="$PWD/$(dirname -- "$git_common_dir")"
      fi
    elif [[ -d "default/.git" ]]; then
      git_root="$PWD/default"
    else
      echo >&2 "Error: not in a git repo or parent of default/.git"
      return 1
    fi

    # Fetch once before processing all arguments
    $git_cmd -C "$git_root" fetch -a

    local repo_name="$(basename "$(dirname -- "$git_root")")"
    local default_branch
    default_branch="$(
      $git_cmd -C "$git_root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null |
        sed 's|^origin/||'
    )"
    if [[ -z "$default_branch" ]]; then
      if $git_cmd -C "$git_root" show-ref --verify --quiet refs/remotes/origin/main; then
        default_branch="main"
      elif $git_cmd -C "$git_root" show-ref --verify --quiet refs/remotes/origin/master; then
        default_branch="master"
      else
        default_branch="main" # ultimate fallback
      fi
    fi

    # Track if any worktree succeeded (for window reuse logic)
    local success_count=0

    # Declare loop variables outside the loop to avoid re-declaration issues
    local branch window_name dir_branch worktree_path worktree_exists has_local has_remote rc

    # Process each argument
    for arg in "$@"; do
      # Check if argument is a path to an existing worktree (can be any repo)
      local path_matched=0
      local path_repo_name=""
      if [[ "$arg" == /* || "$arg" == .* || "$arg" == */* ]]; then
        if [[ -d "$arg" ]]; then
          local resolved_path
          resolved_path="$(cd "$arg" 2>/dev/null && pwd -P)"
          if [[ -n "$resolved_path" ]] && $git_cmd -C "$resolved_path" rev-parse --git-dir &>/dev/null; then
            # It's a git directory - extract branch and repo info
            branch="$($git_cmd -C "$resolved_path" branch --show-current 2>/dev/null)"
            if [[ -n "$branch" ]]; then
              # Get repo name from this path's git structure
              local path_git_common_dir
              path_git_common_dir="$($git_cmd -C "$resolved_path" rev-parse --git-common-dir 2>/dev/null)"
              if [[ -n "$path_git_common_dir" ]]; then
                local path_git_root
                if [[ "$path_git_common_dir" == /* ]]; then
                  # Absolute path (worktree case)
                  path_git_root="$(dirname "$path_git_common_dir")"
                elif [[ "$path_git_common_dir" == ".git" ]]; then
                  # Main repo case - .git is in resolved_path
                  path_git_root="$resolved_path"
                else
                  # Relative path to .git
                  path_git_root="$(cd "$resolved_path/$(dirname "$path_git_common_dir")" && pwd -P)"
                fi
                path_repo_name="$(basename "$(dirname "$path_git_root")")"
              fi
              worktree_path="$resolved_path"
              worktree_exists=1
              path_matched=1
            fi
          fi
        fi
      fi

      # If not a path, resolve branch name (try gh pr first, fall back to arg)
      if [[ $path_matched -eq 0 ]]; then
        branch="$(
          (cd "$git_root" 2>/dev/null && GH_PAGER= gh pr view "$arg" --json headRefName --jq '.headRefName') 2>/dev/null
        )"
        [[ -z "$branch" ]] && branch="$arg"
      fi

      # Use path's repo name if available, otherwise current repo
      if [[ -n "$path_repo_name" ]]; then
        window_name="$path_repo_name/$branch"
      else
        window_name="$repo_name/$branch"
      fi

      # If window already exists, just select it
      if tmux list-windows -F "#W" | grep -Fxq -- "$window_name"; then
        tmux select-window -t "$window_name"
        success_count=$((success_count + 1))
        continue
      fi

      # Only compute worktree path if we didn't already match a path
      if [[ $path_matched -eq 0 ]]; then
        dir_branch="${branch//\//_}"
        worktree_path="$(dirname -- "$git_root")/$dir_branch"
        worktree_exists=0
        if $git_cmd -C "$git_root" worktree list --porcelain |
          awk '/^worktree /{print substr($0,10)}' |
          grep -Fxq -- "$worktree_path"; then
          worktree_exists=1
        fi
      fi

      # Create worktree if it doesn't exist
      if [[ $worktree_exists -eq 0 ]]; then
        $git_cmd -C "$git_root" show-ref --verify --quiet "refs/heads/$branch"
        has_local=$?
        $git_cmd -C "$git_root" show-ref --verify --quiet "refs/remotes/origin/$branch"
        has_remote=$?

        rc=0
        if [[ $has_local -eq 0 ]]; then
          $git_cmd -C "$git_root" worktree add --quiet -- "$worktree_path" "$branch" || rc=$?
        elif [[ $has_remote -eq 0 ]]; then
          $git_cmd -C "$git_root" worktree add --quiet -b "$branch" -- "$worktree_path" "origin/$branch" || rc=$?
        else
          $git_cmd -C "$git_root" worktree add --quiet -b "$branch" -- "$worktree_path" "$default_branch" || rc=$?
        fi
        if [[ $rc -ne 0 ]]; then
          echo >&2 "Warning: failed to create worktree for '$branch', skipping"
          continue
        fi
      fi

      # Create or reuse window
      if [[ $success_count -eq 0 && $can_reuse_window -eq 1 ]]; then
        tmux rename-window "$window_name"
        cd "$worktree_path"
      else
        tmux new-window -n "$window_name" -c "$worktree_path"
      fi

      success_count=$((success_count + 1))
    done

    # Kill original zsh window only if we succeeded with at least one worktree
    # and we didn't reuse it (reuse happens when success_count > 0 and can_reuse_window was 1)
    if [[ $success_count -gt 0 && $can_reuse_window -eq 1 ]]; then
      # Window was already reused, don't kill it
      :
    elif [[ $success_count -gt 0 && $can_reuse_window -eq 0 ]]; then
      # Created new windows but didn't reuse, nothing to do
      :
    fi
    ;;
  esac
}
