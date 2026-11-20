package unit.check.haxe.expressions;

import anyparse.check.Check;
import anyparse.check.Severity;
import anyparse.check.haxe.expressions.PreferArrayContains;

/**
 * The `prefer-array-contains` check: an `Array.indexOf` result compared against the not-found marker is flagged `Info` and
 * rewritten to `contains` — `< 0`, `== -1` and the mirrored sides to `!xs.contains(v)`, `>= 0`, `!= -1`, `> -1` and theirs
 * to `xs.contains(v)`; a `String` receiver, a `Dynamic`, an `indexOf` with a start index and a result used as a position
 * stay silent.
 */
class PreferArrayContainsCheckTest extends Test {

	/** The six forms, each with the call on the left, and the text it becomes. */
	private static final FORMS: Map<String, String> = [
		'xs.indexOf(d) < 0' => '!xs.contains(d)',
		'xs.indexOf(d) == -1' => '!xs.contains(d)',
		'-1 == xs.indexOf(d)' => '!xs.contains(d)',
		'xs.indexOf(d) >= 0' => 'xs.contains(d)',
		'xs.indexOf(d) != -1' => 'xs.contains(d)',
		'xs.indexOf(d) > -1' => 'xs.contains(d)'
	];

	/** The sides swapped: the operator mirrors and the test stays the same. */
	private static final MIRRORED: Map<String, String> = [
		'0 > xs.indexOf(d)' => '!xs.contains(d)',
		'-1 == xs.indexOf(d)' => '!xs.contains(d)',
		'0 <= xs.indexOf(d)' => 'xs.contains(d)',
		'-1 != xs.indexOf(d)' => 'xs.contains(d)',
		'-1 < xs.indexOf(d)' => 'xs.contains(d)'
	];

	/** Each form is one finding and its rewrite, over a typed `Array` parameter. */
	@:pin('control')
	@:killer('M-PAC-ABSENT-FORM')
	public function testEachFormIsRewritten(): Void {
		for (form => contains in FORMS) {
			final src: String = holder('var a = $form;');
			final found: Array<Violation> = violations(src);
			Assert.equals(1, found.length, form);
			Assert.equals('prefer-array-contains', found[0].rule, form);
			Assert.equals(Severity.Info, found[0].severity, form);
			Assert.equals(holder('var a = $contains;'), fixed(src), form);
		}
	}

	/** The call on the right is the same test as the call on the left, the operator mirrored. */
	@:pin('control')
	@:killer('M-PAC-MIRROR')
	public function testMirroredSidesAreRewritten(): Void {
		for (form => contains in MIRRORED) Assert.equals(holder('var a = $contains;'), fixed(holder('var a = $form;')), form);
	}

	/** A test inside a condition keeps its connectives: the `||` of the request this rule came from. */
	public function testTestInsideACondition(): Void {
		Assert.equals(
			holder('if (d == null || d == "" || !["A", "B"].contains(d)) trace(1);'),
			fixed(holder('if (d == null || d == "" || ["A", "B"].indexOf(d) < 0) trace(1);'))
		);
	}

	/** An array literal receiver is an `Array`, and the `!` binds to the whole call. */
	public function testArrayLiteralReceiver(): Void {
		Assert.equals(holder("var a = ![ 'a', 'b' ].contains(d);"), fixed(holder("var a = [ 'a', 'b' ].indexOf(d) < 0;")));
		Assert.equals(holder('var a = [1, 2].contains(n);'), fixed(holder('var a = [1, 2].indexOf(n) >= 0;')));
	}

	/** A field, a nested array and a call result are `Array`s by their declared type. */
	public function testTypedReceiversOtherThanParameters(): Void {
		Assert.equals(holder('var a = items.contains(d);'), fixed(holder('var a = items.indexOf(d) >= 0;')));
		Assert.equals(holder('var a = this.items.contains(d);'), fixed(holder('var a = this.items.indexOf(d) >= 0;')));
		Assert.equals(holder('var a = ys[0].contains(d);'), fixed(holder('var a = ys[0].indexOf(d) >= 0;')));
		Assert.equals(holder('var a = list().contains(d);'), fixed(holder('var a = list().indexOf(d) >= 0;')));
	}

	/** `String.indexOf` is a substring search; a `Dynamic`, an `Any` and a `Vector` give no proof of an `Array`. */
	@:pin('control')
	@:killer('M-PAC-ANY-RECEIVER')
	public function testOnlyArrayReceiversAreTests(): Void {
		for (receiver in ['s', 'dyn', 'any', 'v', 'unknown', 'n.toString()']) {
			Assert.equals(0, violations(holder('var a = $receiver.indexOf(d) < 0;')).length, receiver);
			Assert.equals(0, violations(holder('var a = $receiver.indexOf(d) >= 0;')).length, receiver);
		}
	}

	/** `contains` has no start index. */
	@:pin('control')
	@:killer('M-PAC-FROM-INDEX')
	public function testIndexOfWithAStartIndexIsSilent(): Void {
		Assert.equals(0, violations(holder('var a = xs.indexOf(d, 1) < 0;')).length);
		Assert.equals(0, violations(holder('var a = xs.indexOf(d, n) >= 0;')).length);
		Assert.equals(0, violations(holder('var a = xs.indexOf() >= 0;')).length);
	}

	/** A position, or a comparison that is not the not-found test, is not a membership test. */
	@:pin('control')
	@:killer('M-PAC-ANY-BOUND')
	public function testResultUsedAsAnIndexIsSilent(): Void {
		for (statement in [
			'var a = xs.indexOf(d);',
			'trace(xs.indexOf(d));',
			'var a = xs.indexOf(d) < n;',
			'var a = xs.indexOf(d) == n;',
			'var a = n >= xs.indexOf(d);',
			'var a = xs.indexOf(d) > 0;',
			'var a = xs.indexOf(d) == 0;',
			'var a = xs.indexOf(d) >= 1;',
			'var a = xs.indexOf(d) != 0;',
			'var a = xs.indexOf(d) < 1;',
			'var a = xs.indexOf(d) < -1;',
			'var a = xs.indexOf(d) == -2;',
			'var a = xs.indexOf(d) + 1 < 0;',
			'var a = xs.indexOf(d) < 0.0;'
		]) Assert.equals(0, violations(holder(statement)).length, statement);
	}

	/** A comment in the comparison would be dropped by the rewrite. */
	@:pin('control')
	@:killer('M-PAC-COMMENT')
	public function testCommentInTheComparisonIsSilent(): Void {
		Assert.equals(0, violations(holder('var a = xs.indexOf(d) /* c */ < 0;')).length);
		Assert.equals(0, violations(holder('var a = xs.indexOf(/* c */ d) < 0;')).length);
	}

	/** A `//` in a string is not a comment. */
	public function testCommentMarkerInAStringIsATest(): Void {
		Assert.equals(holder('var a = xs.contains("//");'), fixed(holder('var a = xs.indexOf("//") >= 0;')));
	}

	/** A test inside the searched value is rewritten by the next pass; the outer one is the finding. */
	public function testNestedTestsRewriteOneLevelAtATime(): Void {
		final src: String = holder('var a = xs.indexOf(xs.indexOf(d) >= 0 ? d : s) < 0;');
		Assert.equals(1, violations(src).length);
		Assert.equals(holder('var a = !xs.contains(xs.indexOf(d) >= 0 ? d : s);'), fixed(src));
	}

	/** The searched value keeps its own grouping. */
	public function testValueKeepsItsGrouping(): Void {
		Assert.equals(holder('var a = xs.contains(d + s);'), fixed(holder('var a = xs.indexOf(d + s) >= 0;')));
		Assert.equals(holder('var a = !xs.contains(d == null ? s : d);'), fixed(holder('var a = xs.indexOf(d == null ? s : d) < 0;')));
	}

	/** Tests in a statement list are each a finding. */
	public function testSeveralTestsInOneFile(): Void {
		final src: String = holder('var a = xs.indexOf(d) < 0;\n\t\tvar b = xs.indexOf(s) >= 0;');
		Assert.equals(2, violations(src).length);
		Assert.equals(holder('var a = !xs.contains(d);\n\t\tvar b = xs.contains(s);'), fixed(src));
	}

	public function testRegisteredAndOnByDefault(): Void {
		Assert.notNull(Linter.byId('prefer-array-contains'));
		Assert.isFalse(Std.isOfType(new PreferArrayContains(), DefaultOff));
	}

	public function testGatedAtTheVersionTheStdGainedContains(): Void {
		Assert.equals('4.0', new PreferArrayContains().minLanguageVersion());
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function holder(statement: String): String {
		return 'class C {\n\n\tvar items:Array<String>;\n\n\tfunction list():Array<String> return items;\n\n'
			+ '\tfunction f(xs:Array<String>, ys:Array<Array<String>>, s:String, n:Int, d:String, dyn:Dynamic, any:Any, '
			+ 'v:haxe.ds.Vector<String>):Void {\n\t\t$statement\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return CheckFixture.violations(new PreferArrayContains(), source);
	}

	private function fixed(source: String): String {
		return CheckFixture.fixedSource(new PreferArrayContains(), source);
	}

}
