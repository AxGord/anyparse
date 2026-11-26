package unit.check.common.loops;

import anyparse.check.Check;
import anyparse.check.Severity;
import anyparse.check.common.loops.RedundantMapExists;
import anyparse.query.CanonicalEdit;
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

	/**
	 * The failed proof IS the decline, so it is written onto the finding as its `declineReason`;
	 * a proven site carries none.
	 *
	 * The census's verdict was already the finding's message, and only the message — so
	 * `apq lint --fix`'s ledger reported that this check "declares neither NoAutofix nor a decline
	 * reason" for a site whose text says exactly why.
	 *
	 * RED at base on the `notNull`; the proven arm is green at base BY CONSTRUCTION and
	 * discriminates a reason written for every finding rather than for the declined ones.
	 */
	public function testUnprovenSiteCarriesItsDeclineReason(): Void {
		final unproven: Array<Violation> = violations(cls('m', "'a' => other", ''));
		Assert.equals(1, unproven.length);
		final reason: Null<String> = unproven[0].declineReason;
		if (reason == null) {
			Assert.fail('an unproven site carries no decline reason though its message states one: ${unproven[0].message}');
			return;
		}
		Assert.isTrue(reason.indexOf('stored null') != -1, reason);
		final proven: Array<Violation> = violations(cls('safe', "'a' => 'b'", ''));
		Assert.equals(1, proven.length);
		Assert.isNull(proven[0].declineReason, 'a proven site is fixed, so it declines nothing');
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
			'\n\tpublic function leak():Void {\n\t\thand(m);\n\t}\n\n\tprivate function hand(o:Map<String, String>):Void {\n'
			+ "\t\to['y'] = null;\n\t}\n"
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

	public function testFixParenthesizesALogicalFallback(): Void {
		// `??` binds tighter than `||`: `m[k] ?? a || b` would read `(m[k] ?? a) || b`.
		final source: String = cls('m', "'a' => 'b'", '', 'private', 'm.exists(k) ? m[k] : a || b')[0].source;
		final out: String = fixResult([{ file: 'C.hx', source: source }], 'C.hx');
		Assert.isTrue(out.indexOf('return m[k] ?? (a || b);') != -1, out);
	}

	/**
	 * A file the grammar cannot parse leaves the REPORT scope incomplete — but only for a member it
	 * SPELLS, since that is the only way it could hold a reference. This pins both halves, and which
	 * index the gate reads: handed the RESOLUTION index instead, whose skipped set is permanently
	 * non-empty on any project with libraries configured, the gate would be false for every site — and
	 * the check would report sites as fixable while emitting no edit at all.
	 */
	public function testAnUnparseableFileMentioningTheMemberLeavesTheSiteUnproven(): Void {
		final poisoned: Array<Violation> = violations(
			cls('m', "'a' => 'b'", '').concat([{ file: 'Broken.hx', source: 'class Broken { this is not haxe m' }])
		);
		Assert.equals(1, poisoned.length);
		if (poisoned.length == 1) Assert.isTrue(poisoned[0].message.indexOf('cannot be ruled out') != -1, poisoned[0].message);
		// The same unparseable file NOT spelling the member proves nothing about it, and the
		// site is decided on its own evidence again. A whole-project veto here silenced the
		// check for every file in a scope holding one unparseable file.
		final clean: Array<Violation> = violations(
			cls('m', "'a' => 'b'", '').concat([{ file: 'Broken.hx', source: 'class Broken { this is not haxe' }])
		);
		Assert.equals(1, clean.length);
		if (clean.length == 1) Assert.isTrue(clean[0].message.indexOf('cannot be ruled out') == -1, clean[0].message);
	}

	/** A `//` inside a string literal in a dropped region is no comment: the site is still flagged. */
	@:pin('control')
	@:killer('M-HCM-E-MAPEXISTS-STRING')
	public function testStringMarkerInTheDroppedRegionFlagged(): Void {
		Assert.equals(1, violations(cls('m', "'a' => 'b'", '', 'private', "m.exists('//') ? m['//'] : k")).length);
	}

	/** `if (m.exists(k)) return m[k];` reads the map once into a local typed `Null<V>` and tests the local. */
	@:pin('control')
	@:killer('M-RME-STMT-ARM')
	public function testReturnFormReadsTheMapOnce(): Void {
		final out: String = fixStatement('', 'if (counts.exists(k)) return counts[k];\n\t\treturn 0;');
		Assert.isTrue(out.indexOf('final count:Null<Int> = counts[k];\n\t\tif (count != null) return count;') != -1, out);
	}

	/** Every read of the block form becomes the local, and the else branch is kept as written. */
	@:pin('control')
	@:killer('M-RME-STMT-READS')
	public function testBlockFormRespellsEveryReadAndKeepsTheElse(): Void {
		final out: String = fixStatement(
			'',
			'if (counts.exists(k)) {\n\t\t\tfinal twice: Int = counts[k] * 2;\n\t\t\treturn twice + counts[k];\n\t\t} else {\n'
			+ '\t\t\treturn -1;\n\t\t}'
		);
		Assert.isTrue(
			out.indexOf(
				'final count:Null<Int> = counts[k];\n\t\tif (count != null) {\n\t\t\tfinal twice:Int = count * 2;\n'
				+ '\t\t\treturn twice + count;\n\t\t} else {\n\t\t\treturn -1;\n\t\t}'
			) != -1,
			out
		);
	}

	/** A map the census cannot prove free of stored nulls is reported with the reason and left as written. */
	@:pin('control')
	@:killer('M-RME-STMT-PROOF')
	public function testNullStoringMapLeftAlone(): Void {
		final body: String = 'if (counts.exists(k)) return counts[k];\n\t\tcounts[k] = null;\n\t\treturn 0;';
		final vs: Array<Violation> = violations(statementClass('', body));
		Assert.equals(1, vs.length);
		if (vs.length == 1) Assert.isTrue(vs[0].message.indexOf('cannot be ruled out') != -1, vs[0].message);
		Assert.isTrue(fixStatement('', body).indexOf('if (counts.exists(k)) return counts[k];') != -1);
	}

	/** A public memo field of `Null<V>` values — a memo that stores null by design — is left alone, and the finding says why. */
	@:pin('control')
	@:killer('M-RME-STMT-DECLINE')
	public function testPublicNullableMemoFieldLeftAlone(): Void {
		final fields: String = '\tpublic final paths: Map<String, Null<String>> = [];\n\n';
		final body: String = 'if (paths.exists(k)) return paths[k] == null ? 1 : 2;\n\t\treturn 0;';
		final vs: Array<Violation> = violations(statementClass(fields, body));
		Assert.equals(1, vs.length);
		if (vs.length == 1) Assert.isTrue((vs[0].declineReason ?? '').indexOf('stored null') != -1, vs[0].message);
		Assert.isTrue(fixStatement(fields, body).indexOf('if (paths.exists(k)) return paths[k] == null') != -1);
	}

	/** A call that runs between two reads may write the map, so the reads may answer differently: no finding. */
	@:pin('control')
	@:killer('M-RME-STMT-RUNS-BEFORE')
	public function testCallBetweenTheReadsNotFlagged(): Void {
		final body: String =
			'if (counts.exists(k)) {\n\t\t\tfinal a: Int = counts[k];\n\t\t\tpoke(k);\n\t\t\treturn a + counts[k];\n\t\t}\n\t\treturn 0;';
		Assert.equals(0, violations(statementClass('', body)).length);
	}

	/** A read that is the target of a write writes the map, and the local cannot stand for it: no finding. */
	@:pin('control')
	@:killer('M-RME-STMT-WRITE-TARGET')
	public function testIndexWriteInTheThenBranchNotFlagged(): Void {
		Assert.equals(0, violations(statementClass('', 'if (counts.exists(k)) counts[k] = counts[k] + 1;\n\t\treturn 0;')).length);
	}

	/** A then-branch that redeclares the map's name reads another map through the same spelling: no finding. */
	@:pin('control')
	@:killer('M-RME-STMT-OTHER-USE')
	public function testRedeclaredMapNameNotFlagged(): Void {
		final body: String =
			'if (counts.exists(k)) {\n\t\t\tfinal counts: Map<String, Int> = [\'a\' => 1];\n\t\t\treturn counts[k];\n\t\t}\n\t\treturn 0;';
		Assert.equals(0, violations(statementClass('', body)).length);
	}

	/** A read inside a closure runs when the closure does, after code that may write the map: no finding. */
	@:pin('control')
	@:killer('M-RME-STMT-DEFERRED')
	public function testReadInAClosureNotFlagged(): Void {
		final body: String = 'if (counts.exists(k)) {\n\t\t\tfinal later: () -> Null<Int> = () -> counts[k];\n\t\t\tpoke(k);\n'
			+ '\t\t\treturn later();\n\t\t}\n\t\treturn 0;';
		Assert.equals(0, violations(statementClass('', body)).length);
	}

	/** A local name already spelled in the enclosing function is refused: the site is reported with the reason and not rewritten. */
	@:pin('control')
	@:killer('M-RME-STMT-COLLISION')
	public function testNameCollisionRefused(): Void {
		final body: String = 'final count: Int = 1;\n\t\tif (counts.exists(k)) return counts[k] + count;\n\t\treturn 0;';
		final vs: Array<Violation> = violations(statementClass('', body));
		Assert.equals(1, vs.length);
		if (vs.length == 1) Assert.isTrue((vs[0].declineReason ?? '').indexOf('already spelled') != -1, vs[0].message);
		Assert.isTrue(fixStatement('', body).indexOf('if (counts.exists(k)) return counts[k] + count;') != -1);
	}

	/** A map name with no singular names the local after the key. */
	@:pin('control')
	@:killer('M-RME-STMT-KEY-NAME')
	public function testKeyNamesTheLocalWhenTheMapNameHasNoSingular(): Void {
		final fields: String = '\tprivate var cache: Map<String, Int> = [];\n\n';
		final out: String = fixStatement(fields, 'if (cache.exists(k)) return cache[k];\n\t\treturn 0;');
		Assert.isTrue(out.indexOf('final kValue:Null<Int> = cache[k];\n\t\tif (kValue != null) return kValue;') != -1, out);
	}

	/** A read inside a loop runs again after code textually behind it, which may write the map: no finding. */
	@:pin('control')
	@:killer('M-RME-STMT-LOOP')
	public function testReadInALoopNotFlagged(): Void {
		final body: String = 'var total: Int = 0;\n\t\tif (counts.exists(k)) {\n\t\t\tfor (i in 0...2) {\n\t\t\t\ttotal += counts[k];\n'
			+ '\t\t\t\tpoke(k);\n\t\t\t}\n\t\t}\n\t\treturn total;';
		Assert.equals(0, violations(statementClass('', body)).length);
	}

	/** A map declared without its `Map<K, V>` arguments gives the local no type: reported with the reason, not rewritten. */
	@:pin('control')
	@:killer('M-RME-STMT-UNTYPED')
	public function testUntypedMapDeclarationRefused(): Void {
		final fields: String = '\tprivate var raw: Map = new Map();\n\n';
		final body: String = 'if (raw.exists(k)) return raw[k];\n\t\treturn 0;';
		final vs: Array<Violation> = violations(statementClass(fields, body));
		Assert.equals(1, vs.length);
		if (vs.length == 1) Assert.isTrue((vs[0].declineReason ?? '').indexOf('writes no value type') != -1, vs[0].message);
		Assert.isTrue(fixStatement(fields, body).indexOf('if (raw.exists(k)) return raw[k];') != -1);
	}

	/** A comment inside a span the rewrite re-spells would be deleted with it, so the site is not matched. */
	@:pin('control')
	@:killer('M-RME-STMT-COMMENT')
	public function testCommentInARespelledSpanNotFlagged(): Void {
		Assert.equals(0, violations(statementClass('', 'if (counts.exists(/* why */ k)) return counts[k];\n\t\treturn 0;')).length);
	}

	/** A base class with two map fields, one of which a subtype fixture may poison. */
	private inline function base(): String {
		return 'class Base {\n\n\tprivate var good:Map<String, String> = [];\n\n\tprivate var bad:Map<String, String> = [];\n\n'
			+ '\tpublic function new() {}\n\n\tpublic function readGood(k:String):String {\n\t\treturn good.exists(k) ? good[k] : k;\n\t}\n'
			+ '\n\tpublic function readBad(k:String):String {\n\t\treturn bad.exists(k) ? bad[k] : k;\n\t}\n\n}';
	}

	/** One class with a map field, a lookup over it, and an optional extra member block. */
	private function cls(
		name: String, entries: String, extra: String, ?visibility: String, ?lookup: String
	): Array<{ file: String, source: String }> {
		final vis: String = visibility ?? 'private';
		final expr: String = lookup ?? '$name.exists(k) ? $name[k] : k';
		return [{
			file: 'C.hx',
			source: 'class C {\n\n\t$vis var $name:Map<String, String> = [$entries];\n\n\tvar n:Map<String, String> = [];\n\n'
				+ '\tvar arr:Array<String> = [];\n\n\tvar other:String = \'o\';\n\n\tvar a:Bool = true;\n\n\tpublic function new() {}\n'
				+ '\n\tpublic function read(k:String):String {\n\t\treturn $expr;\n\t}\n\n\tprivate function f(s:String):String {\n'
				+ '\t\treturn s;\n\t}\n$extra\n}'
		}];
	}

	private function violations(files: Array<{ file: String, source: String }>): Array<Violation> {
		return CheckFixture.violationsIn(new RedundantMapExists(), files);
	}

	/** The result of fixing `file`'s own violations — the caller hands a check ONE file's set. */
	private function fixResult(files: Array<{ file: String, source: String }>, file: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: RedundantMapExists = new RedundantMapExists();
		final vs: Array<Violation> = CheckFixture.violationsIn(check, files, plugin).filter(v -> v.file == file);
		var source: String = '';
		for (entry in files) if (entry.file == file) source = entry.source;
		final edits: Array<{ span: Span, text: String }> = check.fix(source, vs, plugin, CheckFixture.index(files, plugin));
		switch CanonicalEdit.canonicalize(source, edits, true, plugin) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
		return '';
	}

	/** One class with a proven `counts` map, optional extra fields, a `read` body and a `poke` that writes the map. */
	private function statementClass(fields: String, body: String): Array<{ file: String, source: String }> {
		return [{
			file: 'S.hx',
			source: 'class S {\n\n\tprivate var counts: Map<String, Int> = [];\n\n$fields\tpublic function new() {}\n\n\tpublic function '
				+ 'read(k: String): Int {\n\t\t$body\n\t}\n\n\tprivate function poke(k: String): Void {\n\t\tcounts[k] = 2;\n\t}\n\n}'
		}];
	}

	/** The fixed source of `statementClass(fields, body)`. */
	private function fixStatement(fields: String, body: String): String {
		return fixResult(statementClass(fields, body), 'S.hx');
	}

}
