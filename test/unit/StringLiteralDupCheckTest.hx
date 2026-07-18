package unit;

import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.StringLiteralDup;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `string-literal-dup` check: a plain string literal repeated
 * `minOccurrences` (default 3) or more times in ONE file, whose raw content is
 * at least `minLength` (default 4) characters, yields ONE `Info` finding at its
 * first occurrence. The occurrence threshold and its boundary, the length boundary,
 * the by-construction empty / single-char exemption, the interpolation
 * exclusion (in both directions), the metadata-argument exclusion, quote-style-
 * agnostic grouping, and the `apqlint.json` overrides are all pinned.
 * Report-only — `fix` yields no edits (the constant's name is intent).
 */
class StringLiteralDupCheckTest extends Test {

	public function testThreeOccurrencesFlagged(): Void {
		// Three plain "hello" (5 chars >= minLength) -> ONE finding at the first occurrence.
		final vs: Array<Violation> = violations(body('trace("hello"); trace("hello"); trace("hello");'));
		Assert.equals(1, vs.length);
		Assert.equals('string-literal-dup', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.contains('hello'));
		Assert.isTrue(vs[0].message.contains('3 times'));
	}

	public function testTwoOccurrencesNotFlagged(): Void {
		// Boundary: two occurrences is below the default minOccurrences (3).
		Assert.equals(0, violations(body('trace("hello"); trace("hello");')).length);
	}

	public function testMinLengthBoundary(): Void {
		// "abc" (3 chars) is below the default minLength (4) -> exempt; "abcd" (4) flags.
		Assert.equals(0, violations(body('trace("abc"); trace("abc"); trace("abc");')).length);
		Assert.equals(1, violations(body('trace("abcd"); trace("abcd"); trace("abcd");')).length);
	}

	public function testEmptyAndSingleCharExempt(): Void {
		// Empty and single-character literals carry no naming value — exempt by construction (minLength).
		Assert.equals(0, violations(body('trace(""); trace(""); trace("");')).length);
		Assert.equals(0, violations(body('trace("x"); trace("x"); trace("x");')).length);
	}

	public function testInterpolationExcluded(): Void {
		// An interpolated literal captures surrounding values — not a constant candidate,
		// so three identical `'v $x'` never group.
		Assert.equals(0, violations(body('trace(\'val $$x\'); trace(\'val $$x\'); trace(\'val $$x\');')).length);
	}

	public function testInterpolationDoesNotInflatePlainGroup(): Void {
		// An interpolated occurrence must not count toward a plain literal's group:
		// two plain "value" + one interpolated stays below the threshold -> 0.
		Assert.equals(0, violations(body('trace("value"); trace("value"); trace(\'value$$x\');')).length);
	}

	public function testMetaArgsExcluded(): Void {
		// A string in `@:meta('…')` is a contract token bound to the annotation, not a
		// duplicated value — excluded, so three `@:native("metatoken")` yield nothing.
		final m: String = '\t@:native("metatoken") var';
		Assert.equals(0, violations('class C {\n$m a:Int;\n$m b:Int;\n$m c:Int;\n}').length);
	}

	public function testMetaArgsDoNotInflateCodeGroup(): Void {
		// A metadata occurrence does not count toward a code group: two plain "shared"
		// plus one `@:native("shared")` stays below the threshold -> 0.
		final src: String = 'class C {\n\t@:native("shared") var a:Int;\n\tfunction f() { trace("shared"); trace("shared"); }\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testDifferentLiteralsNotGrouped(): Void {
		// Three DISTINCT literals, one occurrence each — no group reaches the threshold.
		Assert.equals(0, violations(body('trace("aaaa"); trace("bbbb"); trace("cccc");')).length);
	}

	public function testQuoteStyleAgnosticGrouping(): Void {
		// Same string value, mixed quotes: two "hello" + one plain 'hello' group by content -> ONE finding.
		Assert.equals(1, violations(body('trace("hello"); trace("hello"); trace(\'hello\');')).length);
	}

	public function testConfigOverrideMinOccurrences(): Void {
		// An apqlint.json lowering minOccurrences to 2 flags a two-occurrence group.
		Assert.equals(
			1,
			findingsWithConfig('sld_occ', '{"rules":{"string-literal-dup":{"minOccurrences":2}}}', body('trace("hello"); trace("hello");'))
		);
	}

	public function testConfigOverrideMinLength(): Void {
		// An apqlint.json lowering minLength to 3 flags a three-char literal the default exempts.
		Assert.equals(
			1,
			findingsWithConfig(
				'sld_len', '{"rules":{"string-literal-dup":{"minLength":3}}}', body('trace("abc"); trace("abc"); trace("abc");')
			)
		);
	}

	public function testIntOptionAccessor(): Void {
		final cfg: LintConfig = LintConfig.parse('{"rules":{"string-literal-dup":{"minOccurrences":5,"minLength":8}}}');
		Assert.equals(5, cfg.intOption('string-literal-dup', 'minOccurrences'));
		Assert.equals(8, cfg.intOption('string-literal-dup', 'minLength'));
	}

	public function testFixReturnsEmpty(): Void {
		// Report-only: the constant's name is intent a human supplies, like magic-number.
		final src: String = body('trace("hello"); trace("hello"); trace("hello");');
		final check: StringLiteralDup = new StringLiteralDup();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { trace("hello"); trace("hello"); trace("hello"').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('string-literal-dup'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('string-literal-dup'));
	}

	/** Wrap `stmts` in a one-method class so the fixtures stay terse. */
	private function body(stmts: String): String {
		return 'class C {\n\tfunction f(x:Int) { $stmts }\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new StringLiteralDup().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** Write `configJson` + `fixture` to a fresh temp dir, run the check with on-disk config discovery, return the finding count. */
	private function findingsWithConfig(tag: String, configJson: String, fixture: String): Int {
		final dir: String = tmpDir(tag);
		sys.io.File.saveContent('$dir/apqlint.json', configJson);
		final path: String = '$dir/Foo.hx';
		sys.io.File.saveContent(path, fixture);
		final count: Int = new StringLiteralDup().run([{ file: path, source: fixture }], new HaxeQueryPlugin()).length;
		cleanup(dir, path);
		return count;
	}

	private function tmpDir(tag: String): String {
		final tmp: Null<String> = Sys.getEnv('TMPDIR');
		final base: String = (tmp != null && tmp.length > 0) ? tmp : '/tmp';
		final dir: String = '$base/anyparse_${tag}_${Sys.time()}';
		sys.FileSystem.createDirectory(dir);
		return dir;
	}

	private function cleanup(dir: String, path: String): Void {
		sys.FileSystem.deleteFile(path);
		sys.FileSystem.deleteFile('$dir/apqlint.json');
		sys.FileSystem.deleteDirectory(dir);
	}

}
