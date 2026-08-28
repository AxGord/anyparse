package unit;

import anyparse.check.CompilerDisplayOracle;
import anyparse.check.CompilerOracle;
import anyparse.check.ExplicitLocalType;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import utest.Assert;
import utest.Test;

using StringTools;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

/**
 * `explicit-local-type` must ABSTAIN rather than write an annotation it cannot stand behind.
 * Three ways the compiler-oracle tail used to write a wrong one, each reproduced here from the
 * tree that produced it:
 *
 * 1. The display server answers for a DIFFERENT expression when the queried offset is one it
 *    cannot map — a local inside a map-comprehension body got the COMPREHENSION's type,
 *    `haxe.ds.Map<K, V>`, type parameters and all.
 * 2. A file that no `-cp` of the oracle's hxml covers is resolved through the implicit
 *    process-cwd classpath, so every module it names is spelled REPO-relative — a redeclaration
 *    in `tests/pkg/Main.hx` got `tests.pkg.Thing` while the project builds it as `pkg.Main.Thing`.
 *    That whole configuration is now refused up front (`OracleCoverage`), which
 *    `testCliFixDeclinesAFileTheOracleDoesNotCompile` pins; the abstention stays as the guard
 *    behind it.
 * 3. `Dynamic` is the answer for an expression the compiler could not type, and writing it turns
 *    type checking OFF for the binding this rule exists to strengthen.
 *
 * The E2E scenario carries its own positive control: `mapped` needs the oracle (no structural arm
 * reaches `.map`), so its `Array<Int>` proves the assisted pass RAN over the same file where the
 * three abstentions happened — without it every assertion below would also pass on a dead oracle.
 */
class ExplicitLocalTypeOracleAbstainTest extends Test {

	#if (sys || nodejs)
	/**
	 * All three shapes in ONE out-of-scope file: the comprehension-body local `a`, the same-name
	 * redeclaration `t` (whose type is declared in this very module, so the compiler's repo-rooted
	 * path is the only spelling on offer), and `loose`, whose `Reflect.field` answer is `Dynamic`.
	 */
	private static final MAIN: String = 'package pkg;\n\nclass Main {\n\n\tpublic static function run():Void {\n'
		+ '\t\tfinal winmap:Map<String, String> = [\n\t\t\tfor (e in [\'a@1\', \'b@2\']) {\n' + '\t\t\t\tfinal a = e.split(\'@\');\n'
		+ '\t\t\t\ta[0] => a[1];\n\t\t\t}\n\t\t];\n' + '\t\tfinal t = new Thing(1);\n\t\tfinal t = t.next();\n'
		+ '\t\tfinal bag:Dynamic = {n: 1};\n' + '\t\tfinal loose = Reflect.field(bag, \'n\');\n'
		+ '\t\tfinal mapped = [\'a\', \'b\'].map(s -> s.length);\n' + '\t\ttrace(winmap, t, loose, mapped);\n\t}\n\n}\n\n'
		+ 'class Thing {\n\n\tpublic final n:Int;\n\n\tpublic function new(n:Int) {\n\t\tthis.n = n;\n\t}\n\n'
		+ '\tpublic function next():Thing {\n\t\treturn new Thing(n + 1);\n\t}\n\n}\n';

	/** The module `-main` reaches; `tests/pkg/Main.hx` is pulled in by the `include` below, or not at all. */
	private static final LIB: String = 'class Lib {\n\n\tpublic static function main():Void {\n\t\ttrace(1);\n\t}\n\n}\n';

	/** An oracle that DOES compile the fixture — `tests` on the classpath and `pkg` force-included. */
	private static final HXML: String = '-cp src\n-cp tests\n-main Lib\n--macro include(\'pkg\')\n--no-output\n';

	/** The same oracle with `tests` off its classpath: it typechecks, and it never reads the fixture. */
	private static final UNCOVERED_HXML: String = '-cp src\n-main Lib\n--no-output\n';
	private static final APQLINT: String = '{"compilerOracle":"check.hxml","rules":{"explicit-local-type":{"enabled":true}}}';
	#end

	// --- the display reply's own position: WHICH expression the compiler answered about ---

	/**
	 * The verbatim reply behind defect 1, from `install/src/NpmInstall.hx@1305@type` on a real
	 * tree. Its `p` names lines 43-44 — the enclosing comprehension — while the query sits on
	 * line 45.
	 */
	public function testParsesLineRangePosition(): Void {
		final raw: String = '<type p="/p/install/src/NpmInstall.hx:43: lines 43-44" d="\n\tMap allows key to value mapping.\n">\n'
			+ 'haxe.ds.Map&lt;haxe.ds.Map.K, haxe.ds.Map.V&gt;\n</type>';
		final pos: Null<TypeReplyPosition> = CompilerDisplayOracle.parseTypePosition(raw);
		if (pos == null) {
			Assert.fail('the p attribute was not parsed');
			return;
		}
		Assert.equals('/p/install/src/NpmInstall.hx', pos.file);
		Assert.isTrue(pos.byLine);
		Assert.equals(43, pos.first);
		Assert.equals(44, pos.last);
	}

	public function testParsesCharacterRangePosition(): Void {
		final pos: Null<TypeReplyPosition> =
			CompilerDisplayOracle.parseTypePosition('<type p="/p/NinjaTest.hx:16: characters 9-10">\nT\n</type>');
		if (pos == null) {
			Assert.fail('the p attribute was not parsed');
			return;
		}
		Assert.equals(16, pos.line);
		Assert.isFalse(pos.byLine);
		Assert.equals(9, pos.first);
		Assert.equals(10, pos.last);
	}

	/** No `p` at all is not a refusal — the reply simply cannot be placed, and the caller keeps it. */
	public function testPositionlessReplyParsesNull(): Void {
		Assert.isNull(CompilerDisplayOracle.parseTypePosition('<type>String</type>'));
	}

	/** A `characters a-b` region is 1-based and its start is the queried byte itself. */
	public function testCoversOwnDeclaration(): Void {
		final source: String = 'class C {\n\tfunction f() {\n\t\tvar n = g();\n\t}\n}\n';
		final at: Int = source.indexOf('n = g');
		final col: Int = at - source.indexOf('\t\tvar') + 1;
		Assert.isTrue(CompilerDisplayOracle.replyCovers(source, {
			file: 'C.hx',
			line: 3,
			first: col,
			last: col + 1,
			byLine: false
		}, at));
	}

	/** The defect-1 shape: the answer describes lines ABOVE the queried one, so it is not about this local. */
	public function testRejectsEnclosingLineRange(): Void {
		final source: String = 'class C {\n\tfunction f() {\n\t\tvar m = [\n\t\t\tfor (e in xs) {\n\t\t\t\tvar a = e.split(\'@\');\n'
			+ '\t\t\t\ta[0] => a[1];\n\t\t\t}\n\t\t];\n\t}\n}\n';
		final at: Int = source.indexOf('a = e.split');
		Assert.isFalse(CompilerDisplayOracle.replyCovers(source, {
			file: 'C.hx',
			line: 3,
			first: 3,
			last: 4,
			byLine: true
		}, at));
	}

	// --- Dynamic / Any are never an admissible answer ---

	public function testRejectsDynamic(): Void {
		Assert.isNull(ExplicitLocalType.normalizeInferredType('Dynamic', [], 80));
	}

	public function testRejectsAny(): Void {
		Assert.isNull(ExplicitLocalType.normalizeInferredType('Any', [], 80));
	}

	public function testRejectsDynamicComponent(): Void {
		Assert.isNull(ExplicitLocalType.normalizeInferredType('Array<Dynamic>', [], 80));
	}

	/** A name merely CONTAINING `Dynamic` is a different type and stays admissible. */
	public function testKeepsDynamicNamedType(): Void {
		Assert.equals('DynamicBag', ExplicitLocalType.normalizeInferredType('DynamicBag', [], 80));
	}

	/** `var x:Void` is not a declaration Haxe accepts — the answer is about some enclosing statement. */
	public function testRejectsBareVoid(): Void {
		Assert.isNull(ExplicitLocalType.normalizeInferredType('Void', [], 80));
	}

	/** `Void` inside a type is ordinary — a callback local keeps its annotation. */
	public function testKeepsFunctionReturningVoid(): Void {
		Assert.equals('() -> Void', ExplicitLocalType.normalizeInferredType('() -> Void', [], 80));
	}

	/**
	 * The STRUCTURAL arm refuses `Dynamic` too. It reaches the name by a different route — a
	 * written cast target copied out of the source rather than a compiler answer — and the
	 * annotation is exactly as unhelpful, so the refusal cannot live on the oracle arm alone.
	 */
	public function testStructuralArmRefusesDynamic(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar x = (g() : Dynamic);\n\t}\n}';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: ExplicitLocalType = new ExplicitLocalType();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin).length);
	}

	// --- end to end, against a real compiler and display server ---

	/**
	 * The abstentions and the control, driven through `apq lint --fix` with a real oracle over a
	 * file that oracle DOES compile — the only configuration in which the assisted pass may write
	 * at all, since `testCliFixDeclinesAFileTheOracleDoesNotCompile` below pins the other one.
	 */
	public function testCliFixAbstainsInsteadOfMisAnnotating(): Void {
		#if (sys || nodejs)
		final packed: Null<String> = fixedMain(HXML);
		if (packed == null) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final result: String = packed;
		Assert.isTrue(result.indexOf('finalmapped:Array<Int>') != -1, 'the oracle pass ran over this file');
		Assert.isTrue(result.indexOf('finala=e.split') != -1, 'the comprehension-body local keeps no enclosing type');
		Assert.isTrue(result.indexOf('finalloose=Reflect.field') != -1, 'the untypeable local keeps no Dynamic');
		Assert.isTrue(result.indexOf('finalt:Thing=newThing(1)') != -1, 'the structurally derivable declaration is still annotated');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The oracle-assisted pass must write NOTHING into a file its own hxml does not compile.
	 *
	 * That pass annotates and then asks `haxe <hxml> --no-output` whether the tree still builds —
	 * a control that cannot fire for a file the compile never reads, so every answer it gave was
	 * `Confirmed` by construction. This is where defect 2 of the three above came from: the
	 * display server answers for such a file anyway (the process cwd is implicitly on the
	 * compiler's classpath), and it spells the module REPO-relative, so `tests/pkg/Main.hx` got
	 * `tests.pkg.Thing` for a project that builds it as `pkg.Main.Thing`. The abstention that
	 * caught it is still in place; this pins the phase that should never have asked.
	 *
	 * The last assertion is the run's own control: the STRUCTURAL pass needs no oracle and does
	 * annotate here, so a run that did nothing at all — a broken fixture, a `--rule` that matched
	 * nothing — cannot pass this test by writing nothing.
	 */
	public function testCliFixDeclinesAFileTheOracleDoesNotCompile(): Void {
		#if (sys || nodejs)
		final packed: Null<String> = fixedMain(UNCOVERED_HXML);
		if (packed == null) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final result: String = packed;
		Assert.isTrue(result.indexOf('finalmapped=[') != -1, 'the assisted pass annotated a file the oracle never compiles');
		Assert.isTrue(result.indexOf('finalt=t.next()') != -1, 'the redeclaration was annotated from a compile that never read it');
		Assert.isTrue(result.indexOf('finalt:Thing=newThing(1)') != -1, 'the structural pass, which needs no oracle, still ran');
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * The fixture written out under `hxml` and driven through `apq lint --fix`, returned as
	 * `tests/pkg/Main.hx` with every space removed — or null when the fixture does not typecheck
	 * at all, which every caller reports as a skip rather than a pass it did not earn.
	 */
	private static function fixedMain(hxml: String): Null<String> {
		final dir: String = CliFixture.writeDir('eltabstain', [
			{ name: 'check.hxml', source: hxml },
			{ name: 'apqlint.json', source: APQLINT }
		]);
		FileSystem.createDirectory('$dir/src');
		FileSystem.createDirectory('$dir/tests');
		FileSystem.createDirectory('$dir/tests/pkg');
		File.saveContent('$dir/src/Lib.hx', LIB);
		File.saveContent('$dir/tests/pkg/Main.hx', MAIN);
		final compiles: Bool = switch CompilerOracle.typecheck('check.hxml', dir) {
			case Confirmed: true;
			case _: false;
		};
		if (!compiles) {
			CliFixture.removeDir(dir);
			return null;
		}
		Cli.run(['lint', '--fix', '--rule', 'explicit-local-type', dir]);
		final packed: String = File.getContent('$dir/tests/pkg/Main.hx').replace(' ', '');
		CliFixture.removeDir(dir);
		return packed;
	}
	#end

}
