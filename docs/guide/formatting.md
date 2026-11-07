# File creation and formatting

The create-side and whole-file counterparts of the insert ops — a new file gets the same
guarantees: it parses or is rejected, comes out byte-canonical, and is written atomically.

| Command | Operation |
|---|---|
| `new` | create a new module deterministically — `--kind class` (default; `--implements <iface>` stubs every method with its real sliced signature and carries the imports so it type-checks) / `interface` / `enum` / `typedef` / `abstract` (`--underlying <T>` [`--from`/`--to`]), plus `--extends <T>` (class superclass / interface super-interfaces / typedef `> Base` struct extension, qualified names imported), `--open` (non-final class), `--field` verbatim members, and `@@` stdin sections (`@@ <method>` bodies / `@@ members` free-form member block / `@@ imports` / `@@ doc`). `--raw -` instead takes the COMPLETE file from stdin — the validated atomic equivalent of a raw write, for shapes no spec covers |
| `fmt` | canonicalise files / dirs through the writer round-trip — gofmt-style `--write` (rewrite in place) / `--list` (report drift) |

Because raw text editing has no such guarantee, `new` is the way to create a file and
`fmt` the way to bring one back to canonical form.

**The round trip is fail-closed on COMMENT LOSS — this governs every rewrite in the tool,
not just `fmt`.** The Trivia parser captures a comment only where a capture slot exists, so
an inline comment in a slot-less seam — `if (/* c */ x)`, `return /* r */ x;`, a type
annotation, a class header — never reaches the AST and would be deleted by the re-emission.
Rather than hand back those bytes, `writeRoundTrip` refuses, and each caller keeps the
original bytes:

- `fmt` names the file and the comment on stderr, leaves the file byte-identical and exits
  non-zero (`--write` / `--list` also count it in their `N failed` tally; note a refused
  file never appears on `--list`'s stdout, so check the exit code, not just the list);
- every op that canonicalises through `RefactorSupport` — `add-member`, `rename`,
  `set-doc`, … and `lint --fix` — refuses its edit rather than writing the file without the
  comment. One slot-less comment therefore makes a whole file un-editable by the ops until
  the comment moves; that is the trade, and the message names the comment. `lint --fix`
  narrows the refusal when the comment is lost by an EDIT rather than by the file itself:
  the refused edit set is re-asked one rule at a time and then one FINDING at a time, so
  every other rule's fixes and the same rule's other findings still land, and the stderr
  line names the refused finding (`modifier-order at 5:2: …`). A finding's own edits stay
  atomic (a signature with its call sites is one finding). The two oracle phases narrow it
  too: the oracle-assisted pass takes the same rule-then-finding salvage and names each
  refused file on its own line (`oracle-assisted REFUSED <file>: …`, counted on the summary
  line and in the ledger's gate-refusal block), and a risky rule's edit set the writer refuses
  is split by writer round trips alone before its writable units are typechecked — the
  compile count is what those units would have cost on their own. A source the writer cannot
  round-trip at all is still skipped whole — no subset of edits changes that answer;
- `new` / `new --raw` reject the content instead of creating a file that lost part of it.

Freezing a file's formatting is recoverable; deleting an author's comment is not. Set
`APQ_ALLOW_COMMENT_LOSS=1` to decline the guard while developing the writer itself — it is
process-wide and re-arms the deletion on the write paths too, so `fmt` and `lint --fix`
print a warning when they run under it.

**A rewrite may not strand an `else` — the output must be at least as valid as the input.**
The grammar accepts an `else` with no `if` in front of it (`OrphanElseStmt`) on purpose:
conditional compilation cuts if-chains in half (`if (a) f(); #if x else g(); #end`, or
parallel `if` heads in `#if a if (x) #else if (y) #end`), and such files must parse. So
"it re-parses" does not mean "it compiles": a `patch` that duplicated an `} else if (c)`
header without its `{` wrote `if (c) else if (c) { … }` and reported success. Every op that
canonicalises through `CanonicalEdit` (the addressed ops, `lint --fix`, `FixVerifier`) and
`fmt` therefore count the orphan `else`s that NO `#if` seam explains — one that does not
open a branch of a `#if` region and does not follow a statement ending in one — and refuse a
result holding more of them than the input did, naming the line. The input's own count is
the floor, not zero: a file that already carries such an `else` still formats (as it stands)
and still takes edits that leave it alone. Whether a seam-adjacent `else` compiles depends
on the defines (`#if a if (c) f(); #end else g();` compiles only with `-D a`), which no
whole-file parse knows, so a seam makes an `else` acceptable, never proven valid.

## A case label that wrapped: `sameLine.caseBody`, `sameLine.expressionCase`

`fitLine` means the whole branch fits on one line, and a label that took more than one no longer does: its body goes below
it at the case indent plus one, however short the label's last row, under either `caseSiblings` mode. That holds for any way
a label comes to take a second line: a pattern list that wraps, an object or call pattern that breaks inside, a wrap rule,
a line break in a token.

## Case branches of one switch: `sameLine.caseSiblings`

`off` by default, each `fitLine` branch deciding alone. Under `anyBreak` the branches of one switch share the decision:
one branch below its label, because it is too wide or because of its shape (two statements, an outermost `&&`), moves
all of them, `#if` regions and a switch opened inside `#if` included. A branch that glues its opening `{` to the label
stays there unless another branch leads. A comment alone does not lead: a branch held below its label by a leading comment or one riding the label stays a
follower when its statement would have fit beside the label, and leads when it would not (that comment weighs nothing
in the measure). A trailing comment counts as width where the branch stands on its label, so a line that does not fit
with its comment leads. A two-statement or outermost-`&&` branch leads whether or not a comment holds it. Applies where `caseBody`
or `expressionCase` is `fitLine`; under `same`, `next` and `keep` the key moves nothing. A label too wide for one row leads, since
its flat width does not fit; a label wrapped by a rule with a flat width that fits does not lead, and only its own body moves.

## Blank lines at the edges of a documented type: `emptyLines.<kind>.beginTypeIfDocComments`

`beginTypeIfDocComments` / `endTypeIfDocComments` in `enumEmptyLines`, `typedefEmptyLines` and `enumAbstractEmptyLines`:
the blank lines after `{` and before `}` of a body that holds a doc comment (`/**`) in front of a member or before its
`}`. They replace that kind's `beginType` / `endType` for such a body only, so a packed enum without docs stays packed
while a documented one opens with a blank line. Left out, `beginType` / `endType` apply as before. Values and edge cases:
`docs/haxe-format-config.md`.

## The blank line after a doc-commented member: `emptyLines.<kind>.afterFieldsWithDocComments`

`afterFieldsWithDocComments` in `enumEmptyLines`, `typedefEmptyLines` and `enumAbstractEmptyLines`: `ignore`, `none`
or `one`, like the global key, for the blank line after a member that carries a doc comment in that kind's body. With
`none` a documented member keeps its blank line above (`beforeDocCommentEmptyLines`) and the next member follows it
directly. Left out, an enum or typedef keeps the source blank and an `enum abstract` follows the global key. Details:
`docs/haxe-format-config.md`.

## The trailing comma as a layout lever: `wrapping.trailingComma`

`keep` (default) round-trips a list's trailing comma, `remove` drops it from every multiline array, object literal and
argument list. `split` makes the comma the author's lever: a list whose source writes `,` after its last element is laid
out one element per line, however short (`[1, 2,]`, `{x: 1,}`, `f(a, b,)`, `new T(a,)`), and keeps the comma; a list
without one is laid out by its wrap rules and the line width as under `keep`. Under `split` a `trailingCommas.*Default: yes` knob
adds its comma only to a list laid out one element per line. Function parameter lists, a `{ > Base, }`
extension and the arguments of a call inside a method chain are outside its reach. Details: `docs/haxe-format-config.md`.
