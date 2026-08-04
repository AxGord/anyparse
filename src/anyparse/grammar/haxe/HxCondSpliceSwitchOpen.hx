package anyparse.grammar.haxe;

/**
 * Statement-position token-splice conditional whose every branch opens an
 * OUTER block and, inside it, a `switch (...) {` header, with the case
 * list, the switch's closing `}` and the outer block's `}` all shared
 * after `#end`: `#if <cond> <outer-open> switch (..) { [#elseif ..] #else
 * ..] #end <cases> } }`.
 *
 * Motivating source - `std/haxe/io/Path.hx:241` (`normalize`):
 *
 * ```haxe
 * #if utf16
 * for (c in StringIteratorUnicode.unicodeIterator(tmp)) {
 * 	switch (c) {
 * #else
 * for (i in 0...tmp.length) {
 * 	switch (StringTools.fastCodeAt(tmp, i)) {
 * #end
 * 		case ":".code: acc.add(":"); colon = true;
 * 		case "/".code if (!colon): slashes = true;
 * 		case var i: acc.addChar(i);
 * 	}
 * }
 * ```
 *
 * The shared continuation is a switch CASE LIST, so the sibling
 * `HxCondSpliceBlockOpen` cannot represent it - its `body` is
 * `Array<HxStatement>` and a `case` label is not a statement, so its
 * `@:trail('}')` throws on the first `case`. Here `cases` parses the
 * shared case list structurally with its own `@:trail('}')` closing the
 * switch, and `body` parses the outer block's remaining statements (empty
 * in the motivating source) with a second `@:trail('}')` closing that
 * block - the closer the region's OUTER `{` opened.
 *
 * `raw` captures the region byte-verbatim through `#end` (see
 * `HxCondSwitchOpenRaw`), so every compilation variant survives a writer
 * round-trip. The terminal's outer-`{`-before-`switch` constraint makes
 * `HxStatement.CondSpliceSwitchOpen` disjoint from `CondSpliceBlockOpen`
 * for regions with no switch; the dispatch order (switch-open BEFORE
 * block-open) keeps the block-open ctor from stranding the case list.
 *
 * `cases` reuses `HxSwitchStmt.cases`'s `@:fmt(indentCaseLabels,
 * rightCurly)` and adds `nestBody` because the switch sits one block
 * deeper than the statement position; `body` mirrors
 * `HxCondSpliceBlockOpen.body`'s `@:fmt(nestBody, rightCurly)` +
 * `@:sep` block-Star contract.
 *
 * `cases` also reuses `HxSwitchStmt.cases`'s
 * `@:fmt(caseSiblingSymmetry('caseBody', 'expressionCase'))`
 * (omega-if-leader-case-symmetry). This shared case list IS the whole
 * switch - it is a ROOT case list, not a region nested inside one - so
 * nothing above it runs a widest-sibling pre-pass whose verdict it could
 * inherit, and without the opt-in its cases got no coordination at all
 * (probed: one over-wide body dropped below its label while its inline
 * siblings stayed put). That is the exact opposite of
 * `HxConditionalCase.body` / `elseBody` and `HxElseifCase.body`, which are
 * deliberately NOT opted in: those sit INSIDE an opted-in switch, and an
 * opted-in inner Star would run its OWN pre-pass and overwrite the
 * enclosing switch's verdict, fragmenting one switch into per-region
 * coordination.
 */
@:peg
typedef HxCondSpliceSwitchOpen = {
	var raw: HxCondSwitchOpenRaw;
	@:trail('}') @:trivia @:fmt(nestBody, indentCaseLabels, rightCurly, condSwitchOpenCasesNest,
		caseSiblingSymmetry('caseBody', 'expressionCase')) var cases: Array<HxSwitchCase>;
	@:trail('}') @:trivia @:fmt(nestBody, rightCurly, emptyBlockBreak) @:sep(';', tailRelax, blockEnded(
		'stmtNoSemi', sepStartsElement
	)) var body: Array<HxStatement>;
}
