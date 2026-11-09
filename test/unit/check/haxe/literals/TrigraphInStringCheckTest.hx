package unit.check.haxe.literals;

import anyparse.check.Severity;
import anyparse.check.common.literals.FoldStringLiterals;
import anyparse.check.haxe.literals.TrigraphInString;
import anyparse.grammar.json.JsonQueryPlugin;
import anyparse.macro.CppLiteralGuard;
import anyparse.query.CanonicalEdit;

/**
 * The `trigraph-in-string` check: a plain string literal holding `??` plus a trigraph tail is flagged (`Warning`) and
 * rewritten to a concatenation cut between the question marks, parenthesised where the literal's slot binds an operator.
 * Annotation arguments and target-code calls are skipped; a `case` pattern and a parameter default are reported without
 * an edit.
 */
class TrigraphInStringCheckTest extends Test {

	public function testTrigraphReportedAndOthersNot(): Void {
		final vs: Array<Violation> = violations('class C { function f() { final a = "??)"; } }');
		Assert.equals(1, vs.length);
		Assert.equals('trigraph-in-string', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals(0, violations('class C { function f() { final a = "? ?)"; } }').length);
		Assert.equals(0, violations('class C { function f() { final a = "??x"; } }').length);
		Assert.equals(1, violations("class C { function f() { final a = 'it is ??= done'; } }").length);
	}

	@:pin('control')
	@:killer('M-TRIGRAPH-CUT-NONE')
	public function testFixCutsBetweenTheQuestionMarks(): Void {
		Assert.equals("'?' + '?)'", fixOf("class C { function f() { final a = '??)'; } }"));
		Assert.equals('"x?" + "?=y"', fixOf('class C { function f() { final a = "x??=y"; } }'));
	}

	@:pin('control')
	@:killer('M-TRIGRAPH-CUT-NONE')
	public function testEveryTrigraphIsCut(): Void {
		Assert.equals("'?' + '?=?' + '?='", fixOf("class C { function f() { final a = '??=??='; } }"));
	}

	@:pin('control')
	@:killer('M-TRIGRAPH-BARE-ALWAYS')
	public function testParenthesisedWhereAnOperatorBinds(): Void {
		Assert.equals("('a?' + '?)')", fixOf("class C { function f() { final n = 'a??)'.length; } }"));
		Assert.equals("('?' + '?)')", fixOf("class C { function f(s:String) { final b = '??)' == s; } }"));
	}

	public function testBareWhereTheSlotBindsNothing(): Void {
		Assert.equals("'?' + '?)'", fixOf("class C { function f() { g('??)'); } }"));
		Assert.equals("'?' + '?)'", fixOf("class C { function f() { return '??)'; } }"));
		Assert.equals("'?' + '?)'", fixOf("class C { function f(x:String) { final a = x + '??)'; } }"));
	}

	public function testCalleePositionStillParenthesised(): Void {
		Assert.equals("('?' + '?)')", fixOf("class C { function f() { '??)'.charAt(0); } }"));
	}

	public function testAnnotationAndTargetCodeSkipped(): Void {
		Assert.equals(0, violations("@:native('??=') class C {}").length);
		Assert.equals(0, violations("class C { function f() { untyped __cpp__('??=1'); } }").length);
	}

	public function testEscapeOrInterpolationNotRead(): Void {
		Assert.equals(0, violations("class C { function f(x:Int) { final a = '$x??)'; } }").length);
		Assert.equals(0, violations("class C { function f() { final a = '\\n??)'; } }").length);
	}

	public function testPatternAndParameterDefaultReportedWithoutEdit(): Void {
		final pattern: String = "class C { function f(s:String) { switch s { case '??=': } } }";
		Assert.equals(1, violations(pattern).length);
		Assert.equals('', fixOf(pattern));
		final param: String = "class C { function f(s:String = '??=') {} }";
		Assert.equals(1, violations(param).length);
		Assert.equals('', fixOf(param));
	}

	/** The cut keeps the value and leaves no piece a C++ compiler would rewrite, while the seam between two pieces stays unmergeable. */
	@:pin('control')
	@:killer('M-TRIGRAPH-CUT-NONE')
	public function testCutPiecesKeepTheValueAndHoldNoTrigraph(): Void {
		for (text in ['??)', 'a??=b', '??=??=', '???)', '??(x)??!', '<??>-']) {
			final pieces: Array<String> = CppLiteralGuard.cutTrigraphs(text);
			Assert.equals(text, pieces.join(''));
			for (piece in pieces) Assert.isFalse(CppLiteralGuard.hasTrigraph(piece));
			for (i in 1...pieces.length) Assert.isTrue(CppLiteralGuard.joinsTrigraph(pieces[i - 1], pieces[i]));
		}
		Assert.equals(1, CppLiteralGuard.cutTrigraphs('? ?)').length);
	}

	public function testFixedFileIsCanonicalAndAFixedPointOfBothRules(): Void {
		final src: String = "class C {\n\tfunction f() {\n\t\tfinal a = 'a??)'.length;\n\t}\n}";
		switch CanonicalEdit.canonicalize(src, CheckFixture.edits(new TrigraphInString(), src), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.equals("class C {\n\tfunction f() {\n\t\tfinal a = ('a?' + '?)').length;\n\t}\n}\n", text);
				Assert.equals(0, violations(text).length);
				Assert.equals(0, CheckFixture.violations(new FoldStringLiterals(), text).length);
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		CheckFixture.assertRegistered('trigraph-in-string');
	}

	/** The compiler reads an `inline` field and an enum-abstract value as constants, so the report carries no edit there. */
	@:pin('control')
	@:killer('M-TRIGRAPH-CONSTANT-READ-NONE')
	public function testInlineConstantAndEnumAbstractValueReportedWithoutEdit(): Void {
		final inlined: String = "class C { static inline final INL: String = 'a??='; }";
		Assert.equals(1, violations(inlined).length);
		Assert.equals('', fixOf(inlined));
		final value: String = "enum abstract E(String) { var A = 'b??='; var B = 'c'; }";
		Assert.equals(1, violations(value).length);
		Assert.equals('', fixOf(value));
		Assert.equals("'a?' + '?='", fixOf("class C { static final PLAIN: String = 'a??='; }"));
	}

	/** hxcpp compiles Haxe only: a JSON document holding a trigraph is not that target's literal. */
	@:pin('control')
	@:killer('M-LANGUAGE-BOUND-RUNS-EVERYWHERE')
	public function testAnotherGrammarsDocumentIsNotReported(): Void {
		final rule: TrigraphInString = new TrigraphInString();
		final json: Array<{ file: String, source: String }> = [{ file: 'probe.json', source: '{"a": "??)"}\n' }];
		Assert.equals(0, Linter.collect(json, new JsonQueryPlugin(), [rule]).length);
		final haxe: Array<{ file: String, source: String }> = [{ file: 'Probe.hx', source: "class Probe { static final A = '??)'; }\n" }];
		Assert.equals(1, Linter.collect(haxe, new HaxeQueryPlugin(), [rule]).length);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new TrigraphInString(), src);
	}

	/** The text the fix emits for `src`'s first flagged literal (empty if none). */
	private function fixOf(src: String): String {
		final edits: Array<{ span: Span, text: String }> = CheckFixture.edits(new TrigraphInString(), src);
		return edits.length > 0 ? edits[0].text : '';
	}

}
