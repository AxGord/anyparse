package unit.check.haxe.expressions;

import anyparse.check.Check;
import anyparse.check.LintConfig;
import anyparse.check.Severity;
import anyparse.check.haxe.expressions.PreferSplitPart;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;

/**
 * The `prefer-split-part` check: `s.split(d)[0]` and `s.split(d).pop()` over a `String` and a non-empty literal delimiter are
 * flagged `Info` and rewritten to the project's `allBefore` / `allAfterLast`, with the import; every other cut of a string
 * (`[1]`, a count of parts, an empty or computed delimiter, a receiver that is not a `String`) stays silent.
 */
class PreferSplitPartCheckTest extends Test {

	private static inline final CONFIG: String = '{"rules":{"prefer-split-part":{"enabled":true,"textTools":"lib.Text"}}}';
	private static inline final TEXT: String = 'package lib;\nclass Text {\n\tpublic static function allBefore(text:String, delimiter:String):String return text;\n'
		+ '\tpublic static function allAfterLast(text:String, delimiter:String):String return text;\n}';

	public function testFirstPartIsAllBefore(): Void {
		final src: String = holder('var a = s.split(",")[0];');
		final found: Array<Violation> = violations(src);
		Assert.equals(1, found.length);
		Assert.equals('prefer-split-part', found[0].rule);
		Assert.equals(Severity.Info, found[0].severity);
		Assert.equals(importing(holder('var a = Text.allBefore(s, ",");')), fixed(src));
	}

	public function testPopIsAllAfterLast(): Void {
		final src: String = holder('var a = s.split(".").pop();');
		Assert.equals(1, violations(src).length);
		Assert.equals(importing(holder('var a = Text.allAfterLast(s, ".");')), fixed(src));
	}

	/** Each cut maps to its own function: the first part is the text before, the popped part the text after the last. */
	@:pin('control')
	@:killer('M-SPLITP-MEMBER-SWAP')
	public function testEachCutKeepsItsFunction(): Void {
		final src: String = holder('var a = s.split(",")[0];\n\t\tvar b = s.split(",").pop();');
		Assert.equals(importing(holder('var a = Text.allBefore(s, ",");\n\t\tvar b = Text.allAfterLast(s, ",");')), fixed(src));
	}

	public function testSingleQuotedAndLiteralReceiverAreCuts(): Void {
		Assert.equals(importing(holder("var a = Text.allBefore(s, ':');")), fixed(holder("var a = s.split(':')[0];")));
		Assert.equals(importing(holder('var a = Text.allBefore("a,b", ",");')), fixed(holder('var a = "a,b".split(",")[0];')));
	}

	/** The second part is the text between two delimiters, and null without one: `allAfter` is neither. */
	@:pin('control')
	@:killer('M-SPLITP-ANY-INDEX')
	public function testOtherPartsAndCountsAreSilent(): Void {
		for (statement in [
			'var a = s.split(",")[1];',
			'var a = s.split(",")[2];',
			'var a = s.split(",")[0 + 0];',
			'var a = s.split(",").length > 1;',
			'var a = s.split(",").shift();',
			'var a = s.split(",");'
		]) Assert.equals(0, violations(holder(statement)).length, statement);
	}

	/** A cut at `""` splits into characters, where `allBefore` answers the empty string. */
	@:pin('control')
	@:killer('M-SPLITP-EMPTY-DELIMITER')
	public function testEmptyDelimiterIsSilent(): Void {
		Assert.equals(0, violations(holder('var a = s.split("")[0];')).length);
		Assert.equals(0, violations(holder("var a = s.split('')[0];")).length);
	}

	/** A delimiter the program computes is no literal. */
	@:pin('control')
	@:killer('M-SPLITP-INTERPOLATED')
	public function testComputedDelimiterIsSilent(): Void {
		Assert.equals(0, violations(holder('var a = s.split(d)[0];')).length);
		Assert.equals(0, violations(holder("var a = s.split('$d')[0];")).length);
		Assert.equals(0, violations(holder("var a = s.split('${d}')[0];")).length);
		Assert.equals(1, violations(holder("var a = s.split('$$')[0];")).length);
	}

	/** `EReg.split` is spelled alike, and a nullable text is not what the utility takes. */
	@:pin('control')
	@:killer('M-SPLITP-ANY-RECEIVER')
	public function testOnlyStringReceiversAreCuts(): Void {
		Assert.equals(0, violations(holder('var a = r.split(",")[0];')).length);
		Assert.equals(0, violations(holder('var a = n.split(",")[0];')).length);
		Assert.equals(0, violations(holder('var a = d.split(",")[0];')).length);
	}

	@:pin('control')
	@:killer('M-SPLITP-COMMENT')
	public function testCommentInTheCutIsSilent(): Void {
		Assert.equals(0, violations(holder('var a = s.split(/* c */ ",")[0];')).length);
	}

	/** A cut over a cut is rewritten one level at a time, the inner first. */
	public function testNestedCutsRewriteOneLevelAtATime(): Void {
		final src: String = holder('var a = s.split(",")[0].split(":")[0];');
		Assert.equals(importing(holder('var a = Text.allBefore(s, ",").split(":")[0];')), fixed(src));
	}

	public function testFollowingPassTypesTheOuterCut(): Void {
		final src: String = importing(holder('var a = Text.allBefore(s, ",").split(":")[0];'));
		Assert.equals(importing(holder('var a = Text.allBefore(Text.allBefore(s, ","), ":");')), fixed(src));
	}

	/** The import goes in once for several sites, grouped with them so the verifier keeps or drops them together. */
	@:pin('control')
	@:killer('M-SPLITP-IMPORT-LOST')
	public function testImportAddedOnceAndGroupedWithItsSites(): Void {
		final src: String = holder('var a = s.split(",")[0];\n\t\tvar b = s.split(".").pop();');
		final check: PreferSplitPart = new PreferSplitPart();
		check.setConfigResolver(_ -> LintConfig.parse(CONFIG));
		final run: FixRun = CheckFixture.fixRun(check, files(src), 'C.hx', null, _ -> LintConfig.parse(CONFIG));
		final groups: Array<Null<Int>> = check.fixGrouped(
			src, run.violations, new CachingGrammarPlugin(new HaxeQueryPlugin()), CheckFixture.index(files(src))
		)
			.map(e -> e.group);
		Assert.equals(3, groups.length);
		Assert.notNull(groups[0]);
		Assert.equals(groups[0], groups[1]);
		Assert.equals(groups[0], groups[2]);
		Assert.equals(importing(holder('var a = Text.allBefore(s, ",");\n\t\tvar b = Text.allAfterLast(s, ".");')), fixed(src));
	}

	public function testVisibleTypeTakesNoImport(): Void {
		final src: String = 'package lib;\n' + holder('var a = s.split(",")[0];');
		Assert.equals('package lib;\n' + holder('var a = Text.allBefore(s, ",");'), fixed(src));
	}

	/** Without the option the rule has nothing to name: no finding, and no fix. */
	public function testInertWithoutAnOption(): Void {
		final json: String = '{"rules":{"prefer-split-part":{"enabled":true}}}';
		Assert.equals(
			0,
			CheckFixture.violationsIn(new PreferSplitPart(), files(holder('var a = s.split(",")[0];')), null, _ -> LintConfig.parse(json))
				.length
		);
	}

	/** A class the index cannot find, or one lacking a function, is an error and no site of the file is rewritten behind it. */
	@:pin('control')
	@:killer('M-SPLITP-ANY-TOOLS', 'M-SPLITP-ANY-SKIPPABLE')
	public function testUnusableToolsAreConfigurationErrors(): Void {
		final src: String = holder('var a = s.split(",")[0];');
		for (tools => reason in [
			'"lib.Gone"' => 'names no type',
			'"lib.Partial"' => 'has no one public static function allAfterLast',
			'"lib.Wrong"' => 'has no one public static function allBefore',
			'"lib.Hidden"' => 'has no one public static function allBefore',
			'"lib.Secret"' => 'private type',
			'"lib.Twin"' => 'ambiguous',
			'"lib.Text3Required"' => 'has no one public static function allBefore',
			'3' => 'is not a string'
		]) {
			final json: String = '{"rules":{"prefer-split-part":{"enabled":true,"textTools":$tools}}}';
			final all: Array<Violation> = CheckFixture.violationsIn(new PreferSplitPart(), files(src), null, _ -> LintConfig.parse(json));
			Assert.isTrue(all.length > 0, '$tools');
			for (v in all) {
				Assert.equals(Severity.Error, v.severity, '$tools');
				Assert.isNull(v.span, '$tools');
			}
			Assert.isTrue(all.filter(v -> v.message.indexOf(reason) >= 0).length > 0, '$tools: ${all.map(v -> v.message)}');
		}
	}

	/** A trailing optional parameter, as `allBefore(text, delimiter, ?startIndex)` has, is no obstacle: the call has two arguments. */
	@:pin('control')
	@:killer('M-SPLITP-EXACT-PARAMS')
	public function testTrailingOptionalParameterIsAccepted(): Void {
		final src: String = holder('var a = s.split(",")[0];');
		final json: String = '{"rules":{"prefer-split-part":{"enabled":true,"textTools":"lib.Text3"}}}';
		final run: FixRun = CheckFixture.fixRun(new PreferSplitPart(), files(src), 'C.hx', null, _ -> LintConfig.parse(json));
		Assert.equals(1, run.violations.length);
		Assert.equals(Severity.Info, run.violations[0].severity);
		Assert.equals('import lib.Text3;\n\n' + holder('var a = Text3.allBefore(s, ",");'), CanonicalEdit.applyEdits(src, run.edits));
	}

	/** `split` cuts without overlap and `lastIndexOf` takes the rightmost match, so an overlapping delimiter is no `allAfterLast`. */
	@:pin('control')
	@:killer('M-SPLITP-OVERLAPPING-POP')
	public function testPopOverASelfOverlappingDelimiterIsSilent(): Void {
		for (delimiter in ['::', '..', 'aa', 'abab', "'--'"]) {
			final quoted: String = delimiter.charAt(0) == "'" ? delimiter : '"$delimiter"';
			Assert.equals(0, violations(holder('var a = s.split($quoted).pop();')).length, delimiter);
			Assert.equals(1, violations(holder('var a = s.split($quoted)[0];')).length, delimiter);
		}
		for (delimiter in ['"::x"', '"a:b"', '":"', '"ab"', '"\\\\"', '"\\n"']) {
			final expected: Int = delimiter.indexOf('\\') >= 0 ? 0 : 1;
			Assert.equals(expected, violations(holder('var a = s.split($delimiter).pop();')).length, delimiter);
		}
	}

	public function testRegisteredDefaultOff(): Void {
		Assert.notNull(Linter.byId('prefer-split-part'));
		Assert.isTrue(Std.isOfType(new PreferSplitPart(), DefaultOff));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function holder(statement: String): String {
		return 'class C {\n\n\tfunction f(s:String, r:EReg, n:Null<String>, d:Dynamic):Void {\n\t\t$statement\n\t}\n}';
	}

	private function importing(source: String): String {
		return 'import lib.Text;\n\n$source';
	}

	private function files(source: String): Array<{ file: String, source: String }> {
		return [
			{ file: 'C.hx', source: source },
			{ file: 'lib/Text.hx', source: TEXT },
			{
				file: 'lib/Partial.hx',
				source: 'package lib;\nclass Partial {\n'
					+ '\tpublic static function allBefore(text:String, delimiter:String):String return text;\n}'
			},
			{
				file: 'lib/Wrong.hx',
				source: 'package lib;\nclass Wrong {\n\tpublic static function allBefore(text:String, delimiter:Int):String return text;\n'
					+ '\tpublic static function allAfterLast(text:String, delimiter:String):String return text;\n}'
			},
			{
				file: 'lib/Hidden.hx',
				source: 'package lib;\nclass Hidden {\n\tstatic function allBefore(text:String, delimiter:String):String return text;\n'
					+ '\tpublic static function allAfterLast(text:String, delimiter:String):String return text;\n}'
			},
			{
				file: 'lib/Text3.hx',
				source: 'package lib;\nclass Text3 {\n'
					+ '\tpublic static function allBefore(text:String, delimiter:String, ?startIndex:Int):String return text;\n'
					+ '\tpublic static function allAfterLast(text:String, delimiter:String, ?startIndex:Int):String return text;\n}'
			},
			{
				file: 'lib/Text3Required.hx',
				source: 'package lib;\nclass Text3Required {\n'
					+ '\tpublic static function allBefore(text:String, delimiter:String, startIndex:Int):String return text;\n'
					+ '\tpublic static function allAfterLast(text:String, delimiter:String, startIndex:Int):String return text;\n}'
			},
			{
				file: 'lib/Secret.hx',
				source: 'package lib;\nprivate class Secret {\n\tpublic static function allBefore(text:String, delimiter:String):String '
					+ 'return text;\n\tpublic static function allAfterLast(text:String, delimiter:String):String return text;\n}'
			},
			{ file: 'lib/Twin.hx', source: 'package lib;\nclass Twin {\n\tpublic static var one:Int = 1;\n}' },
			{ file: 'lib/other/Twin.hx', source: 'package lib;\nclass Twin {\n\tpublic static var two:Int = 2;\n}' },
			{ file: 'String.hx', source: 'extern class String { function toString():String; }' },
			{ file: 'EReg.hx', source: 'extern class EReg { function split(s:String):Array<String>; }' }
		];
	}

	private function violations(source: String): Array<Violation> {
		return CheckFixture.violationsIn(new PreferSplitPart(), files(source), null, _ -> LintConfig.parse(CONFIG))
			.filter(v -> v.file == 'C.hx');
	}

	private function fixed(source: String): String {
		return CanonicalEdit.applyEdits(
			source, CheckFixture.fixRun(new PreferSplitPart(), files(source), 'C.hx', null, _ -> LintConfig.parse(CONFIG)).edits
		);
	}

}
