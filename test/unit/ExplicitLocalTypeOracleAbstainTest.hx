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
	private static final MAIN: String = 'package pkg;\n\nclass Main {\n\n' + '\tpublic static function run():Void {\n'
		+ '\t\tfinal winmap:Map<String, String> = [\n' + '\t\t\tfor (e in [\'a@1\', \'b@2\']) {\n' + '\t\t\t\tfinal a = e.split(\'@\');\n'
		+ '\t\t\t\ta[0] => a[1];\n\t\t\t}\n\t\t];\n' + '\t\tfinal t = new Thing(1);\n\t\tfinal t = t.next();\n'
		+ '\t\tfinal bag:Dynamic = {n: 1};\n' + '\t\tfinal loose = Reflect.field(bag, \'n\');\n'
		+ '\t\tfinal mapped = [\'a\', \'b\'].map(s -> s.length);\n' + '\t\ttrace(winmap, t, loose, mapped);\n\t}\n\n}\n\n'
		+ 'class Thing {\n\n\tpublic final n:Int;\n\n\tpublic function new(n:Int) {\n\t\tthis.n = n;\n\t}\n\n'
		+ '\tpublic function next():Thing {\n\t\treturn new Thing(n + 1);\n\t}\n\n}\n';

	/** The only module the oracle hxml compiles — `tests/pkg/Main.hx` is deliberately outside its `-cp`. */
	private static final LIB: String = 'class Lib {\n\n\tpublic static function main():Void {\n\t\ttrace(1);\n\t}\n\n}\n';
	private static final HXML: String = '-cp src\n-main Lib\n--no-output\n';
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
		final source: String =
			'class C {\n\tfunction f() {\n\t\tvar m = [\n\t\t\tfor (e in xs) {\n\t\t\t\tvar a = e.split(\'@\');\n\t\t\t\ta[0] => a[1];\n\t\t\t}\n\t\t];\n\t}\n}\n';
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
	 * The three abstentions and the control, driven through `apq lint --fix` with a real oracle
	 * over a file the oracle's own hxml does NOT compile — the condition under which every one of
	 * them shipped, because the verify-and-revert pass covers only the compiled set.
	 */
	public function testCliFixAbstainsInsteadOfMisAnnotating(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('eltabstain', [
			{ name: 'check.hxml', source: HXML },
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
			Assert.pass('haxe unavailable — skipped');
			CliFixture.removeDir(dir);
			return;
		}
		Cli.run(['lint', '--fix', '--rule', 'explicit-local-type', dir]);
		final packed: String = File.getContent('$dir/tests/pkg/Main.hx').replace(' ', '');
		Assert.isTrue(packed.indexOf('finalmapped:Array<Int>') != -1, 'the oracle pass ran over this file');
		Assert.isTrue(packed.indexOf('finala=e.split') != -1, 'the comprehension-body local keeps no enclosing type');
		Assert.isTrue(packed.indexOf('finalt=t.next()') != -1, 'the redeclaration keeps no repo-rooted path');
		Assert.isTrue(packed.indexOf('finalloose=Reflect.field') != -1, 'the untypeable local keeps no Dynamic');
		Assert.isTrue(packed.indexOf('finalt:Thing=newThing(1)') != -1, 'the structurally derivable declaration is still annotated');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
