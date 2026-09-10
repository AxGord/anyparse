# decisions — hypotheses this project tried and refuted

One line per idea that was proposed, believed, or half-built and then **did not survive contact
with the tree**: what was tried, why it is not here, and the commit that holds the detail. It
exists because git is searchable by text and not by idea — the next person to have one of these
thoughts should find the answer here instead of re-deriving it.

**What goes here:** a refutation. "We wanted X, we looked, and X is wrong / already there /
unreachable." One sentence, no chronicle.

**What does not:** a measurement. A reading is of one tree at one moment — it belongs in the
commit message that made it and in the campaign ledger, never in this file and never in a code
comment (`doc-measurement-claim` reports the latter). A line here may cite the number that
decided the question; it may not become a record of runs.

**Where the detail is:** the named commit. Most are merges of a slice branch, so read them with
`git log <sha>^1..<sha>^2` — `git show` on a merge prints the merge line and nothing else.

---

- `interfaceRequires` was to be priced as the cost of the widest index per candidate → a CPU
  profile of the narrow run put the whole cost in reading and parsing the declared scope under
  `widest()`; the interface gate was never called at all — `8fcb97e3`
- `subtypeMemberNames` was to get a memo for the same reason → it is called nowhere on this
  project's own sources and a handful of times on the largest external tree, so the memo would
  have been state without pain — `8fcb97e3`
- a method used as a value was to be treated as unsafe under `-dce full` → it compiles and runs
  on the project's Haxe; only reflection with a static call site is the real hazard, and that is
  what the gate reads now — `1d12e591`
- `patch`'s doc guard was to compare a declaration count across two containers → both counts
  already read the same container, so the guard needed a different question (the bytes the block
  documents), not a second container — `961e6d17`
- `&&=` and `||=` were to be added to the mutating-operator table → the language has no such
  operators and refuses them outright; only `>>>=` was really missing — `8fcb97e3`
- the grammar's `PlainMeta` constructor was to be given a projection → it is unreachable by
  construction: the sibling pattern is the same regex minus one optional group at the same
  anchor, so the sibling wins on every input — `f743471b`
- four rules were believed to read the subtype adjacency key that a simple name had collided in
  → the readers are eight, reached through four different accessors; the fix had to be at the
  key, not at the callers — `440ca9a5`
- `hxformat.json` was believed to be read by two formatting engines, so a change to it had to
  keep both happy → the other engine is never run over this tree; the only fork arm reads the
  fork's own config — `050c91bb`
- the string-literal table carve-out was to key on ARITY, the number of entries → the
  discriminator is homogeneity: a table is a collection literal of only literals, at any size and
  in the map spelling too — `a3588740`
- a stale doc claimed a live suffix guess (`endsWith('Lit')`) in the grammar-agnostic layer →
  both sites were plain membership tests; the guess had already been removed and only its doc
  survived — `9a16cbdc`
- a new `RefShape` field was proposed for the binder kinds → every kind already had a field; what
  was missing was a DERIVATION over eleven of them — `c07d514a`
- two builds of one commit were believed to drift in test counts → three independent builds of
  the same commit produced byte-identical counts; what moves the number is the ambient environment — a
  `haxelib setup`'d `$HOME`, a populated `bin/` — `53d58cd4`
- the addressing layer was believed to fail SILENTLY on a bad selector → it always exited
  non-zero with a name hint; what it lacked was a clause naming the KIND — `abda1bcd`
- a glue form was believed unable to force a body break, so a new primitive was scoped → glue
  already breaks the body itself, and the probe that shows it is one element wider — `56a02109`
- `comment-rewrite`'s refusal on an edit that widens a comment was filed as a defect → it is the
  intended guard against a silently over-wide line, and the way out is already named in its own
  message — `da0be5b8`
- metadata arguments were believed invisible to the query layer → they are children of the
  metadata node; only the metadata NAME is filtered, by the symbol-name rule — `e52665e5`
- the percent-share guard was to refuse a sign not followed by a digit or `(` → the `(` half
  silences the readings this project writes (`57% (anyparse)`, `9 % (5 of 54)`) and refuses no
  arithmetic the digit half already misses; the guard that works is per LINE — `c35ae45e`
- the recording verb was to be read as SENTENCE-INITIAL and capitalised → a wrapped sentence
  starts its line mid-clause, this project writes emphasis in upper case, and the parenthetical
  and dash-introduced readings are the larger half; the discriminator is clause POSITION —
  `c35ae45e`
