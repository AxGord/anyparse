package unit.grammar;

import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * `@:key` refusals, asked of the compiler: a schema whose `@:key` is not exactly one string, spells a key no writer can
 * emit as written, or gives two fields one key does not build. Each case compiles a one-schema fixture against this
 * tree's `src` and reads the error the macro raises.
 */
class JsonKeyMetaCompileTest extends Test {

	/** A `@:key` that is not exactly one string literal is refused, naming the field. */
	@:pin('control') @:killer('M-JSON-KEY-UNCHECKED')
	public function testAKeyMustBeOneString(): Void {
		#if nodejs
		Assert.stringContains('@:key on field "a" takes exactly one string', compileError('@:key(1) var a: String;'));
		Assert.stringContains('@:key on field "a" takes exactly one string', compileError("@:key('a', 'b') var a: String;"));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/** A key holding a quote, a backslash or a control character is refused: the writer emits a key as written. */
	@:pin('control') @:killer('M-JSON-KEY-UNWRITABLE')
	public function testAKeyMustBeWritableAsIs(): Void {
		#if nodejs
		Assert.stringContains('holds a quote, a backslash or a control character', compileError("@:key('a\"b') var a: String;"));
		Assert.stringContains('holds a quote, a backslash or a control character', compileError("@:key('a\\\\b') var a: String;"));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/** Two fields spelled with one key are refused — the declared key and a field's own name alike — at the second field. */
	@:pin('control') @:killer('M-JSON-KEY-DUPLICATES', 'M-JSON-KEY-DUP-AT-FIELD')
	public function testTwoFieldsCannotShareAKey(): Void {
		#if nodejs
		final error: String = compileError("var a: String;\n@:key('a') var b: String;");
		Assert.stringContains('fields "a" and "b" are both spelled "a"', error);
		Assert.stringContains('Keyed.hx:2:', error, 'the error points at the second field');
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/** A well-formed key compiles: the refusals above are about the key, not the fixture. */
	public function testAWellFormedKeyCompiles(): Void {
		#if nodejs
		Assert.equals('', compileError("@:key('content-type') var a: String;"));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	#if nodejs
	/** What compiling the parser of a schema with `fields` against this tree's `src` prints on failure; '' on success. */
	private static function compileError(fields: String): String {
		final dir: String = CliFixture.writeDir('jsonkey', [
			{ name: 'Keyed.hx', source: '@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws typedef Keyed = { $fields };\n' },
			{
				name: 'Main.hx',
				source: '@:build(anyparse.macro.Build.buildParser(Keyed)) class KeyedParser {}\n'
				+ 'class Main { static function main() KeyedParser.parse("{}"); }\n'
			}
		]);
		final run: js.node.ChildProcess.ChildProcessSpawnSyncResult = js.node.ChildProcess.spawnSync('haxe', [
			'-cp',
			'${Sys.getCwd()}/src',
			'-cp',
			dir,
			'--main',
			'Main',
			'--js',
			'$dir/out.js',
			'--no-output'
		], cast { encoding: 'utf8' });
		CliFixture.removeDir(dir);
		return run.status == 0 ? '' : '${run.stderr}';
	}
	#end

}
