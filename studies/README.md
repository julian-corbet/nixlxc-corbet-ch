# Studies

Written investigations that motivate design decisions — comparisons, failed approaches, upstream
research. Cross-linked from experiments/ where a study led to a runnable experiment.

## Index

- **[adopting-a-live-container.md](adopting-a-live-container.md)** — what it cost to move a running,
  privileged, GPU-bearing container from a hand-authored liblxc document onto these options without
  restarting it into a different shape. Six findings, none of which produced an error: an immutable
  field that makes adoption and replacement different acts, a merged probe that is invalid because
  the thing merged into is a tagged union, a stable path that cannot buy a stable device number,
  ordering that cannot be guessed on another owner's behalf, a fail-closed guard nobody could hear,
  and eight dangerous mutations that all passed a set of checks claiming to catch them.

## The study this file used to promise

It asked why `modules/containers` renders its own mount table rather than re-adopting the legacy
string-rendering shape it replaces. That question has since been answered by evidence rather than
argument, so it is recorded here instead of written up separately.

The legacy shape hardcoded host paths as string literals with nothing to check them against — a
typo'd category was a silently-dropped mount. The consumer that ran it retired that renderer
outright: its storage model now emits typed mount entries this module renders, and the container's
whole config comes from typed options. The measurable outcome is that the container declares
**no `extraConfig` at all**. That is the argument, and it is stronger as a fact than it would have
been as prose: an escape hatch nothing reaches for is a boundary that holds, and a module whose
escape hatch carries the substance is a text file with a Nix wrapper.

The one genuinely load-bearing detail worth keeping from the original question — why a delivered
mount is resolved-and-checked while a raw device bind cannot be — lives in `mounts`' own option
documentation, next to the code it governs.
