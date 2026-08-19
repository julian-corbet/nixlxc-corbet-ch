# Adopting live workloads onto typed modules

What it costs to move a workload that is already running onto declared, typed options — without
restarting it into a different shape.

**Two adoptions, one day, and this file says which is which.** An earlier draft framed all six
findings as the cost of the LXC migration. Two of them were not: they came from adopting a database
tier onto a Kubernetes app grammar the same morning, six hours earlier and in a different
repository. The findings are real and they generalise, which is exactly why the provenance matters —
a study that quietly absorbs a neighbour's evidence is one that will be cited for things it did not
observe. Each section below names its source.

The LXC container: 66 functional directives, fourteen device binds, a twenty-two-rule
deny-by-default cgroup policy, fourteen dataset-backed mounts, a desktop session, and consumers that
notice.

## 1. An immutable field makes adoption and replacement different acts

*Source: the Kubernetes adoption, not the LXC one.*

The app grammar named a Deployment's selector one way; the object had shipped with another since
before the module existed. `spec.selector` is immutable — `kubectl apply --dry-run=server` refuses
the change outright, so this one DID produce an error, loudly, at the right time. Reaching the
"correct" scheme means deleting and recreating, which on a single-writer database is an outage.

**Adopting an existing workload means preserving its immutable identity, not asserting a nicer
one.** Force the selector to the live value and the same object, with the same pods, simply changes
who declares it. Relabelling stays possible later as a scheduled, deliberate recreate.

Generalises directly to liblxc, which is why it is kept here: a container's `lxc.uts.name`, its
rootfs path and its MAC are all identity a running system is known by. Before adopting anything,
enumerate the target's immutable fields and check whether your declaration can reproduce them. If it
cannot, you are not writing an adoption.

## 2. A merged override onto a tagged union is invalid

*Source: the Kubernetes adoption, not the LXC one.*

Merging a typed override onto a rendered readiness probe produced an object carrying **both** an
`exec` and a `tcpSocket` handler. Kubernetes permits exactly one. Each half was individually
well-typed, so nothing at evaluation objected; the API server rejected the result.

The general shape, and the reason it belongs in a liblxc repo too: **an attrset merge is the wrong
default whenever the target is a tagged union rather than a bag of independent fields.** Ask whether
the thing you are merging into has *alternatives* in it. `lxc.net.<n>.type` and the device rule
grammar have exactly that character.

Found only by diffing the built render against the live object.

## 3. A stable path does not buy a stable number

*Source: the LXC adoption.*

Device nodes were bound through `/dev/dri/by-path/…` precisely because a card *number* is an
enumeration order decided by driver probe order, and it moves — it had already moved once, pointing
four references at the wrong silicon for nine days.

By-path fixes the **mount**. It cannot fix the **cgroup rule**, because cgroup v2's device filter is
a kernel ABI keyed on `major:minor` with no path form. So the mount binds the right hardware while
the rule may deny the very node just bound: the node is present, every `open()` refused, nothing
logged. `/dev/kfd`'s major was `register_chrdev(0, …)` — handed out at module load — and went
242 → 235 → 234 across three months, leaving ROCm denied while the container reported healthy.

**Declaring puts every such number in one typed place; only a runtime check can say whether it is
still true.** Build both, and be explicit about which answers what.

## 4. Rendering and materialising are different jobs with different owners

*Source: the LXC adoption.*

This module renders a container's config and, when it owns the runtime, materialises it at the
lxcpath. Under `runtimeManagedElsewhere` that second half was wrong three ways at once, all
measured on the host:

- it ordered itself before a unit that did not exist there, leaving a dangling wants-link;
- its only live edge was `After=local-fs.target`, reached at 1.6 s, while the pool holding the
  target mounted at 227 s — so the write would land on the root dataset and be occluded;
- it rewrote the live file *after* the container had started from it, so the file on disk no longer
  described the running container and nothing could tell.

None of it is fixable from inside, because the missing fact — which unit starts these containers and
what it must be ordered after — belongs to whoever owns the runtime. So it renders and stops.
**Ordering is not a property you can guess on someone else's behalf.**

## 5. A guard nobody can hear is indistinguishable from one that failed open

*Source: the LXC adoption.*

The pre-start hook was fail-closed and correct, and produced **zero** journal lines across every
start, because `lxc-start` daemonizes and hook stderr goes nowhere. The argument for the whole
arrangement was "the container started, therefore the guard passed" — which holds only if the guard
ran. It had a fail-open branch for an unreadable config, pointing at a path that had never existed.

Worse, the fix for the invisibility was itself invisible: `logger` was not on the hook's PATH and
`|| true` swallowed it. The same lookup governed `zfs`, whose absence would have silently degraded a
mount check to a weaker one with nothing to say so.

**Make a guard state its verdict somewhere durable, then verify the statement appears** — under the
environment it actually runs in. `env -i` plus direct exec is the test.

## 6. A check that cannot fail on the mutation it is named for is worse than no check

*Source: both adoptions, and then this module itself — three times in one day.*

The consumer's eval-time invariants were written, shipped, and described as "each perturbed and
confirmed to fail by name." An adversarial pass ran eight dangerous mutations through them and **all
eight passed**, including deleting a still-bound device's cgroup rule and moving the deny-all after
the allowlist, which clears it.

Then the same thing happened one layer up, in this repo. Its own checks were green while the wire
carrying every mount from the module to the renderer could be cut outright: replacing
`entries = cfg.<name>.mounts` with `entries = [ ]` rendered a container with no `/home`, no shared
`/nix` and no device nodes, and all 73 checks stayed green — because the render tests called the
renderer directly and never exercised the module's wiring, while no eval fixture declared any of the
hardware options at all.

Two habits follow, and they are the whole point of this file:

- **Mutation-test every guard.** Write the wrong config, run the check, watch it fail. A guard that
  has never been seen to fail is a comment. Test the WIRING, not only the leaves: a fixture that
  never sets an option cannot notice when that option stops being passed.
- **Do not claim what the layer cannot decide.** One of the eight is genuinely undecidable at
  evaluation, and the honest fix was to stop asserting it and name the layer that owns it. A count
  comparison that *looked* like coupling passed the exact mutation it was named for.
