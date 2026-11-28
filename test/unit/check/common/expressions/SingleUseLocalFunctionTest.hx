package unit.check.common.expressions;

import anyparse.check.Check.FixEdit;
import anyparse.check.Severity;
import anyparse.check.common.expressions.SingleUseLocalFunction;

/**
 * The `single-use-local-function` check: a local function read once, as a value, becomes a lambda at that read and its
 * declaration goes. Each refusal fixture is aimed at ONE gate; the result-type gate is proved through the file's index.
 */
class SingleUseLocalFunctionTest extends Test {

	/** The callees the fixtures pass a function to: a `Void` one, an `Int` one, a generic one and an untyped one. */
	private static final HEAD: String = 'class Box {\n\tpublic function new(f: Dynamic) {}\n}\n\nclass C {\n\tstatic function run(f: () '
		+ '-> Void): Void {}\n\tstatic function take(f: () -> Int): Int return f();\n\tstatic function each<T>(f: () '
		+ '-> T): T return f();\n\tstatic function loose(f: Dynamic): Void {}\n\tfunction m(): Dynamic {\n';

	private static final TAIL: String = '\t}\n}';

	/** The shape that motivated the rule: a hinted result the callee's parameter restates, the body one `return`. */
	@:pin('control')
	@:killer('M-SULF-BINDER-OFF')
	public function testHintedResultTheCalleeRestatesRewritten(): Void {
		final src: String = within('\t\tfunction fix(): Int {\n\t\t\treturn 1;\n\t\t}\n\t\treturn take(fix);\n');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		if (vs.length == 1) Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(within('\t\treturn take(() -> 1);\n'), fixed(src));
	}

	/** The callee in another module: its parameter's result type is read through the resolution index. */
	@:pin('guard')
	public function testCalleeAcrossFilesRewritten(): Void {
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'C.hx',
				source: 'class C {\n\tfunction m(): Int {\n\t\tfunction fix(): Int return 1;\n\t\treturn R.take(fix);\n\t}\n}'
			},
			{ file: 'R.hx', source: 'class R {\n\tpublic static function take(f: () -> Int): Int return f();\n}' }
		];
		final es: Array<FixEdit> = CheckFixture.fixRun(new SingleUseLocalFunction(), files).edits;
		Assert.equals(2, es.length);
		Assert.isTrue(es.map(e -> e.text).contains('() -> 1'));
	}

	/** A body whose returns pin its result needs no expected type: an untyped callee takes the lambda. */
	@:pin('control')
	@:killer('M-SULF-SHAPE-PROOF-OFF')
	public function testPreservingBodyNeedsNoExpectedType(): Void {
		final src: String = within('\t\tfunction go(x: Int) {\n\t\t\treturn x + 1;\n\t\t}\n\t\tloose(go);\n');
		Assert.equals(within('\t\tloose((x: Int) -> x + 1);\n'), fixed(src));
	}

	/** A lone parameter written with a type keeps its parentheses: `x: Int -> e` is no lambda. */
	@:pin('control')
	@:killer('M-HAXE-LAMBDA-LONE-TYPED-PARAM')
	public function testLoneTypedParameterParenthesised(): Void {
		Assert.equals(within('\t\tloose((x: Int) -> x);\n'), fixed(within('\t\tfunction go(x: Int) return x;\n\t\tloose(go);\n')));
	}

	/** A body of several statements is carried whole as a block, here proved `Void` by the callee's parameter. */
	@:pin('guard')
	public function testBlockBodyCarriedWhole(): Void {
		final src: String = within('\t\tfunction go() {\n\t\t\ttrace(1);\n\t\t\ttrace(2);\n\t\t}\n\t\trun(go);\n');
		Assert.equals(within('\t\trun(() -> {\n\t\t\ttrace(1);\n\t\t\ttrace(2);\n\t\t});\n'), fixed(src));
	}

	/** A comment inside a body carried whole rides along with it. */
	@:pin('guard')
	public function testBodyCommentRidesAlong(): Void {
		final src: String = within('\t\tfunction go() {\n\t\t\t// note\n\t\t\ttrace(1);\n\t\t}\n\t\trun(go);\n');
		Assert.equals(within('\t\trun(() -> {\n\t\t\t// note\n\t\t\ttrace(1);\n\t\t});\n'), fixed(src));
	}

	/** Every value position the line names: an argument, a construction argument, a return, an initializer, an assignment. */
	@:pin('control')
	@:killer('M-SULF-VALUE-POSITION-NONE')
	public function testEveryValuePositionFlagged(): Void {
		for (use in [
			'loose(go);',
			'new Box(go);',
			'return go;',
			'var h = go;',
			'var h = null;\n\t\th = go;'
		]) Assert.equals(1, violations(within('\t\tfunction go() return 1;\n\t\t$use\n')).length, use);
	}

	/** A function called by name, or read as anything but a value passed on, stays. */
	@:pin('control')
	@:killer('M-SULF-VALUE-POSITION-ANY')
	public function testCalledByNameRefused(): Void {
		for (use in ['go();', 'loose(go.bind());', 'loose(go == null);'])
			Assert.equals(0, violations(within('\t\tfunction go() return 1;\n\t\t$use\n')).length, use);
	}

	/** Read twice, it stays: the lambda could stand at only one of the reads. */
	@:pin('control')
	@:killer('M-SULF-COUNT')
	public function testUsedTwiceRefused(): Void {
		Assert.equals(0, violations(within('\t\tfunction go() return 1;\n\t\tloose(go);\n\t\tloose(go);\n')).length);
	}

	/**
	 * A recursive function reads its own name: with one more read outside it is read twice, and its inner read crosses
	 * the function itself, so two guards hold it and no single cut flips it.
	 */
	@:pin('guard')
	public function testRecursiveRefused(): Void {
		final src: String = within('\t\tfunction go(n: Int): Int return n == 0 ? 0 : go(n - 1);\n\t\tloose(go);\n');
		Assert.equals(0, violations(src).length);
	}

	/**
	 * Under a loop or a closure the lambda would be a fresh closure on every pass; a function's only read inside its own
	 * body crosses the function itself.
	 */
	@:pin('control')
	@:killer('M-SULF-BARRIER')
	public function testReferenceUnderLoopOrClosureRefused(): Void {
		for (body in [
			'\t\tfunction go() return 1;\n\t\tfor (i in 0...3) loose(go);\n',
			'\t\tfunction go() return 1;\n\t\trun(() -> loose(go));\n',
			'\t\tfunction go() {\n\t\t\tloose(go);\n\t\t\treturn 1;\n\t\t}\n'
		]) Assert.equals(0, violations(within(body)).length, body);
	}

	/** A function declaring type parameters stays: a lambda cannot declare them. */
	@:pin('control')
	@:killer('M-SULF-TYPE-PARAMS')
	public function testTypeParametersRefused(): Void {
		Assert.equals(0, violations(within('\t\tfunction go<T>(x: T) return x;\n\t\tloose(go);\n')).length);
	}

	/** A function carrying metadata is another node kind, so it is never a candidate. */
	@:pin('guard')
	public function testMetadataRefused(): Void {
		Assert.equals(0, violations(within('\t\t@:keep function go() return 1;\n\t\tloose(go);\n')).length);
	}

	/** A comment above the function, or in a part the rewrite drops, would be lost with the declaration. */
	@:pin('control')
	@:killer('M-SULF-COMMENT')
	public function testCommentRefused(): Void {
		for (decl in [
			'\t\t/** Doc. */\n\t\tfunction go() return 1;\n',
			'\t\t// note\n\t\tfunction go() return 1;\n',
			'\t\tfunction go() /* why */ return 1;\n',
			'\t\tfunction go() return 1; // trailing\n'
		]) Assert.equals(0, violations(within('${decl}\t\tloose(go);\n')).length, decl);
	}

	/** An optional, a defaulted and a rest parameter stay. */
	@:pin('control')
	@:killer('M-SULF-PARAM-FORMS')
	public function testParameterFormsRefused(): Void {
		for (param in ['?a: Int', 'a: Int = 1', '...a: Int'])
			Assert.equals(0, violations(within('\t\tfunction go($param) return 1;\n\t\tloose(go);\n')).length, param);
	}

	/** A name the body reads declared again before the reference: the moved body would read the new binding. */
	@:pin('control')
	@:killer('M-SULF-SHADOW')
	public function testShadowedCaptureRefused(): Void {
		final src: String = within('\t\tvar x = 1;\n\t\tfunction go() return x;\n\t\t{\n\t\t\tvar x = 2;\n\t\t\tloose(go);\n\t\t}\n');
		Assert.equals(0, violations(src).length);
	}

	/**
	 * The result unproved stays: a hint a generic callee would infer otherwise (`Float` against `1`), and a `Void` body
	 * whose last expression an untyped callee would take as the lambda's result.
	 */
	@:pin('control')
	@:killer('M-SULF-RESULT')
	public function testUnprovedResultRefused(): Void {
		for (body in [
			'\t\tfunction go(): Float return 1;\n\t\treturn each(go);\n',
			'\t\tfunction go() {\n\t\t\ttrace(1);\n\t\t}\n\t\tloose(go);\n'
		]) Assert.equals(0, violations(within(body)).length, body);
	}

	/** A function declared inside another flagged one rides in the outer lambda as written; the next pass takes it. */
	@:pin('guard')
	public function testNestedFunctionWaitsAPass(): Void {
		final src: String = within(
			'\t\tfunction outer() {\n\t\t\tfunction inner() return 1;\n\t\t\treturn take(inner);\n\t\t}\n\t\tloose(outer);\n'
		);
		Assert.equals(2, violations(src).length);
		Assert.equals(within('\t\tloose(() -> {\n\t\t\tfunction inner() return 1;\n\t\t\treturn take(inner);\n\t\t});\n'), fixed(src));
	}

	public function testRegistered(): Void {
		CheckFixture.assertRegistered('single-use-local-function');
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function within(body: String): String {
		return HEAD + body + TAIL;
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new SingleUseLocalFunction(), src);
	}

	private function fixed(src: String): String {
		return CheckFixture.fixedSource(new SingleUseLocalFunction(), src);
	}

}
