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

## The `;` after a typedef: `whitespace.typedefSemicolon`

A key of its own, not part of haxe-formatter's schema: `preserve` (the default) writes the `;` where the source has it, `always` writes it after every typedef, `never` drops it where Haxe does not need it. It shares its values with `whitespace.optionalSemicolon` but never its setting, so `optionalSemicolon: always` for statements composes with `typedefSemicolon: never`.

`never` drops the `;` only when the right-hand side as written ends with `}`: an anonymous structure (one line or several), the last `& {…}` clause of an intersection, a function type returning a structure. Any other body keeps it. The test reads the typedef the formatter writes, not the source, so a structure that `prefer-intersection-type` rewrote into `A & B` keeps its `;`. A blank line or a comment after the dropped `;` stays where it was.

```haxe
// "typedefSemicolon": "never"
typedef Named = {> Base, name:String}
typedef Both = Base & Other;
typedef Tail = Base & {x:Int}
typedef Callback = (a:Int) -> Void;
```

## Braces that `remove` keeps: `whitespace.bracesConfig.singleStatementBraces`

`remove` drops the braces around a single-statement body, but never where the bare form reads as a dangling-else puzzle: a bare `if` in the then-position of an `if`, and a bare `for` / `while` there when an `else` follows it. Those gain braces, and the `else` gains its own so the pair stays symmetric. There is no separate key: it is part of `remove`. `symmetric` only repairs a pair with one braced branch, so it leaves two bare branches alone, and `keep` changes nothing.

```haxe
// "singleStatementBraces": "remove"
if (a) {
	for (x in xs)
		g(x);
} else {
	h();
}
```

## Padding inside square brackets: `whitespace.bracketConfig`

Four kinds of bracket, each its own `openingPolicy` / `closingPolicy` pair (`none`, `before`, `after`, `onlyBefore`, `onlyAfter`, `around`): `accessBrackets` (index access, `a[i]`), `arrayLiteralBrackets` (`[1, 2]`), `mapLiteralBrackets` (`[k => v]`) and `comprehensionBrackets` (`[for (x in xs) x]`). Every kind is tight by default, and a kind left out stays tight.

```json
"whitespace": { "bracketConfig": { "comprehensionBrackets": { "openingPolicy": "onlyAfter", "closingPolicy": "onlyBefore" } } }
```

```haxe
// comprehensionBrackets padded, the other kinds tight
final ids = [ for (x in xs) x.id ];
final a = [1, 2];
final m = [1 => 2];
final v = xs[0];
```

With `wrapping.comprehensionFit` absent, padded comprehension brackets also change the layout (below); set it to `false` to keep the padding whitespace-only.

## A comprehension's layout apart from its padding: `wrapping.comprehensionFit`

`true` lays a comprehension out by width: it stays on one line while the line fits `maxLineLength` (a source that wrapped it reflows), and a construct after it on that line that can break breaks first. A sole block body hugs the brackets (`[ for (x in xs) {` … `} ]`) only while every generator head, its iterable laid flat, fits the bracket line up to the body's `{`; past it `[`, the heads and `]` each take their own line. Beside another literal argument a comprehension is one unit with it: a run wider than a line puts each literal on its own line. A sole call argument that fits on its own line takes that line whole (`f(` / `[ for … ]` / `)`), and the brackets hug the parentheses only when it does not. A ternary breaks at `?` / `:` for a comprehension branch only when that lets the branch fit its own line; otherwise it stays glued (`c ? [] : [`) and the comprehension breaks. `false` leaves it on the generic array rules, so a multi-line comprehension keeps `[`, `for` and `]` on their own lines. Absent, it follows the comprehension padding: padded brackets (`comprehensionBrackets.openingPolicy: after` / `onlyAfter`, or `sameLine.comprehensionFor: fitLine`) mean `true`, tight brackets mean `false`. `comprehensionFor: fitLine` sets it to `true` when the key is absent. This repository pads its comprehensions with the key at `true`.

```json
"wrapping": { "comprehensionFit": false },
"whitespace": { "bracketConfig": { "comprehensionBrackets": { "openingPolicy": "onlyAfter", "closingPolicy": "onlyBefore" } } }
```

```haxe
// comprehensionFit: false — padded, the brackets keep their lines
final a = [
	for (x in xs) {
		final y = x + 1;
		y * 2;
	}
];
final c = [ for (x in xs) x ];
```

## A sole object element hugs its brackets: `wrapping.soleObjectCuddledBrackets`

`true` keeps an array literal whose only element is an object literal that breaks hugged to it: `[{` on the opening line, the fields one indent deeper than the array's line, `}]` together on the closing line. It holds in every position: a call argument (the arguments after it ride the `}]` line), a variable initializer, a return value. A list that fits stays on one line (`[{a: 1}]`). A line comment before or after the element, a second element, or an element that is not an object literal (a block expression, a nested array, a call) keeps the exploded layout. `false`, the default, puts `[` and `]` on lines of their own around the object. The wider `wrapping.soleItemCuddledBrackets` cuddles any sole element that ends in a closing delimiter, calls included; either key on cuddles an object element. This repository sets the key to `true`.

```json
"wrapping": { "soleObjectCuddledBrackets": true }
```

```haxe
// soleObjectCuddledBrackets: true
return follow(LAYOUT, json, [{
	path: "p.C",
	name: "q.D"
}], plugin);

// false
return follow(LAYOUT, json, [
	{
		path: "p.C",
		name: "q.D"
	}
], plugin);
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

## Branches of one `#if` region: `sameLine.conditionalSiblings`

`anyBreak` by default, the values of `caseSiblings`. The branches of one `#if` / `#elseif` / `#else` region share the break
decision: when any branch breaks, by its shape (two statements, two members) or because it does not fit the line, every
branch opens and closes on lines of its own. `off` lets each branch decide alone: a one-element branch stays beside its
`#if` even when it is too wide for the line, wrapping inside its member, while a longer one breaks.

```json
{ "sameLine": { "conditionalSiblings": "off" } }
```

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

## Metadata counts as a doc comment: `emptyLines.<kind>.metadataCountsAsDocComment`

`metadataCountsAsDocComment` (`true` / `false`) in `enumEmptyLines`, `typedefEmptyLines` and `enumAbstractEmptyLines`,
and at `emptyLines` level for class, interface and plain `abstract` bodies: a member whose metadata (`@:meta`,
`@:fmt(...)`) stands on a line of its own above the declaration, as a doc comment would (one annotation on a line above
it is enough: `@:keep` over `@:native("e") var e`), is laid out for blank lines as a
doc-commented member is, so `beforeDocCommentEmptyLines`, `afterFieldsWithDocComments` and `beginTypeIfDocComments` /
`endTypeIfDocComments` fire on it too. Metadata the output keeps on the declaration's line leaves a plain member, so a run
of `@:auto public var a:Signal;` lines stays tight: that is `lineEnds.metadataVar` (and its siblings) at `none` with the
source glued, or `fit` joining a lone simple annotation (counted as joined even when a long line later breaks it). A
member with both a doc comment and metadata still takes one blank line, not two. The metadata is read from the member's AST, so a
`#if` member counts only by its doc comment. Off by default (haxe-formatter has no such key):

```json
{ "emptyLines": { "typedefEmptyLines": { "metadataCountsAsDocComment": true } } }
```

## A blank line before a commented group: `emptyLines.<kind>.beforeCommentedFields`

`beforeCommentedFields` (`0` or `1`) in `enumEmptyLines`, `typedefEmptyLines` and `enumAbstractEmptyLines`, and at
`emptyLines` level for class, interface and plain `abstract` bodies. With `1`, a member that whole-line `//` comments sit
directly above takes one blank line in front of it, so a heading comment opens its group instead of sticking to the
previous one:

```haxe
enum abstract Align(String) {
	// align each item
	final NONE = 'none';

	// use item size
	final HORIZONTAL = 'horizontal';
	final VERTICAL = 'vertical';
}
```

The first member of the body is left to `beginType`. The comment stays on its member, and the other members of the
group follow by the kind's own keys. Only a run of `//` comments counts: a trailing comment on the previous member's
line, a `/* */` comment and a doc comment do not (a doc comment has `beforeDocCommentEmptyLines` and
`afterFieldsWithDocComments`), and `beforeDocCommentEmptyLines: none` on a member that counts as documented still
wins. `0` by default, which writes what the other keys say (haxe-formatter has no such key):

```json
{ "emptyLines": { "enumAbstractEmptyLines": { "existingBetweenFields": "remove", "beforeCommentedFields": 1 } } }
```

An `enum abstract` body that `abstractRulesUnlessValueList` hands to the abstract rules reads the `emptyLines` level
key, as it reads every other abstract key.

## A commented group stays glued: `emptyLines.<kind>.glueCommentedGroups`

`glueCommentedGroups` (`true` or `false`) in `enumEmptyLines` and `enumAbstractEmptyLines`, and at `emptyLines` level
for class, interface and plain `abstract` bodies. With `true`, a run of `//` comments heads a subgroup, not one member:
the members after the headed one that sit directly under it in the source keep no blank line between them, even where
`betweenVars`, `betweenFunctions` or an enum's `betweenFields` would put one. With
`beforeCommentedFields: 1` and `classEmptyLines.betweenVars: 1`:

```haxe
class Palette {
	var name:String;

	// colours
	var red:Int;
	var green:Int;
	var blue:Int;

	var alpha:Int;
}
```

The group ends at the first member that:

- has a blank line in front of it in the source — the blank stays, and that member and the ones after it follow the
  kind's own keys (`alpha` above takes `betweenVars`);
- is of another kind, such as a function after the group's vars;
- carries a comment of its own: a block comment, a doc comment or the next `//` heading;
- counts as documented — a doc comment, or metadata on its own line under `metadataCountsAsDocComment`.

The key only holds blank lines back: a blank line the author wrote is never removed, the doc-comment keys
(`beforeDocCommentEmptyLines`, `afterFieldsWithDocComments`) and `beforeCommentedFields` keep their blank lines, and
`aroundMultilineFields` still separates a member that renders over several lines. `false` by default, which writes what
the other keys say (haxe-formatter has no such key):

```json
{ "emptyLines": { "beforeCommentedFields": 1, "glueCommentedGroups": true, "classEmptyLines": { "betweenVars": 1 } } }
```

An `enum abstract` body that `abstractRulesUnlessValueList` hands to the abstract rules reads the `emptyLines` level
key. Typedef bodies have no such key.

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
lets a source trailing `,` survive in a list broken over lines, one item per line or packed to fill them, a call inside
a method chain included, and lets those keys add one there; a list that stays on one line, a call glued around a block
or collection argument, or a sole argument sharing the open delimiter's line drops a source `,` and gets none added, so
a list one pass broke and the next glues writes the same. A config that
sets `arrayLiteralDefault`, `callArgumentDefault` or `objectLiteralDefault` to `"yes"` and says nothing about
`wrapping.trailingComma` loads as `keep`, so the comma it asks for is added. A function parameter list's trailing `,`
is always dropped and a mandatory comma (`{> Base,}`) always written, whatever the key says. Details: `docs/haxe-format-config.md`.

## Lists break by the wrapping rules

An object, array or map literal and an anonymous type lay out by `wrapping.objectLiteral` / `arrayWrap` / `mapWrap` /
`anonType` alone (item count, item length, line width): a break the source put between items, grid rows included, does
not keep a list open, and the built-in fallback of those four is `ignore`. A `"defaultWrap": "noWrap"` block on one of
them lays that list out by its rules and otherwise flat, without reading source breaks, except that a grid-shaped array and, under `"rules": []`, a comprehension still follow the source. Under the other non-`ignore`
values (`onePerLine`, `fillLine`, …) an object literal and an anonymous type also lay out by the cascade alone, so a
source-broken short `{x: 1, y: 2, z: 3}` or `{x:Int, y:Int, z:Int}` glues onto one line; only an array or a map literal
still keeps a break the source put between its items. A typedef's body keeps its source lines until its own decision.
With no `wrapping.objectLiteral` key, an object literal of at most four fields, none longer than 30 characters and 60 in
all, that overflows only by what stands around it (the text before it, its siblings and closers after it) breaks at its
braces and keeps its fields on one line inside them; so does such a literal a source trailing `,` keeps open under
`trailingCommas.objectLiteralDefault`. When that line does not fit, or the literal is longer, it goes one field per line.

A `fillLine` / `fillLineWithLeadingBreak` list and a filled operator chain keep an item on its row while the row, its
`,` or closing delimiters included, is at most `maxLineLength` wide: a row of exactly the limit fits, one column more
breaks (haxe-formatter breaks one column earlier). A call that ends such a row exactly at the limit keeps its arguments flat.

## Simple operands share a line: `"type": "fillSimpleRuns"`

A `wrapping.opBoolChain` rule of type `fillSimpleRuns` breaks an overflowing `&&` / `||` chain so that each run
of consecutive simple operands fills its lines, while every other operand starts a line and ends it. Simple is a null
check or comparison of names, field reads and literals, or a plain or negated name; a call, a parenthesised
expression, an index, a collection literal, a lambda, a comment or a nested chain is not. The first operand stays on
the chain's own line, and in a chain that mixes `&&` with `||` every `||` starts a line. This repository's
`hxformat.json` takes it for `opBoolChain`; the built-in cascade keeps `onePerLineAfterFirst`.

## A literal argument: `callParameter.containerItemWrap`

When a call's argument list breaks, an array or object literal argument that carries a call takes a line of its own,
unless it is simple: at most three items, none of them a nested literal, the whole literal at most 60 characters wide.
A simple one fills the argument line with its neighbours. The test is the nested cascade `containerItemWrap` inside
`wrapping.callParameter`, measured over the literal's own items; `onePerLine` gives the literal its own line, any other
mode lets it fill. A `callParameter` block that does not name the key keeps the built-in one. Details:
`docs/haxe-format-config.md`.

## Items with type parameters: `typeParamItemCount >= n`

A wrapping rule of `anonType` or `functionSignature` may count the items whose declared type carries type parameters:
`a:Array<Int>`, `b:Null<String>`, a nested `{c:Map<K, V>}`. A function type without them (`Int->Void`) counts zero, and
a default value is not a type. A typedef body lays out by `anonType`, so "four fields on one line, three when one is
generic" is an `itemCount >= n` 5 rule beside an `itemCount >= n` 4 + `typeParamItemCount >= n` 1 rule, both
`onePerLine`. Details: `docs/haxe-format-config.md`.

## Files that hold only typedefs: `moduleOnlyTypedefs`

A wrapping rule of `typedefBody` (or `anonType`) may ask whether the module declares nothing but typedefs: `package`,
`import`, `using` lines and comments do not count, a `#if` region counts by all of its arms, and any class, enum,
abstract, interface or function makes the answer no. `{ "cond": "moduleOnlyTypedefs", "value": 1 }` beside
`{ "cond": "itemCount >= n", "value": 2 }` puts every body of two or more items, a `> Base` extension counting as one,
one item per line in such a file, while a one-field body stays on its line and a typedef next to a class keeps the fit
rules. Without the rule nothing moves. Details: `docs/haxe-format-config.md`.

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

## A ternary that ends in a block: `sameLine.ternaryTailBlockMaxThenLength`

A ternary whose else branch ends in a multi-line block breaks at `?` and `:` by default. With
`"ternaryTailBlockMaxThenLength": 20` a then branch of at most 20 columns keeps the head on one line and the block
breaks instead:

```haxe
callback(ready ? [] : updates.map(u -> {
	id: u.id,
	name: u.name
}));
```

The block is a lambda body, an object or array literal, or the last argument of a call ending in one, and it must be
multi-line on its own: a function or statement body, or a literal a wrap rule lays out one item per line
(`onePerLine`, an `itemCount` rule). A literal that breaks only because it is too wide for the line keeps the ladder.
The ladder also stays when the then branch is wider, when the head line does not fit, when the else branch breaks
before its block (call arguments laid one per line), when an argument before the block holds a block, and when the
block is in the then branch (`c ? {…} : x` would hide `: x`). `0` (the default) is off.

## Metadata placed by width: `lineEnds.metadata*: fit`

`fit` is a value of `lineEnds.metadataType`, `metadataFunction`, `metadataVar` and `metadataOther`, not part of
haxe-formatter's schema. It is decided by width and never reads the source layout:

- one simple metadata stays on the declaration's line when the declaration's head fits `wrapping.maxLineLength`, else takes a
  line of its own — and, when `lineEnds.metadataInlineMaxLength` is set, also when the metadata itself is wider than that
  (below). The head ends where the body or the initializer may break: at a var's `=`, before a body
  `sameLine.functionBody: fitLine` may move. A body or initializer that does not fit breaks first, and the metadata stays;
- several simple metadata share one line above the declaration when that row fits, and are never joined to the declaration itself;
- otherwise — a complex metadata, a row that does not fit, a comment between metadata or after the last one, a `#if` in the run — one per line, as `after`.

Simple is no argument, or exactly one that is a number, `true` / `false` / `null`, an identifier, a dotted path, a
one-line string without interpolation, or a prefix or binary operator over such operands (`@:nullSafety(Strict)`,
`@:access(pkg.Type)`, `@:xml('action')`, `@:op(A + B)`, `@:op(-A)`). A call, several arguments, an object, array or
function literal, an operator over any of them and an interpolated or multi-line string are complex. With `fit` on all four keys:

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

### A width limit for the one metadata on the declaration's line: `lineEnds.metadataInlineMaxLength`

An integer, not part of haxe-formatter's schema. Under `fit` — on all four `metadata*` keys and on a local `var` —
the one simple metadata stays on its declaration's line only when its own written text, the `@` included, is at
most this many characters; a wider one takes a line of its own above the declaration. Unset or `0` is no limit.
A row of several simple metadata is not measured by it, and nothing changes for a key that is not `fit`.

```json
{ "lineEnds": { "metadataFunction": "fit", "metadataInlineMaxLength": 20 } }
```

```haxe
@:nullSafety(Strict) function f() {}

@:describe('a sentence in plain words')
function g() {}
```

## Metadata as written: `lineEnds.metadata*: none`

`none` adds no break after a metadata, on all four `metadata*` keys and on a local `var`. Metadata written on one line
stays on it; a break the source has between two metadata stays, as one line break (a blank line between them goes);
the line of the declaration follows the source: the last metadata stays glued to it when written so. Metadata inside
a declaration (`var @:a @:b x`, `<@:a T>`) is always joined with a space. With `{ "lineEnds": { "metadataType": "none" } }`
this run is left as it is:

```haxe
@SuppressWarnings("x")
@:forward(a, b)
@:nullSafety(Strict) abstract X(Int) {}
```
