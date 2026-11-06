package unit.check.common.control;

import anyparse.check.Severity;
import anyparse.check.common.control.HoistCommonBranchHead;
import anyparse.check.common.control.HoistCommonBranchTail;
import anyparse.query.ParseGate;

/**
 * The `hoist-common-branch-head` check: a statement-position `if` chain with a final `else` whose every branch opens
 * with the same statements is flagged `Info`, and `fix` writes those statements once before the chain. The gates covered
 * here: the head must be token-identical in ALL branches, must not exit, must not write a name a condition reads, must
 * not declare a name a condition or the code after the chain reads, and — when a condition has a side effect — may only
 * be constant local declarations; the `if` must stand as a block statement and carry no conditional compilation, and —
 * for the FIX only — no branch other than the final `else` may end up empty and no comment may sit in a removed region.
 */
class HoistCommonBranchHeadTest extends Test {

	private static final TWO_BRANCHES: String = 'class C { function f(c:Bool) { if (c) { h(); a(); } else { h(); b(); } } }';
	private static final GETTER_OWNER: String =
		'class C { static var n:Int = 0; static var next(get, never):Int; static function get_next():Int { n++; return n; } ';
	private static final FIELD_OWNER: String = 'class C { var count:Int = 1; function reset():Void { count = 0; } ';

	public function testSharedHeadMovesBeforeTheIf(): Void {
		final vs: Array<Violation> = violations(TWO_BRANCHES);
		Assert.equals(1, vs.length);
		Assert.equals('hoist-common-branch-head', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('every branch of this if opens with the same statement — move it before the if', vs[0].message);
		final fixed: String = fixed(TWO_BRANCHES);
		Assert.equals('class C { function f(c:Bool) { h();\nif (c) { a(); } else { b(); } } }', fixed);
		Assert.notNull(ParseGate.parseOrNull(new HaxeQueryPlugin(), fixed));
		Assert.equals(0, violations(fixed).length);
	}

	public function testElseIfChainHeadMovesOnce(): Void {
		final src: String =
			'class C { function f(c:Bool, d:Bool) { if (c) { h(); u(); a(); } else if (d) { h(); u(); b(); } else { h(); u(); e(); } } }';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('every branch of this if opens with the same 2 statements — move them before the if', vs[0].message);
		Assert.equals(
			'class C { function f(c:Bool, d:Bool) { h(); u();\nif (c) { a(); } else if (d) { b(); } else { e(); } } }', fixed(src)
		);
	}

	public function testOnlyTheSharedPrefixMoves(): Void {
		final src: String = 'class C { function f(c:Bool) { if (c) { h(); a(); } else { h(); h2(); } } }';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C { function f(c:Bool) { h();\nif (c) { a(); } else { h2(); } } }', fixed(src));
	}

	public function testEmptiedFinalElseIsDropped(): Void {
		final src: String = 'class C { function f(c:Bool) { if (c) { h(); a(); } else { h(); } } }';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C { function f(c:Bool) { h();\nif (c) { a(); } } }', fixed(src));
	}

	public function testBraceLessFinalElseIsDropped(): Void {
		final src: String = 'class C { function f(c:Bool) { if (c) { h(); a(); } else h(); } }';
		Assert.equals(1, violations(src).length);
		Assert.equals('class C { function f(c:Bool) { h();\nif (c) { a(); } } }', fixed(src));
	}

	public function testEmptiedThenBranchIsReportOnly(): Void {
		final src: String = 'class C { function f(c:Bool) { if (c) { h(); } else { h(); a(); } } }';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	@:pin('control')
	@:killer('M-HCBH-EMPTY-ONLY-FINAL')
	public function testEmptiedMiddleArmIsReportOnly(): Void {
		final src: String = 'class C { function f(c:Bool, d:Bool) { if (c) { h(); a(); } else if (d) { h(); } else { h(); b(); } } }';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	@:pin('guard')
	public function testIdenticalBranchesAreLeftToTheTailRule(): Void {
		Assert.equals(0, violations('class C { function f(c:Bool) { if (c) { h(); } else { h(); } } }').length);
		Assert.equals(
			1,
			CheckFixture.violations(new HoistCommonBranchTail(), 'class C { function f(c:Bool) { if (c) { h(); } else { h(); } } }').length
		);
		final same: String = 'class C { function f(c:Bool) { if (c) { h(); } else { h(); } } }';
		Assert.equals(same, fixed(same));
	}

	@:pin('guard')
	public function testIfWithoutElseIsNeverFlagged(): Void {
		Assert.equals(0, violations('class C { function f(c:Bool) { if (c) { h(); a(); } h(); } }').length);
		Assert.equals(0, violations('class C { function f(c:Bool, d:Bool) { if (c) { h(); a(); } else if (d) { h(); b(); } } }').length);
	}

	@:pin('control')
	@:killer('M-HCBH-NO-EXIT')
	public function testHeadThatExitsIsNoHead(): Void {
		Assert.equals(0, violations('class C { function f(c:Bool) { if (c) { return; a(); } else { return; b(); } } }').length);
		Assert.equals(
			0, violations('class C { function f(c:Bool, z:Bool) { if (c) { if (z) return; a(); } else { if (z) return; b(); } } }').length
		);
		Assert.equals(
			0, violations('class C { function f(c:Bool) { while (true) { if (c) { break; a(); } else { break; b(); } } } }').length
		);
		Assert.equals(0, violations('class C { function f(c:Bool) { if (c) { throw 1; a(); } else { throw 1; b(); } } }').length);
	}

	@:pin('control')
	@:killer('M-HCBH-COND-READS-WRITE')
	public function testConditionReadingAMovedWriteStaysSilent(): Void {
		Assert.equals(0, violations('class C { function f(n:Int) { if (n > 0) { n = 1; a(); } else { n = 1; b(); } } }').length);
		Assert.equals(0, violations('class C { function f(n:Int) { if (n > 0) { n++; a(); } else { n++; b(); } } }').length);
		Assert.equals(0, violations('class C { function f() { if (this.n > 0) { this.n = 1; a(); } else { this.n = 1; b(); } } }').length);
		Assert.equals(0, violations('class C { function f() { if (n > 0) { this.n = 1; a(); } else { this.n = 1; b(); } } }').length);
		Assert.equals(
			0, violations('class C { function f(l:Array<Int>) { if (l.length > 0) { l.push(1); a(); } else { l.push(1); b(); } } }').length
		);
		Assert.equals(
			0,
			violations('class C { function f(c:Bool, d:Bool) { if (c) { a(); } else if (d) { n = 1; h(); } else { n = 1; h(); } } }').length
		);
		Assert.equals(
			0,
			violations(
				'class C { function f(n:Int, d:Bool) { if (d) { n = 1; a(); } else if (n > 0) { n = 1; b(); } else { n = 1; e(); } } }'
			).length
		);
		Assert.equals(1, violations('class C { function f(n:Int, m:Int) { if (n > 0) { m = 1; a(); } else { m = 1; b(); } } }').length);
	}

	@:pin('control')
	@:killer('M-HCBH-EFFECTFUL-COND')
	public function testConditionCallingAFunctionStaysSilent(): Void {
		Assert.equals(0, violations('class C { function f() { if (g()) { h(); a(); } else { h(); b(); } } }').length);
		Assert.equals(
			0, violations('class C { function f(c:Bool) { if (c) { h(); a(); } else if (g()) { h(); b(); } else { h(); e(); } } }').length
		);
		Assert.equals(0, violations('class C { function f() { if ((n = g()) > 0) { h(); a(); } else { h(); b(); } } }').length);
		Assert.equals(
			0,
			violations('class C { function f(c:Bool) { if (c) { h(); a(); } else if (n++ > 2) { h(); b(); } else { h(); e(); } } }').length
		);
		Assert.equals(0, violations('class C { function f() { if (g()) { var t = n; a(t); } else { var t = n; b(t); } } }').length);
	}

	@:pin('control')
	@:killer('M-HCBH-EFFECTFUL-COND')
	public function testPropertyGetterConditionIsNotPure(): Void {

		Assert.equals(
			0, violationsIn(GETTER_OWNER, 'static function f() { if (next > 1) { o.push(n); a(); } else { o.push(n); b(); } } }').length
		);
		Assert.equals(
			0, violationsIn(GETTER_OWNER, 'static function f() { if (next > 1) { var t = n; a(t); } else { var t = n; b(t); } } }').length
		);

		Assert.equals(
			1, violationsIn(GETTER_OWNER, 'static function f() { if (n > 1) { var t = 5; a(t); } else { var t = 5; b(t); } } }').length
		);
	}

	@:pin('control')
	@:killer('M-HCBH-INERT-CALL')
	public function testCallInTheHeadStaysSilentWhenAConditionReadsAField(): Void {

		Assert.equals(
			0, violationsIn(FIELD_OWNER, 'function f() { if (count > 0) { reset(); o.push(1); } else { reset(); o.push(2); } } }').length
		);
		Assert.equals(
			0, violationsIn(FIELD_OWNER, 'function f() { if (this.count > 0) { reset(); a(); } else { reset(); b(); } } }').length
		);
		Assert.equals(0, violationsIn(FIELD_OWNER, 'function f() { if (count > 0) { new D(); a(); } else { new D(); b(); } } }').length);
		Assert.equals(
			1, violationsIn(FIELD_OWNER, 'function f() { if (count > 0) { var q = 5; a(q); } else { var q = 5; b(q); } } }').length
		);
		Assert.equals(1, violationsIn(FIELD_OWNER, 'function f(c:Bool) { if (c) { reset(); a(); } else { reset(); b(); } } }').length);
	}

	@:pin('control')
	@:killer('M-HCBH-HELD-LOCAL')
	public function testLocalRewrittenByACalledClosureIsNotHeld(): Void {
		Assert.equals(
			0,
			violations('class C { function f() { var k = 1; function bump() k = 0; if (k > 0) { bump(); a(); } else { bump(); b(); } } }')
				.length
		);
		Assert.equals(
			0,
			violations('class C { function f() { var k = 1; var bump = () -> k = 0; if (k > 0) { bump(); a(); } else { bump(); b(); } } }')
				.length
		);
		Assert.equals(
			1,
			violations('class C { function f() { var k = 1; function other() {} if (k > 0) { other(); a(); } else { other(); b(); } } }')
				.length
		);
	}

	@:pin('control')
	@:killer('M-HCBH-CONSTANT-DECL')
	public function testEffectfulConditionAdmitsOnlyConstantDeclarations(): Void {
		final constant: String = 'class C { function f() { if (g()) { var q = 5; a(q); } else { var q = 5; b(q); } } }';
		Assert.equals(1, violations(constant).length);
		Assert.equals('class C { function f() { var q = 5;\nif (g()) { a(q); } else { b(q); } } }', fixed(constant));
		Assert.equals(
			1, violations('class C { function f() { if (g()) { var q:Int = 5 + 1; a(q); } else { var q:Int = 5 + 1; b(q); } } }').length
		);
		Assert.equals(0, violations('class C { function f() { if (g()) { var q = k; a(q); } else { var q = k; b(q); } } }').length);
		Assert.equals(0, violations('class C { function f() { if (g()) { var q = k(); a(q); } else { var q = k(); b(q); } } }').length);
		Assert.equals(
			1, violations('class C { function f() { if (g()) { var q = 5; r(); a(q); } else { var q = 5; r(); b(q); } } }').length
		);
		Assert.equals(
			'class C { function f() { var q = 5;\nif (g()) { r(); a(q); } else { r(); b(q); } } }',
			fixed('class C { function f() { if (g()) { var q = 5; r(); a(q); } else { var q = 5; r(); b(q); } } }')
		);
	}

	@:pin('control')
	@:killer('M-HCBH-DECL-CAPTURE')
	public function testDeclaredNameReadByAConditionOrTheCodeAfterIsNotMoved(): Void {
		Assert.equals(0, violations('class C { function f(q:Int) { if (q > 0) { var q = 5; a(q); } else { var q = 5; b(q); } } }').length);
		Assert.equals(
			0, violations('class C { function f(c:Bool) { if (c) { var q = 5; a(q); } else { var q = 5; b(q); } use(q); } }').length
		);
		Assert.equals(
			1, violations('class C { function f(c:Bool) { use(q); if (c) { var q = 5; a(q); } else { var q = 5; b(q); } } }').length
		);
		Assert.equals(
			0, violations('class C { function f(c:Bool) { if (c) { function g() {} a(); } else { function g() {} b(); } g(); } }').length
		);
	}

	@:pin('control')
	@:killer('M-HCBH-SHORTEN')
	public function testHeadShortensFromItsEndUntilTheGatesHold(): Void {
		final src: String = 'class C { function f(n:Int) { if (n > 0) { h(); n = 2; a(); } else { h(); n = 2; b(); } } }';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('every branch of this if opens with the same statement — move it before the if', vs[0].message);
		Assert.equals('class C { function f(n:Int) { h();\nif (n > 0) { n = 2; a(); } else { n = 2; b(); } } }', fixed(src));
	}

	@:pin('control')
	@:killer('M-HCBT-STATEMENT-POSITION')
	public function testOnlyABlockStatementIfIsAChainHead(): Void {
		Assert.equals(0, violations('class C { function f(c:Bool) { var x = if (c) { h(); a(); } else { h(); b(); }; } }').length);
		Assert.equals(
			0, violations('class C { function f(c:Bool, xs:Array<Int>) { for (x in xs) if (c) { h(); a(); } else { h(); b(); } } }').length
		);
	}

	public function testDifferentArgumentsAreNotTheSameHead(): Void {
		Assert.equals(0, violations('class C { function f(c:Bool) { if (c) { h(1); a(); } else { h(2); b(); } } }').length);
	}

	public function testConditionalCompilationNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(c:Bool) { if (c) { h(); a(); } else { h(); #if x b(); #end } } }').length);
	}

	public function testMacroReificationNotWalked(): Void {
		Assert.equals(
			0, violations('class C { macro function f(c:Bool) { return macro { if (c) { h(); a(); } else { h(); b(); } }; } }').length
		);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		CheckFixture.assertRegistered('hoist-common-branch-head');
	}

	@:pin('control')
	@:killer('M-HCBT-NESTED-ALL-OR-NOTHING')
	public function testNestedChainWaitsForTheOuterRewrite(): Void {
		final inHead: String = 'class C { function f(c:Bool, d:Bool) { if (c) { if (d) { x(); a(); } else { x(); b(); } p(); }'
			+ ' else { if (d) { x(); a(); } else { x(); b(); } q(); } } }';
		Assert.equals(
			'class C { function f(c:Bool, d:Bool) { if (d) { x(); a(); } else { x(); b(); }\nif (c) { p(); } else { q(); } } }',
			fixed(inHead)
		);
		Assert.equals(
			'class C { function f(c:Bool, d:Bool) { x();\nif (d) { a(); } else { b(); }\nif (c) { p(); } else { q(); } } }',
			fixed(fixed(inHead))
		);
	}

	@:pin('guard')
	public function testSharedHeadAndTailEachRuleMovesItsOwnPart(): Void {
		final src: String = 'class C { function f(c:Bool) { if (c) { h(); a(); t(); } else { h(); b(); t(); } } }';
		final head: String = fixed(src);
		Assert.equals('class C { function f(c:Bool) { h();\nif (c) { a(); t(); } else { b(); t(); } } }', head);
		final both: String = CheckFixture.fixedSource(new HoistCommonBranchTail(), head);
		Assert.equals('class C { function f(c:Bool) { h();\nif (c) { a(); } else { b(); }\nt(); } }', both);
		Assert.equals(both, CheckFixture.fixedSource(new HoistCommonBranchHead(), both));
		Assert.equals(both, fixed(CheckFixture.fixedSource(new HoistCommonBranchTail(), src)));
	}

	@:pin('control')
	@:killer('M-HCBH-COMMENT-IN-HEAD')
	public function testCommentInARemovedRegionIsReportOnly(): Void {
		final inside: String = 'class C { function f(c:Bool) { if (c) { h(); // note\n a(); } else { h(); b(); } } }';
		Assert.equals(1, violations(inside).length);
		Assert.equals(0, edits(inside).length);
		final before: String = 'class C { function f(c:Bool) { if (c) { /* note */ h(); a(); } else { h(); b(); } } }';
		Assert.equals(3, edits(before).length);
	}

	@:pin('control')
	@:killer('M-HCBH-COMMENT-IN-ELSE')
	public function testEmptiedElseWithACommentInItIsReportOnly(): Void {
		final emptied: String = 'class C { function f(c:Bool) { if (c) { h(); a(); } else { h(); /* note */ } } }';
		Assert.equals(1, violations(emptied).length);
		Assert.equals(0, edits(emptied).length);
	}

	@:pin('control')
	@:killer('M-HCBT-SUPPRESSED')
	public function testSuppressedChainStaysWhileFreeChainMoves(): Void {
		final src: String = 'class C {\nfunction f(c:Bool) {\n// CHECKSTYLE:OFF\nif (c) { h(); a(); } else { h(); b(); }\n'
			+ '// CHECKSTYLE:ON\n}\nfunction g(c:Bool) { if (c) { h(); a(); } else { h(); b(); } }\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(
			'class C {\nfunction f(c:Bool) {\n// CHECKSTYLE:OFF\nif (c) { h(); a(); } else { h(); b(); }\n// CHECKSTYLE:ON\n}\n'
			+ 'function g(c:Bool) { h();\nif (c) { a(); } else { b(); } }\n}',
			fixed(src)
		);
	}

	@:pin('control')
	@:killer('M-PURITY-STATIC-GETTER')
	public function testGetterReadThroughItsOwnTypeIsNotPure(): Void {
		Assert.equals(
			0,
			violationsIn(GETTER_OWNER, 'static function f() { if (C.next > 1) { var t = n; a(t); } else { var t = n; b(t); } } }').length
		);
	}

	private static function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new HoistCommonBranchHead(), src);
	}

	private static function edits(src: String): Array<{ span: Span, text: String }> {
		return CheckFixture.edits(new HoistCommonBranchHead(), src);
	}

	private static function fixed(src: String): String {
		return CheckFixture.fixedSource(new HoistCommonBranchHead(), src);
	}

	private static function violationsIn(owner: String, member: String): Array<Violation> {
		return violations(owner + member);
	}

}
