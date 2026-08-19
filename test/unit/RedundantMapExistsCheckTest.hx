package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check;
import anyparse.check.RedundantMapExists;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * The `redundant-map-exists` check: `m.exists(k) ? m[k] : d` is flagged `Info` and — where
 * the no-null-value census clears — rewritten to `m[k] ?? d`. The two forms diverge on a
 * key whose STORED value is null, so the census is what licenses the fix; a site it cannot
 * prove is still reported, with its own message, and gets no edit.
 */
class RedundantMapExistsCheckTest extends Test {

	public function testProvenSiteFlaggedAsFixable(): Void {
		final vs: Array<Violation> = violations(cls('safe', "'a' => 'b'", ''));
		Assert.equals(1, vs.length);
		Assert.equals('redundant-map-exists', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('can be map[key] ?? default') != -1, vs[0].message);
	}

	public function testElementWriteOfNullLeavesTheSiteUnproven(): Void {
		final vs: Array<Violation> = violations(cls('m', "'a' => 'b'", "\n\tpublic function poison():Void {\n\t\tm['x'] = null;\n\t}\n"));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('cannot be ruled out') != -1, vs[0].message);
	}

	public function testNonLiteralValueInTheInitializerLeavesTheSiteUnproven(): Void {
		final vs: Array<Violation> = violations(cls('m', "'a' => other", ''));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('cannot be ruled out') != -1, vs[0].message);
	}

	public function testEscapingReceiverLeavesTheSiteUnproven(): Void {
		// The map OBJECT reaches a callee, which can store a null through the same reference.
		final vs: Array<Violation> = violations(cls(
			'm', "'a' => 'b'",
			"\n\tpublic function leak():Void {\n\t\thand(m);\n\t}\n\n\tprivate function hand(o:Map<String, String>):Void {\n\t\to['y'] = null;\n\t}\n"
		));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('cannot be ruled out') != -1, vs[0].message);
	}

	public function testPublicFieldLeavesTheSiteUnproven(): Void {
		// A public field is writable by any holder of the instance, in a file no census sees.
		final vs: Array<Violation> = violations(cls('m', "'a' => 'b'", '', 'public'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('cannot be ruled out') != -1, vs[0].message);
	}

	public function testSubtypeStoringNullLeavesTheSiteUnproven(): Void {
		final vs: Array<Violation> = violations([
			{ file: 'Base.hx', source: base() },
			{
				file: 'Sub.hx',
				source: 'class Sub extends Base {\n\n\tpublic function new() {\n\t\tsuper();\n\t\tbad[\'x\'] = null;\n\t}\n\n}'
			}
		]);
		Assert.equals(2, vs.length);
		Assert.isTrue(vs[0].message.indexOf('can be map[key] ?? default') != -1, vs[0].message);
		Assert.isTrue(vs[1].message.indexOf('cannot be ruled out') != -1, vs[1].message);
	}

	public function testSubtypeAssigningAProvenMapLiteralKeepsTheSiteProven(): Void {
		final vs: Array<Violation> = violations([
			{ file: 'Base.hx', source: base() },
			{
				file: 'Sub.hx',
				source: 'class Sub extends Base {\n\n\tpublic function new() {\n\t\tsuper();\n\t\tgood = [\'a\' => \'b\'];\n\t}\n\n}'
			}
		]);
		Assert.equals(2, vs.length);
		Assert.isTrue(vs[0].message.indexOf('can be map[key] ?? default') != -1, vs[0].message);
	}

	public function testMismatchedKeyNotFlagged(): Void {
		Assert.equals(0, violations(cls('m', "'a' => 'b'", '', 'private', 'm.exists(k) ? m[other] : k')).length);
	}

	public function testMismatchedReceiverNotFlagged(): Void {
		Assert.equals(0, violations(cls('m', "'a' => 'b'", '', 'private', 'm.exists(k) ? n[k] : k')).length);
	}

	public function testImpureKeyNotFlagged(): Void {
		// `k` is evaluated twice by the ternary and once after; a call there is order-dependent.
		Assert.equals(0, violations(cls('m', "'a' => 'b'", '', 'private', 'm.exists(f(k)) ? m[f(k)] : k')).length);
	}

	public function testNonMapReceiverNotFlagged(): Void {
		// `arr.exists(...)` is `Lambda.exists`, and the rewrite's null-on-missing contract is
		// the Map abstract's, not a general one.
		Assert.equals(0, violations(cls('m', "'a' => 'b'", '', 'private', 'arr.exists(k) ? arr[k] : k')).length);
	}

	public function testCommentInTheDroppedRegionNotFlagged(): Void {
		Assert.equals(0, violations(cls('m', "'a' => 'b'", '', 'private', 'm.exists(k) /* why */ ? m[k] : k')).length);
	}

	public function testFixRewritesOnlyTheProvenSite(): Void {
		final source: String = base();
		final out: String = fixResult([
			{ file: 'Base.hx', source: source },
			{
				file: 'Sub.hx',
				source: 'class Sub extends Base {\n\n\tpublic function new() {\n\t\tsuper();\n\t\tbad[\'x\'] = null;\n\t}\n\n}'
			}
		], 'Base.hx');
		Assert.isTrue(out.indexOf('return good[k] ?? k;') != -1, out);
		Assert.isTrue(out.indexOf('return bad.exists(k) ? bad[k] : k;') != -1, out);
	}

	public function testFixParenthesizesATernaryFallback(): Void {
		final source: String = cls('m', "'a' => 'b'", '', 'private', 'm.exists(k) ? m[k] : (a ? k : k)')[0].source;
		final out: String = fixResult([{ file: 'C.hx', source: source }], 'C.hx');
		Assert.isTrue(out.indexOf('return m[k] ?? (a ? k : k);') != -1, out);
	}

	/** One class with a map field, a lookup over it, and an optional extra member block. */
	private function cls(
		name: String, entries: String, extra: String, ?visibility: String, ?lookup: String
	): Array<{ file: String, source: String }> {
		final vis: String = visibility ?? 'private';
		final expr: String = lookup ?? '$name.exists(k) ? $name[k] : k';
		return [
			{
				file: 'C.hx',
				source: 'class C {\n\n\t$vis var $name:Map<String, String> = [$entries];\n\n\tvar n:Map<String, String> = [];\n\n'
					+ '\tvar arr:Array<String> = [];\n\n\tvar other:String = \'o\';\n\n\tvar a:Bool = true;\n\n\tpublic function new() {}\n\n'
					+ '\tpublic function read(k:String):String {\n\t\treturn $expr;\n\t}\n\n'
					+ '\tprivate function f(s:String):String {\n\t\treturn s;\n\t}\n$extra\n}'
			}
		];
	}

	/** A base class with two map fields, one of which a subtype fixture may poison. */
	private function base(): String {
		return 'class Base {\n\n\tprivate var good:Map<String, String> = [];\n\n\tprivate var bad:Map<String, String> = [];\n\n'
			+ '\tpublic function new() {}\n\n\tpublic function readGood(k:String):String {\n\t\treturn good.exists(k) ? good[k] : k;\n\t}\n\n'
			+ '\tpublic function readBad(k:String):String {\n\t\treturn bad.exists(k) ? bad[k] : k;\n\t}\n\n}';
	}

	private function violations(files: Array<{ file: String, source: String }>): Array<Violation> {
		return new RedundantMapExists().run(files, new HaxeQueryPlugin());
	}

	/** The result of fixing `file`'s own violations — the caller hands a check ONE file's set. */
	private function fixResult(files: Array<{ file: String, source: String }>, file: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: RedundantMapExists = new RedundantMapExists();
		final vs: Array<Violation> = check.run(files, plugin).filter(v -> v.file == file);
		var source: String = '';
		for (entry in files) if (entry.file == file) source = entry.source;
		final edits: Array<{ span: Span, text: String }> = check.fix(source, vs, plugin, SymbolIndex.build(files, plugin));
		switch RefactorSupport.canonicalize(source, edits, true, plugin) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
		return '';
	}

}
