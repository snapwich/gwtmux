[![Validate](https://github.com/snapwich/gwtmux/actions/workflows/test.yml/badge.svg)](https://github.com/snapwich/gwtmux/actions/workflows/test.yml)

# gwtmux

Git worktree + tmux integration. Create and manage git worktrees in dedicated tmux windows.

## Directory Structure Convention

gwtmux expects a specific directory layout:

```
myrepo/
├── default/     # Main/Master branch (contains .git)
├── <feature-a>/   # worktree for feature-a branch
├── <bugfix-b>/    # worktree for bugfix-b branch
└── <etc>/         # all worktrees manged by gwtmux are siblings of default/
```

Branch names with slashes (e.g., `feature/foo`) are converted to underscores for directory names (`feature_foo`).

## Flat repos

A repo that has no `<parent>/default/` wrapper is a **flat repo**, for example a plain clone at
`~/repos/myrepo`. gwtmux finds a flat repo by the name of the repo root directory: a root that has
the name `default` follows the convention above, all other names are flat.

In a flat repo, gwtmux manages only tmux windows. It creates no worktrees, because a flat repo has
no parent directory that can hold them. All other operations work: open a window by path, open a
window for each worktree, clean up with `-d`, and rename in a worktree that you made with
`git worktree add`.

A flat repo does not fetch, because it resolves no branch from a remote.

Submodules are not supported. gwtmux resolves the repo root from
`git rev-parse --git-common-dir`, which inside a submodule points at
`<superproject>/.git/modules` - so every lookup aims at the superproject, not
at anything you can see. Done mode (`-d`) therefore refuses to run inside a
submodule. That refusal does not reach every case: inside a WORKTREE of a
submodule it does not fire, and the other modes do not check at all. Do not
run gwtmux inside a submodule.

### Support matrix

|                            | convention              | flat                    |
| -------------------------- | ----------------------- | ----------------------- |
| `gwtmux <branch>` / `<pr>` | yes                     | error                   |
| `gwtmux <path>`            | yes                     | yes, opens window       |
| `gwtmux` (no args)         | from parent dir         | from inside repo        |
| `-d`                       | yes                     | yes                     |
| `-dw` on root              | error                   | error                   |
| `-dbB` on root             | yes (switch to primary) | yes (switch to primary) |
| `-dwB <name>`              | yes, any worktree       | yes, any worktree       |
| `--rename` in worktree     | yes                     | yes                     |
| `--rename` at root         | error                   | error                   |

### Window names

| worktree                        | window name             |
| ------------------------------- | ----------------------- |
| convention repo root            | `<parent>/default`      |
| worktree of a convention repo   | `<parent>/<branch>`     |
| flat repo root                  | `<repo>`                |
| worktree of a flat repo         | `<repo>/<dir name>`     |

The window name of a flat repo comes from the directory name, not from the branch. Thus an in-place
`git switch` does not move the window. Two repos that have the same directory name in different
locations get the same window name.

## Features

- **Create worktrees**: Open branches or PRs in new tmux windows with `gwtmux <branch>`
- **PR support**: Pass a PR number and gwtmux resolves the branch name via GitHub CLI
- **Batch operations**: Open multiple worktrees at once with `gwtmux branch1 branch2 branch3`
- **Cleanup**: Remove worktrees, delete branches (local/remote), and close tmux windows
- **Rename**: Atomically rename worktree directory, branch, remote tracking, and tmux window

## Dependencies

**Required:**

- `git`
- `tmux`

**Optional:**

- `gh` (GitHub CLI) - enables PR number support

## Installation

```bash
# Clone to XDG-compliant location
git clone https://github.com/snapwich/gwtmux ~/.local/share/gwtmux

# Add to your shell config (.zshrc, .bashrc, etc.)
echo 'source ~/.local/share/gwtmux/gwtmux.sh' >> ~/.zshrc
```

## Usage

### Create Worktrees (Normal Mode)

```bash
# Create worktree from branch name
gwtmux feature-branch

# Create worktree from PR number (requires gh CLI)
gwtmux 123

# Create multiple worktrees at once
gwtmux feature-1 feature-2 bugfix-3

# Open all existing worktrees in windows (run from repo parent dir,
# or from anywhere inside a flat repo)
gwtmux

# Open an existing worktree by path
gwtmux ../other-worktree
```

An argument counts as a path when it has the shape of a path (`/...`, `./...`,
`../...`, `.` or `..`) or when it is the root of a worktree. A path argument
must be that root: a subdirectory of a worktree is an error, and so is a
path-shaped argument that is no worktree at all. Thus a branch name that
contains a slash, such as `feature/auth`, stays a branch name.

### Cleanup (Done Mode)

```bash
# Just close the tmux window
gwtmux -d

# Delete worktree and close window
gwtmux -dw

# Delete worktree + safe delete branch (only if merged)
gwtmux -dwb

# Delete worktree + force delete branch (even if unmerged)
gwtmux -dwB

# Also delete remote branch
gwtmux -dwbr   # or -dwBr for force

# Delete specific worktrees by name (from any location)
gwtmux -dwB feature-1 feature-2
```

A name is matched against the worktrees of the repo by path, then directory
name, then branch. An ambiguous name is an error and nothing is deleted.

Worktrees nested inside a target are removed too, after a prompt. Their
branches obey the same `-b` merge rule as the target, and gwtmux never removes
a nested worktree with `--force`: uncommitted work there stops the operation,
just as it does in the target itself. A target that gwtmux cannot remove keeps
its branch and its tmux window, and the command exits non-zero.

### Rename

```bash
# Set the worktree, branch, remote branch, and tmux window to one name
gwtmux --rename new-branch-name
```

This command makes all names agree with the new name:

1. Moves the worktree directory
2. Renames the local branch
3. If the configured upstream branch has a different name: pushes the new
   branch, deletes the old remote branch, and sets the new upstream
4. Renames the tmux window

The command skips each step that already matches the new name. Thus you can
use it to unify a worktree, branch, and remote branch that have different
names.

The command deletes the old remote branch only when the latest commit is
authored by you, and only when that remote branch contains no commit that the
renamed branch lacks. A branch that tracks a differently named shared branch,
as `git checkout -b feat origin/develop` makes it, therefore keeps
`origin/develop` and gets a warning instead.

## License

MIT
