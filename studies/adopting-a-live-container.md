# Adopting a live container onto typed options

What it cost to move a running, privileged, GPU-bearing LXC from a hand-authored liblxc document
onto this module's options — without restarting it into a different shape. Six findings, each one
paid for. They are written down because every one of them is invisible until it is not: none
produced an error, and four of them had already been silently true for days or weeks.

The container: 66 functional directives, fourteen device binds, a twenty-two-rule deny-by-default
cgroup policy, fourteen dataset-backed mounts, a desktop session, and consumers that notice.

## 1. An immutable field makes adoption and replacement different acts

The app grammar names its Deployment selector one way; the object had shipped with another since
before the module existed. `spec.selector` is immutable — the API server refuses the change
outright — so reaching the "correct" scheme means deleting and recreating, which on a single-writer
database or a desktop session is an outage.

**Adopting an existing workload means preserving its immutable identity, not asserting a nicer
one.** Force the selector to the live value and the same object, with the same pods, simply changes
who declares it. Relabelling stays possible later as a scheduled, deliberate recreate. It is not
something an adoption should force, and a module that cannot express the old shape cannot adopt
anything — it can only replace it.

The general rule: before adopting, enumerate the target's immutable fields and check whether your
declaration can reproduce them. If it cannot, you are not writing an adoption.

## 2. A merged probe is an invalid probe

Merging a typed override onto a rendered probe produced an object carrying **both** an `exec` and a
`tcpSocket` handler. Kubernetes permits exactly one. The API server rejects it — but nothing at
evaluation time does, because each half is individually well-typed.

`mkForce` there is load-bearing, not style. The general shape: an attrset merge is the wrong default
whenever the target is a tagged union rather than a bag of independent fields. Ask whether the thing
you are merging into has *alternatives* in it; if it does, replace rather than merge.

Found only by diffing the built render against the live object. No eval-time check sees it.

## 3. A stable path does not buy a stable number

Device nodes were bound through `/dev/dri/by-path/…` precisely because a card *number* is an
enumeration order decided by driver probe order, and it moves — it had already moved once, pointing
four references at the wrong silicon for nine days.

By-path fixes the **mount**. It cannot fix the **cgroup rule**, because cgroup v2's device filter is
a kernel ABI keyed on `major:minor` with no path form. So the mount binds the right hardware while
the rule may deny the very node just bound, and the failure is silent: the node is present, every
`open()` is refused, nothing is logged.

That is not a modelling gap to be closed by declaring harder. A major is assigned by the running
kernel — one of these was `register_chrdev(0, …)`, handed out at module load, and went 242 → 235 →
234 across three months. **Declaring puts every such number in one typed place; only a runtime check
can say whether it is still true.** Build both, and say which is which.

## 4. Rendering and materialising are different jobs with different owners

This module renders a container's config and, when it owns the runtime, materialises it at the
lxcpath before the autostart pass. Under `runtimeManagedElsewhere` that second half was wrong in
three ways at once, all measured:

- it ordered itself before a unit that did not exist on that host, leaving a dangling wants-link;
- its only live edge was `After=local-fs.target`, reached at 1.6 s, while the pool holding the
  target mounted at 227 s — so the write would land on the root dataset and be occluded;
- it rewrote the live file *after* the container had started from it, so the file on disk no longer
  described the running container and nothing could tell.

None of it is fixable from inside the module, because the missing fact — which unit starts these
containers, and what it must be ordered after — belongs to whoever owns the runtime. So it renders
and stops. **Ordering is not a property you can guess on someone else's behalf.**

## 5. A guard nobody can hear is indistinguishable from one that failed open

The pre-start hook was fail-closed and correct, and produced **zero** journal lines across every
start, because `lxc-start` daemonizes and hook stderr goes nowhere. The argument for the whole
arrangement was "the container started, therefore the guard passed" — which holds only if the guard
ran. It had a fail-open branch for an unreadable config, and that branch pointed at a path which had
never existed.

Worse, the fix for the invisibility was itself invisible: `logger` was not on the hook's PATH, and
the `|| true` swallowed it. The same lookup governed `zfs`, whose absence would have silently
degraded a mount check to a weaker one with nothing to say so.

**Make a guard state its verdict somewhere durable, then verify the statement appears** — under the
environment it actually runs in, not the one your shell has. `env -i` and direct exec is the test.

## 6. A check that cannot fail on the mutation it is named for is worse than no check

The eval-time invariants for this container were written, shipped, and described as "each perturbed
and confirmed to fail by name." An adversarial pass ran eight dangerous mutations through them and
**all eight passed** — including deleting a still-bound device's cgroup rule, and moving the
deny-all *after* the allowlist, which clears it.

The defects were one shape: testing PRESENCE where the danger is POSITION, testing the wrong parsed
field, or matching a substring anywhere in the document instead of on the directive that governs it.

Two habits follow, and they are the whole lesson of this file:

- **Mutation-test every guard.** Write the wrong config, run the check, watch it fail. A guard that
  has never been seen to fail is a comment.
- **Do not claim what the layer cannot decide.** One of the eight is genuinely undecidable at
  evaluation, and the honest fix was to stop asserting it and say which layer owns it — a count
  comparison that *looked* like coupling passed the exact mutation it was named for.
