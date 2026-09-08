package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * omega-fnlambda-body-width: a `function`-keyword anonymous-function item whose body carries no forced break parks that body behind
 * a `BodyGroup` (`sameLine.ifBody: fitLine` and its siblings), and the static width measures - `DocMeasure.flatTokenWidth`,
 * `Renderer.fitsFlat` - DEFER a `BodyGroup` to width 0. The item therefore under-measures by the whole body, and each width-only
 * cascade above it reads a line that is short by exactly that much: `callParameter`'s `exceedsMaxLineLength`, `methodChain`'s
 * `lineLength >= n`, and the statement's own `ifBody: fitLine` fit all answer "it fits" for a line that does not. The render side
 * cannot repair it either - `shapeNoWrap` wraps a committed body in `Flatten` and `Renderer.pushStructural` skips `fitsFlat` under
 * force-flat - so the result is a FIXED POINT of any width.
 *
 * Numbers, each a reading of the artefact named. The reduction the defect was first measured on (Pony identifiers, statement at two
 * tabs) sat at 146 columns under `maxLineLength: 140`, against 141 for its arrow twin, which broke correctly - the one-variable
 * probe, the only difference being the lambda spelling. THIS file's controls are a second reduction with synthetic identifiers: 159
 * columns for the plain case and 420 for the 260-character body, both fixed points before the slice. The Pony SITE itself is not
 * over the limit - it sits at exactly 140 with the `+` continuation laid at the STATEMENT's own indent, which
 * `testTheConcatenatedThrowNoLongerContinuesAtTheStatementIndent` is the reduction of.
 *
 * The mechanism that fixes it was never missing, only GATED on the ARROW spelling: `WrapList.emit` already re-tags a hardline-free
 * `BodyGroup` inside an item as a `Group` that `pushStructural` resolves identically (`groupifyInlineBodies`), and its gate
 * `isArrowPlainIfBody` requires an arrow-lambda marker. `isFunctionInlineBodyItem` opens the same gate to the `function` spelling -
 * the exact complement of `isFunctionBlockLambdaItem` on the `flatLength` axis, so a BLOCK body, which owns its own layout and hugs,
 * is excluded by construction.
 *
 * The two gates coincide only for a plain `if` body: the new one accepts any hardline-free body, `isArrowPlainIfBody` still demands
 * `if` with no top-level `else`. So for a `for` / `while` / `switch` / `if`-`else` body the `function` spelling now measures and the
 * arrow spelling does not (T875) - measured under Pony's own `hxformat.json`, where `function(r) for (q in r) f(q)` goes from a
 * 149-column line to a correct break while `(r) -> for (q in r) f(q)` is byte-identical on both engines. Not a regression, and no
 * fixture here: under THIS file's config both spellings already break correctly for that body, so a fixture would be vacuous.
 *
 * Identifiers are fully synthetic. Every case asserts idempotence as well as the shape.
 */
@:nullSafety(Strict)
final class HxFunctionLambdaBodyWidthSliceTest extends Test {

	/**
	 * The Pony-shaped config the site is written under: tab indent,
	 * `maxLineLength` 140, `ifBody: fitLine` (what parks the lambda's `if` body
	 * behind a `BodyGroup`), and the three cascades that read the under-measured
	 * width — `callParameter`, `methodChain` and `opAddSubChain`.
	 */
	private static final CFG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {'
		+ '"maxLineLength": 140, "methodChainCuddledLinks": true, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": ['
		+ '{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}, "methodChain": {'
		+ '"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "lineLength >= n", "value": 140}], "type": "onePerLineAfterFirst"}, '
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "onePerLineAfterFirst"}]}, "mapWrap": {'
		+ '"defaultWrap": "ignore", "rules": [{"conditions": [{"cond": "totalItemLength <= n", "value": 80}], "type": "noWrap"}, {'
		+ '"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "onePerLine"}]}, "opAddSubChain": {'
		+ '"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {'
		+ '"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}]}}, "whitespace": '
		+ '{"typeHintColonPolicy": "after", "typeCheckColonPolicy": "after"}, "sameLine": {"ifBody": "fitLine", '
		+ '"forBody": "fitLine", "whileBody": "fitLine", "functionBody": "fitLine", "caseBody": "fitLine"}}';

	/** Statement prefix: a method body at two tabs. */
	private static final HEAD: String = 'class M {\n\tfunction save() {\n\t\t';

	/** Statement suffix. */
	private static final TAIL: String = '\n\t}\n}';

	/** The two-link chain whose last argument is the lambda under test. */
	private static final CHAIN: String = 'store.where(owner == keyValue && slot == itemKey).update([\'value\' => (a: DbValue)], ';

	public function new(): Void {
		super();
	}

	/**
	 * THE motivating shape, reduced from `pony.net.http.ServersideStorageDB.save()`:
	 * a statement-`if` whose body is a two-link chain whose last argument is
	 * `function(r) if (!r) throw '…'`. At 159 columns it was a FIXED POINT — the
	 * writer re-emitted it unchanged, over the limit, because the parked `throw`
	 * was invisible to all three cascades. With the body's width visible the
	 * statement-`if` moves its body to its own line (`ifBody: fitLine`), the chain
	 * still does not fit at five tabs so `methodChain` goes `onePerLineAfterFirst`,
	 * and `.update(…)` lands at 100 columns.
	 */
	@:pin('control')
	@:killer('M-FN-LAMBDA-BODY-DEFERRED')
	public function testStatementIfWithFunctionLambdaIfBodyBreaksInsteadOfOverflowing(): Void {
		assertWrite(
			'${HEAD}if (a != orig[k])\n\t\t\tstore.where(owner == keyValue && slot == itemKey)\n\t\t\t\t'
			+ '.update([\'value\' => (a: DbValue)], function(r) if (!r) throw \'storage save failed\');$TAIL',
			'${HEAD}if (a != orig[k]) ${CHAIN}function(r) if (!r) throw \'storage save failed\');$TAIL'
		);
	}

	/**
	 * The width is not a threshold effect: with a 260-character body the same
	 * shape was ALSO a fixed point, at 420 columns. Every break point the
	 * construct owns now fires — the statement body, the call parens, the
	 * lambda's own `fitLine` body — and what is left over the limit is one
	 * unbreakable string literal.
	 */
	@:pin('control')
	@:killer('M-FN-LAMBDA-BODY-DEFERRED')
	public function testAFourHundredColumnFunctionLambdaBodyBreaksEveryPointItOwns(): Void {
		final long: String = 'storage save failed ' + repeat('x', 260);
		assertWrite(
			'${HEAD}if (a != orig[k])\n\t\t\tstore.where(owner == keyValue && slot == itemKey).update(\n\t\t\t\t'
			+ '[\'value\' => (a: DbValue)],\n\t\t\t\tfunction(r) if (!r)\n\t\t\t\t\tthrow \'$long\'\n\t\t\t);$TAIL',
			'${HEAD}if (a != orig[k]) ${CHAIN}function(r) if (!r) throw \'$long\');$TAIL'
		);
	}

	/**
	 * The user's actual bytes: the throw is an `opAddSubChain`. Pre-slice the
	 * statement stayed glued and the chain broke before its first `+`, laying the
	 * continuation at the STATEMENT's own indent (two tabs, the same column as the
	 * `if`) — `Nest` bumps are skipped in MFlat, so the `Fill` broke under the
	 * nearest MBreak frame, which was the statement. With the width visible the
	 * outer breaks first and the whole `+` chain fits on the `.update(…)` line.
	 */
	@:pin('control')
	@:killer('M-FN-LAMBDA-BODY-DEFERRED')
	public function testTheConcatenatedThrowNoLongerContinuesAtTheStatementIndent(): Void {
		assertWrite(
			'${HEAD}if (a != orig[k])\n\t\t\tstore.where(owner == keyValue && slot == itemKey)\n\t\t\t\t'
			+ '.update([\'value\' => (a: DbValue)], function(r) if (!r) throw \'storage \' + \'save \' + \'failed\');$TAIL',
			'${HEAD}if (a != orig[k]) ${CHAIN}function(r) if (!r) throw \'storage \' + \'save \' + \'failed\');$TAIL'
		);
	}

	/**
	 * The same continuation-indent defect without an enclosing `if`: a bare call
	 * statement. Pre-slice the call stayed glued at the statement indent and only
	 * the `+` chain broke, at that same indent; now the argument list opens and
	 * the continuation sits under the argument it belongs to.
	 */
	@:pin('control')
	@:killer('M-FN-LAMBDA-BODY-DEFERRED')
	public function testABareCallStatementOpensItsArgumentListInsteadOfSplittingTheChain(): Void {
		final pad: String = 'failed ' + repeat('y', 44);
		final tailLit: String = repeat('z', 22);
		assertWrite(
			'${HEAD}store.update(\n\t\t\t[\'value\' => (a: DbValue)],\n\t\t\tfunction(r) if (!r) throw \'storage \' + \'save \' + \'$pad'
			+ '\'\n\t\t\t+ \'$tailLit\'\n\t\t);$TAIL',
			'${HEAD}store.update([\'value\' => (a: DbValue)], function(r) if (!r) throw \'storage \' + \'save \' + \'$pad\' + \'$tailLit'
			+ '\');$TAIL'
		);
	}

	/**
	 * GUARD: a lambda whose body is a `{}`-block carries a hardline, so
	 * `flatLength(item) < 0` — `isFunctionBlockLambdaItem`, the complement — and
	 * the re-tag never reaches it. The block owns its layout and the head stays
	 * glued. Holds with the slice reverted.
	 */
	@:pin('guard')
	public function testABlockBodiedFunctionLambdaKeepsItsGluedHead(): Void {
		assertWrite(
			'${HEAD}if (a != orig[k]) store.where(owner == keyValue && slot == itemKey).update([\'value\' => (a: DbValue)], function(r) {'
			+ '\n\t\t\tif (!r) throw \'storage save failed\';\n\t\t});$TAIL',
			'${HEAD}if (a != orig[k]) ${CHAIN}function(r) { if (!r) throw \'storage save failed\'; });$TAIL'
		);
	}

	/**
	 * GUARD: a lambda body that parks nothing (`return <expr>`) already measured
	 * at full width, so its layout is untouched by the re-tag. Holds with the
	 * slice reverted — it states that the fix adds no width where none was hidden.
	 */
	@:pin('guard')
	public function testAReturnBodiedFunctionLambdaIsUnchanged(): Void {
		assertWrite(
			'${HEAD}if (a != orig[k])\n\t\t\tstore.where(owner == keyValue && slot == itemKey)\n\t\t\t\t'
			+ '.update([\'value\' => (a: DbValue)], function(r) return reportOutcome(r, \'storage save\'));$TAIL',
			'${HEAD}if (a != orig[k]) ${CHAIN}function(r) return reportOutcome(r, \'storage save\'));$TAIL'
		);
	}

	/**
	 * GUARD: the ARROW spelling of the same body went through
	 * `isArrowPlainIfBody` before this slice and must keep its bytes — the gate
	 * was widened, not rewritten. Holds with the slice reverted.
	 */
	@:pin('guard')
	public function testTheArrowSpellingOfTheSameBodyIsUnchanged(): Void {
		assertWrite(
			'${HEAD}if (a != orig[k])\n\t\t\tstore.where(owner == keyValue && slot == itemKey).update([\'value\' => (a: DbValue)], (r) '
			+ '-> if (!r) throw \'storage save failed\');$TAIL',
			'${HEAD}if (a != orig[k]) store.where(owner == keyValue && slot == itemKey).update([\'value\' => (a: DbValue)], (r) '
			+ '-> if (!r) throw \'storage save failed\');$TAIL'
		);
	}

	/**
	 * GUARD: a `function`-lambda argument whose whole statement FITS keeps its one
	 * line. The re-tag changes measurement only, so revealing a width that is
	 * still inside the limit must move nothing.
	 */
	@:pin('guard')
	public function testAFittingFunctionLambdaArgumentStaysOnOneLine(): Void {
		final src: String =
			'${HEAD}if (a != orig[k]) store.update([\'value\' => (a: DbValue)], function(r) if (!r) throw \'storage save failed\');$TAIL';
		assertWrite(src, src);
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CFG);
	}

	private function assertWrite(expected: String, src: String): Void {
		final out: String = triviaWrite(src);
		Assert.equals(expected, out);
		Assert.equals(out, triviaWrite(out));
	}

	/** `n` copies of `ch` — the long bodies these fixtures need without a `StringTools` static call. */
	private static inline function repeat(ch: String, n: Int): String {
		return [for (i in 0...n) ch].join('');
	}

}
