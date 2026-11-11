package unit.check.common.types;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Severity;
import anyparse.check.common.types.AnonShortFields;

/**
 * The `anon-short-fields` check: an anonymous structure type whose fields are all written `var x:T;` (beside short
 * fields, with `public` and `@:optional` as the only extras) becomes `{ x:T, ... }`, in a typedef body and in an inline
 * type alike. Every refusal keeps the whole body as written: a `final` / `function` field, an extension clause, an
 * `#if` region, another annotation, an accessor, an initializer, a further declarator, a doc block or a comment the
 * rewrite would lose. A fix is the writer's canonical form and a fixed source reports nothing.
 */
class AnonShortFieldsCheckTest extends Test {

	public function testAllVarFieldsFlaggedAndRewritten(): Void {
		final source: String = 'typedef P = {\n\tvar name:String;\n\tvar role:String;\n}\n';
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.equals('anon-short-fields', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		assertFixed('typedef P = { name:String, role:String }\n', source);
	}

	@:pin('control')
	@:killer('M-ANON-SHORT-SEPARATOR')
	public function testFieldsAreSeparatedByCommas(): Void {
		assertFixed('typedef P = { a:Int, b:Int, c:Int }\n', 'typedef P = { var a:Int; var b:Int; var c:Int; }\n');
	}

	@:pin('control')
	@:killer('M-ANON-SHORT-KEEPS-PUBLIC')
	public function testPublicIsDropped(): Void {
		assertFixed('typedef P = { a:Int, b:Int }\n', 'typedef P = { public var a:Int; var b:Int; }\n');
	}

	@:pin('control')
	@:killer('M-ANON-SHORT-OPTIONAL-MARK')
	public function testOptionalAnnotationBecomesTheQuestionMark(): Void {
		assertFixed('typedef P = { ?a:Int, b:Int }\n', 'typedef P = { @:optional var a:Int; var b:Int; }\n');
	}

	public function testOptionalAnnotationBeforePublicBecomesTheQuestionMark(): Void {
		assertFixed('typedef P = { ?a:Int }\n', 'typedef P = { @:optional public var a:Int; }\n');
	}

	public function testOptionalVarKeepsItsQuestionMark(): Void {
		assertFixed('typedef P = { ?a:Int, b:Int }\n', 'typedef P = { var ?a:Int; var b:Int; }\n');
	}

	public function testOptionalAnnotationOnAnOptionalVarIsOneMark(): Void {
		assertFixed('typedef P = { ?a:Int }\n', 'typedef P = { @:optional var ?a:Int; }\n');
	}

	@:pin('control')
	@:killer('M-ANON-SHORT-MIXED')
	public function testMixedBodyIsRewritten(): Void {
		assertFixed('typedef P = { a:Int, b:Int, c:Int }\n', 'typedef P = { a:Int, var b:Int; c:Int }\n');
	}

	public function testInlineTypeInASignature(): Void {
		final source: String = 'function f(a:{ var x:Int; var y:Int; }):Void {}\n';
		Assert.equals(1, violations(source).length);
		assertFixed('function f(a:{ x:Int, y:Int }):Void {}\n', source);
	}

	public function testInlineTypeOfAField(): Void {
		assertFixed('class C {\n\tvar p:{ x:Int };\n}\n', 'class C {\n\tvar p:{ var x:Int; };\n}\n');
	}

	public function testNestedStructuresAreBothRewritten(): Void {
		assertFixed('typedef P = { a:{ n:Int }, b:Int }\n', 'typedef P = { var a:{ var n:Int; }; var b:Int; }\n');
	}

	public function testGenericArgumentStructure(): Void {
		assertFixed('typedef P = { m:Map<String, { x:Int }> }\n', 'typedef P = { var m:Map<String, { var x:Int; }>; }\n');
	}

	public function testTypeParameterConstraintStructure(): Void {
		assertFixed('class C {\n\tstatic function f<T:{ x:Int }>() {}\n}\n', 'class C {\n\tstatic function f<T:{ var x:Int; }>() {}\n}\n');
	}

	public function testFunctionTypeParameterStructure(): Void {
		assertFixed('class C {\n\tvar g:(q:{ w:Int }) -> Void;\n}\n', 'class C {\n\tvar g:(q:{ var w:Int; }) -> Void;\n}\n');
	}

	@:pin('control')
	@:killer('M-ANON-SHORT-KEEPS-LONG')
	public function testFinalAmongVarsKeepsTheBodyAsWritten(): Void {
		Assert.equals(0, violations('typedef P = {\n\tvar a:Int;\n\tfinal b:Int;\n\tvar c:Int;\n}\n').length);
	}

	@:pin('control')
	@:killer('M-ANON-SHORT-KEEPS-LONG')
	public function testFunctionFieldKeepsTheBodyAsWritten(): Void {
		Assert.equals(0, violations('typedef P = {\n\tvar a:Int;\n\tfunction f():Void;\n}\n').length);
	}

	@:pin('control')
	@:killer('M-ANON-SHORT-KEEPS-LONG')
	public function testExtensionClauseKeepsTheBodyAsWritten(): Void {
		Assert.equals(0, violations('typedef P = {\n\t> Q,\n\tvar a:Int;\n}\n').length);
	}

	@:pin('control')
	@:killer('M-ANON-SHORT-KEEPS-LONG')
	public function testConditionalRegionKeepsTheBodyAsWritten(): Void {
		Assert.equals(0, violations('typedef P = {\n\tvar a:Int;\n\t#if sys\n\tvar b:Int;\n\t#end\n}\n').length);
	}

	@:pin('control')
	@:killer('M-ANON-SHORT-ACCESSOR')
	public function testAccessorKeepsTheBodyAsWritten(): Void {
		Assert.equals(0, violations('typedef P = {\n\tvar a(get, never):Int;\n\tvar b:Int;\n}\n').length);
	}

	@:pin('control')
	@:killer('M-ANON-SHORT-FOREIGN-META')
	public function testOtherAnnotationKeepsTheBodyAsWritten(): Void {
		Assert.equals(0, violations('typedef P = {\n\t@:meta var a:Int;\n\tvar b:Int;\n}\n').length);
	}

	@:pin('control')
	@:killer('M-ANON-SHORT-DOC')
	public function testDocBlockKeepsTheBodyAsWritten(): Void {
		Assert.equals(0, violations('typedef P = {\n\t/** the name */\n\tvar a:Int;\n\tvar b:Int;\n}\n').length);
	}

	@:pin('control')
	@:killer('M-ANON-SHORT-RUN-COMMENT')
	public function testCommentInTheLeadingRunKeepsTheBodyAsWritten(): Void {
		Assert.equals(0, violations('typedef P = {\n\tvar /* n */ a:Int;\n}\n').length);
	}

	@:pin('control')
	@:killer('M-ANON-SHORT-TAIL')
	public function testCommentBeforeTheTerminatorKeepsTheBodyAsWritten(): Void {
		Assert.equals(0, violations('typedef P = {\n\tvar a:Int /* n */;\n}\n').length);
	}

	public function testCommentAroundTheColonKeepsTheBodyAsWritten(): Void {
		Assert.equals(0, violations('typedef P = {\n\tvar a /* n */ :Int;\n}\n').length);
	}

	public function testInitializerKeepsTheBodyAsWritten(): Void {
		Assert.equals(0, violations('typedef P = {\n\tvar a:Int = 3;\n}\n').length);
	}

	public function testFurtherDeclaratorKeepsTheBodyAsWritten(): Void {
		Assert.equals(0, violations('typedef P = {\n\tvar a:Int, b:Int;\n}\n').length);
	}

	public function testShortFieldsAreNotFlagged(): Void {
		Assert.equals(0, violations('typedef P = { a:Int, ?b:Int }\n').length);
	}

	public function testTrailingAndOwnLineCommentsStayWithTheirFields(): Void {
		final out: String = fixed('typedef P = {\n\tvar a:Int; // the a\n\t// the b\n\tvar b:Int;\n}\n');
		Assert.isTrue(out.indexOf('// the a') != -1, out);
		Assert.isTrue(out.indexOf('// the b') != -1, out);
		Assert.isTrue(out.indexOf('var ') == -1, out);
		Assert.notNull(new HaxeQueryPlugin().writeRoundTrip(out), out);
	}

	public function testAFixedSourceReportsNothing(): Void {
		Assert.equals(0, violations(fixed('typedef P = {\n\tvar a:Int;\n\t@:optional var b:Int;\n}\n')).length);
	}

	public function testTheRuleIsOffUnlessAsked(): Void {
		Assert.isTrue(new AnonShortFields() is DefaultOff);
	}

	private function violations(source: String): Array<Violation> {
		return CheckFixture.violations(new AnonShortFields(), source);
	}

	private function fixed(source: String): String {
		return CheckFixture.fixedSource(new AnonShortFields(), source);
	}

	private function canonical(source: String): String {
		return new HaxeQueryPlugin().writeRoundTrip(source) ?? source;
	}

	/**
	 * `source` fixed spells the same structure as `expected` and nothing else: the fixed text parses, the writer lays it
	 * out exactly as it lays out `expected`, and it reports nothing more.
	 */
	private function assertFixed(expected: String, source: String): Void {
		final out: String = fixed(source);
		final written: Null<String> = new HaxeQueryPlugin().writeRoundTrip(out);
		Assert.notNull(written, out);
		Assert.equals(canonical(expected), written);
		Assert.equals(0, violations(out).length);
	}

}
