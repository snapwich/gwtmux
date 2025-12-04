_default:
    just --list

init-submodules:
    git submodule update --init --recursive

test: init-submodules
    ./tests/bats/bin/bats tests/gwtmux.bats
