# Studies

Written investigations that motivate design decisions — comparisons, failed
approaches, upstream research. Cross-linked from experiments/ where a study
led to a runnable experiment.

The one worth reading first, once it's written up: why `modules/containers` renders its own
mount table instead of re-adopting the legacy `render-storage.nix` shape (hardcoded host paths
as string literals, no way to catch a typo'd category) — see the top-level README's "What
nixlxc replaces" for the short version, in the meantime.
