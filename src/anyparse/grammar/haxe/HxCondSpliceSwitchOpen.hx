package anyparse.grammar.haxe;

/**
 * Statement-position token-splice conditional whose every branch opens an OUTER block and,
 * inside it, a `switch (...) {` header, with the case list, the switch's closing `}` and the
 * outer block's `}` all shared after `#end`: `#if <cond> <outer-open> switch (..) { [#elseif
 * ..] #else ..] #end <cases> } }`:
 *
 * ```haxe
 * #if utf16
 * for (c in StringIteratorUnicode.unicodeIterator(tmp)) {
 * 	switch (c) {
 * #else
 * for (i in 0...tmp.length) {
 * 	switch (StringTools.fastCodeAt(tmp, i)) {
 * #end
 * 		case var i: acc.addChar(i);
 * 	}
 * }
 * ```
 *
 * The shared continuation is a switch CASE LIST, so the sibling `HxCondSpliceBlockOpen`
 * cannot represent it — its `body` is `Array<HxStatement>` and a `case` label is not a
 * statement. Here `cases` parses the shared case list structurally with its own
 * `@:trail('}')` closing the switch, and `body` parses the outer block's remaining statements
 * with a second `@:trail('}')` closing that block — the closer the region's OUTER `{` opened.
 * `raw` captures the region byte-verbatim through `#end` (see `HxCondSwitchOpenRaw`, whose
 * outer-`{`-before-`switch` constraint keeps this ctor disjoint from `CondSpliceBlockOpen`
 * for regions with no switch; the dispatch order, switch-open BEFORE block-open, keeps the
 * block-open ctor from stranding the case list).
 *
 * `cases` reuses `HxSwitchStmt.cases`'s `@:fmt(indentCaseLabels, rightCurly)` and adds
 * `nestBody` because the switch sits one block deeper than the statement position; `body`
 * mirrors `HxCondSpliceBlockOpen.body`'s `@:fmt(nestBody, rightCurly)` + `@:sep` block-Star
 * contract. `cases` also reuses `@:fmt(caseSiblingSymmetry('caseBody', 'expressionCase'))`
 * (omega-if-leader-case-symmetry): this shared case list IS the whole switch — a ROOT case
 * list, not a region nested inside one — so nothing above it runs a widest-sibling pre-pass
 * whose verdict it could inherit, and without the opt-in one over-wide body dropped below
 * its label while its inline siblings stayed put. The opposite of `HxConditionalCase.body` /
 * `elseBody` and `HxElseifCase.body`, which sit INSIDE an opted-in switch and must not run
 * their OWN pre-pass over the enclosing switch's verdict.
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
