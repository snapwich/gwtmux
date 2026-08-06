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

# Open all existing worktrees in windows (run from repo parent dir)
gwtmux
```

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
names. The command deletes the old remote branch only when the latest commit
is authored by you.

## License

MIT
