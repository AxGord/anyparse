package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.CompilerDisplayOracle;
import anyparse.check.CompilerOracle;
import anyparse.check.ExplicitLocalType;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * End-to-end coverage of the `explicit-local-type` compiler-oracle TAIL: a warm Haxe
 * display server names the inferred type of a `.map()` / comprehension local (which
 * the structural arm cannot pin) so `fixWithOracle` annotates it, while a monomorph
 * (`var empty = []` -> `Array<Unknown<0>>`) stays report-only. The second scenario
 * drives the whole `apq lint --fix` path with a `compilerOracle` + opt-in config.
 *
 * Spawns the real compiler and a display server, so each scenario probes availability
 * (`oracleWorks`) and skips gracefully (Assert.pass) when the host has no `haxe`.
 */
class ExplicitLocalTypeOracleE2ETest extends Test {

	#if (sys || nodejs)
	private static final SRC: String = 'class Main {\n\n\tstatic function main() {\n'
		+ '\t\tvar mapped = [\'a\', \'b\'].map(function(s) return s.length);\n\t\tvar comp = [for (i in 0...3) i];\n'
		+ '\t\tvar empty = [];\n\t\ttrace(mapped, comp, empty);\n\t}\n\n}\n';

	// One inferable local inside a `macro …` quotation and one as real code. The oracle-assisted
	// batch reads its findings through `Linter.collect`, so only the second is annotated — the
	// quotation is the AST this function builds, and annotating a local there rewrites the code the
	// macro emits.
	private static final QUOTED: String = 'import haxe.macro.Expr;\n\nclass Main {\n\n\tstatic function build():Expr {\n'
		+ '\t\treturn macro {\n\t\t\tvar quoted = [for (i in 0...3) i];\n\t\t\ttrace(quoted);\n\t\t};\n\t}\n\n'
		+ '\tstatic function main() {\n\t\tvar comp = [for (i in 0...3) i];\n\t\ttrace(comp, build());\n\t}\n\n}\n';

	/**
	 * A GENERIC owner: `held` needs the oracle and its type mentions the CLASS parameter (printed
	 * `Array<Box.T>`), `both` the METHOD parameter (`Array<pair.U>`) — neither spelling compiles,
	 * so without the qualifier strip the whole file is reverted and `msg` loses its annotation too.
	 */
	private static final BOX: String = 'class Box<T> {\n\n\tpublic final v:T;\n\n\tpublic function new(v:T) {\n\t\tthis.v = v;\n\t}\n\n'
		+ '\tpublic function get():T {\n\t\tvar held = [v].map(x -> x);\n\t\treturn held[0];\n\t}\n\n'
		+ '\tpublic function pair<U>(u:U):Array<U> {\n\t\tvar both = [u].map(x -> x);\n\t\treturn both;\n\t}\n\n'
		+ '\tpublic function tag():Int {\n\t\tvar entry = [({n: 1} : Entry)];\n\t\treturn entry[0].n;\n\t}\n\n}\n\n'
		+ 'private typedef Entry = {final n:Int;}\n';
	private static final BOXMAIN: String = 'class Main {\n\n\tstatic function main() {\n'
		+ '\t\tfinal b:Box<Int> = new Box(1);\n\t\ttrace(b.get(), b.pair(\'s\'), b.tag());\n\t}\n\n}\n';
	private static final HXML: String = '-cp .\n-main Main\n';
	#end

	public function testFixWithOracleAnnotatesInference(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('eltoracle', [{ name: 'Main.hx', source: SRC }, { name: 'check.hxml', source: HXML }]);
		final path: String = '$dir/Main.hx';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: ExplicitLocalType = new ExplicitLocalType();
		final violations: Array<Violation> = check.run([{ file: path, source: SRC }], plugin).filter(v -> v.rule == 'explicit-local-type');
		Assert.equals(3, violations.length, 'three untyped locals are flagged');
		final display: Null<CompilerDisplayOracle> = CompilerDisplayOracle.start('check.hxml', dir);
		if (display == null) {
			Assert.pass('display server unavailable — skipped');
			CliFixture.removeDir(dir);
			return;
		}
		final edits: Array<{ text: String, span: Span }> = check.fixWithOracle(SRC, violations, plugin, display);
		display.stop();
		switch RefactorSupport.canonicalize(SRC, edits, true, plugin) {
			case Ok(text):
				final packed: String = StringTools.replace(text, ' ', '');
				Assert.isTrue(packed.indexOf('varmapped:Array<Int>') != -1, 'the .map() local is annotated Array<Int>');
				Assert.isTrue(packed.indexOf('varcomp:Array<Int>') != -1, 'the comprehension local is annotated Array<Int>');
				Assert.isTrue(packed.indexOf('varempty=[]') != -1, 'the monomorph empty array stays report-only');
			case Err(message):
				Assert.fail('canonicalize failed: $message');
		}
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The oracle-assisted path leaves a quoted local alone, driven through the real `apq lint --fix`
	 * with a real oracle and display server.
	 *
	 * HONEST LIMIT: this pins the BEHAVIOUR, not the gate. Measured with `Cli`'s `Linter.collect`
	 * wiring reverted, the quoted local is still not annotated — the display server has no typed AST
	 * for reified source, so `fixWithOracle` gets no type for that position and proposes nothing. The
	 * gate is therefore belt over braces here, and the assertion below would stay green without it.
	 * The gate's own coverage lives in `ReificationGateTest` (the shared entry) and
	 * `ReificationGateFixPathTest` (the sibling fix path, which IS discriminating).
	 */
	public function testCliFixLeavesQuotedLocalAlone(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final apqlint: String = '{"compilerOracle":"check.hxml","rules":{"explicit-local-type":{"enabled":true}}}';
		final dir: String = CliFixture.writeDir('eltquoted', [
			{ name: 'Main.hx', source: QUOTED },
			{ name: 'check.hxml', source: HXML },
			{ name: 'apqlint.json', source: apqlint }
		]);
		final packed: String = fixedPacked('$dir/Main.hx', '$dir/Main.hx');
		Assert.isTrue(packed.indexOf('varcomp:Array<Int>') != -1, 'the RUNTIME local is annotated, so the oracle path did run');
		Assert.isTrue(packed.indexOf('varquoted=[for') != -1, 'the QUOTED local is left exactly as written');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testCliFixAnnotatesWithOracle(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final apqlint: String = '{"compilerOracle":"check.hxml","rules":{"explicit-local-type":{"enabled":true}}}';
		final dir: String = CliFixture.writeDir('eltoracle', [
			{ name: 'Main.hx', source: SRC },
			{ name: 'check.hxml', source: HXML },
			{ name: 'apqlint.json', source: apqlint }
		]);
		final packed: String = fixedPacked('$dir/Main.hx', '$dir/Main.hx');
		Assert.isTrue(packed.indexOf('varmapped:Array<Int>') != -1, 'disk carries the oracle-annotated .map() local');
		Assert.isTrue(packed.indexOf('varcomp:Array<Int>') != -1, 'disk carries the oracle-annotated comprehension local');
		Assert.isTrue(packed.indexOf('varempty=[]') != -1, 'the monomorph stays unannotated');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testCliFixAnnotatesGenericLocals(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final apqlint: String = '{"compilerOracle":"check.hxml","rules":{"explicit-local-type":{"enabled":true}}}';
		final dir: String = CliFixture.writeDir('eltgeneric', [
			{ name: 'Box.hx', source: BOX },
			{ name: 'Main.hx', source: BOXMAIN },
			{ name: 'check.hxml', source: HXML },
			{ name: 'apqlint.json', source: apqlint }
		]);
		final packed: String = fixedPacked(dir, '$dir/Box.hx');
		Assert.isTrue(packed.indexOf('varheld:Array<T>') != -1, 'the CLASS type parameter is annotated bare');
		Assert.isTrue(packed.indexOf('varboth:Array<U>') != -1, 'the METHOD type parameter is annotated bare');
		Assert.isTrue(packed.indexOf('varentry:Array<Entry>') != -1, 'the own-module PRIVATE type is annotated bare');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * Run `lint --fix` over `scope` and return `target`'s content with every space removed — the
	 * shape every CLI scenario here shares, so an assertion can be written against the packed text.
	 */
	private function fixedPacked(scope: String, target: String): String {
		Cli.run(['lint', '--fix', '--rule', 'explicit-local-type', scope]);
		return StringTools.replace(File.getContent(target), ' ', '');
	}

	private function oracleWorks(): Bool {
		final dir: String = CliFixture.writeDir('eltoracle', [{ name: 'Main.hx', source: SRC }, { name: 'check.hxml', source: HXML }]);
		final ok: Bool = switch CompilerOracle.typecheck('check.hxml', dir) {
			case Confirmed: true;
			case _: false;
		};
		CliFixture.removeDir(dir);
		return ok;
	}
	#end

}
