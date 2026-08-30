package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.ExtractSuperclass;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.MoveSymbol.MoveResult;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `ExtractSuperclass.extract` — generate a superclass, pull a chosen set
 * of instance members up into it, and make the class extend it. Each test
 * drives the PURE op with an in-memory source, asserts the generated
 * superclass + the removed members + the `extends` edit, and re-parses.
 * Refusal cases assert `Err`.
 */
class ExtractSuperclassSliceTest extends Test {

	/** The chosen members land on the new superclass and leave the source; the source extends it. */
	public function testExtractBasic(): Void {
		final src: String = 'package pkg;\n\nclass Widget {\n\tpublic var id:Int = 0;\n\tpublic function new() {}\n'
			+ '\tpublic function bump():Void { id = id + 1; }\n\tpublic function render():String return \'w\';\n}';
		final changes: Array<MoveChange> = okChanges('pkg/Widget.hx', 'Widget', 'Base', 'pkg/Base.hx', ['id', 'bump'], src);
		Assert.equals(2, changes.length);
		final base: String = changeFor(changes, 'pkg/Base.hx').newSource;
		Assert.isTrue(base.contains('class Base'), 'declares the superclass');
		Assert.isTrue(base.contains('var id'), 'field lands on Base');
		Assert.isTrue(base.contains('function bump'), 'method lands on Base');
		final newSrc: String = changeFor(changes, 'pkg/Widget.hx').newSource;
		Assert.isTrue(newSrc.contains('class Widget extends Base {'), 'class extends Base');
		Assert.isFalse(newSrc.contains('function bump'), 'bump left the source');
		Assert.isTrue(newSrc.contains('function render'), 'render stays in the source');
	}

	/** Imports the moved bodies reference are carried into the superclass. */
	public function testImportCarry(): Void {
		final src: String = 'package pkg;\n\nimport haxe.ds.Option;\n\nclass S {\n\tpublic function new() {}\n'
			+ '\tpublic function pick():Option<Int> return None;\n\tpublic function keep():Void {}\n}';
		final changes: Array<MoveChange> = okChanges('pkg/S.hx', 'S', 'B', 'pkg/B.hx', ['pick'], src);
		Assert.isTrue(StringTools.contains(changeFor(changes, 'pkg/B.hx').newSource, 'import haxe.ds.Option;'), 'carries the import');
	}

	/** A moved member referencing a staying member is refused (stranding). */
	public function testStrandedRefused(): Void {
		final src: String = 'package pkg;\n\nclass S {\n\tpublic function new() {}\n\tpublic function helper():Int return 1;\n'
			+ '\tpublic function calc():Int return helper();\n}';
		assertErr(ExtractSuperclass.extract('pkg/S.hx', 'S', 'B', 'pkg/B.hx', ['calc'], src, plugin()));
	}

	/** `extends` is inserted before an existing `implements` clause. */
	public function testExtendsBeforeImplements(): Void {
		final src: String = 'package pkg;\n\nclass S implements IThing {\n\tpublic function new() {}\n\tpublic function a():Void {}\n'
			+ '\tpublic function thing():Void {}\n}';
		final changes: Array<MoveChange> = okChanges('pkg/S.hx', 'S', 'B', 'pkg/B.hx', ['a'], src);
		Assert.isTrue(
			StringTools.contains(changeFor(changes, 'pkg/S.hx').newSource, 'class S extends B implements IThing {'),
			'extends inserted before implements'
		);
	}

	/**
	 * A `{` inside a header comment is NOT the class body brace — the op must
	 * anchor past the comment instead of splicing `extends` into it.
	 */
	public function testCommentBraceInHeader(): Void {
		final src: String =
			'package pkg;\n\nclass Holder /* body { starts */ {\n\tpublic function new() {}\n\n\tpublic function ping():Void {}\n}\n';
		final changes: Array<MoveChange> = okChanges('pkg/Holder.hx', 'Holder', 'BaseHolder', 'pkg/BaseHolder.hx', ['ping'], src);
		final newSrc: String = changeFor(changes, 'pkg/Holder.hx').newSource;
		Assert.isTrue(newSrc.contains('class Holder extends BaseHolder /* body { starts */ {'), 'extends lands outside the comment');
		Assert.isFalse(newSrc.contains('body extends'), 'nothing spliced inside the comment');
		Assert.isFalse(newSrc.contains('function ping'), 'the pulled member left the source');
		Assert.isTrue(
			StringTools.contains(changeFor(changes, 'pkg/BaseHolder.hx').newSource, 'function ping'), 'and landed on the superclass'
		);
	}

	/** A `{` inside a header LINE comment is not the body brace either. */
	public function testLineCommentBraceInHeader(): Void {
		final src: String =
			'package pkg;\n\nclass Holder // note {\n{\n\tpublic function new() {}\n\n\tpublic function ping():Void {}\n}\n';
		final changes: Array<MoveChange> = okChanges('pkg/Holder.hx', 'Holder', 'BaseHolder', 'pkg/BaseHolder.hx', ['ping'], src);
		final newSrc: String = changeFor(changes, 'pkg/Holder.hx').newSource;
		Assert.isTrue(newSrc.contains('class Holder extends BaseHolder // note {'), 'extends lands before the line comment');
	}

	/** A structural type-parameter constraint brace is not the body brace. */
	public function testTypeParamConstraintBrace(): Void {
		final src: String =
			'package pkg;\n\nclass Holder<T:{ x:Int }> {\n\tpublic function new() {}\n\n\tpublic function ping():Void {}\n}\n';
		final changes: Array<MoveChange> = okChanges('pkg/Holder.hx', 'Holder', 'BaseHolder', 'pkg/BaseHolder.hx', ['ping'], src);
		final newSrc: String = changeFor(changes, 'pkg/Holder.hx').newSource;
		Assert.isTrue(newSrc.contains('class Holder<T:{ x:Int }> extends BaseHolder {'), 'extends lands after the type params');
	}

	/** A class that already extends a class is refused (single inheritance). */
	public function testAlreadyExtendsRefused(): Void {
		final src: String =
			'package pkg;\n\nclass S extends Other {\n\tpublic function new() { super(); }\n\tpublic function a():Void {}\n}';
		assertErr(ExtractSuperclass.extract('pkg/S.hx', 'S', 'B', 'pkg/B.hx', ['a'], src, plugin()));
	}

	/** A static member is refused. */
	public function testStaticRefused(): Void {
		final src: String = 'package pkg;\n\nclass S {\n\tpublic function new() {}\n\tpublic static function s():Void {}\n}';
		assertErr(ExtractSuperclass.extract('pkg/S.hx', 'S', 'B', 'pkg/B.hx', ['s'], src, plugin()));
	}

	/** An override member is refused. */
	public function testOverrideRefused(): Void {
		final src: String =
			'package pkg;\n\nclass S {\n\tpublic function new() {}\n\toverride public function toString():String return \'s\';\n}';
		assertErr(ExtractSuperclass.extract('pkg/S.hx', 'S', 'B', 'pkg/B.hx', ['toString'], src, plugin()));
	}

	/** A constructor is refused. */
	public function testConstructorRefused(): Void {
		final src: String = 'package pkg;\n\nclass S {\n\tpublic function new() {}\n\tpublic function a():Void {}\n}';
		assertErr(ExtractSuperclass.extract('pkg/S.hx', 'S', 'B', 'pkg/B.hx', ['new'], src, plugin()));
	}

	/** An unknown member is refused. */
	public function testUnknownMemberRefused(): Void {
		final src: String = 'package pkg;\n\nclass S {\n\tpublic function new() {}\n\tpublic function a():Void {}\n}';
		assertErr(ExtractSuperclass.extract('pkg/S.hx', 'S', 'B', 'pkg/B.hx', ['nope'], src, plugin()));
	}

	/** An empty member set is refused. */
	public function testEmptyMembersRefused(): Void {
		final src: String = 'package pkg;\n\nclass S {\n\tpublic function new() {}\n\tpublic function a():Void {}\n}';
		assertErr(ExtractSuperclass.extract('pkg/S.hx', 'S', 'B', 'pkg/B.hx', [], src, plugin()));
	}

	/**
	 * A leading header comment repeating the type name must not win the race for
	 * the name token: the `extends` clause has to land on real code. It did land
	 * inside the comment before the anchor moved to
	 * `RefactorSupport.activeCodeIdentTokenOffset` - and because the result
	 * still PARSED, nothing downstream caught it while the members had already
	 * left the source.
	 */
	public function testExtendsSkipsNameRepeatingHeaderComment(): Void {
		final src: String = 'package pkg;\n\nclass /* Holder { */ Holder {\n\tpublic function new() {}\n\tpublic function m():Void {}\n}';
		final changes: Array<MoveChange> = okChanges('pkg/Holder.hx', 'Holder', 'Base', 'pkg/Base.hx', ['m'], src);
		final newSrc: String = changeFor(changes, 'pkg/Holder.hx').newSource;
		Assert.isTrue(newSrc.contains('Holder extends Base {'), 'extends lands after the real name: <$newSrc>');
		Assert.isTrue(newSrc.contains('/* Holder { */'), 'the comment is left verbatim: <$newSrc>');
	}

	/**
	 * The created superclass is canonical UNDER THE PROJECT'S CONFIG — the twin of
	 * `ExtractInterfaceSliceTest.testCreatedInterfaceIsCanonicalUnderProjectConfig`,
	 * and the same `writeRoundTrip(source, null)` defect.
	 */
	public function testCreatedSuperclassIsCanonicalUnderProjectConfig(): Void {
		final config: String = '{"indentation": {"character": "    ", "tabWidth": 4}}';
		final src: String = 'package pkg;\n\nclass Widget {\n    public function new() {}\n\n'
			+ '    public function bump():Void {}\n\n    public function render():String return \'w\';\n}\n';
		switch ExtractSuperclass.extract('pkg/Widget.hx', 'Widget', 'Base', 'pkg/Base.hx', ['bump'], src, plugin(), config) {
			case Ok(changes, _):
				final base: String = changeFor(changes, 'pkg/Base.hx').newSource;
				Assert.isTrue(base.contains('\n    public function bump'), 'indented by the config, not the default tab:\n<$base>');
				Assert.equals(
					base, plugin().writeRoundTrip(base, config),
					'the created file must pass the ONE-pass canonical gate the next op puts on it'
				);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/**
	 * A pulled-up member carries its BODY, so every writer shape that needs TWO
	 * round trips to settle can reach the assembled superclass. One round trip
	 * there wrote a file its own `fmt --list` called drifted; the fixed-point loop
	 * is what closes it, and the advisory says the writer needed the second pass.
	 *
	 * The config and the body are the case-body shape
	 * `unit.WrapFlatSourceFixedPointTest` pins as STILL divergent, and this test
	 * goes LOUD the day that pin does — deliberately, the same way the pin itself
	 * does. The fixed-point assertion below stays true either way, but the
	 * ADVISORY assertion FAILS once the writer converges in one pass: the note is
	 * born from `rewrites > 1`, so a fixed writer produces no note and there is
	 * nothing for `advisory` to contain. That failure is the signal to read, not a
	 * bug to patch — delete the advisory assertion then, and keep the fixed-point
	 * one.
	 */
	public function testCreatedSuperclassSettlesTheWriterFixedPoint(): Void {
		final config: String = '{"indentation": {"character": "tab", "tabWidth": 4, "alignInlineSwitchCaseBody": true}, "sameLine": {'
			+ '"caseBody": "fitLine", "expressionCase": "fitLine"}, "wrapping": {"maxLineLength": 140, "objectLiteral": {"defaultWrap": '
			+ '"onePerLine", "rules": [{"conditions": [{"cond": "totalItemLength <= n", "value": 140}], "type": "noWrap"}]}}}';
		final src: String = 'package pkg;\n\nclass Unpack {\n\tpublic function new() {}\n\n\tpublic function readNode(xml: Fast): Void {\n'
			+ '\t\tswitch xml.name {\n\t\t\tcase \'zip\':\n\t\t\t\tcfg.zips.push({ path: try StringTools.trim(xml.innerData) catch ('
			+ '_: Any) \'\', file: xml.att.file, rm: xml.isTrue(\'rm\'), log: !xml.isFalse(\'log\') });\n\t\t\tcase _:\n'
			+ '\t\t\t\ttrace(xml);\n\t\t}\n\t}\n\n\tpublic function keep(): Void {}\n}\n';
		switch ExtractSuperclass.extract(
			'pkg/Unpack.hx', 'Unpack', 'BaseUnpack', 'pkg/BaseUnpack.hx', ['readNode'], src, plugin(), config
		) {
			case Ok(changes, advisory):
				final base: String = changeFor(changes, 'pkg/BaseUnpack.hx').newSource;
				Assert.equals(base, plugin().writeRoundTrip(base, config), 'the created file must be the writer FIXED POINT:\n<$base>');
				Assert.isTrue(
					advisory != null && advisory.contains('rewrites to reach its fixed point'),
					'the advisory must say the writer needed a second pass, got: $advisory'
				);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/**
	 * A blank-line run INSIDE a string literal must survive a cut somewhere else in
	 * the file.
	 *
	 * RED at the base commit, where the edited source was finished by a hand-rolled
	 * `collapseBlankRuns` — a whole-file scan that shortened any run of 3+ newlines to
	 * one blank line, with no idea where literals and comments start. It ran over the
	 * WHOLE file, so pulling up `alpha` silently deleted a newline from `banner`'s
	 * literal: the result still parsed, `fmt --list` still called it canonical, and the
	 * only witness was the string's length at runtime (measured: 20 -> 19).
	 *
	 * The WRITER already gives back the separator a cut doubles, and it cannot damage a
	 * literal doing so — not because it knows what one is (it does not: see the config
	 * note below), but because a CANONICAL source cannot hold an over-long run anywhere,
	 * so the writer never has one to shorten. That is why the hand-rolled pass is gone
	 * rather than taught about quoting.
	 *
	 * What this pins is therefore "no whole-file text scan", not "goes through the
	 * writer": a bare `applyEdits` would pass it too, which is what the M4 mutation
	 * showed. The two `testTheEditedSourceComesBackCanonical` pins carry the writer half.
	 *
	 * `maxAnywhereInFile: 2` is load-bearing: the compiled DEFAULT is 1, under which
	 * the writer itself shortens the run, and the fixture would then prove nothing
	 * about this op. (That the writer does that INSIDE a literal at all is a separate
	 * defect of its own.)
	 */
	public function testABlankRunInsideAStringLiteralSurvivesACutElsewhere(): Void {
		final config: String = '{"emptyLines": {"maxAnywhereInFile": 2}}';
		final literal: String = '"one\n\n\nfour"';
		final src: String = 'package pkg;\n\nclass Src {\n\tpublic function new() {}\n\n\tpublic function banner():String {\n'
			+ '\t\treturn $literal;\n\t}\n\n\tpublic function alpha():Int {\n\t\treturn 1;\n\t}\n}\n';
		Assert.equals(
			src, plugin().writeRoundTrip(src, config), 'the fixture must be canonical under this config, else the cut is judged by nothing'
		);
		switch ExtractSuperclass.extract('pkg/Src.hx', 'Src', 'Base', 'pkg/Base.hx', ['alpha'], src, plugin(), config, config) {
			case Ok(changes, _):
				final newSrc: String = changeFor(changes, 'pkg/Src.hx').newSource;
				Assert.isTrue(newSrc.contains(literal), 'the untouched literal keeps every newline it had:\n<$newSrc>');
				Assert.isFalse(newSrc.contains('function alpha'), 'the cut still happened — else the assertion above is vacuous');
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/**
	 * The EDITED source must come back canonical, not just the CREATED one.
	 *
	 * RED at the base commit: `extends Base ` is a verbatim splice, and on a header
	 * already near the limit it pushes the line past it — where the writer wraps the
	 * trailing `implements` clause onto a continuation line. The source was canonical
	 * one second before the op ran and drifted the moment it returned, which is the
	 * defect the created file had already been taught to avoid, one file over.
	 */
	public function testTheEditedSourceComesBackCanonical(): Void {
		final src: String = 'package pkg;\n\nclass Long implements AlphaBetaGammaDeltaEpsilonZetaEtaThetaIotaKappaLambdaMuNuXiOm'
			+ ' implements OmicronPiRhoSigmaTauUpsilonPhiChiPsiOmegaAlphaBetaGamma {\n\tpublic function new() {}\n\n'
			+ '\tpublic function alpha():Int {\n\t\treturn 1;\n\t}\n\n\tpublic function beta():Int {\n\t\treturn 2;\n\t}\n}\n';
		Assert.equals(
			src, plugin().writeRoundTrip(src, null), 'the fixture must be canonical BEFORE the op, else there is no drift to see'
		);
		final changes: Array<MoveChange> = okChanges('pkg/Long.hx', 'Long', 'Base', 'pkg/Base.hx', ['alpha'], src);
		final newSrc: String = changeFor(changes, 'pkg/Long.hx').newSource;
		Assert.equals(newSrc, plugin().writeRoundTrip(newSrc, null), 'the edited file must be the writer fixed point:\n<$newSrc>');
		// ONE string spanning both halves: the clause this op INSERTED and the wrap only the
		// writer produces. Neither can be satisfied without the other.
		Assert.isTrue(
			newSrc.contains(
				'class Long extends Base implements AlphaBetaGammaDeltaEpsilonZetaEtaThetaIotaKappaLambdaMuNuXiOm\n\t\timplements Omicron'
			),
			'the inserted `extends` sits on a header the writer then wrapped — the raw splice produced neither together'
		);
	}

	private function okChanges(
		srcFile: String, srcType: String, superName: String, superFile: String, memberNames: Array<String>, srcSource: String
	): Array<MoveChange> {
		switch ExtractSuperclass.extract(srcFile, srcType, superName, superFile, memberNames, srcSource, plugin()) {
			case Ok(changes, advisory):
				Assert.notNull(advisory);
				for (c in changes) {
					var parsed: Bool = true;
					try
						plugin().parseFile(c.newSource)
					catch (_: haxe.Exception)
						parsed = false;
					Assert.isTrue(parsed, 'rewritten ${c.file} should re-parse');
				}
				return changes;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return [];
		}
	}

	private function assertErr(result: MoveResult): Void {
		switch result {
			case Ok(changes, _):
				Assert.fail('expected Err, got Ok with ${changes.length} change(s)');
			case Err(_):
				Assert.pass();
		}
	}

	private function changeFor(changes: Array<MoveChange>, file: String): MoveChange {
		for (c in changes) if (c.file == file) return c;
		Assert.fail('no change for file $file');
		return { file: file, newSource: '' };
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

}
