# gwtmux - Git worktree + tmux integration
# https://github.com/snapwich/gwtmux
#
# Create git worktrees from branches or PR numbers in new tmux windows.
# Manage worktree lifecycle with cleanup and rename operations.

# display-message pinned to the invoking pane. Without -t, tmux resolves
# formats against the *active* pane, so if the user switches windows while a
# command runs, bare calls report the wrong window. TMUX_PANE is set by tmux
# in each pane's environment and is immune to focus changes.
_gwtmux_display() {
  if [[ -n "${TMUX_PANE:-}" ]]; then
    tmux display-message -p -t "$TMUX_PANE" "$1"
  else
    tmux display-message -p "$1"
  fi
}

# Resolve an exact window name to its window id within a session.
# Window ids (@N) are stable; names and indexes can change mid-operation.
_gwtmux_window_id_by_name() {
  tmux list-windows -t "$1" -F "#{window_id} #{window_name}" 2>/dev/null |
    awk -v name="$2" '{
      win_name = substr($0, index($0, " ") + 1)
      if (win_name == name) { print $1; exit }
    }'
}

# Resolve a git dir query (--git-dir or --git-common-dir) to an absolute,
# normalized path. Git prints these relative to the working directory when run
# inside the main repo (".git" at the top, "../../.git" two levels down), so
# callers that apply dirname to the raw value walk *into* the repo instead of up
# out of it, and callers that compare the two values see a false mismatch.
# Args: <flag> [dir] (dir defaults to $PWD)
_gwtmux_git_dir_path() {
  local flag="$1" cwd="${2:-$PWD}" dir
  dir="$(git -C "$cwd" rev-parse "$flag" 2>/dev/null)" || return 1
  [[ -z "$dir" ]] && return 1
  (cd "$cwd" && cd "$dir" && pwd -P) 2>/dev/null
}

# Resolve the root of the worktree that contains a directory, absolute and
# normalized. Fails (prints nothing) when the directory is not inside a
# worktree. Callers compare the result against the directory itself to tell a
# worktree root from a subdirectory of one.
# Args: <dir>
_gwtmux_worktree_root() {
  local dir="$1" top
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ -z "$top" ]] && return 1
  (cd "$top" && pwd -P) 2>/dev/null
}

# Tell a flat repo from one that follows the directory convention. A convention
# repo lives at "<parent>/default" with its worktrees as siblings; any other
# repo root is flat, and gwtmux only ever opens windows for it. Purely a name
# test: no probing, no marker file, and a repo literally named "default" is
# read as a convention repo.
# Args: <git_root>
_gwtmux_is_flat() {
  [[ "$(basename -- "$1")" != "default" ]]
}

# Tell whether a directory is the root of a main git repo, rather than merely
# some directory that lies inside one. "git rev-parse --git-dir" answers yes for
# every directory under a repo, so probing "<dir>/default" with it called any
# repo that happens to contain a subdirectory named "default" a convention repo.
# A worktree root is not a main repo root either: --git-common-dir points at the
# main repo, which is what the convention layout means by "<parent>/default".
# Args: <dir>
_gwtmux_is_repo_root() {
  local dir="$1" common_dir resolved
  [[ -d "$dir" ]] || return 1
  common_dir="$(_gwtmux_git_dir_path --git-common-dir "$dir")" || return 1
  resolved="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  [[ -n "$resolved" ]] || return 1
  [[ "$(dirname -- "$common_dir")" == "$resolved" ]]
}

# Decide whether a normal-mode argument names a path instead of a branch, by
# the same rule the argument loop applies: explicitly path-shaped ("/...",
# "./...", "../...", "." or "..") or the root of an existing worktree. A name
# that merely contains a slash, like "feature/auth", stays a branch name.
# Args: <arg>
_gwtmux_arg_is_path() {
  local arg="$1" resolved
  case "$arg" in
  /* | ./* | ../* | . | ..) return 0 ;;
  esac
  [[ -d "$arg" ]] || return 1
  resolved="$(cd "$arg" 2>/dev/null && pwd -P)" || return 1
  [[ -n "$resolved" ]] || return 1
  [[ "$(_gwtmux_worktree_root "$resolved" 2>/dev/null)" == "$resolved" ]]
}

# Compute the tmux window name for a worktree. Single source of truth: every
# naming site routes through here so one worktree always maps to one name.
# Args: <worktree_path> [git_root] [branch]
#   git_root defaults to the main repo root resolved from <worktree_path>
#   branch   defaults to <worktree_path>'s current branch
# Callers that name a worktree before creating it must pass both optional args,
# since neither can be read from a path that does not exist yet.
_gwtmux_window_name() {
  local wt_path="$1" git_root="${2:-}" branch="${3:-}"
  local git_common_dir parent_name resolved_path

  if [[ -z "$git_root" ]]; then
    git_common_dir="$(_gwtmux_git_dir_path --git-common-dir "$wt_path")" || return 1
    git_root="$(dirname -- "$git_common_dir")"
  fi

  resolved_path="$(cd "$wt_path" 2>/dev/null && pwd -P)"
  [[ -z "$resolved_path" ]] && resolved_path="$wt_path"

  # Flat repo: the repo directory names its own window, and its worktrees hang
  # off that name by directory basename. Nothing here is branch-based, so an
  # in-place "git switch" never moves a window out from under the user.
  if _gwtmux_is_flat "$git_root"; then
    if [[ "$resolved_path" == "$git_root" ]]; then
      echo "$(basename -- "$git_root")"
    else
      echo "$(basename -- "$git_root")/$(basename -- "$resolved_path")"
    fi
    return 0
  fi

  parent_name="$(basename -- "$(dirname -- "$git_root")")"

  # The main repo root is named after its own directory ("<parent>/default"),
  # not after whatever branch happens to be checked out there.
  if [[ "$resolved_path" == "$git_root" ]]; then
    echo "$parent_name/$(basename -- "$git_root")"
    return 0
  fi

  [[ -z "$branch" ]] && branch="$(git -C "$wt_path" branch --show-current 2>/dev/null)"
  # Detached HEAD: there is no branch to name the window after, so use the
  # directory basename instead of a trailing-slash name like "myrepo/".
  [[ -z "$branch" ]] && branch="$(basename -- "$resolved_path")"

  echo "$parent_name/$branch"
}

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

# List a repo's worktrees as "<path><TAB><branch>" lines, with an empty branch
# for a detached HEAD. One pass over --porcelain, so a caller that needs both
# fields does not run a second git command per worktree.
# Args: <git_root>
_gwtmux_worktree_list() {
  git -C "$1" worktree list --porcelain 2>/dev/null | awk '
    /^worktree /{
      if (wt != "") print wt "\t" br
      wt = substr($0, 10)
      br = ""
      next
    }
    /^branch refs\/heads\//{ br = substr($0, 19) }
    END { if (wt != "") print wt "\t" br }
  '
}

# Resolve a done-mode <name> argument to the path of one of a repo's worktrees.
# Tiers are tried in order and the first one with any match wins:
#   1. path     - <name> is path-shaped and resolves to a listed worktree
#   2. basename - worktree dir basename equals <name>, or its
#                 slashes-to-underscores form (the name normal mode gave the dir)
#   3. branch   - worktree's current branch equals <name>
# Two matches inside one tier are ambiguous. Picking one would delete the wrong
# worktree, so the candidates are listed and the caller aborts. The check is
# lazy: only the name actually asked for can be ambiguous, duplicate basenames
# elsewhere in the repo are nobody's business.
# Args: <git_root> <name> [base_dir]  (base_dir resolves relative names, $PWD)
# Prints the worktree path. Returns 1 when nothing matched (the caller reports
# that, it knows the context) and 2 when the name was ambiguous (reported here).
_gwtmux_resolve_worktree() {
  local git_root="$1" name="$2" base_dir="${3:-$PWD}"
  local dir_name="${name//\//_}"
  local target="" wt_path wt_branch wt_base
  local -a tier_path=() tier_base=() tier_branch=() candidates=()

  case "$name" in
  /* | ./* | ../*)
    target="$(cd "$base_dir" 2>/dev/null && cd "$name" 2>/dev/null && pwd -P)"
    ;;
  esac

  while IFS=$'\t' read -r wt_path wt_branch; do
    [[ -z "$wt_path" ]] && continue
    wt_base="${wt_path##*/}"
    # Each worktree counts for its own highest tier only, so a worktree matched
    # by path is not also a basename candidate.
    if [[ -n "$target" && "$wt_path" == "$target" ]]; then
      tier_path+=("$wt_path")
    elif [[ "$wt_base" == "$name" || "$wt_base" == "$dir_name" ]]; then
      tier_base+=("$wt_path")
    elif [[ -n "$wt_branch" && "$wt_branch" == "$name" ]]; then
      tier_branch+=("$wt_path")
    fi
  done < <(_gwtmux_worktree_list "$git_root")

  if [[ ${#tier_path[@]} -gt 0 ]]; then
    candidates=("${tier_path[@]}")
  elif [[ ${#tier_base[@]} -gt 0 ]]; then
    candidates=("${tier_base[@]}")
  elif [[ ${#tier_branch[@]} -gt 0 ]]; then
    candidates=("${tier_branch[@]}")
  else
    return 1
  fi

  if [[ ${#candidates[@]} -gt 1 ]]; then
    echo >&2 "Error: worktree '$name' is ambiguous - candidates:"
    for wt_path in "${candidates[@]}"; do
      echo >&2 "  - $wt_path"
    done
    echo >&2 "Pass a path to pick one."
    return 2
  fi

  # Printed via [@] expansion: the one element, without an index that would
  # differ between bash and zsh.
  printf '%s\n' "${candidates[@]}"
}

# Refuse a worktree whose computed window name another worktree of the same repo
# already claims. Two worktrees on one name means the window opened or killed
# for the second is really the first one's. What collides is the NAME, not the
# directory basename: a convention worktree is named "<parent>/<branch>" and a
# flat repo root just "<repo>", so two worktrees can share a directory basename
# and still be provably distinct windows - refusing those was a false positive.
# Lazy like the resolver: only the worktree asked for is checked.
# Args: <worktree_path> [git_root] [window_name]
#   git_root and window_name are resolved from <worktree_path> when omitted;
#   pass them when the caller has already computed them.
_gwtmux_check_unique_window_name() {
  local wt_path="$1" git_root="${2:-}" window_name="${3:-}"
  local git_common_dir resolved_path other_path other_branch
  local -a dupes=()

  if [[ -z "$git_root" ]]; then
    git_common_dir="$(_gwtmux_git_dir_path --git-common-dir "$wt_path")" || return 0
    git_root="$(dirname -- "$git_common_dir")"
  fi
  [[ -z "$window_name" ]] && window_name="$(_gwtmux_window_name "$wt_path" "$git_root")"
  [[ -z "$window_name" ]] && return 0

  # git lists worktrees physically; compare like for like or the worktree being
  # checked counts as a duplicate of itself.
  resolved_path="$(cd "$wt_path" 2>/dev/null && pwd -P)"
  [[ -z "$resolved_path" ]] && resolved_path="$wt_path"

  while IFS=$'\t' read -r other_path other_branch; do
    [[ -z "$other_path" || "$other_path" == "$resolved_path" ]] && continue
    if [[ "$(_gwtmux_window_name "$other_path" "$git_root" "$other_branch")" == "$window_name" ]]; then
      dupes+=("$other_path")
    fi
  done < <(_gwtmux_worktree_list "$git_root")

  [[ ${#dupes[@]} -eq 0 ]] && return 0

  echo >&2 "Error: window name '$window_name' is not unique in '$git_root' - these worktrees collide:"
  echo >&2 "  - $resolved_path"
  for other_path in "${dupes[@]}"; do
    echo >&2 "  - $other_path"
  done
  return 1
}

# Resolve the branch to switch to before deleting the branch that a main repo
# root has checked out. Starts from the same cascade the merge check uses
# (origin/HEAD, then origin/main, origin/master, then literal "main"), then
# gates the answer on a local branch of that name existing: a merge check can
# tolerate a fictional "main", a checkout cannot.
# Args: <git_root>
_gwtmux_primary_branch() {
  local git_root="$1" primary

  primary="$(git -C "$git_root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  if [[ -z "$primary" ]]; then
    if git -C "$git_root" show-ref --verify --quiet refs/remotes/origin/main; then
      primary="main"
    elif git -C "$git_root" show-ref --verify --quiet refs/remotes/origin/master; then
      primary="master"
    else
      primary="main" # ultimate fallback
    fi
  fi

  if ! git -C "$git_root" show-ref --verify --quiet "refs/heads/$primary"; then
    if git -C "$git_root" show-ref --verify --quiet refs/heads/main; then
      primary="main"
    elif git -C "$git_root" show-ref --verify --quiet refs/heads/master; then
      primary="master"
    else
      echo >&2 "Error: cannot determine primary branch to switch to (no local main or master)."
      return 1
    fi
  fi

  echo "$primary"
}

# Refuse to switch away from a branch while the working tree has work in it:
# the switch would carry the changes onto the primary branch. Untracked files
# are exempt, they belong to no branch and survive the switch unchanged.
# --ignore-submodules=dirty so a submodule with local work of its own does not
# block the parent repo.
# Args: <worktree_path>
_gwtmux_check_clean_tree() {
  local wt_path="$1"

  if git -C "$wt_path" diff --quiet --ignore-submodules=dirty &&
    git -C "$wt_path" diff --cached --quiet --ignore-submodules=dirty; then
    return 0
  fi

  echo >&2 "Error: uncommitted changes — commit, stash, or discard before gwtmux -d<b|B>."
  return 1
}

# Refuse to act inside a submodule. gwtmux derives the repo root as the parent
# of --git-common-dir, which for a submodule is "<super>/.git/modules" — not a
# repo root at all. Git resolves that path back to the SUPERPROJECT, so every
# lookup keyed on it (the -d name resolver above all) silently targets the
# superproject's worktrees and branches instead of anything the user can see.
# Submodules were never part of the design, so refuse rather than guess.
# Args: [dir] (defaults to $PWD)
_gwtmux_refuse_submodule() {
  local dir="${1:-$PWD}" super
  super="$(git -C "$dir" rev-parse --show-superproject-working-tree 2>/dev/null)" || return 0
  [[ -z "$super" ]] && return 0
  echo >&2 "Error: '$dir' is inside a submodule of '$super' — gwtmux does not support submodules."
  return 1
}

# Find worktrees nested under a given worktree path
# Sets caller's _nested_worktrees array
_gwtmux_find_nested_worktrees() {
  local git_root="$1"
  local parent_path="$2"
  _nested_worktrees=()

  local wt_path
  while IFS= read -r wt_path; do
    if [[ "$wt_path" == "$parent_path"/* ]]; then
      _nested_worktrees+=("$wt_path")
    fi
  done < <(git -C "$git_root" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}')
}

# Remove nested worktrees and optionally their branches
# Args: git_root delete_local delete_remote nested_paths...
_gwtmux_remove_nested_worktrees() {
  local git_root="$1"
  local delete_local="$2"
  local delete_remote="$3"
  shift 3

  local nwt_path nwt_branch force_flag
  for nwt_path in "$@"; do
    nwt_branch="$(git -C "$nwt_path" branch --show-current 2>/dev/null)"

    force_flag=""
    [[ $delete_local -eq 2 ]] && force_flag="--force"
    git -C "$git_root" worktree remove $force_flag "$nwt_path" || {
      echo >&2 "Error: failed to remove nested worktree '$nwt_path'"
      return 1
    }

    if [[ -n "$nwt_branch" && $delete_local -gt 0 ]]; then
      if [[ $delete_local -eq 1 ]]; then
        git -C "$git_root" branch -d "$nwt_branch" 2>/dev/null || true
      else
        git -C "$git_root" branch -D "$nwt_branch" 2>/dev/null || true
      fi
      if [[ $delete_remote -eq 1 ]]; then
        if git -C "$git_root" show-ref --verify --quiet "refs/remotes/origin/$nwt_branch"; then
          git -C "$git_root" push origin --delete "$nwt_branch" 2>/dev/null || true
        fi
      fi
    fi
  done
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
  gwtmux <path>            Open existing worktree root in new tmux window
  gwtmux <repo>/<branch>   Create branch in repo at <repo>/default
  gwtmux branch1 branch2   Create multiple worktrees at once
  gwtmux                   Open windows for all existing worktrees
                           (from the repo parent dir, or inside a flat repo)

  If window already exists for the branch, it will be selected instead.
  Branch names with slashes are converted to underscores for directory names.
  A path argument must be the root of a worktree; a subdirectory is an error.
  An argument counts as a path only when it is path-shaped ("/...", "./...",
  "../...", "." or "..") or when it is a worktree root, so a branch name that
  contains a slash is still a branch name.

FLAT REPOS:
  A repo whose root directory does not have the name "default" is a flat repo:
  a plain clone with no <parent>/default layout. gwtmux only opens windows
  there - it creates no worktrees and it does not fetch.

                            convention              flat
  gwtmux <branch> | <pr>    yes                     error
  gwtmux <path>             yes                     yes, opens window
  gwtmux (no args)          from parent dir         from inside repo
  -d                        yes                     yes
  -dw on repo root          error                   error
  -db, -dB on repo root     yes (switch to primary) yes (switch to primary)
  -dwB <name>               yes, any worktree       yes, any worktree
  --rename in worktree      yes                     yes
  --rename at repo root     error                   error

  Windows are named <parent>/<branch> in a convention repo, and <repo> or
  <repo>/<dir name> in a flat repo. Two worktrees of one repo cannot share a
  directory name, because their windows would have the same name.

DONE MODE (-d):
  gwtmux -d                Delete current worktree's tmux window only
  gwtmux -d -w             Also delete the worktree directory
  gwtmux -d -b             Also delete local branch (safe - must be merged)
  gwtmux -d -B             Also delete local branch (force - even if unmerged)
  gwtmux -d -r             Also delete remote branch (requires -b or -B)
  gwtmux -d -wbr           Combine flags: worktree + branch + remote
  gwtmux -d -wBr name...   Delete specific worktree(s) by name

  Flags can be combined: -dwbr, -dBrw, etc.
  A <name> is matched against the repo's worktrees by path, then directory
  name, then branch, and can reach any worktree of the repo. An ambiguous
  name is an error and nothing is deleted.
  In the main repo root, -w is an error, but -b and -B switch to the primary
  branch (main or master) before they delete. That needs a tree with no
  uncommitted changes, and a branch that is not the primary branch itself.
  Bare -d deletes nothing, thus it switches nothing.
  If current window is last in session, renames to shell name instead of killing.

RENAME MODE (--rename):
  gwtmux --rename <name>   Unify worktree dir, branch, remote branch, and window to <name>

  Only works from within a worktree (not main repo).
  Steps that already match <name> are skipped, so it is safe to use when
  the dir, branch, and remote branch names do not agree.
  Remote branch is only touched via the configured upstream; deleting the
  old remote branch requires the latest commit to be authored by you.

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

  # Pin tmux context to the invoking pane up front. All later tmux operations
  # target these ids so the command behaves the same whether or not the user
  # switches or rearranges windows while it runs.
  local gwt_window="" gwt_session=""
  if [[ -n "$TMUX" ]]; then
    gwt_window="$(_gwtmux_display '#{window_id}' 2>/dev/null)"
    gwt_session="$(_gwtmux_display '#{session_id}' 2>/dev/null)"
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

    # Declared outside the loop: zsh echoes a re-declared local that carries no
    # assignment, so a second flag argument would print "i=1" to stdout.
    local flags="" i=0

    while [[ $# -gt 0 ]]; do
      case "$1" in
      -*)
        # Handle combined flags like -dwbr or -dBrw
        flags="${1#-}"
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
    # The directory whose repo every later lookup keys on; the submodule guard
    # below checks this one, not always $PWD.
    local done_probe_dir="$PWD"
    if ! git_common_dir="$(_gwtmux_git_dir_path --git-common-dir)"; then
      # Not in a git repo - but if worktree names were provided, try to find git root from them
      if [[ ${#worktree_names[@]} -gt 0 ]]; then
        # Try to find git common dir from the first specified worktree. The name
        # may be a path ("/...", "./...", "../...") or the basename of a
        # worktree directory here; either way the directory's .git file points
        # back at the repo.
        # Use array index that works in both bash (0-indexed) and zsh (1-indexed)
        local first_wt_name="${worktree_names[*]:0:1}"
        [[ -z "$first_wt_name" ]] && first_wt_name="${worktree_names[1]}"
        local first_wt_path
        case "$first_wt_name" in
        /*) first_wt_path="$first_wt_name" ;;
        ./* | ../*) first_wt_path="$PWD/$first_wt_name" ;;
        *)
          first_wt_path="$PWD/${first_wt_name//\//_}"
          [[ -d "$first_wt_path" ]] || first_wt_path="$PWD/$first_wt_name"
          ;;
        esac
        if [[ -d "$first_wt_path" ]]; then
          git_common_dir="$(_gwtmux_git_dir_path --git-common-dir "$first_wt_path")"
          done_probe_dir="$first_wt_path"
        fi
      fi
      if [[ -z "$git_common_dir" ]]; then
        echo >&2 "Error: not in a git repository"
        return 1
      fi
    fi

    # Nothing in done mode can be trusted inside a submodule: the resolver would
    # aim at the superproject. Refuse before any validation or deletion runs.
    _gwtmux_refuse_submodule "$done_probe_dir" || return 1

    # If no worktree names provided, use current worktree (backward compatibility)
    if [[ ${#worktree_names[@]} -eq 0 ]]; then
      # Original single-worktree behavior
      local branch="$(git branch --show-current)"
      local worktree_root="$(git rev-parse --show-toplevel)"

      # The main repo root has no worktree to remove, so -w is still an error
      # there, but -b/-B are not: the branch can go once the checkout steps off
      # it. Keyed off the repo itself (--git-dir == --git-common-dir), not off
      # the directory layout.
      local git_dir="$(_gwtmux_git_dir_path --git-dir)"
      local in_main_repo=0 switch_branch=""
      [[ "$git_dir" == "$git_common_dir" ]] && in_main_repo=1

      if [[ $in_main_repo -eq 1 && $delete_worktree -eq 1 ]]; then
        echo >&2 "Error: in main repo, not a worktree. Refusing to delete."
        return 1
      fi

      # Validate the switch before anything destructive runs: on a failure the
      # branch and the checkout are both left exactly as they were.
      if [[ $in_main_repo -eq 1 && -n "$branch" && $delete_local -gt 0 ]]; then
        switch_branch="$(_gwtmux_primary_branch "$(dirname "$git_common_dir")")" || return 1
        if [[ "$branch" == "$switch_branch" ]]; then
          echo >&2 "Error: '$branch' is the primary branch. Refusing to delete."
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

        # --format, not the default listing: git marks a branch checked out in
        # ANOTHER worktree with "+", which "^[* ]" never matched, and an
        # interpolated branch name is a regex there ("-Fxq" takes it literally).
        if ! git branch --merged "$default_branch" --format='%(refname:short)' |
          grep -Fxq -- "$branch"; then
          echo >&2 "Error: branch '$branch' is not merged into '$default_branch'. Use -B to force delete."
          return 1
        fi
      fi

      # Last validation before the switch: the tree it moves has to be clean.
      if [[ -n "$switch_branch" ]]; then
        _gwtmux_check_clean_tree "$worktree_root" || return 1
      fi

      # Check for nested worktrees when deleting worktree directory
      local -a _nested_worktrees=()
      if [[ $delete_worktree -eq 1 ]]; then
        _gwtmux_find_nested_worktrees "$(dirname "$git_common_dir")" "$worktree_root"
        if [[ ${#_nested_worktrees[@]} -gt 0 ]]; then
          echo "Worktree '$(basename "$worktree_root")' has nested worktrees:"
          for nwt in "${_nested_worktrees[@]}"; do
            echo "  - $nwt"
          done
          printf "Remove nested worktrees? No cancels the entire operation. [y/N] "
          local confirm_nested
          read -r confirm_nested </dev/tty
          if [[ "$confirm_nested" != "y" && "$confirm_nested" != "Y" ]]; then
            return 1
          fi
        fi
      fi

      # Remove worktree if requested
      if [[ $delete_worktree -eq 1 ]]; then
        local original_dir="$PWD"
        cd "$(dirname "$git_common_dir")"
        # Remove nested worktrees before parent
        if [[ ${#_nested_worktrees[@]} -gt 0 ]]; then
          _gwtmux_remove_nested_worktrees "$(dirname "$git_common_dir")" "$delete_local" "$delete_remote" "${_nested_worktrees[@]}" || {
            local rc=$?
            cd "$original_dir"
            return $rc
          }
        fi
        git worktree remove "$worktree_root" || {
          local rc=$?
          cd "$original_dir"
          return $rc
        }
      fi

      # Delete local branch if requested
      if [[ -n "$branch" && $delete_local -gt 0 ]]; then
        # The main repo root still has this branch checked out, so step off it
        # first. Validated above: the tree is clean and this is not the primary.
        if [[ -n "$switch_branch" ]]; then
          git switch "$switch_branch" || return $?
        fi

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
      if [[ -n "$TMUX" && -n "$gwt_window" ]]; then
        local window_count=$(tmux list-windows -t "$gwt_session" | wc -l)
        if [[ $window_count -eq 1 ]]; then
          # Last window: rename to shell name instead of killing the session.
          # The main repo root is never deleted, so its cwd is still valid and
          # moving out of it would be gratuitous.
          [[ $in_main_repo -eq 0 ]] && cd ..
          local shell_name=$(basename "${SHELL:-zsh}")
          tmux rename-window -t "$gwt_window" "$shell_name"
        else
          # Not last window: kill as usual
          tmux kill-window -t "$gwt_window"
        fi
      fi
    else
      # Multi-worktree mode: two-phase validation
      # Parent dir is the directory containing the main repo
      # e.g., if git_common_dir is /path/myrepo/default/.git, parent is /path/myrepo
      local git_root="$(dirname "$git_common_dir")"
      local parent_dir="$(dirname "$git_root")"

      # Arrays to store validated data
      local -a worktree_paths=()
      local -a branch_names=()
      local -a window_names=()
      # Empty unless this target is the main repo root, where the branch can
      # only be deleted after the checkout steps off it (see below).
      local -a switch_branches=()

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
        # Resolve the name against the repo's own worktree list (path, then dir
        # basename, then branch). Replaces the old guess of "sibling of the repo
        # root named after the branch", which could only ever find worktrees
        # laid out that way.
        local wt_path="" resolve_rc=0
        wt_path="$(_gwtmux_resolve_worktree "$git_root" "$wt_name")" || resolve_rc=$?
        if [[ $resolve_rc -ne 0 ]]; then
          # rc 2 is an ambiguous name, already reported with its candidates
          [[ $resolve_rc -eq 1 ]] && echo >&2 "Error: worktree '$wt_name' does not exist"
          return 1
        fi

        # Get branch name for this worktree
        local wt_branch="$(git -C "$wt_path" branch --show-current 2>/dev/null)"

        # The main repo root is not a worktree anyone can remove, so -w is an
        # error on it, but -b/-B are not: the branch can go once the checkout
        # steps off it. Keyed off the repo itself (--git-dir == --git-common-dir),
        # not off the directory layout.
        local wt_git_dir="$(_gwtmux_git_dir_path --git-dir "$wt_path")"
        local wt_switch_branch=""
        if [[ "$wt_git_dir" == "$git_common_dir" ]]; then
          if [[ $delete_worktree -eq 1 ]]; then
            echo >&2 "Error: worktree '$wt_name' is the main repo. Refusing to delete."
            return 1
          fi
          if [[ -n "$wt_branch" && $delete_local -gt 0 ]]; then
            wt_switch_branch="$(_gwtmux_primary_branch "$git_root")" || return 1
            if [[ "$wt_branch" == "$wt_switch_branch" ]]; then
              echo >&2 "Error: '$wt_branch' is the primary branch. Refusing to delete."
              return 1
            fi
          fi
        fi

        # Pre-flight check: validate branch merge status if safe delete requested
        if [[ -n "$wt_branch" && $delete_local -eq 1 ]]; then
          # See the single-target check above: "+" for a branch checked out in
          # another worktree is exactly this path's normal case.
          if ! git -C "$git_root" branch --merged "$default_branch" --format='%(refname:short)' |
            grep -Fxq -- "$wt_branch"; then
            echo >&2 "Error: branch '$wt_branch' (worktree '$wt_name') is not merged into '$default_branch'. Use -B to force delete."
            return 1
          fi
        fi

        # Last validation before the switch: the tree it moves has to be clean.
        if [[ -n "$wt_switch_branch" ]]; then
          _gwtmux_check_clean_tree "$wt_path" || return 1
        fi

        # Same name normal mode gave the window when it opened this worktree.
        # The window to close is found by that name, so a second worktree
        # mapping to it would have ITS window killed instead - refuse here, in
        # phase 1, before anything destructive runs.
        local wt_window_name="$(_gwtmux_window_name "$wt_path" "$git_root" "$wt_branch")"
        _gwtmux_check_unique_window_name "$wt_path" "$git_root" "$wt_window_name" || return 1

        # Store validated data
        worktree_paths+=("$wt_path")
        branch_names+=("$wt_branch")
        switch_branches+=("$wt_switch_branch")
        window_names+=("$wt_window_name")
      done

      # Check for nested worktrees across all parents
      local -a _all_nested_worktrees=()
      if [[ $delete_worktree -eq 1 ]]; then
        local -a _nested_worktrees=()
        for wt_path in "${worktree_paths[@]}"; do
          _gwtmux_find_nested_worktrees "$git_root" "$wt_path"
          [[ ${#_nested_worktrees[@]} -gt 0 ]] && _all_nested_worktrees+=("${_nested_worktrees[@]}")
        done
        if [[ ${#_all_nested_worktrees[@]} -gt 0 ]]; then
          echo "Nested worktrees found that will also be removed:"
          for nwt in "${_all_nested_worktrees[@]}"; do
            echo "  - $nwt"
          done
          printf "Remove nested worktrees? No cancels the entire operation. [y/N] "
          local confirm_nested
          read -r confirm_nested </dev/tty
          if [[ "$confirm_nested" != "y" && "$confirm_nested" != "Y" ]]; then
            return 1
          fi
        fi
      fi

      # ====================================================================
      # PHASE 2: EXECUTION - All validations passed, proceed with deletions
      # ====================================================================
      # Process each worktree (bash uses 0-indexed arrays, zsh uses 1-indexed)
      local start_idx=0
      [[ -n "${ZSH_VERSION:-}" ]] && start_idx=1

      # Defer killing our own window until the end
      # (killing the current window terminates the shell running this script)
      local deferred_kill=0

      local idx=$start_idx
      local end_idx=$((start_idx + ${#worktree_paths[@]}))
      while [[ $idx -lt $end_idx ]]; do
        local wt_path="${worktree_paths[$idx]}"
        local branch="${branch_names[$idx]}"
        local window_name="${window_names[$idx]}"
        local switch_branch="${switch_branches[$idx]}"

        # Remove worktree if requested
        if [[ $delete_worktree -eq 1 ]]; then
          local original_dir="$PWD"
          cd "$parent_dir"
          # Remove nested worktrees before parent
          local -a _nested_worktrees=()
          _gwtmux_find_nested_worktrees "$git_root" "$wt_path"
          if [[ ${#_nested_worktrees[@]} -gt 0 ]]; then
            _gwtmux_remove_nested_worktrees "$git_root" "$delete_local" "$delete_remote" "${_nested_worktrees[@]}" || {
              echo >&2 "Error: failed to remove nested worktrees for '$wt_path'"
              cd "$original_dir" 2>/dev/null || true
              return 1
            }
          fi
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
          # The main repo root still has this branch checked out, so step off it
          # first. Validated above: clean tree, and not the primary branch.
          if [[ -n "$switch_branch" ]]; then
            git -C "$wt_path" switch "$switch_branch" || {
              echo >&2 "Error: failed to switch '$wt_path' to '$switch_branch'"
              return 1
            }
          fi

          local local_deleted=1
          if [[ $delete_local -eq 1 ]]; then
            # Safe delete (already validated above)
            git -C "$git_root" branch -d "$branch" || {
              local_deleted=0
              echo >&2 "Warning: failed to delete branch '$branch'"
            }
          else
            # Force delete
            git -C "$git_root" branch -D "$branch" || {
              local_deleted=0
              echo >&2 "Warning: failed to force delete branch '$branch'"
            }
          fi

          # Delete remote branch if requested. Only after the local delete
          # actually succeeded: the branch still exists here, so dropping the
          # remote would leave nothing to restore it from. The single-target
          # path above already aborts on the same failure.
          if [[ $delete_remote -eq 1 && $local_deleted -eq 1 ]]; then
            if git -C "$git_root" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
              git -C "$git_root" push origin --delete "$branch" || {
                echo >&2 "Warning: failed to delete remote branch 'origin/$branch'"
              }
            fi
          fi
        fi

        # Close tmux window for this worktree (defer if it's our own window)
        if [[ -n "$TMUX" ]]; then
          local target_window_id="$(_gwtmux_window_id_by_name "$gwt_session" "$window_name")"
          if [[ -n "$target_window_id" ]]; then
            if [[ "$target_window_id" == "$gwt_window" ]]; then
              # Defer killing our own window until all other deletions are complete
              deferred_kill=1
            else
              tmux kill-window -t "$target_window_id" 2>/dev/null || true
            fi
          fi
        fi

        idx=$((idx + 1))
      done

      # Kill our own window last (if it was one of the worktrees we deleted)
      if [[ $deferred_kill -eq 1 && -n "$TMUX" && -n "$gwt_window" ]]; then
        local window_count="$(tmux list-windows -t "$gwt_session" | wc -l)"
        if [[ $window_count -eq 1 ]]; then
          # Last window: navigate to parent and rename to shell name
          local shell_name=$(basename "${SHELL:-zsh}")
          tmux rename-window -t "$gwt_window" "$shell_name"
        else
          # Not last window: kill as usual
          tmux kill-window -t "$gwt_window"
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
    if ! git_dir="$(_gwtmux_git_dir_path --git-dir)"; then
      echo >&2 "Error: not in a git repo"
      return 1
    fi

    git_common_dir="$(_gwtmux_git_dir_path --git-common-dir)"
    if [[ "$git_dir" == "$git_common_dir" ]]; then
      echo >&2 "Error: in main repo, not a worktree. Refusing to rename."
      return 1
    fi

    local current_branch="$(git branch --show-current)"
    if [[ -z "$current_branch" ]]; then
      echo >&2 "Error: not on a branch"
      return 1
    fi

    local worktree_root="$(git rev-parse --show-toplevel)"
    local parent_dir="$(dirname "$worktree_root")"

    # Convert slashes to underscores like gwtmux does
    local dir_new_name="${new_name//\//_}"
    local new_path="$parent_dir/$dir_new_name"

    if [[ "$new_path" != "$worktree_root" && -e "$new_path" ]]; then
      echo >&2 "Error: $new_path already exists"
      return 1
    fi

    # Resolve the configured upstream. Remote "." is a local tracking branch,
    # so no remote operations apply.
    local upstream_remote="$(git config "branch.$current_branch.remote")"
    local upstream_merge="$(git config "branch.$current_branch.merge")"
    local upstream_branch="${upstream_merge#refs/heads/}"
    local has_remote=0
    if [[ -n "$upstream_remote" && "$upstream_remote" != "." && -n "$upstream_branch" ]]; then
      has_remote=1
    fi

    # Remote operations only happen when the upstream branch name differs
    # from the target. Deleting the old remote branch is destructive, so
    # require the latest commit to be yours before touching the remote.
    local update_remote=0
    if [[ $has_remote -eq 1 && "$upstream_branch" != "$new_name" ]]; then
      update_remote=1
      local commit_author="$(git log -1 --format='%ae')"
      local current_user="$(git config user.email)"
      if [[ "$commit_author" != "$current_user" ]]; then
        echo >&2 "Error: latest commit not authored by you ($commit_author vs $current_user)"
        return 1
      fi
    fi

    # Rename directory
    local moved_dir=0
    if [[ "$new_path" != "$worktree_root" ]]; then
      git worktree move "$worktree_root" "$new_path" || return $?
      moved_dir=1
    fi

    # cd into new directory
    cd "$new_path" || return $?

    # Rename branch
    local renamed_branch=0
    if [[ "$new_name" != "$current_branch" ]]; then
      git branch -m "$current_branch" "$new_name" || return $?
      renamed_branch=1
    fi

    if [[ $update_remote -eq 1 ]]; then
      if ! git push "$upstream_remote" "$new_name"; then
        echo >&2 "Error: failed to push new branch. Reverting local changes..."
        [[ $renamed_branch -eq 1 ]] && git branch -m "$new_name" "$current_branch"
        if [[ $moved_dir -eq 1 ]]; then
          git worktree move "$new_path" "$worktree_root"
          cd "$worktree_root"
        fi
        return 1
      fi
      git push "$upstream_remote" --delete "$upstream_branch" ||
        echo >&2 "Warning: could not delete $upstream_remote/$upstream_branch (may already be deleted)"
      git branch -u "$upstream_remote/$new_name" || return $?
    fi

    # Update tmux window
    tmux rename-window -t "$gwt_window" "$(_gwtmux_window_name "$new_path" "" "$new_name")"
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
    local current_window="$(_gwtmux_display '#W')"
    local current_window_id="$gwt_window"
    local pane_count="$(_gwtmux_display '#{window_panes}')"
    local shell_name=$(basename "${SHELL:-zsh}")
    local can_reuse_window=0
    if [[ "$current_window" == "$shell_name" && "$pane_count" == "1" ]]; then
      can_reuse_window=1
    fi

    if [[ $# -eq 0 ]]; then
      # Convention mode is decided first, on "$PWD/default is a repo ROOT".
      # Testing flat-ness first would key the dispatch on whatever repo the
      # current directory belongs to - including an ANCESTOR repo (a dotfiles
      # repo at ~, a monorepo above ~/repos) - and open that repo's worktrees
      # instead of the convention repo standing right here. The root test is
      # what makes it a convention repo: "rev-parse --git-dir" also succeeds for
      # a plain subdirectory named "default", which sent any repo carrying one
      # down a convention branch that matched none of its worktrees.
      if ! _gwtmux_is_repo_root "$PWD/default"; then
        # Flat repo: open a window for the repo itself plus one per worktree,
        # wherever those live. Keyed on the repo the current directory belongs
        # to, so a subdirectory of it or one of its worktrees works too. No
        # fetch - flat mode creates nothing and resolves no branch from a
        # remote.
        local noarg_common_dir="" noarg_root=""
        if noarg_common_dir="$(_gwtmux_git_dir_path --git-common-dir)" &&
          noarg_root="$(dirname -- "$noarg_common_dir")" &&
          _gwtmux_is_flat "$noarg_root"; then
          # Declared before the loop: zsh echoes a re-declared local that
          # carries no assignment.
          local flat_wt_path="" flat_wt_branch="" flat_window_name=""
          local flat_matched=0
          while IFS=$'\t' read -r flat_wt_path flat_wt_branch; do
            [[ -z "$flat_wt_path" ]] && continue
            flat_window_name="$(_gwtmux_window_name "$flat_wt_path" "$noarg_root" "$flat_wt_branch")"
            [[ -z "$flat_window_name" ]] && continue
            flat_matched=$((flat_matched + 1))
            if [[ -z "$(_gwtmux_window_id_by_name "$gwt_session" "$flat_window_name")" ]]; then
              tmux new-window -t "$gwt_session" -n "$flat_window_name" -c "$flat_wt_path"
            fi
          done < <(_gwtmux_worktree_list "$noarg_root")

          # Kill the original shell window only once this repo actually has a
          # window to move to. Killing it after matching nothing took the whole
          # tmux session down with it whenever it was the only window.
          if [[ $flat_matched -eq 0 ]]; then
            echo >&2 "Error: no worktrees found for '$noarg_root'"
            return 1
          fi
          if [[ $can_reuse_window -eq 1 ]]; then
            tmux kill-window -t "$current_window_id"
          fi
          return 0
        fi

        # Neither layout: not a flat repo and no "default/" here.
        echo >&2 "Error: branch or PR number required"
        return 1
      fi

      $git_cmd -C "$PWD/default" fetch --prune --no-recurse-submodules --quiet

      # git reports worktree paths physically ("/private/var/..."), while $PWD
      # keeps whatever logical form the shell arrived by ("/var/...", a symlinked
      # home). Comparing the two matched nothing under any symlinked ancestor:
      # no window was opened, and the shell window was killed anyway.
      local pwd_physical="$(pwd -P)"
      local noarg_matched=0

      while IFS= read -r worktree_path; do
        # Only process worktrees in current directory
        if [[ "$(dirname -- "$worktree_path")" == "$pwd_physical" ]]; then
          local window_name="$(_gwtmux_window_name "$worktree_path")"
          if [[ -n "$window_name" ]]; then
            noarg_matched=$((noarg_matched + 1))
            # Check if window already exists
            if [[ -z "$(_gwtmux_window_id_by_name "$gwt_session" "$window_name")" ]]; then
              tmux new-window -t "$gwt_session" -n "$window_name" -c "$worktree_path"
            fi
          fi
        fi
      done < <($git_cmd -C "$PWD/default" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}')

      # Kill the original shell window only once there is a window to move to.
      # Matching nothing and killing anyway destroyed the session whenever this
      # was its only window.
      if [[ $noarg_matched -eq 0 ]]; then
        echo >&2 "Error: no worktrees found in '$pwd_physical'"
        return 1
      fi
      if [[ $can_reuse_window -eq 1 ]]; then
        tmux kill-window -t "$current_window_id"
      fi
      return 0
    fi

    # Try to find git root for arguments that need it (branch names, PR numbers)
    # Path arguments don't need git_root, so don't fail here.
    local git_common_dir git_root
    local has_git_root=0
    if git_common_dir="$(_gwtmux_git_dir_path --git-common-dir)"; then
      # Root of the main repo, regardless of how deep in it (or in one of its
      # worktrees) we were invoked. New worktrees are siblings of this root.
      git_root="$(dirname -- "$git_common_dir")"
      has_git_root=1
    elif [[ -d "default" ]] && $git_cmd -C "$PWD/default" rev-parse --git-dir &>/dev/null; then
      git_root="$PWD/default"
      has_git_root=1
    fi

    # Fetch once before processing all arguments (only if we have a git root and
    # some argument can need the remote). A flat repo creates no worktree and
    # resolves no branch, and an argument that is already a path only opens a
    # window for a worktree that exists, so neither is worth a network round
    # trip. Declared before the loop: zsh echoes a re-declared local that
    # carries no assignment.
    local needs_fetch=0 fetch_arg=""
    if [[ $has_git_root -eq 1 ]] && ! _gwtmux_is_flat "$git_root"; then
      for fetch_arg in "$@"; do
        if ! _gwtmux_arg_is_path "$fetch_arg"; then
          needs_fetch=1
          break
        fi
      done
    fi
    if [[ $needs_fetch -eq 1 ]]; then
      $git_cmd -C "$git_root" fetch -a
    fi

    local default_branch=""
    if [[ $has_git_root -eq 1 ]]; then
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
    fi

    # Save original git context for restoring per-iteration
    local orig_git_root="$git_root"
    local orig_default_branch="$default_branch"
    local orig_has_git_root="$has_git_root"

    # Track if any worktree succeeded (for window reuse logic)
    local success_count=0

    # Declare loop variables outside the loop to avoid re-declaration issues
    local branch window_name dir_branch worktree_path worktree_exists has_local has_remote rc repo_path_matched pr_branch arg_parent arg_basename resolved_parent repo_parent_candidate candidate_common_dir path_matched arg_is_path_shaped arg_worktree_root resolved_path existing_window_id

    # Save original directory for resolving relative args after cd
    local orig_pwd="$PWD"
    local reused_window_path=""

    # Process each argument
    for arg in "$@"; do
      # Restore working directory for relative path resolution
      cd "$orig_pwd"

      # Restore git context for each iteration
      git_root="$orig_git_root"
      default_branch="$orig_default_branch"
      has_git_root="$orig_has_git_root"
      repo_path_matched=0

      # Check if argument is a path to an existing worktree (can be any repo).
      # An arg only counts as a path when it is explicitly path-shaped ("/...",
      # "./...", "../...") or resolves to a worktree root. An arg that merely
      # contains a slash, like a "feature/auth" branch name, must not be
      # hijacked as a path just because a directory of that name happens to
      # exist next to it.
      path_matched=0
      arg_is_path_shaped=0
      case "$arg" in
      /* | ./* | ../* | . | ..) arg_is_path_shaped=1 ;;
      esac
      resolved_path=""
      arg_worktree_root=""
      if [[ -d "$arg" ]]; then
        resolved_path="$(cd "$arg" 2>/dev/null && pwd -P)"
        if [[ -n "$resolved_path" ]]; then
          arg_worktree_root="$(_gwtmux_worktree_root "$resolved_path")" || arg_worktree_root=""
        fi
      fi
      if [[ -n "$arg_worktree_root" && "$arg_worktree_root" == "$resolved_path" ]]; then
        # A worktree root - the window name comes from the worktree itself, so
        # no branch resolution is needed
        worktree_path="$resolved_path"
        worktree_exists=1
        path_matched=1
      elif [[ -n "$arg_worktree_root" && $arg_is_path_shaped -eq 1 ]]; then
        # Deliberately a path, but a subdirectory of a worktree rather than the
        # root of one. Opening it would give a window that no other gwtmux
        # command can find again, so name the root and stop.
        echo >&2 "Error: '$arg' is not a worktree root (did you mean '$arg_worktree_root'?)"
        return 1
      fi

      # If not an existing path, check if a leading path prefix is a repo parent
      # (contains default/.git). Walk up from the immediate parent so the branch
      # name may itself contain slashes, e.g. <repo>/demo/test-branch creates
      # branch "demo/test-branch". The deepest matching ancestor wins.
      if [[ $path_matched -eq 0 && ( "$arg" == /* || "$arg" == .* || "$arg" == */* ) ]]; then
        arg_parent="$(dirname -- "$arg")"
        arg_basename="$(basename -- "$arg")"
        resolved_parent=""
        while [[ "$arg_parent" != "." && "$arg_parent" != "/" ]]; do
          if [[ -d "$arg_parent" ]]; then
            repo_parent_candidate="$(cd "$arg_parent" 2>/dev/null && pwd -P)"
            if [[ -n "$repo_parent_candidate" && -d "$repo_parent_candidate/default" ]] && $git_cmd -C "$repo_parent_candidate/default" rev-parse --git-dir &>/dev/null; then
              resolved_parent="$repo_parent_candidate"
              break
            fi
            # A flat repo root inside the path. There is no default/ to hold a
            # sibling worktree, and walking past it would fold the whole prefix
            # into the branch name and offer to create a branch named after a
            # filesystem path in whatever repo the current directory belongs to.
            if [[ -n "$repo_parent_candidate" ]]; then
              candidate_common_dir="$(_gwtmux_git_dir_path --git-common-dir "$repo_parent_candidate")"
              if [[ -n "$candidate_common_dir" && "$(dirname -- "$candidate_common_dir")" == "$repo_parent_candidate" ]] &&
                _gwtmux_is_flat "$repo_parent_candidate"; then
                echo >&2 "Error: '$repo_parent_candidate' is a flat repo (no default/ layout) — cannot create worktree '$arg_basename' there."
                return 1
              fi
            fi
          fi
          # Not a repo parent: fold this component into the branch name and go up
          arg_basename="$(basename -- "$arg_parent")/$arg_basename"
          arg_parent="$(dirname -- "$arg_parent")"
        done
        if [[ -n "$resolved_parent" ]]; then
            # Override git context for this iteration
            git_root="$resolved_parent/default"
            has_git_root=1
            $git_cmd -C "$git_root" fetch -a 2>/dev/null || true
            # Compute default_branch for this repo
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
                default_branch="main"
              fi
            fi
            branch="$arg_basename"
            # Resolve PR numbers via gh (same as non-path branch resolution)
            pr_branch="$(
              (cd "$git_root" 2>/dev/null && GH_PAGER= gh pr view "$arg_basename" --json headRefName --jq '.headRefName') 2>/dev/null
            )"
            [[ -n "$pr_branch" ]] && branch="$pr_branch"
            repo_path_matched=1
        fi
      fi

      # An explicitly path-shaped arg that reached this point names neither a
      # worktree root nor a repo parent, so there is nothing to open and nowhere
      # to create anything. Fail here: the branch handling below would otherwise
      # fold the whole path into a branch name and create that branch, plus a
      # worktree for it, in whatever repo the current directory belongs to.
      if [[ $path_matched -eq 0 && $repo_path_matched -eq 0 && $arg_is_path_shaped -eq 1 ]]; then
        echo >&2 "Error: '$arg' is not a worktree root"
        return 1
      fi

      # If not a path, resolve branch name (try gh pr first, fall back to arg)
      if [[ $path_matched -eq 0 && $repo_path_matched -eq 0 ]]; then
        if [[ $has_git_root -eq 0 ]]; then
          echo >&2 "Error: not in a git repo or parent of default/.git"
          return 1
        fi
        # Flat repos are window-only. Refused here, before the gh lookup below,
        # so a PR number costs no API call either.
        if _gwtmux_is_flat "$git_root"; then
          echo >&2 "Error: '$git_root' is a flat repo (no default/ layout) — cannot create worktree '$arg' there."
          return 1
        fi
        branch="$(
          (cd "$git_root" 2>/dev/null && GH_PAGER= gh pr view "$arg" --json headRefName --jq '.headRefName') 2>/dev/null
        )"
        [[ -z "$branch" ]] && branch="$arg"
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

      # Name the window. A worktree that does not exist yet cannot be read, so
      # pass its repo root and branch along.
      if [[ $path_matched -eq 1 ]]; then
        # Check the name before a worktree that shares it sends us to some
        # other worktree's window. The repo is resolved from the path itself:
        # $git_root here belongs to the current directory, which an explicit
        # path argument need not be part of.
        window_name="$(_gwtmux_window_name "$worktree_path")"
        _gwtmux_check_unique_window_name "$worktree_path" "" "$window_name" || return 1
      else
        window_name="$(_gwtmux_window_name "$worktree_path" "$git_root" "$branch")"
      fi

      # If window already exists, just select it (by id - name targets are
      # prefix/fuzzy matched by tmux and can hit the wrong window)
      existing_window_id="$(_gwtmux_window_id_by_name "$gwt_session" "$window_name")"
      if [[ -n "$existing_window_id" ]]; then
        tmux select-window -t "$existing_window_id"
        success_count=$((success_count + 1))
        continue
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
          local confirm=""
          printf "Create new branch '%s'? [Y/n] " "$branch"
          read -r confirm </dev/tty
          if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
            echo "Skipping '$branch'"
            continue
          fi
          $git_cmd -C "$git_root" worktree add --quiet --no-track -b "$branch" -- "$worktree_path" "origin/$default_branch" || rc=$?
        fi
        if [[ $rc -ne 0 ]]; then
          echo >&2 "Warning: failed to create worktree for '$branch', skipping"
          continue
        fi
      fi

      # Create or reuse window
      if [[ $success_count -eq 0 && $can_reuse_window -eq 1 ]]; then
        tmux rename-window -t "$gwt_window" "$window_name"
        reused_window_path="$worktree_path"
      else
        tmux new-window -t "$gwt_session" -n "$window_name" -c "$worktree_path"
      fi

      success_count=$((success_count + 1))
    done

    # cd into reused window's worktree (deferred to avoid being undone by loop's cd "$orig_pwd")
    if [[ -n "$reused_window_path" ]]; then
      cd "$reused_window_path"
    fi
    ;;
  esac
}
