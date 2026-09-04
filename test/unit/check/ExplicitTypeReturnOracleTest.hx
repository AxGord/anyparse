package unit.check;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.Check.Violation;
import anyparse.check.CompilerDisplayOracle;
import anyparse.check.CompilerOracle;
import anyparse.check.ExplicitType;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.Cli;
import anyparse.runtime.Span;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * End-to-end coverage of the `explicit-type` compiler-oracle RETURN-TYPE tail: a warm Haxe
 * display server names the type of a method the structural passes cannot pin (a value-returning
 * body), so `fixWithOracle` annotates it, while the `: Void` case is already handled structurally
 * and a constructor is never flagged at all.
 *
 * `returnTypeOf` — the parse of the compiler's printed function type — is covered directly,
 * because only a function-TYPED parameter discriminates its depth scan and no realistic fixture
 * reaches that shape through the display server.
 *
 * Spawns the real compiler and a display server, so each end-to-end scenario probes availability
 * (`oracleWorks`) and skips gracefully (Assert.pass) when the host has no `haxe`.
 */
class ExplicitTypeReturnOracleTest extends Test {

	#if (sys || nodejs)
	private static final SRC: String = 'class Main {\n\n\tpublic var count = 0;\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function label(n:Int) {\n\t\treturn n > 1 ? \'many\' : \'one\';\n\t}\n\n'
		+ '\tpublic function shout(n:Int) {\n\t\ttrace(n);\n\t}\n\n'
		+ '\tstatic function main() {\n\t\tfinal m:Main = new Main();\n\t\ttrace(m.label(2));\n\t\tm.shout(1);\n\t}\n\n}\n';

	/** A GENERIC owner: the compiler prints `Box.T` for the class parameter and `pair.U` for the method one. */
	private static final BOX: String = 'class Box<T> {\n\n\tpublic final v:T;\n\n\tpublic function new(v:T) {\n\t\tthis.v = v;\n\t}\n\n'
		+ '\tpublic function get() {\n\t\treturn v;\n\t}\n\n' + '\tpublic function pair<U>(u:U) {\n\t\treturn {a: v, b: u};\n\t}\n\n}\n';
	private static final BOXMAIN: String =
		'class Main {\n\n\tstatic function main() {\n\t\tfinal b:Box<Int> = new Box(1);\n\t\ttrace(b.get(), b.pair(\'s\'));\n\t}\n\n}\n';
	private static final HXML: String = '-cp .\n-main Main\n';
	#end

	public function new() {
		super();
	}

	// --- returnTypeOf: the printed function type ---

	public function testReturnTypeOfSimple(): Void {
		Assert.equals('String', ExplicitType.returnTypeOf('(name : String) -> String'));
	}

	public function testReturnTypeOfNoParams(): Void {
		Assert.equals('Void', ExplicitType.returnTypeOf('() -> Void'));
	}

	public function testReturnTypeOfFunctionTypedParam(): Void {
		Assert.equals('Int', ExplicitType.returnTypeOf('(f : (Int) -> Int) -> Int'));
	}

	public function testReturnTypeOfGenericResult(): Void {
		Assert.equals('Array<Int>', ExplicitType.returnTypeOf('(xs : Array<Int>) -> Array<Int>'));
	}

	public function testReturnTypeOfRejectsNonFunction(): Void {
		Assert.isNull(ExplicitType.returnTypeOf('String'));
	}

	public function testReturnTypeOfRejectsUnbalanced(): Void {
		Assert.isNull(ExplicitType.returnTypeOf('(a : Int -> Int'));
	}

	public function testReturnTypeOfRejectsMissingArrow(): Void {
		Assert.isNull(ExplicitType.returnTypeOf('(a : Int) Int'));
	}

	public function testReturnTypeOfRejectsEmptyResult(): Void {
		Assert.isNull(ExplicitType.returnTypeOf('(a : Int) ->   '));
	}

	// --- fixWithOracle end to end ---

	public function testFixWithOracleAnnotatesValueReturn(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('etroracle', [{ name: 'Main.hx', source: SRC }, { name: 'check.hxml', source: HXML }]);
		final path: String = '$dir/Main.hx';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: ExplicitType = new ExplicitType();
		final all: Array<Violation> = check.run([{ file: path, source: SRC }], plugin);
		final returns: Array<Violation> = all.filter(v -> v.message.indexOf('return type') != -1);
		Assert.equals(3, returns.length, 'label, shout and main are flagged; the constructor is not');
		final display: Null<CompilerDisplayOracle> = CompilerDisplayOracle.start('check.hxml', dir);
		if (display == null) {
			Assert.pass('display server unavailable — skipped');
			CliFixture.removeDir(dir);
			return;
		}
		final edits: Array<{ span: Span, text: String }> = check.fixWithOracle(SRC, returns, plugin, display);
		display.stop();
		switch CanonicalEdit.canonicalize(SRC, edits, true, plugin) {
			case Ok(text):
				final packed: String = StringTools.replace(text, ' ', '');
				Assert.isTrue(packed.indexOf('label(n:Int):String') != -1, 'the value-returning method is annotated String');
				Assert.isTrue(packed.indexOf('shout(n:Int):Void') != -1, 'the value-less method is annotated Void');
				Assert.isTrue(packed.indexOf('functionnew(){}') != -1, 'the constructor is left alone');
			case Err(message):
				Assert.fail('canonicalize failed: $message');
		}
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testCliFixAnnotatesReturnTypes(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final apqlint: String = '{"compilerOracle":"check.hxml"}';
		final dir: String = CliFixture.writeDir('etrcli', [
			{ name: 'Main.hx', source: SRC },
			{ name: 'check.hxml', source: HXML },
			{ name: 'apqlint.json', source: apqlint }
		]);
		Cli.run(['lint', '--fix', '--rule', 'explicit-type', '$dir/Main.hx']);
		final packed: String = File.getContent('$dir/Main.hx').replace(' ', '');
		Assert.isTrue(packed.indexOf('label(n:Int):String') != -1, 'the oracle-assisted return type reached the file');
		Assert.isTrue(packed.indexOf('shout(n:Int):Void') != -1, 'the Void return type reached the file');
		// The oracle pass only ever edits FUNCTION nodes, so a field annotated from its literal
		// initializer is the one assertion here that ONLY the structural `fix()` can satisfy.
		Assert.isTrue(packed.indexOf('count:Int=0') != -1, 'the structural initializer pass still runs alongside it');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testCliFixAnnotatesGenericOwner(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final apqlint: String = '{"compilerOracle":"check.hxml"}';
		final dir: String = CliFixture.writeDir('etrgeneric', [
			{ name: 'Box.hx', source: BOX },
			{ name: 'Main.hx', source: BOXMAIN },
			{ name: 'check.hxml', source: HXML },
			{ name: 'apqlint.json', source: apqlint }
		]);
		Cli.run(['lint', '--fix', '--rule', 'explicit-type', dir]);
		final packed: String = File.getContent('$dir/Box.hx').replace(' ', '');
		// The compiler prints these as `Box.T` / `pair.U`, which do not compile — without the
		// strip the whole file is reverted, so EITHER assertion failing means nothing landed.
		Assert.isTrue(packed.indexOf('get():T') != -1, 'the class type parameter is annotated bare');
		Assert.isTrue(packed.indexOf('pair<U>(u:U):') != -1, 'the method type parameter is annotated too');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** Whether this host can run the compiler at all — the guard every end-to-end scenario probes. */
	private function oracleWorks(): Bool {
		final dir: String = CliFixture.writeDir('etroracle', [{ name: 'Main.hx', source: SRC }, { name: 'check.hxml', source: HXML }]);
		final ok: Bool = switch CompilerOracle.typecheck('check.hxml', dir) {
			case Confirmed: true;
			case _: false;
		};
		CliFixture.removeDir(dir);
		return ok;
	}
	#end

}
