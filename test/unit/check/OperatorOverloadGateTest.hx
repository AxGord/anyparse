package unit.check;

import anyparse.check.Check;
import anyparse.check.DoubleNegation;
import anyparse.check.FoldStringLiterals;
import anyparse.check.InvertNegatedIfElse;
import anyparse.check.JoinStringAppend;
import anyparse.check.LintConfig;
import anyparse.check.PreferTernaryReturn;
import anyparse.check.SimplifyNegatedCompound;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin;
import anyparse.runtime.Span;
import unit.CheckFixture;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * A rule that moves, drops or rebuilds an operator may do so only when the operator is the
 * LANGUAGE's. In Haxe an abstract may declare its own (`@:op`), and such a type usually carries
 * `@:from` / `@:to` as well — so the rewritten program still compiles and only a runtime test
 * tells the difference. That is why every case here is a PAIR: the same source with and without
 * the annotation, so the assertion is that the annotation FLIPPED the outcome and not that the
 * rule happens to be silent.
 *
 * The measured instance: `pony.fs.Dir` declares `@:op(A + B) addString(a: String)` that inserts
 * a path separator, so `dir + 'pages'` is `/root/pages` while the folded `'${dir}pages'` is
 * `/rootpages`. Three sites in `pony/text/tpl/TplSystem.hx` shipped that way and a test caught it.
 *
 * The negation family is the same class one operator over: Haxe does not derive `@:op(A != B)`
 * from `@:op(A == B)`, and an `@:op(!A)` need not be an involution, so a rebuilt condition and a
 * stripped `!!` can both disagree with the source while compiling.
 */
class OperatorOverloadGateTest extends Test {

	/** The `Dir` shape: an abstract that IS a string by conversion and joins by a rule of its own. */
	private static final CONCAT_OVERLOAD: String = 'abstract Dir(String) from String to String {\n\n'
		+ '\t@:op(A + B) public inline function addString(a: String): Dir return cast this + \'/\' + a;\n\n}\n';

	/** The same abstract with the annotation removed — then `+` on it IS the language concatenation. */
	private static final CONCAT_PLAIN: String = 'abstract Dir(String) from String to String {\n\n'
		+ '\tpublic inline function addString(a: String): Dir return cast this + \'/\' + a;\n\n}\n';

	/** One typed operand of the abstract and one chain of plain literals — the gate must part them. */
	private static final CONCAT_USE: String = 'class Use {\n\n\tpublic static function f(dir: Dir): String {\n'
		+ '\t\treturn dir + \'pages\';\n\t}\n\n\tpublic static function g(): String {\n\t\treturn \'a\' + \'b\' + \'c\';\n\t}\n\n}\n';

	/** `@:op(A == B)` with NO `@:op(A != B)`, plus an `@:op(!A)` — the two the negation family reads. */
	private static final NEGATION_OVERLOAD: String = 'abstract Flag(Bool) from Bool to Bool {\n\n'
		+ '\t@:op(A == B) public inline function eq(b: Flag): Bool return this == cast b;\n\n'
		+ '\t@:op(!A) public inline function inv(): Bool return this;\n\n}\n';

	private static final NEGATION_PLAIN: String =
		'abstract Flag(Bool) from Bool to Bool {\n\n\tpublic inline function eq(b: Flag): Bool return this == cast b;\n\n}\n';

	/** A negated comparison, a double negation and a negated if-else, all over the abstract. */
	private static final NEGATION_USE: String = 'class Use2 {\n\n\tpublic static function a(f: Flag, g: Flag): Bool {\n'
		+ '\t\treturn !(f == g);\n\t}\n\n\tpublic static function b(f: Flag): Bool {\n\t\treturn !!f;\n\t}\n\n'
		+ '\tpublic static function d(f: Flag, x: Int): Int {\n\t\tif (!f) return x else return -x;\n\t}\n\n}\n';

	/** A negated ternary and a negated guard pair over the `Flag` abstract — the value forms of the `if (!f)` swap. */
	private static final NEGATED_VALUE_USE: String = 'class Use3 {\n\n\tpublic static function e(f: Flag, x: Int): Int {\n'
		+ '\t\treturn !f ? x : -x;\n\t}\n\n\tpublic static function g(f: Flag, x: Int): Int {\n\t\tif (!f) return x;\n'
		+ '\t\treturn -x;\n\t}\n\n}\n';

	/** Two default-first ternaries over the `Flag` abstract — what `defaultLast` turns by adding a `!` and by flipping `==`. */
	private static final DEFAULT_FIRST_USE: String = 'class Use4 {\n\n\tpublic static function h(f: Flag, x: Null<Int>): Null<Int> {\n'
		+ '\t\treturn f ? null : x;\n\t}\n\n\tpublic static function k(f: Flag, g: Flag, x: Null<Int>): Null<Int> {\n'
		+ '\t\treturn f == g ? null : x;\n\t}\n\n}\n';

	/** An abstract whose `@:op(A += B)` inserts a separator — the append twin of the `Dir` shape. */
	private static final APPEND_OVERLOAD: String = 'abstract Route(String) from String to String {\n\n'
		+ '\t@:op(A += B) public inline function append(s: String): Route return cast this + \'/\' + s;\n\n}\n';

	private static final APPEND_PLAIN: String = 'abstract Route(String) from String to String {\n\n'
		+ '\tpublic inline function append(s: String): Route return cast this + \'/\' + s;\n\n}\n';

	/** Two appends the join would fuse into one — with string-literal terms, which is what makes the run look String-typed. */
	private static final APPEND_USE: String = 'class UseR {\n\n\tpublic static function f(): Route {\n\t\tvar r: Route = \'root\';\n'
		+ '\t\tr += \'a\';\n\t\tr += \'b\';\n\t\treturn r;\n\t}\n\n}\n';

	/** The same two operand shapes as a MEMBER read with no `this` and an unqualified call. */
	private static final CONCAT_MEMBER_USE: String = 'class UseM {\n\n\tprivate static var root: Dir;\n\n'
		+ '\tpublic static function f(): String {\n\t\treturn root + \'pages\';\n\t}\n\n'
		+ '\tpublic static function g(): String {\n\t\treturn base() + \'pages\';\n\t}\n\n'
		+ '\tprivate static function base(): Dir {\n\t\treturn root;\n\t}\n\n}\n';

	/**
	 * The join turns N appends into ONE, so an overloaded `+=` runs its body once instead of N
	 * times: `r += 'a'; r += 'b'` is `root/a/b` where the joined `r += 'a' + 'b'` is `root/ab`.
	 * The rule's own type gate cannot catch it — a string-literal term is exactly what makes such
	 * a run look String-typed.
	 */
	public function testJoinAppendSkipsOverloadedAddAssign(): Void {
		Assert.isFalse(reports(new JoinStringAppend(), APPEND_OVERLOAD, APPEND_USE, 'r += \'a\''));
	}

	public function testJoinAppendReportsPlainAddAssign(): Void {
		Assert.isTrue(reports(new JoinStringAppend(), APPEND_PLAIN, APPEND_USE, 'r += \'a\''));
	}

	/** The path-join site is not reported at all — the merge would change the value, so the finding is false. */
	public function testFoldSkipsOverloadedConcatSite(): Void {
		Assert.isFalse(reports(new FoldStringLiterals(), CONCAT_OVERLOAD, CONCAT_USE, 'dir + \''));
	}

	/** Without the annotation the very same site IS reported — the annotation is what moved it. */
	public function testFoldReportsThePlainConcatSite(): Void {
		Assert.isTrue(reports(new FoldStringLiterals(), CONCAT_PLAIN, CONCAT_USE, 'dir + \''));
	}

	/**
	 * A chain of plain literals in the SAME file still folds: the gate is per construct, judged on
	 * that construct's operands, not a whole-file veto.
	 */
	public function testFoldStillReportsLiteralChainNextToIt(): Void {
		Assert.isTrue(reports(new FoldStringLiterals(), CONCAT_OVERLOAD, CONCAT_USE, '\'a\' + \'b\''));
	}

	/**
	 * An operand that is a member of the enclosing type read WITHOUT `this` types through the
	 * shared walk, so the gate can prove the overload rather than abstaining. Before that arm both
	 * of these sites answered `Unproven` — a finding reported without a fix, where the truth is
	 * that the finding is wrong.
	 */
	public function testFoldSkipsOverloadedImplicitMemberOperand(): Void {
		Assert.isFalse(reports(new FoldStringLiterals(), CONCAT_OVERLOAD, CONCAT_MEMBER_USE, 'root + \''));
	}

	/** The same for an operand that is an unqualified call to a sibling method. */
	public function testFoldSkipsOverloadedUnqualifiedCallOperand(): Void {
		Assert.isFalse(reports(new FoldStringLiterals(), CONCAT_OVERLOAD, CONCAT_MEMBER_USE, 'base() + \''));
	}

	/** Both shapes stay reportable when the type declares no overload — the arms type them either way. */
	public function testFoldReportsPlainImplicitMemberOperand(): Void {
		Assert.isTrue(reports(new FoldStringLiterals(), CONCAT_PLAIN, CONCAT_MEMBER_USE, 'root + \''));
	}

	/** `!(f == g)` does not flip to `f != g`: Haxe derives no `@:op(A != B)` from the `==` overload. */
	public function testNegatedCompoundSkipsOverloadedEquality(): Void {
		Assert.isFalse(reports(new SimplifyNegatedCompound(), NEGATION_OVERLOAD, NEGATION_USE, '!(f == g)'));
	}

	public function testNegatedCompoundReportsPlainEquality(): Void {
		Assert.isTrue(reports(new SimplifyNegatedCompound(), NEGATION_PLAIN, NEGATION_USE, '!(f == g)'));
	}

	/** `!!f` is redundant only while `!` is an involution, which an `@:op(!A)` need not be. */
	public function testDoubleNegationSkipsOverloadedNot(): Void {
		Assert.isFalse(reports(new DoubleNegation(), NEGATION_OVERLOAD, NEGATION_USE, '!!f'));
	}

	public function testDoubleNegationReportsPlainNot(): Void {
		Assert.isTrue(reports(new DoubleNegation(), NEGATION_PLAIN, NEGATION_USE, '!!f'));
	}

	/** Dropping the `!` and swapping the branches is an exact complement only for the built-in `!`. */
	public function testInvertIfElseSkipsOverloadedNot(): Void {
		Assert.isFalse(reports(new InvertNegatedIfElse(), NEGATION_OVERLOAD, NEGATION_USE, 'if (!f)'));
	}

	public function testInvertIfElseReportsPlainNot(): Void {
		Assert.isTrue(reports(new InvertNegatedIfElse(), NEGATION_PLAIN, NEGATION_USE, 'if (!f)'));
	}

	/** The ternary swap is the same complement, so it asks the same question. */
	@:pin('control') @:killer('M-NEGCOND-OVERLOAD-BLIND')
	public function testInvertTernarySkipsOverloadedNot(): Void {
		Assert.isFalse(reports(new InvertNegatedIfElse(), NEGATION_OVERLOAD, NEGATED_VALUE_USE, '!f ?'));
	}

	public function testInvertTernaryReportsPlainNot(): Void {
		Assert.isTrue(reports(new InvertNegatedIfElse(), NEGATION_PLAIN, NEGATED_VALUE_USE, '!f ?'));
	}

	/**
	 * A ternary BUILT from a negated guard is oriented positive only for the built-in `!`, and the
	 * fix decides it with the overload declared in ANOTHER module — the report index it is handed.
	 */
	@:pin('control') @:killer('M-NEGCOND-OVERLOAD-BLIND', 'M-OPSEL-REPORT-DROPPED')
	public function testTernaryReturnKeepsOverloadedNot(): Void {
		Assert.equals('return !f ? x : -x;', ternaryReturnFix(NEGATION_OVERLOAD));
	}

	public function testTernaryReturnInvertsPlainNot(): Void {
		Assert.equals('return f ? -x : x;', ternaryReturnFix(NEGATION_PLAIN));
	}

	/**
	 * `defaultLast` turns `f ? null : x` by ADDING a `!` and `f == g ? null : x` by FLIPPING the `==`, so each
	 * asks the operator table about the operator it writes: an `@:op(!A)` refuses the first, an `@:op(A == B)`
	 * without its `!=` twin refuses the second; the plain abstract turns both.
	 *
	 * RED under M-NEGCOND-DEFAULT-LAST-OVERLOAD-BLIND (no operator asked) and M-NEGCOND-DEFAULT-LAST-EQ-UNASKED
	 * (only the not asked).
	 */
	@:pin('control') @:killer('M-NEGCOND-DEFAULT-LAST-OVERLOAD-BLIND', 'M-NEGCOND-DEFAULT-LAST-EQ-UNASKED')
	public function testDefaultLastAsksTheOperatorItWrites(): Void {
		final eqOnly: String = 'abstract Flag(Bool) from Bool to Bool {\n\n'
			+ '\t@:op(A == B) public inline function eq(b: Flag): Bool return this == cast b;\n\n}\n';
		final notOnly: String =
			'abstract Flag(Bool) from Bool to Bool {\n\n\t@:op(!A) public inline function inv(): Bool return this;\n\n}\n';
		Assert.isFalse(lastReports(notOnly, 'f ?'));
		Assert.isFalse(lastReports(eqOnly, 'f == g ?'));
		Assert.isTrue(lastReports(NEGATION_PLAIN, 'f ?'));
		Assert.isTrue(lastReports(NEGATION_PLAIN, 'f == g ?'));
	}

	/**
	 * Whether `check` reports a finding whose span covers `needle` in the USE file, with `decl` in
	 * the same run — the two-file shape is the point: the annotation that decides the verdict lives
	 * in another module, which is where a check would never look on its own.
	 *
	 * A finding the operator gate left report-only counts as NOT reported here: for these rules the
	 * finding IS the rewrite, and `fold`'s report-only message is spelled out in its own tests.
	 */
	private function reports(check: Check, decl: String, use: String, needle: String): Bool {
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final at: Int = use.indexOf(needle);
		Assert.isTrue(at >= 0, 'the fixture holds $needle');
		final found: Array<Violation> = CheckFixture.violationsIn(check, [
			{ file: 'Decl.hx', source: decl },
			{ file: 'Use.hx', source: use }
		], plugin);
		return found.exists(v -> {
			final span: Null<Span> = v.span;
			return v.file == 'Use.hx' && span != null && span.from <= at && at < span.to
			&& v.message.indexOf('overloads the concatenation operator') == -1;
		});
	}

	/** The one `prefer-ternary-return` edit over `NEGATED_VALUE_USE`'s guard pair, with `decl` in the same run. */
	private function ternaryReturnFix(decl: String): String {
		final run: FixRun = CheckFixture.fixRun(new PreferTernaryReturn(), [
			{ file: 'Use.hx', source: NEGATED_VALUE_USE },
			{ file: 'Decl.hx', source: decl }
		], 'Use.hx', new HaxeQueryPlugin());
		Assert.equals(1, run.edits.length);
		return run.edits.length == 0 ? '' : run.edits[0].text;
	}

	/** Whether `invert-negated-if-else` under `defaultLast` reports `DEFAULT_FIRST_USE` at `needle`, with `decl` in the same run. */
	private function lastReports(decl: String, needle: String): Bool {
		final at: Int = DEFAULT_FIRST_USE.indexOf(needle);
		Assert.isTrue(at >= 0, 'the fixture holds $needle');
		final config: LintConfig = LintConfig.parse(InvertNegatedIfElseCheckTest.lastConfig());
		final found: Array<Violation> = CheckFixture.violationsIn(new InvertNegatedIfElse(), [
			{ file: 'Decl.hx', source: decl },
			{ file: 'Use.hx', source: DEFAULT_FIRST_USE }
		], new HaxeQueryPlugin(), _ -> config);
		return found.exists(v -> {
			final span: Null<Span> = v.span;
			return v.file == 'Use.hx' && span != null && span.from <= at && at < span.to;
		});
	}

}
