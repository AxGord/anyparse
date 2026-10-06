package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.PreferApiIdiom;
import anyparse.check.RuleDeclaration;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `prefer-api-idiom` check: adjacent writes of every field a declared idiom names, on one receiver of EXACTLY the
 * declared type, become the declared method call (`p.x = 1; p.y = 2;` → `p.setTo(1, 2);`, `p.x = q.x; p.y = q.y;` →
 * `p.copyFrom(q);`). Each soundness gate — an impure right-hand side, one reading a field written above it, a getter hop
 * in the receiver, a subclass or a namesake receiver, a partial write, a comment the rewrite would drop, a window inside
 * the type itself — is pinned by its own fixture, and so is every verdict of the config reader.
 */
class PreferApiIdiomCheckTest extends Test {

	/** The idiom type: two plain fields, a getter property, a static, the declared method and copy, and a one-argument method. */
	private static final POINT: String = 'package geom;\n\nclass Point {\n\tpublic var x:Float;\n\tpublic var y:Float;\n'
		+ '\tpublic var len(get, never):Float;\n\tpublic static var origin:Float = 0;\n\n'
		+ '\tpublic function new(x:Float = 0, y:Float = 0) {\n\t\tthis.x = x;\n\t\tthis.y = y;\n\t}\n\n'
		+ '\tpublic function setTo(xa:Float, ya:Float):Void {\n\t\tthis.x = xa;\n\t\tthis.y = ya;\n\t}\n\n'
		+ '\tpublic function copyFrom(p:Point):Void {\n\t\tx = p.x;\n\t\ty = p.y;\n\t}\n\n'
		+ '\tpublic function setOne(a:Float):Void {}\n\n\tfunction get_len():Float {\n\t\treturn x;\n\t}\n}\n';

	private static final SUB_POINT: String = 'package geom;\n\nclass SubPoint extends Point {}\n';

	/** A namesake in another package: same simple name, same members, a different declaration. */
	private static final OTHER_POINT: String = 'package other;\n\nclass Point {\n\tpublic var x:Float;\n\tpublic var y:Float;\n\n'
		+ '\tpublic function new() {}\n\n\tpublic function setTo(a:Float, b:Float):Void {}\n}\n';

	/** Path receivers: a plain field and a getter property of the idiom type. */
	private static final HOLDER: String = 'package app;\n\nimport geom.Point;\n\nclass Holder {\n\tpublic var pt:Point = new Point();\n'
		+ '\tpublic var pt2(get, never):Point;\n\n\tpublic function new() {}\n\n\tfunction get_pt2():Point {\n\t\treturn pt;\n\t}\n}\n';

	private static final CONFIG: String = '{"rules":{"prefer-api-idiom":{"idioms":['
		+ '{"type":"geom.Point","fields":["x","y"],"method":"setTo"},{"type":"geom.Point","fields":["x","y"],"copy":"copyFrom"}]}}}';
	private static final SUBTYPES_CONFIG: String =
		'{"rules":{"prefer-api-idiom":{"idioms":[{"type":"geom.Point","fields":["x","y"],"method":"setTo","subtypes":true}]}}}';

	public function testPairedWritesBecomeTheMethodCall(): Void {
		final vs: Array<Violation> = violationsOf(user('p.x = 1;\n\t\tp.y = 2;'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-api-idiom', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('geom.Point.setTo') != -1, vs[0].message);
		final out: String = fixResultOf(user('p.x = 1;\n\t\tp.y = 2;'));
		Assert.isTrue(out.indexOf('\t\tp.setTo(1, 2);\n') != -1, out);
		Assert.isTrue(out.indexOf('p.x = 1') == -1, out);
	}

	public function testReversedWritesKeepTheDeclaredParameterOrder(): Void {
		Assert.equals('p.setTo(1, 2);', onlyEditText(user('p.y = 2;\n\t\tp.x = 1;')));
	}

	public function testCopyWindowBecomesTheCopyMethod(): Void {
		Assert.equals('p.copyFrom(q);', onlyEditText(user('p.x = q.x;\n\t\tp.y = q.y;')));
	}

	public function testCopyAcceptsASubtypeValue(): Void {
		Assert.equals('p.copyFrom(s);', onlyEditText(user('p.x = s.x;\n\t\tp.y = s.y;')));
	}

	public function testPathReceiverThroughAPlainField(): Void {
		Assert.equals('h.pt.setTo(1, 2);', onlyEditText(user('h.pt.x = 1;\n\t\th.pt.y = 2;')));
	}

	public function testReadingTheOldValueOfItsOwnFieldIsKept(): Void {
		Assert.equals('p.setTo(p.x + 1, p.y + 1);', onlyEditText(user('p.x = p.x + 1;\n\t\tp.y = p.y + 1;')));
	}

	public function testOnlyTheMatchedWindowOfALongerRunIsRewritten(): Void {
		final out: String = fixResultOf(user('p.x = 1;\n\t\tp.y = 2;\n\t\tp.x = 3;'));
		Assert.isTrue(out.indexOf('\t\tp.setTo(1, 2);\n\t\tp.x = 3;\n') != -1, out);
	}

	/** A getter hop reads code once per statement today and once in the call. */
	@:pin('control') @:killer('M-IDIOM-GETTER-HOP')
	public function testAGetterHopInTheReceiverRefuses(): Void {
		Assert.equals(0, violationsOf(user('h.pt2.x = 1;\n\t\th.pt2.y = 2;')).length);
	}

	/** A call may reach the written fields through an alias, and the call form evaluates every argument first. */
	@:pin('control') @:killer('M-IDIOM-NO-PURITY')
	public function testAnImpureRightHandSideRefuses(): Void {
		Assert.equals(0, violationsOf(user('p.x = next();\n\t\tp.y = 2;')).length);
	}

	/** `p.y = p.x` reads the NEW `x` today and the old one in `setTo(1, p.x)`. */
	@:pin('control') @:killer('M-IDIOM-NO-EARLIER-READ-GATE')
	public function testReadingAFieldWrittenAboveRefuses(): Void {
		Assert.equals(0, violationsOf(user('p.x = 1;\n\t\tp.y = p.x;')).length);
	}

	/** `q` may alias `p`, so ANY receiver's read of a field written above refuses. */
	@:pin('control') @:killer('M-IDIOM-NO-EARLIER-READ-GATE')
	public function testReadingThatFieldThroughAnotherReceiverRefuses(): Void {
		Assert.equals(0, violationsOf(user('p.x = 1;\n\t\tp.y = q.x;')).length);
	}

	/** A subclass may override the method with one that is no longer the declared equivalence. */
	@:pin('control') @:killer('M-IDIOM-SUBTYPES-ALWAYS')
	public function testASubclassReceiverRefusesUnlessDeclared(): Void {
		Assert.equals(0, violationsOf(user('s.x = 1;\n\t\ts.y = 2;')).length);
		Assert.equals('s.setTo(1, 2);', onlyEditText(user('s.x = 1;\n\t\ts.y = 2;'), SUBTYPES_CONFIG));
	}

	public function testANamesakeInAnotherPackageRefuses(): Void {
		Assert.equals(0, violationsOf(user('o.x = 1;\n\t\to.y = 2;')).length);
	}

	public function testAPartialOrInterruptedWriteRefuses(): Void {
		Assert.equals(0, violationsOf(user('p.x = 1;')).length);
		Assert.equals(0, violationsOf(user('p.x = 1;\n\t\tnext();\n\t\tp.y = 2;')).length);
		Assert.equals(0, violationsOf(user('p.x = 1;\n\t\tq.y = 2;')).length);
	}

	/** The comment would be deleted with the statements, or end up describing the whole call. */
	@:pin('control') @:killer('M-IDIOM-NO-COMMENT-GATE')
	public function testACommentInTheWindowRefuses(): Void {
		Assert.equals(0, violationsOf(user('p.x = 1; // one\n\t\tp.y = 2;')).length);
		Assert.equals(0, violationsOf(user('p.x = 1;\n\t\tp.y = 2; // two')).length);
	}

	public function testACompoundWriteRefuses(): Void {
		Assert.equals(0, violationsOf(user('p.x += 1;\n\t\tp.y = 2;')).length);
	}

	public function testAnUnannotatedLocalReceiverRefuses(): Void {
		Assert.equals(0, violationsOf(user('final r = new Point();\n\t\tr.x = 1;\n\t\tr.y = 2;')).length);
	}

	/** `setTo`'s own body writes `this.x` then `this.y`: rewriting it into `this.setTo(xa, ya)` would recurse forever. */
	@:pin('control') @:killer('M-IDIOM-NO-SELF-TYPE-GATE')
	public function testTheTypesOwnBodyIsNeverRewritten(): Void {
		final vs: Array<Violation> = violationsOf(user('p.x = 1;\n\t\tp.y = 2;'));
		Assert.equals(0, vs.filter(v -> v.file == 'geom/Point.hx').length, [for (v in vs) '${v.file} ${v.message}'].join('\n'));
		Assert.equals(1, vs.length);
	}

	public function testNoConfigIsInert(): Void {
		Assert.equals(0, violationsOf(user('p.x = 1;\n\t\tp.y = 2;'), '{}').length);
		Assert.equals('needs-config', new PreferApiIdiom().skipReason('app/User.hx', LintConfig.parse('{}')));
		Assert.isNull(new PreferApiIdiom().skipReason('app/User.hx', LintConfig.parse(CONFIG)));
	}

	@:pin('control') @:killer('M-IDIOM-READER-LENIENT')
	public function testTheReaderNamesEveryDroppedEntry(): Void {
		final problems: Array<String> = [];
		final specs: Array<IdiomSpec> = RuleDeclaration.idioms(
			LintConfig.parse(
				'{"rules":{"prefer-api-idiom":{"idioms":[1, {"fields":["x"],"method":"m"}, {"type":"T","method":"m"}, {'
				+ '"type":"T","fields":["x","x"],"method":"m"},{"type":"T","fields":["x"],"method":"m","copy":"c"}, {"type":"T",'
				+ '"fields":["x"]}, {"type":"T","fields":"x","method":"m"},{"type":"T","fields":["x"],"method":"m","extra":1}]}}}'
			),
			'prefer-api-idiom', problems
		);
		Assert.equals(1, specs.length, 'only the last entry survives, its unknown key ignored');
		Assert.same([
			'idioms[0] is not an object — dropped',
			'idioms[1] declares no "type" — dropped',
			'idioms[2] ("T") declares no "fields" list of names — dropped',
			'idioms[3] ("T") names a field twice — dropped',
			'idioms[4] ("T") must declare exactly one of "method" and "copy" — dropped',
			'idioms[5] ("T") must declare exactly one of "method" and "copy" — dropped',
			'idioms[6] "fields" has the wrong type — dropped',
			'idioms[7] declares unknown key "extra" — ignored'
		], problems);
		final notArray: Array<String> = [];
		Assert.equals(
			0,
			RuleDeclaration.idioms(LintConfig.parse('{"rules":{"prefer-api-idiom":{"idioms":{}}}}'), 'prefer-api-idiom', notArray).length
		);
		Assert.same(['"idioms" is not an array — ignored'], notArray);
	}

	@:pin('control') @:killer('M-IDIOM-VALIDATE-TRUSTS')
	public function testTheIndexRefutesADeclarationThatCannotBeTrue(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final index: SymbolIndex = SymbolIndex.build(user('p.x = 1;'), plugin);
		final specs: Array<IdiomSpec> = RuleDeclaration.idioms(
			LintConfig.parse(
				'{"rules":{"prefer-api-idiom":{"idioms":[{"type":"geom.Nope","fields":["x"],"method":"setOne"},{'
				+ '"type":"geom.Point","fields":["len","y"],"method":"setTo"},{"type":"geom.Point","fields":["origin","y"],'
				+ '"method":"setTo"},{"type":"geom.Point","fields":["x","y"],"method":"setOne"},{"type":"geom.Point","fields":["x"],'
				+ '"copy":"setOne"},{"type":"geom.Point","fields":["x","y"],"method":"setTo"}]}}}'
			),
			'prefer-api-idiom', []
		);
		final problems: Array<String> = [];
		final fieldKinds: Array<String> = plugin.refShape().fieldDeclKinds ?? [];
		final memberKinds: Array<String> = plugin.refShape().memberDeclKinds ?? [];
		final idioms: Array<Idiom> = PreferApiIdiom.validate(specs, index, fieldKinds, memberKinds, plugin.typeSyntax, problems);
		Assert.equals(1, idioms.length);
		Assert.same([
			'"geom.Nope" names no single type in the resolution scope — idiom dropped',
			'"geom.Point.len" is not a plain instance field (a property with an accessor, a method, a static, or nothing) — idiom dropped',
			'"geom.Point.origin" is not a plain instance field (a property with an accessor, a method, a static, or nothing) '
			+ '— idiom dropped',
			'"geom.Point.setOne" is not an instance method of 2 parameter(s) — idiom dropped',
			'"geom.Point.setOne" does not take a "geom.Point" — copy idiom dropped'
		], problems);
	}

	/** The fixture set: the user file first (its findings are the ones fixed), then every type it reaches. */
	private function user(body: String): Array<{ file: String, source: String }> {
		final source: String = 'package app;\n\nimport geom.Point;\n\nclass User {\n\tpublic function new() {}\n\n'
			+ '\tfunction f(p:Point, q:Point, s:geom.SubPoint, h:Holder, o:other.Point):Void {\n\t\t$body\n\t}\n\n'
			+ '\tfunction next():Float {\n\t\treturn 0;\n\t}\n}\n';
		return [
			{ file: 'app/User.hx', source: source },
			{ file: 'app/Holder.hx', source: HOLDER },
			{ file: 'geom/Point.hx', source: POINT },
			{ file: 'geom/SubPoint.hx', source: SUB_POINT },
			{ file: 'other/Point.hx', source: OTHER_POINT }
		];
	}

	private function check(config: String): PreferApiIdiom {
		final rule: PreferApiIdiom = new PreferApiIdiom();
		rule.setConfigResolver(_ -> LintConfig.parse(config));
		return rule;
	}

	private function violationsOf(files: Array<{ file: String, source: String }>, ?config: String): Array<Violation> {
		return check(config ?? CONFIG).run(files, new HaxeQueryPlugin());
	}

	private function editsOf(files: Array<{ file: String, source: String }>, ?config: String): Array<{ span: Span, text: String }> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final rule: PreferApiIdiom = check(config ?? CONFIG);
		final own: Array<Violation> = rule.run(files, plugin).filter(v -> v.file == files[0].file);
		return own.length == 0 ? [] : rule.fix(files[0].source, own, plugin, SymbolIndex.build(files, plugin));
	}

	private function onlyEditText(files: Array<{ file: String, source: String }>, ?config: String): String {
		final edits: Array<{ span: Span, text: String }> = editsOf(files, config);
		Assert.equals(1, edits.length);
		return edits.length == 1 ? edits[0].text : '';
	}

	/** `files[0]` with its own findings fixed, canonicalised WITHOUT reformatting, exactly as `apq lint --fix` writes it. */
	private function fixResultOf(files: Array<{ file: String, source: String }>, ?config: String): String {
		switch CanonicalEdit.canonicalize(files[0].source, editsOf(files, config), false, new HaxeQueryPlugin()) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
		return '';
	}

}
