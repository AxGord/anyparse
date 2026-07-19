package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.OversizedType;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

using StringTools;

/**
 * The `oversized-type` check: a type whose member count or line extent exceeds
 * the default thresholds (50 members / 2000 lines) is flagged `Warning`; a
 * smaller one is not. Both boundaries are pinned (== max is quiet, over flags); `#if`-guarded members count; an `apqlint.json` overrides both
 * thresholds. Report-only — `fix` yields no edits.
 */
class OversizedTypeCheckTest extends Test {

	public function testSmallTypeNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tvar x:Int;\n\tfunction f():Int { return x; }\n}').length);
	}

	public function testMemberBoundaryNotFlagged(): Void {
		// Exactly 50 members == max -> quiet (the check flags only >).
		Assert.equals(0, violations(classWithMembers(50)).length);
	}

	public function testOverMemberLimitFlagged(): Void {
		final vs: Array<Violation> = violations(classWithMembers(51));
		Assert.equals(1, vs.length);
		Assert.equals('oversized-type', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.contains("type 'C'"));
		Assert.isTrue(vs[0].message.contains('51 members (max 50)'));
		Assert.isTrue(vs[0].message.contains('hxq clusters'));
	}

	public function testOverLineLimitFlagged(): Void {
		// One member, but the type body spans > 2000 lines.
		final blanks: String = [for (_ in 0...2001) '\n'].join('');
		final vs: Array<Violation> = violations('class C {\n$blanks\tvar x:Int;\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('2004 lines (max 2000)'));
	}

	public function testLineBoundaryNotFlagged(): Void {
		// Exactly 2000 lines == max -> quiet.
		final blanks: String = [for (_ in 0...1997) '\n'].join('');
		Assert.equals(0, violations('class C {\n$blanks\tvar x:Int;\n}').length);
	}

	public function testConditionalMembersCounted(): Void {
		// 48 plain + 3 `#if`-guarded members = 51 > 50 — guarded members count.
		final src: String = classWithMembers(48).replace('\n}', '\n\t#if debug\n\tvar ca:Int;\n\tvar cb:Int;\n\tvar cc:Int;\n\t#end\n}');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('51 members (max 50)'));
	}

	public function testBareNoqaInsideBodyDoesNotSuppress(): Void {
		// Regression (WriterLowering miss): the reported span is the type HEADER line
		// only — an unrelated bare `// noqa` deep inside the body must not swallow the
		// type-level finding (span-covers suppression would clear a whole-body span).
		final src: String = classWithMembers(51).replace('\tvar v25:Int;', '\tvar v25:Int; // noqa');
		final vs: Array<Violation> = suppressed(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('51 members (max 50)'));
	}

	public function testNoqaOnHeaderLineSuppresses(): Void {
		// Deliberate suppression: a named noqa ON the header line clears the finding.
		final src: String = classWithMembers(51).replace('class C {', 'class C { // noqa: oversized-type');
		Assert.equals(0, suppressed(src).length);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = classWithMembers(51);
		final check: OversizedType = new OversizedType();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { var x ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('oversized-type'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('oversized-type'));
	}

	public function testRespectsApqlintThresholdsFromDisk(): Void {
		// End-to-end: an apqlint.json discovered by walking up from the file lowers
		// both thresholds; a 3-member, 5-line type exceeds both, and the one finding
		// names both in a single message.
		final tmp: Null<String> = Sys.getEnv('TMPDIR');
		final base: String = (tmp != null && tmp.length > 0) ? tmp : '/tmp';
		final dir: String = '$base/anyparse_ot_cfg_${Sys.time()}';
		sys.FileSystem.createDirectory(dir);
		sys.io.File.saveContent('$dir/apqlint.json', '{"rules": {"oversized-type": {"maxMembers": 2, "maxLines": 3}}}');
		final path: String = '$dir/Foo.hx';
		final src: String = 'class Foo {\n\tvar a:Int;\n\tvar b:Int;\n\tvar c:Int;\n}';
		sys.io.File.saveContent(path, src);
		final vs: Array<Violation> = new OversizedType().run([{ file: path, source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('3 members (max 2)'));
		Assert.isTrue(vs[0].message.contains('5 lines (max 3)'));
		sys.FileSystem.deleteFile(path);
		sys.FileSystem.deleteFile('$dir/apqlint.json');
		sys.FileSystem.deleteDirectory(dir);
	}

	private function violations(src: String): Array<Violation> {
		return new OversizedType().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** Like `violations`, but through `Linter.run` so inline `// noqa` suppression applies. */
	private function suppressed(src: String): Array<Violation> {
		return Linter.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin(), [new OversizedType()]);
	}

	/** A parseable class named `C` with exactly `n` field members, one per line. */
	private static function classWithMembers(n: Int): String {
		return 'class C {\n' + [for (i in 0...n) '\tvar v$i:Int;'].join('\n') + '\n}';
	}

}
