package unit.format;

import unit.grammar.haxe.HxWriteFixture;
import utest.Assert;
import utest.Test;

/**
 * `whitespace.bracesConfig.singleStatementBraces: "symmetric"` - the ADD direction of a policy
 * that until now only ever removed.
 *
 * The user decided it (2026-09-03), choosing the ADD direction, with the boundary stated:
 * an if/else with EXACTLY ONE braced branch gets the other braced; a bare single statement with
 * NO braced sibling is left alone. That second half is what makes this not "brace everything" -
 * Pony's `if (d.length != 4) throw '…';` must survive untouched, and `testABareBranchWithNoBracedSiblingIsUntouched`
 * is its pin.
 *
 * The value rides the SAME sibling probe the `remove` direction has always used (gate 7's
 * `siblingKeepsBraces`), so the two directions cannot drift apart: `"remove"` arms both,
 * `"symmetric"` only the repair, `"keep"` neither. `else if` and - per the same user's other
 * decision - `else switch` are exempt, because braces there would rebuild the very
 * `else { if … }` the chain form exists to avoid.
 *
 * Trivia writer throughout: the plain writer captures no source-newline slots, so a
 * "left alone" assertion against it passes vacuously.
 */
@:nullSafety(Strict)
class BraceSymmetrySliceTest extends Test {

	private static final BASE: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140}';
	private static final KEEP: String = '$BASE}';
	private static final SYMMETRIC: String = '$BASE, "whitespace": {"bracesConfig": {"singleStatementBraces": "symmetric"}}}';
	private static final REMOVE: String = '$BASE, "whitespace": {"bracesConfig": {"singleStatementBraces": "remove"}}}';
	private static final SYMMETRIC_NEXT: String =
		'$BASE, "sameLine": {"expressionIf": "next"}, "whitespace": {"bracesConfig": {"singleStatementBraces": "symmetric"}}}';

	/** The MegaSaveBuilder shape, already canonical under `SYMMETRIC` — see `testAMacroReificationIsNotBraced`. */
	private static final MACRO_TRY: String =
		'class C {\n\tmacro function f() {\n\t\te = macro try $$b{exprs} catch (err:Dynamic) {\n\t\t\tq();\n\t\t\tr();\n\t\t};\n\t}\n}';

	public function testThenBracedElseBareGainsBraces(): Void {
		final out: String = HxWriteFixture.triviaWrite(wrap('if (a) {\n\t\t\tp();\n\t\t\tq();\n\t\t} else\n\t\t\tr();'), SYMMETRIC);
		Assert.isTrue(out.indexOf('} else {') != -1, 'the bare else must gain braces in: <$out>');
		Assert.isTrue(out.indexOf('r();') != -1, 'its statement must survive in: <$out>');
	}

	public function testThenBareElseBracedGainsBraces(): Void {
		final out: String = HxWriteFixture.triviaWrite(wrap('if (a)\n\t\t\tp();\n\t\telse {\n\t\t\tq();\n\t\t\tr();\n\t\t}'), SYMMETRIC);
		Assert.isTrue(out.indexOf('if (a) {') != -1, 'the bare then must gain braces in: <$out>');
	}

	/** The boundary the user drew: no braced sibling, nothing to be symmetric WITH, no change. */
	public function testABareBranchWithNoBracedSiblingIsUntouched(): Void {
		final src: String = wrap('if (d.length != 4)\n\t\t\tthrow \'bad\';');
		Assert.equals(HxWriteFixture.triviaWrite(src, KEEP), HxWriteFixture.triviaWrite(src, SYMMETRIC));
	}

	public function testBothBranchesBareIsUntouched(): Void {
		final src: String = wrap('if (a)\n\t\t\tp();\n\t\telse\n\t\t\tq();');
		Assert.equals(HxWriteFixture.triviaWrite(src, KEEP), HxWriteFixture.triviaWrite(src, SYMMETRIC));
	}

	/** An `else if` link is EXEMPT — bracing it rebuilds the `else { if … }` the chain avoids. */
	public function testAnElseIfLinkIsExempt(): Void {
		final out: String = HxWriteFixture.triviaWrite(wrap('if (a) {\n\t\t\tp();\n\t\t} else if (b)\n\t\t\tq();'), SYMMETRIC);
		Assert.isTrue(out.indexOf('} else if (b)') != -1, 'the else-if link must stay a link in: <$out>');
		Assert.isTrue(out.indexOf('else {') == -1, 'the link must not be wrapped in a block in: <$out>');
	}

	/** An `else switch` is exempt for the same reason — the user asked for `} else switch s {`. */
	public function testAnElseSwitchIsExempt(): Void {
		final src: String = wrap('if (a) {\n\t\t\tp();\n\t\t} else\n\t\t\tswitch s {\n\t\t\t\tcase _:\n\t\t\t\t\tq();\n\t\t\t}');
		final out: String = HxWriteFixture.triviaWrite(src, SYMMETRIC);
		Assert.isTrue(out.indexOf('else {') == -1, 'the switch else-body must not be wrapped in a block in: <$out>');
	}

	/**
	 * A `switch` in the else of a VALUE `if` is exempt too — the value path has its own skip
	 * list, spelled in the grammar as `@:fmt(valueBraceSymmetry(…))`'s tail, and it named only
	 * `IfExpr`. Found by the Pony sweep, not by a fixture: `pony/color/UColor.hx:216` came out
	 * `} else {` + `switch s {` instead of `} else switch s {`, because the statement skip list
	 * and the value one are two lists and only the first had been taught about `switch`.
	 */
	public function testAValueIfElseSwitchIsExempt(): Void {
		final src: String = 'class C {\n\tfunction f(s:String):Int {\n\t\treturn if (s == \'\') {\n\t\t\tp();\n\t\t\t0;\n'
			+ '\t\t} else\n\t\t\tswitch s {\n\t\t\t\tcase _:\n\t\t\t\t\t1;\n\t\t\t}\n\t}\n}';
		final out: String = HxWriteFixture.triviaWrite(src, SYMMETRIC);
		Assert.isTrue(out.indexOf('else {') == -1, 'the value-if switch else-body must not be wrapped in a block in: <$out>');
	}

	/** A comment trailing the bare branch travels INTO the block the repair creates. */
	public function testATrailingCommentOnTheBareBranchSurvives(): Void {
		final out: String = HxWriteFixture.triviaWrite(wrap('if (a) {\n\t\t\tp();\n\t\t\tq();\n\t\t} else\n\t\t\tr(); // why'), SYMMETRIC);
		Assert.isTrue(out.indexOf('// why') != -1, 'the comment must survive the wrap in: <$out>');
	}

	/** `keep` is the default and is byte-inert on every shape above. */
	public function testKeepChangesNothing(): Void {
		final src: String = wrap('if (a) {\n\t\t\tp();\n\t\t\tq();\n\t\t} else\n\t\t\tr();');
		Assert.equals(src, HxWriteFixture.triviaWrite(src, KEEP));
	}

	/**
	 * `remove` still does BOTH: it de-braces where it can and repairs the asymmetry it cannot.
	 * Splitting the field must not split the behaviour of the value that already existed.
	 */
	public function testRemoveStillRepairsAsymmetry(): Void {
		final out: String = HxWriteFixture.triviaWrite(wrap('if (a) {\n\t\t\tp();\n\t\t\tq();\n\t\t} else\n\t\t\tr();'), REMOVE);
		Assert.isTrue(out.indexOf('} else {') != -1, 'remove must still brace the bare sibling in: <$out>');
	}

	/**
	 * T507 — a value-`if` then-branch that the repair WRAPS must not also re-emit the `;` the
	 * source wrote after it. The `;` lives in the grammar's `@:trailOpt(';')` slot; the wrap lifts
	 * the branch expression into an `ExprStmt` inside a synthesized block, which carries the
	 * terminator itself, so emitting the slot as well puts a second `;` after the closing brace.
	 *
	 * Found by the Pony sweep, not by a fixture: `pony/text/ParseBoy.hx` and
	 * `pony/text/tpl/TplPut.hx` came out `};` on the line before `else`. Haxe accepts it (the
	 * whole library typechecked and its 142 munit tests passed on the swept tree), so nothing but
	 * a human reading the diff could have caught it.
	 *
	 * The first assertion is the VACUITY GUARD: with the wrap not firing at all there would be no
	 * `};` either and the second assertion would pass on a writer that does nothing.
	 */
	public function testAWrappedValueThenBranchDropsItsSourceSemicolon(): Void {
		final out: String = HxWriteFixture.triviaWrite(valueIf('p();'), SYMMETRIC);
		Assert.isTrue(out.indexOf('if (a) {') != -1, 'the wrap must have fired at all in: <$out>');
		Assert.isTrue(out.indexOf('};') == -1, 'the source `;` must not survive the wrap in: <$out>');
	}

	/** The same pin in the shape the field report carries — `sameLine.expressionIf: "next"`, where the `};` got its own line. */
	public function testTheSemicolonDropAlsoHoldsUnderExpressionIfNext(): Void {
		final out: String = HxWriteFixture.triviaWrite(valueIf('p();'), SYMMETRIC_NEXT);
		Assert.isTrue(out.indexOf('if (a) {') != -1, 'the wrap must have fired at all in: <$out>');
		Assert.isTrue(out.indexOf('};') == -1, 'the source `;` must not survive the wrap in: <$out>');
	}

	/**
	 * The other side of the same gate, and the reason the drop is conditioned on the wrap rather
	 * than made unconditional the way the STATEMENT side does it (`emitMandatoryRefTrail` drops the
	 * slot of every `@:fmt(dropSingleStmtBraces)` field outright): with no braced sibling nothing
	 * is wrapped and the source's `;` must survive verbatim.
	 */
	public function testAnUnwrappedValueThenBranchKeepsItsSourceSemicolon(): Void {
		final src: String = 'class C {\n\tfunction f(a:Bool):Int {\n\t\treturn if (a) p(); else q();\n\t}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, SYMMETRIC));
	}

	/**
	 * The correctness condition behind that: with NO `else`, the value-`if` ate the ENCLOSING
	 * statement's terminator on the way in and the same slot is the only place the grammar has to
	 * park it. Dropping it here would emit code that does not compile.
	 */
	public function testAnElselessValueIfKeepsItsSemicolon(): Void {
		final src: String = 'class C {\n\tfunction f(a:Bool):Void {\n\t\tfinal x:Int = if (a) 1;\n\t\ttrace(x);\n\t}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, SYMMETRIC));
	}

	/**
	 * T508 — inside a `macro …` reification the code is DATA, so a brace level is part of the
	 * value the macro returns, not layout. `pony/magic/builder/MegaSaveBuilder.hx` came out
	 * `macro try { $b{exprs}; } catch (…)`, i.e. `EBlock(exprs)` → `EBlock([EBlock(exprs)])` — an
	 * added scope in every class that build-macro touches, with no test in Pony that runs it.
	 *
	 * `@:fmt(clearBracePolicy)` on `HxExpr.MacroExpr` / `MacroClassExpr` clears BOTH brace knobs
	 * for the reified subtree, so the whole policy — wrap and de-brace alike — is inert there.
	 */
	public function testAMacroReificationIsNotBraced(): Void {
		Assert.equals(MACRO_TRY, HxWriteFixture.triviaWrite(MACRO_TRY, SYMMETRIC));
	}

	/**
	 * The KILLER control for the pin above: the identical construct with the `macro` keyword
	 * removed must still be repaired. Without it the pin passes on an engine whose try/catch
	 * symmetry is simply broken or switched off.
	 */
	public function testTheSameTryOutsideAMacroIsStillBraced(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\ttry p() catch (err:Dynamic) {\n\t\t\tq();\n\t\t\tr();\n\t\t}\n\t}\n}';
		final out: String = HxWriteFixture.triviaWrite(src, SYMMETRIC);
		Assert.isTrue(out.indexOf('try {') != -1, 'the bare try body must gain braces outside a macro in: <$out>');
	}

	/** The reification barrier covers the value-`if` repair too, not only the try/catch group. */
	public function testAValueIfInsideAMacroIsNotBraced(): Void {
		final src: String = 'class C {\n\tmacro function f() {\n\t\te = macro if (a) p(); else {\n\t\t\tq();\n\t\t\tr();\n\t\t}\n\t}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, SYMMETRIC));
	}

	/** …and the DE-brace direction, which changes the emitted AST by exactly as much in reverse. */
	public function testAMacroReificationIsNotDeBraced(): Void {
		final src: String = 'class C {\n\tmacro function f() {\n\t\te = macro {\n\t\t\tif (a) {\n\t\t\t\tp();\n\t\t\t}\n\t\t};\n\t}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, REMOVE));
	}

	/** The KILLER control for the de-brace half: the same block outside a reification does lose its braces. */
	public function testTheSameBlockOutsideAMacroIsStillDeBraced(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tif (a) {\n\t\t\tp();\n\t\t}\n\t}\n}';
		final out: String = HxWriteFixture.triviaWrite(src, REMOVE);
		Assert.isTrue(out.indexOf('if (a) {') == -1, 'the block must de-brace outside a macro in: <$out>');
		Assert.isTrue(out.indexOf('p();') != -1, 'and its statement must survive in: <$out>');
	}

	/**
	 * T505 — the WRAP direction keeps two skip lists, one per position:
	 * `SingleStmtBraces.SYMMETRY_WRAP_SKIP_CTORS` (`IfStmt` / `SwitchStmt` / `SwitchStmtBare`) for
	 * a statement branch, and the tail of `@:fmt(valueBraceSymmetry(…))` (`IfExpr` / `SwitchExpr` /
	 * `SwitchExprBare` / `ObjectLit`) for a value one. Teaching one does not teach the other, and
	 * that is exactly how the `UColor.hx` defect shipped: `switch` reached the statement list and
	 * not the value one, and only the Pony sweep noticed.
	 *
	 * The lists cannot simply be merged — they are keyed on ctor NAMES, and the two positions have
	 * different ctors. What they must agree on is the ANSWER, so this pin asks each ctor family in
	 * both positions and compares the verdicts. `ObjectLit` is the one legitimate asymmetry and is
	 * therefore not a row: a `{` in statement position opens a block, so the value list's fourth
	 * entry has no statement twin to disagree with.
	 *
	 * "Wrapped" is measured as `symmetric` differing from `keep`, not by looking for braces in the
	 * output — the repair is the only thing `symmetric` does, so the inequality IS the verdict and
	 * the pin never has to know what either layout looks like.
	 */
	public function testTheStatementAndValueSkipListsAgree(): Void {
		final rows: Array<{ name: String, stmt: String, value: String }> = [
			{ name: 'a bare call', stmt: stmtIf('p();'), value: valueIf('p();') },
			{
				// Both link bodies are ALREADY braced, so the CHAIN-symmetry mechanism
				// (`SingleStmtBraces.chainForcesBraces`, statement side only) has nothing to add and the
				// row asks the skip lists alone: would the `else if` LINK itself be wrapped in a block?
				name: 'an else-if link',
				stmt: 'class C {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a) {\n\t\t\tp();\n\t\t\tq();\n\t\t} else if (b) {\n'
					+ '\t\t\tr();\n\t\t}\n\t}\n}',
				value: 'class C {\n\tfunction f(a:Bool, b:Bool):Int {\n\t\treturn if (a) {\n\t\t\tp();\n\t\t\t0;\n\t\t} else if (b) {\n'
					+ '\t\t\tr();\n\t\t\t1;\n\t\t}\n\t}\n}'
			},
			{
				name: 'an else switch',
				stmt: 'class C {\n\tfunction f(a:Bool, s:String):Void {\n\t\tif (a) {\n\t\t\tp();\n\t\t\tq();\n\t\t} else\n'
					+ '\t\t\tswitch s {\n\t\t\t\tcase _:\n\t\t\t\t\tr();\n\t\t\t}\n\t}\n}',
				value: 'class C {\n\tfunction f(a:Bool, s:String):Int {\n\t\treturn if (a) {\n\t\t\tp();\n\t\t\t0;\n\t\t} else\n'
					+ '\t\t\tswitch s {\n\t\t\t\tcase _:\n\t\t\t\t\t1;\n\t\t\t}\n\t}\n}'
			},
			{
				name: 'a try/catch',
				stmt: 'class C {\n\tfunction f(a:Bool):Void {\n\t\tif (a)\n\t\t\ttry\n\t\t\t\tp()\n\t\t\tcatch (e:Dynamic)\n'
					+ '\t\t\t\tq();\n\t\telse {\n\t\t\tr();\n\t\t\ts();\n\t\t}\n\t}\n}',
				value: 'class C {\n\tfunction f(a:Bool):Int {\n\t\treturn if (a)\n\t\t\ttry\n\t\t\t\tp()\n\t\t\tcatch (e:Dynamic)\n'
					+ '\t\t\t\tq()\n\t\telse {\n\t\t\tr();\n\t\t\t0;\n\t\t}\n\t}\n}'
			}
		];
		var anyWrapped: Bool = false;
		var anySkipped: Bool = false;
		for (row in rows) {
			final inStmt: Bool = repairs(row.stmt);
			final inValue: Bool = repairs(row.value);
			Assert.equals(
				inStmt, inValue, '${row.name}: statement position answered $inStmt, value position $inValue — the two skip lists disagree'
			);
			if (inStmt)
				anyWrapped = true
			else
				anySkipped = true;
		}
		// VACUITY GUARD: with every row answering the same way the comparison above is free.
		Assert.isTrue(anyWrapped, 'no row was repaired — the matrix cannot discriminate');
		Assert.isTrue(anySkipped, 'no row was skipped — the matrix cannot discriminate');
	}

	public function testTheRepairIsIdempotent(): Void {
		final once: String = HxWriteFixture.triviaWrite(wrap('if (a) {\n\t\t\tp();\n\t\t\tq();\n\t\t} else\n\t\t\tr();'), SYMMETRIC);
		Assert.equals(once, HxWriteFixture.triviaWrite(once, SYMMETRIC));
	}

	private function wrap(body: String): String {
		return 'class C {\n\tfunction f(a:Bool, b:Bool, d:String, s:String):Void {\n\t\t$body\n\t}\n}';
	}

	/** Did `symmetric` move this source? The repair is all it does, so the inequality IS the wrap verdict. */
	private static function repairs(src: String): Bool {
		return HxWriteFixture.triviaWrite(src, KEEP) != HxWriteFixture.triviaWrite(src, SYMMETRIC);
	}

	/** A statement-position `if` whose then-branch is `body` and whose else is a two-statement block. */
	private static function stmtIf(body: String): String {
		return 'class C {\n\tfunction f(a:Bool):Void {\n\t\tif (a)\n\t\t\t$body\n\t\telse {\n\t\t\tq();\n\t\t\tr();\n\t\t}\n\t}\n}';
	}

	/** The value-position twin of `stmtIf` — same branches, in a `return`. */
	private static function valueIf(body: String): String {
		return 'class C {\n\tfunction f(a:Bool):Int {\n\t\treturn if (a)\n\t\t\t$body\n\t\telse {\n\t\t\tq();\n\t\t\t0;\n\t\t}\n\t}\n}';
	}

}
