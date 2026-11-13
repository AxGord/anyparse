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

## The colon of a function-type parameter and of a type-parameter constraint: `whitespace.arrowParamColonPolicy`, `whitespace.typeParamConstraintColonPolicy`

Two keys of their own, not part of haxe-formatter's schema. `arrowParamColonPolicy` spaces the `:` of a named function-type parameter (`(call:QueryNode) -> Bool`); `typeParamConstraintColonPolicy` spaces the `:` of a type-parameter constraint (`<T:Dynamic>`, in a class, typedef or function header). Each takes the usual policy values (`none`, `before`, `after`, `around`) and is set on its own. Left out, the colon follows `typeHintColonPolicy`, the policy of the annotation colons (`var x: Int`, `f(a: Int)`): under `after` it is `(call: Int)`, `<T: Foo>`; with neither key set it is tight (`(call:Int)`, `<T:Foo>`). A key that is set wins over `typeHintColonPolicy`.

```haxe
// "arrowParamColonPolicy": "after", "typeParamConstraintColonPolicy": "around"
typedef Check = (call: QueryNode) -> Bool;
function first<T : Dynamic>(items:Array<T>):T {}
```

## A value `try` that does not fit: `sameLine.expressionTryOverflow`

A brace-less value `try` (`final x = try f() catch (e: E) g()`) that fits the line stays on it. One that does not fit breaks at its seams, never inside the first call or the tail, with `sameLine.expressionTry` left at `same`. `next` (the default) puts each body on its own indented line with `catch` at the statement's indent, the shape a value `if` takes under `sameLine.expressionIf: next`:

```haxe
final carried: CarriedDocuments = try
	PackageDocumentCarry.carry(documents, members[0].keys)
catch (exception: Exception)
	return Left(reasons);
```

`same` keeps the body on the `try` line and breaks before `catch` only, each `catch` one indent in:

```haxe
final carried: CarriedDocuments = try PackageDocumentCarry.carry(documents, members[0].keys)
	catch (exception: Exception) return Left(reasons);
```

An array that does not fit on one line, or one written across several lines, counts as not fitting: the seams break and the array wraps in its body position. A `[]` body is an ordinary body with its own line; a curly block, an object literal and a function body keep the head's line.

`sameLine.expressionTry: next` keeps breaking every body unconditionally, and a statement `try` follows `sameLine.tryBody` and `sameLine.catchBody` as before.

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

## An `enum abstract` with more than values: `emptyLines.enumAbstractEmptyLines.abstractRulesUnlessValueList`

`false` by default. Set, an `enum abstract` body holding a method, a property, a `static` member or a `//` comment in
front of a member follows `abstractEmptyLines` — blank lines at `{` and `}`, between members, `existingBetweenFields` —
instead of `enumAbstractEmptyLines`, so groups labelled by line comments and values above a property keep their blank
lines. A body of plain values, doc comments and `#if` regions included, keeps the `enumAbstractEmptyLines` rules.
Details: `docs/haxe-format-config.md`.

## The trailing comma: `wrapping.trailingComma`

`remove` by default: an array, map or object literal and a `new` or call argument list never end with a `,`, flat
(`[1, 2,]` → `[1, 2]`) or broken over lines, whatever the source had and whatever a `trailingCommas.*Default: "yes"`
asks for; a line comment that followed the dropped `,` stays beside the last element (`b, // c` → `b // c`). `keep`
lets a source trailing `,` survive in every layout, a call inside a method chain or glued around a block argument
included, and lets those keys add one to a list broken over lines, one item per line or packed to fill them; a list
that stays on one line, or a sole argument sharing the open delimiter's line, gets none it did not have. A config that
sets `arrayLiteralDefault`, `callArgumentDefault` or `objectLiteralDefault` to `"yes"` and says nothing about
`wrapping.trailingComma` loads as `keep`, so the comma it asks for is added. A function parameter list's trailing `,`
is always dropped and a mandatory comma (`{> Base,}`) always written, whatever the key says. Details: `docs/haxe-format-config.md`.

## Lists break by the wrapping rules

An object, array or map literal and an anonymous type lay out by `wrapping.objectLiteral` / `arrayWrap` / `mapWrap` /
`anonType` alone (item count, item length, line width): a break the source put between items, grid rows included, does
not keep a list open, and the built-in fallback of those four is `ignore`. A `"defaultWrap": "noWrap"` block on one of
them lays that list out by its rules and otherwise flat, without reading source breaks, except that a grid-shaped array and, under `"rules": []`, a comprehension still follow the source; the other non-`ignore` values
(`onePerLine` is the pinned one) still read them. A typedef's body keeps its source lines until its own decision.

## A literal argument: `callParameter.containerItemWrap`

When a call's argument list breaks, an array or object literal argument that carries a call takes a line of its own,
unless it is simple: at most three items, none of them a nested literal, the whole literal at most 60 characters wide.
A simple one fills the argument line with its neighbours. The test is the nested cascade `containerItemWrap` inside
`wrapping.callParameter`, measured over the literal's own items; `onePerLine` gives the literal its own line, any other
mode lets it fill. A `callParameter` block that does not name the key keeps the built-in one. Details:
`docs/haxe-format-config.md`.

## A simple value `if` on one line: `sameLine.expressionIfFit` and its caps

Under `sameLine.expressionIf: next` every value `if` breaks, each value on its own line. `sameLine.expressionIfFit: true` keeps a chain on one line when it fits, and two caps narrow that to a simple chain; a chain either cap refuses keeps the `next` layout whole, never half-joined:

- `expressionIfFitMaxBranches` — the most values a chain may hold (`if (c) a else b` is 2, `if (c) a else if (d) b else e` is 3);
- `expressionIfFitMaxValueWidth` — the widest one value may render (each branch and the final `else`); a value that cannot render flat, such as a block, refuses too.

`0` is no cap. With `"expressionIfFit": true, "expressionIfFitMaxValueWidth": 8`:

```haxe
return if (a < b) -1 else if (a > b) 1 else 0;
final a = if (c)
	1
else
	make(x, y);
```

## Metadata placed by width: `lineEnds.metadata*: fit`

`fit` is a value of `lineEnds.metadataType`, `metadataFunction`, `metadataVar` and `metadataOther`, not part of
haxe-formatter's schema. It is decided by width and never reads the source layout:

- one simple metadata stays on the declaration's line when that line fits `wrapping.maxLineLength`, else takes a line of its own;
- several simple metadata share one line above the declaration when that row fits, and are never joined to the declaration itself;
- otherwise — a complex metadata, a row that does not fit, a comment between metadata or after the last one, a `#if` in the run — one per line, as `after`.

Simple is no argument, or exactly one that is a number, `true` / `false` / `null`, an identifier, a dotted path or a
one-line string without interpolation (`@:nullSafety(Strict)`, `@:access(pkg.Type)`, `@:xml('action')`). A call, several
arguments, an object, array or function literal and an interpolated or multi-line string are complex. With `fit` on all four keys:

```haxe
@:access(a.B) @:nullSafety(Strict)
abstract class C {
	@:from public static inline function f(v:Int):C {}

	@:build(macros.X.build())
	@:a
	var t:Int;
}
```

A local `var` or `final` follows the same rules: `@:a @:b var x = 1;` puts `@:a @:b` on a line of its own above the `var`.
