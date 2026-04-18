# linX86 — x86_64-linux-gnu target branch

This branch carries patches specific to the x86_64-linux-gnu target
(Ubuntu 24.04 noble, Zig 0.15.2, gfortran 14.3.0 from ubuntu-toolchain-r/test).

## Reference machine
- 2013 MacBook Pro, Intel x86_64, Ubuntu 24.04
- Zig 0.15.2 at ~/.local/bin/zig
- gfortran 14.3.0 at /usr/bin/gfortran-14 (bare `gfortran` is a user-local symlink)
- libgfortran.so lives at /usr/lib/gcc/x86_64-linux-gnu/14/

## Relationship to other branches
- `main` — target-agnostic truth
- `jetson-thor` — aarch64 Linux + Jetson AGX Thor GPU (nvfortran -gpu=cc110)
- `linX86` — this branch
- `winX86` — Windows x86_64 (MSYS2 UCRT64)

## Build
See main CLAUDE.md for module-specific instructions. linX86 adds:
- `FC=gfortran-14` env var plumbing where scripts hardcoded bare `gfortran`
- `/usr/lib/gcc/x86_64-linux-gnu/14` in link search paths
- `x86_64-linux-gnu` in per-module TargetId enums where missing
- forCUDA sibling path resolution extended to `linux-x86_64`
