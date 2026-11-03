package unit.check.common.expressions;

import anyparse.check.Check.FixEdit;
import anyparse.check.common.expressions.RedundantLambdaWrapper;
import anyparse.query.GrammarPlugin;
import anyparse.query.StdResolver;
import haxe.io.Path;

/**
 * `redundant-lambda-wrapper` on a callee that is a static of a STD type (`Reflect.compare`, `Math.sqrt`): the
 * finding is the rule's risky arm, so its rewrite stands only where the compiler oracle confirms it compiles and the
 * safe `fix` declines it. Every fixture names the std type it reads through `StdScope` stubs, since a plain test
 * index holds no std at all and the rule then proves nothing about the name.
 */
class RedundantLambdaWrapperStdCheckTest extends Test {

	/** A std-rooted type of one function of every shape the arm refuses, and one plain twin beside each. */
	private static final ODD: String = 'class Odd {\n\tpublic static function plain(a:Int):Int return a;\n'
		+ '\tpublic static function pair(a:Int, b:Int):Int return a;\n\tpublic static function opt(a:Int, '
		+ '?b:Int):Int return a;\n\tpublic static function dflt(a:Int, b:Int = 1):Int return a;\n\tpublic static '
		+ 'function rest(...a:Int):Int return 0;\n\toverload public static function ov(a:Int):Int return a;\n'
		+ '\tpublic static dynamic function dyn(a:Int):Int return a;\n\tpublic function inst(a:Int):Int return '
		+ 'a;\n\tpublic static var field:Int;\n\tmacro public static function mac(a:Int):Int return a;\n'
		+ '\t@:overload(function(a:String):Int {}) public static function ov2(a:Int):Int return a;\n'
		+ '\tpublic static function twice(a:Int):Int return a;\n\tpublic static function twice(a:Int, b:Int):Int '
		+ 'return a;\n\t#if neko\n\tpublic static function guarded(a:Int):Int return a;\n\t#end\n}\n';

	@:pin('control')
	@:killer('M-ETA-STD-ARM-UNSPLIT', 'M-ETA-STD-STATIC-NEVER-PROVEN')
	public function testStdStaticComparatorIsTheRiskyArm(): Void {
		final src: String = body('out.sort((a, b) -> Reflect.compare(a, b));');
		final scoped: GrammarPlugin = StdScope.plugin(files(src));
		final check: RedundantLambdaWrapper = new RedundantLambdaWrapper();
		final vs: Array<Violation> = CheckFixture.violationsIn(check, files(src), scoped);
		Assert.equals(1, vs.length);
		Assert.equals(1, check.riskyArmFindings(vs).length, 'the finding belongs to the risky arm');
		final edits: Array<FixEdit> = check.riskyFix(src, vs, scoped);
		Assert.equals(1, edits.length);
		Assert.equals('Reflect.compare', edits[0].text);
		Assert.equals('\t\tout.sort(Reflect.compare);', apply(src, edits).split('\n')[2]);
	}

	@:pin('control')
	@:killer('M-ETA-STD-FIX-KEEPS-STD')
	public function testSafeFixDeclinesTheStdCallee(): Void {
		final src: String = body('out.sort((a, b) -> Reflect.compare(a, b));');
		final scoped: GrammarPlugin = StdScope.plugin(files(src));
		final check: RedundantLambdaWrapper = new RedundantLambdaWrapper();
		final vs: Array<Violation> = CheckFixture.violationsIn(check, files(src), scoped);
		Assert.equals(0, CheckFixture.fixIn(check, files(src), vs, 'C.hx', scoped).length, 'no oracle, no rewrite');
		Assert.notNull(vs[0].declineReason, 'the ledger names why the finding was left');
	}

	public function testAnnotatedParametersAreNotRefused(): Void {
		final src: String = body('out.sort((a: String, b: String) -> Reflect.compare(a, b));');
		Assert.equals(1, stdFindings(src).length);
	}

	public function testNonGenericStdStaticIsFlagged(): Void {
		Assert.equals(1, stdFindings(body('ints.map(x -> Math.sqrt(x));')).length);
	}

	public function testUserStaticStaysTheSafeArm(): Void {
		final src: String = 'class Helper {\n\tpublic static function isPos(v:Int):Bool return true;\n}\n'
			+ body('ints.foreach(p -> Helper.isPos(p));');
		final scoped: GrammarPlugin = StdScope.plugin(files(src));
		final check: RedundantLambdaWrapper = new RedundantLambdaWrapper();
		final vs: Array<Violation> = CheckFixture.violationsIn(check, files(src), scoped);
		Assert.equals(1, vs.length);
		Assert.equals(0, check.riskyArmFindings(vs).length, 'a callee the project declares needs no oracle');
		Assert.equals(1, CheckFixture.fixIn(check, files(src), vs, 'C.hx', scoped).length);
	}

	public function testInlineBodyIsNeverReduced(): Void {
		Assert.equals(0, stdFindings(body('out.sort((a, b) -> inline Reflect.compare(a, b));')).length);
	}

	public function testBarePluginProvesNoStdName(): Void {
		final src: String = body('out.sort((a, b) -> Reflect.compare(a, b));');
		Assert.equals(0, CheckFixture.violations(new RedundantLambdaWrapper(), src).length);
	}

	public function testArityMismatchNotFlagged(): Void {
		Assert.equals(0, stdFindings(body('out.sort(a -> Reflect.compare(a));')).length);
	}

	public function testLocalShadowOfTheTypeNameNotFlagged(): Void {
		Assert.equals(0, stdFindings(body('final Reflect = 1;\n\t\tout.sort((a, b) -> Reflect.compare(a, b));')).length);
	}

	/** The project's own `Reflect` takes the name: the finding is then the safe arm's, not the std one. */
	public function testProjectDeclaredTypeOfTheSameNameIsNotStd(): Void {
		final src: String = 'class Reflect {\n\tpublic static function compare(a:Int, b:Int):Int return 0;\n}\n'
			+ body('out.sort((a, b) -> Reflect.compare(a, b));');
		final scoped: GrammarPlugin = StdScope.plugin(files(src));
		final check: RedundantLambdaWrapper = new RedundantLambdaWrapper();
		final vs: Array<Violation> = CheckFixture.violationsIn(check, files(src), scoped);
		Assert.equals(0, check.riskyArmFindings(vs).length);
		Assert.equals(1, vs.length);
	}

	/** A same-named type in another package that lacks the member still withholds the std proof: the table is keyed by simple name. */
	public function testSameNameInAnotherPackageWithoutTheMemberIsNotStd(): Void {
		final other: String = 'package other;\n\nclass Reflect {\n\tpublic static function unrelated(a:Int):Int return a;\n}\n';
		final src: String = body('out.sort((a, b) -> Reflect.compare(a, b));');
		final withOther: Array<{ file: String, source: String }> = files(src).concat([{ file: 'other/Reflect.hx', source: other }]);
		Assert.equals(
			0, CheckFixture.violationsIn(new RedundantLambdaWrapper(), withOther, StdScope.plugin(withOther)).length,
			'the project declares the name, so no std proof'
		);
		Assert.equals(1, stdFindings(src).length, 'without the other declaration the same source fires');
	}

	/** The std name is proven only over a complete project: a declared root that matched nothing leaves the index short of files. */
	public function testIncompleteProjectProvesNoStdName(): Void {
		final src: String = body('out.sort((a, b) -> Reflect.compare(a, b));');
		Assert.equals(
			0, CheckFixture.violationsIn(new RedundantLambdaWrapper(), files(src), StdScope.plugin(files(src), null, false)).length,
			'an incomplete project'
		);
		Assert.equals(1, stdFindings(src).length, 'the complete twin fires');
	}

	public function testEachStdShapeIsDecidedByOneVariable(): Void {
		discriminate('optional parameter', 'x -> Odd.opt(x)', 'x -> Odd.plain(x)');
		discriminate('defaulted parameter', 'x -> Odd.dflt(x)', 'x -> Odd.plain(x)');
		discriminate('rest parameter', 'x -> Odd.rest(x)', 'x -> Odd.plain(x)');
		discriminate('overload modifier', 'x -> Odd.ov(x)', 'x -> Odd.plain(x)');
		discriminate('dynamic member', 'x -> Odd.dyn(x)', 'x -> Odd.plain(x)');
		discriminate('macro member', 'x -> Odd.mac(x)', 'x -> Odd.plain(x)');
		discriminate('overload annotation', 'x -> Odd.ov2(x)', 'x -> Odd.plain(x)');
		discriminate('instance member', 'x -> Odd.inst(x)', 'x -> Odd.plain(x)');
		discriminate('a field', 'x -> Odd.field(x)', 'x -> Odd.plain(x)');
		discriminate('two declarations of the name', 'x -> Odd.twice(x)', 'x -> Odd.plain(x)');
		discriminate('declared under a conditional', 'x -> Odd.guarded(x)', 'x -> Odd.plain(x)');
		discriminate('arity', '(x, y) -> Odd.plain(x, y)', '(x, y) -> Odd.pair(x, y)');
	}

	/** One count per callee kind in a single source: the whole population this widening changes, by kind. */
	public function testCensusByCalleeKind(): Void {
		final src: String = 'class Helper {\n\tpublic static function isPos(v:Int):Bool return true;\n}\nclass C {\n'
			+ '\tfunction ok(v:Int):Bool return true;\n\tfunction f(xs:Array<Int>):Void {\n'
			+ '\t\txs.foreach(p -> Helper.isPos(p));\n\t\txs.foreach(p -> ok(p));\n\t\txs.sort((a, b) '
			+ '-> Reflect.compare(a, b));\n\t\txs.map(x -> Math.sqrt(x));\n\t\txs.map(x -> Unknown.go(x));\n\t}\n}\n';
		final scoped: GrammarPlugin = StdScope.plugin(files(src));
		final check: RedundantLambdaWrapper = new RedundantLambdaWrapper();
		final vs: Array<Violation> = CheckFixture.violationsIn(check, files(src), scoped);
		final std: Int = check.riskyArmFindings(vs).length;
		Assert.equals(2, std, 'Reflect.compare and Math.sqrt');
		Assert.equals(2, vs.length - std, 'a user static and an enclosing member');
	}

	private function discriminate(label: String, gated: String, twin: String): Void {
		final root: Null<String> = StdResolver.stdDir();
		if (root == null) {
			Assert.pass('no installed Haxe std on this machine');
			return;
		}
		Assert.equals(0, oddFindings(root, gated), '$label: the gated source must be refused');
		Assert.equals(1, oddFindings(root, twin), '$label: the plain twin must fire, else the fixture never reached this gate');
	}

	private function oddFindings(root: String, lambda: String): Int {
		final src: String = body('ints.foreach($lambda);');
		final scoped: GrammarPlugin = StdScope.plugin(files(src), [{ file: Path.join([root, 'Odd.hx']), source: ODD }]);
		return CheckFixture.violationsIn(new RedundantLambdaWrapper(), files(src), scoped).length;
	}

	private function stdFindings(src: String): Array<Violation> {
		return CheckFixture.violationsIn(new RedundantLambdaWrapper(), files(src), StdScope.plugin(files(src)));
	}

	private static function body(statement: String): String {
		return 'class C {\n\tfunction f(out:Array<String>, ints:Array<Int>):Void {\n\t\t$statement\n\t}\n}\n';
	}

	private static function files(src: String): Array<{ file: String, source: String }> {
		return [{ file: 'C.hx', source: src }];
	}

	private static function apply(src: String, edits: Array<FixEdit>): String {
		return src.substring(0, edits[0].span.from) + edits[0].text + src.substring(edits[0].span.to, src.length);
	}

}
