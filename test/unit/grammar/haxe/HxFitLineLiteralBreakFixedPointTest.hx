package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

using StringTools;

/**
 * An object literal that decides its own break inside a `fitLine` statement body is laid out in one write as the next
 * write reads it back.
 *
 * An object literal's Star force-commits a source-multi-line literal, so the next write reads a broken literal as a
 * body that cannot render flat and glues it, wrapping the header if the glued line needs the room. The write before it
 * measured a flat body and moved it to the next line. The literal is now named (`BreakCommits.named`), and the chain
 * and the `fitLine` host around it offer the read-back layout for the measure render to pick, so the source's line
 * shape no longer decides the placement.
 */
@:nullSafety(Strict)
final class HxFitLineLiteralBreakFixedPointTest extends Test {

	/** The first `k` of the width sweep: every shape is flat below it. */
	private static inline final MIN_K: Int = 40;

	/** The last `k` of the width sweep: past it the literal's own field no longer fits a line. */
	private static inline final MAX_K: Int = 120;

	/** The width knobs under which the defect stood: fit-line bodies, a threshold rule on object literals, a wrapping ternary. */
	private static final CFG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "sameLine": {'
		+ '"ifBody": "fitLine", "forBody": "fitLine", "whileBody": "fitLine"}, "wrapping": {"maxLineLength": 140, "objectLiteral": {'
		+ '"defaultWrap": "onePerLine", "rules": [{"conditions": [{"cond": "totalItemLength <= n", "value": 140}], "type": "noWrap"}]}, '
		+ '"conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": ['
		+ '{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}, "ternaryExpression": {"defaultWrap": "noWrap", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "onePerLineAfterFirst", "location": "beforeLast"}]}}}';

	private static final HEADER: String = "for (keyword in [IMPORT_WORD, USING_WORD]) if (line == keyword || line.startsWith('$keyword '))";
	private static final TERNARY: String = 'usingFlag && keyword == IMPORT_WORD';
	private static final FIELDS: String = 'keyword: keyword, path: withoutSemicolon(line.substr(keyword.length).trim())';

	/** The braceless form settled on: the literal glued behind the ternary, the condition wrapped to make it fit. */
	private static final SETTLED: String = 'class C {\n\tfunction f() {\n\t\tfor (keyword in [IMPORT_WORD, USING_WORD]) if (\n'
		+ '\t\t\tline == keyword || line.startsWith(\'$$keyword \')\n\t\t) return usingFlag && keyword == IMPORT_WORD ? null : {\n'
		+ '\t\t\tkeyword: keyword,\n\t\t\tpath: withoutSemicolon(line.substr(keyword.length).trim())\n\t\t};\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** Every source spelling of the braceless ternary body lands on one layout, and that layout is its own fixed point. */
	@:pin('control')
	@:killer('M-CHAIN-LITERAL-NAMED')
	public function testTheBracelessTernaryBodySettlesInOneWrite(): Void {
		for (src in [
			statement('$HEADER return $TERNARY ? null : { $FIELDS };'),
			statement('$HEADER\n\t\t\treturn $TERNARY ? null : { $FIELDS };'),
			statement('$HEADER return $TERNARY\n\t\t\t? null\n\t\t\t: { $FIELDS };')
		]) Assert.equals(SETTLED, HxWriteFixture.triviaWrite(src, CFG), src);
		Assert.equals(SETTLED, HxWriteFixture.triviaWrite(SETTLED, CFG));
	}

	/** The `return` host reads the break too: on its flat answer the literal drops below a bare `return`. */
	@:pin('control')
	@:killer('M-RETURN-LITERAL-OFFER')
	public function testABareReturnKeepsTheLiteralOnItsLine(): Void {
		final name: String = ''.lpad('b', 90);
		final value: String = ''.lpad('2', 40);
		final cond: String = ''.lpad('a', 120);
		final expected: String =
			'class C {\n\tfunction f() {\n\t\tif ($cond)\n\t\t\treturn {\n\t\t\t\ta: 1,\n\t\t\t\t$name: $value\n\t\t\t};\n\t}\n}';
		Assert.equals(expected, HxWriteFixture.triviaWrite(statement('if ($cond) return { a: 1, $name: $value };'), CFG));
	}

	/** A literal that breaks glues to the header in one write rather than moving to the next line and gluing on the next. */
	@:pin('control')
	@:killer('M-FITLINE-LITERAL-NAMED')
	public function testABreakingLiteralGluesInOneWrite(): Void {
		final name: String = ''.lpad('b', 90);
		final value: String = ''.lpad('2', 40);
		final expected: String = 'class C {\n\tfunction f() {\n\t\tif (c) foo.bar = {\n\t\t\ta: 1,\n\t\t\t$name: $value\n\t\t};\n\t}\n}';
		Assert.equals(expected, HxWriteFixture.triviaWrite(statement('if (c) foo.bar = { a: 1, $name: $value };'), CFG));
		Assert.equals(expected, HxWriteFixture.triviaWrite(expected, CFG));
	}

	/**
	 * The `fitLine` host offers the read-back layout itself: with the literal only named, a ternary body keeps the placement
	 * its host read off the flat body.
	 */
	@:pin('control')
	@:killer('M-FITLINE-HOST-OFFER')
	public function testTheHostLaysItselfOutForTheBreak(): Void {
		Assert.equals(SETTLED, HxWriteFixture.triviaWrite(statement('$HEADER return $TERNARY ? null : { $FIELDS };'), CFG));
	}

	/** One write is a fixed point at every width around the break, under every host and on either ternary branch. */
	@:pin('control')
	@:killer('M-CHAIN-LITERAL-NAMED')
	public function testOneWriteIsAFixedPointAtEveryWidth(): Void {
		for (k in MIN_K ... MAX_K) {
			final literal: String = '{ aaaa: 1, bbbb: \'${''.lpad('k', k)}\' }';
			for (body in [
				'if (cond) foo.bar = $literal;',
				'for (a in b) x = $literal;',
				'while (cond) return $literal;',
				'if (cond) x = 1; else foo.bar = $literal;',
				'switch (x) { case 1: return $literal; case _: }',
				'do x = $literal while (cond);',
				'var x = flag ? null : $literal;',
				'if (cond) foo($literal);',
				'if (cond) foo(1, $literal);',
				'if (line == keyword || line.startsWith(prefix)) return flag && other ? null : $literal;',
				'if (line == keyword || line.startsWith(prefix)) return flag && other ? $literal : null;',
				'for (a in b) if (line == keyword || line.startsWith(prefix)) return flag ? null : $literal;'
			]) {
				final once: String = HxWriteFixture.triviaWrite(statement(body), CFG);
				Assert.equals(once, HxWriteFixture.triviaWrite(once, CFG), 'k=$k\n$body');
			}
		}
	}

	/** A literal that fits its line is not touched by the offer: it stays flat and on the header's line. */
	@:pin('guard')
	public function testAFittingLiteralStaysFlat(): Void {
		final src: String = statement('if (c) foo.bar = {a: 1, b: 2};');
		Assert.equals(src, HxWriteFixture.triviaWrite(src, CFG));
	}

	/**
	 * Two literals breaking in one ternary settle in one write: the ternary is offered with both breaks committed, so the
	 * first write lays it out for both rather than for one branch's break alone.
	 */
	@:pin('control')
	@:killer('M-OFFER-COMBINED')
	public function testTwoBreakingBranchesSettleInOneWrite(): Void {
		final literal: String = '{ aaaa: 1, ${''.lpad('b', 61)}: ${''.lpad('2', 56)} }';
		final once: String = HxWriteFixture.triviaWrite(
			statement('if (line == keyword || line.startsWith(prefix)) return flag ? $literal : $literal;'), CFG
		);
		Assert.equals(once, HxWriteFixture.triviaWrite(once, CFG), 'one write of two breaking branches must be the fixed point');
	}

	/** A plain fit-line host, a loop body, reads the break as well as the construct-group one does. */
	@:pin('control')
	@:killer('M-FOR-LITERAL-OFFER')
	public function testALoopBodyGluesALiteralThatBreaks(): Void {
		final field: String = ''.lpad('k', 110);
		final expected: String =
			'class C {\n\tfunction f() {\n\t\tfor (a in b) x = {\n\t\t\taaaa: 1,\n\t\t\tbbbb: \'$field\'\n\t\t};\n\t}\n}';
		Assert.equals(expected, HxWriteFixture.triviaWrite(statement('for (a in b) x = { aaaa: 1, bbbb: \'$field\' };'), CFG));
	}

	/**
	 * A literal that fits its line moves no host: three nested fit-line hosts keep the staircase they take for any other
	 * body, from a flat source and from the staircase alike. A link whose body offers the literal's break is still a link.
	 */
	@:pin('control')
	@:killer('M-CHAIN-LINK-THROUGH-OFFER')
	public function testNestedHostsKeepTheirStaircaseForALiteralThatFits(): Void {
		final expected: String = statement(
			'for (culprit in culprits)\n\t\t\tfor (rule in culprit.rules)\n'
			+ '\t\t\t\tif (!isBanned(culprit.file, rule)) _banned.push({file: culprit.file, rule: rule});'
		);
		for (src in [
			statement(
				'for (culprit in culprits) for (rule in culprit.rules) if (!isBanned(culprit.file, rule)) '
				+ '_banned.push({ file: culprit.file, rule: rule });'
			),
			expected
		]) Assert.equals(expected, HxWriteFixture.triviaWrite(src, CFG), src);
	}

	/**
	 * A value-`if` branch literal drops its source newlines, so the next write decides its break again rather than reading
	 * it back: no host lays itself out for that break, and the `return` keeps the value-`if` below it from either spelling.
	 */
	@:pin('control')
	@:killer('M-IGNORED-LITERAL-REDECIDED')
	public function testAValueIfBranchLiteralMovesNoHost(): Void {
		final field: String = ''.lpad('k', 96);
		final expected: String = statement('return\n\t\t\tif (c) null else {\n\t\t\t\taaaa: 1,\n\t\t\t\tbbbb: \'$field\'\n\t\t\t};');
		for (src in [
			statement('return if (c) null else { aaaa: 1, bbbb: \'$field\' };'),
			statement('return if (c) null else {\n\t\t\taaaa: 1,\n\t\t\tbbbb: \'$field\'\n\t\t};'),
			expected
		]) Assert.equals(expected, HxWriteFixture.triviaWrite(src, CFG), src);
	}

	/**
	 * Two literals breaking in one ternary under the compiled defaults land on the fixed point in one write: they are fit
	 * pivots, named, and the ternary is offered with both breaks committed. No single cut flips it: unnamed, the renderer's
	 * own fit decision already settled it.
	 */
	@:pin('guard')
	public function testTwoFitPivotBranchesSettleInOneWrite(): Void {
		final literal: String = '{aaaa: 1, bbbb: \'${''.lpad('k', 124)}\'}';
		final broken: String = '{\n\t\t\t\t\taaaa: 1,\n\t\t\t\t\tbbbb: \'${''.lpad('k', 124)}\'\n\t\t\t\t}';
		final expected: String = statement('if (c)\n\t\t\tx = flag\n\t\t\t\t? $broken\n\t\t\t\t: $broken;');
		Assert.equals(expected, HxWriteFixture.triviaWrite(statement('if (c) x = flag ? $literal : $literal;'), '{}'));
	}

	/**
	 * Under the cross config a var's anonymous type annotation stays on its line beside a ternary whose literal breaks:
	 * the annotation is measured against the line the literal leaves, whichever way the source spelled the literal, while
	 * an annotation the source broke keeps its break. Kept by the user's call over the base layout, which broke the
	 * annotation only when the literal was flat in the source.
	 */
	@:pin('control')
	@:killer('M-CHAIN-LITERAL-NAMED')
	public function testAnAnonAnnotationStaysFlatBesideABreakingTernaryLiteral(): Void {
		final xconfig: String = sys.io.File.getContent('tools/data/xconfig-hxformat.json');
		final call: String = 'commitAssisted(candidates, measured.judging, files, changedFiles, editsPerFile)';
		final fields: String = '\n\t\t\ttail: \', oracle-assisted: 0 applied\',\n\t\t\tappliedCount: 0\n\t\t';
		final flat: String = crossStatement(
			'final applied: { tail: String, appliedCount: Int } = candidates.length == 0 ? {$fields} : $call;'
		);
		for (src in [
			crossStatement(
				'final applied: { tail: String, appliedCount: Int } = candidates.length == 0\n\t\t\t'
				+ '? { tail: \', oracle-assisted: 0 applied\', appliedCount: 0 }\n\t\t\t: $call;'
			),
			flat
		]) Assert.equals(flat, HxWriteFixture.triviaWrite(src, xconfig), src);
		final broken: String = crossStatement(
			'final applied: {\n\t\t\ttail: String,\n\t\t\tappliedCount: Int\n\t\t} = candidates.length == 0 ? {$fields} : $call;'
		);
		Assert.equals(broken, HxWriteFixture.triviaWrite(broken, xconfig));
	}

	private static function statement(s: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$s\n\t}\n}';
	}

	/** `s` as the body of a method, laid out as the cross config lays a class out: a blank line inside the class braces. */
	private static function crossStatement(s: String): String {
		return 'class C {\n\n\tfunction f() {\n\t\t$s\n\t}\n\n}';
	}

}
