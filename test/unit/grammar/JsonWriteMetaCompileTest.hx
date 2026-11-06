package unit.grammar;

import utest.Assert;
import utest.Test;

/**
 * `@:writeNull` and `@:bare` refusals, asked of the compiler: a held null on a field that is not optional, a bare struct
 * of other than one required field, and a parser of a bare struct, whose document holds no key to read it by.
 */
class JsonWriteMetaCompileTest extends Test {

	/** `@:writeNull` on a required field is refused: only an optional one holds null. */
	public function testAWriteNullFieldIsOptional(): Void {
		#if nodejs
		Assert.stringContains('@:writeNull needs an @:optional field', compileError('', '@:writeNull var a: String;', false));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/** `@:bare` on a struct of two fields, or of one optional field, is refused. */
	public function testABareStructHoldsOneRequiredField(): Void {
		#if nodejs
		final refusal: String = '@:bare needs a struct of exactly one required field';
		Assert.stringContains(refusal, compileError('@:bare', 'var a: String; var b: String;', false));
		Assert.stringContains(refusal, compileError('@:bare', '@:optional var a: Null<String>;', false));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	/** A parser of a `@:bare` struct is refused; its writer and a `@:writeNull` field build. */
	public function testABareStructIsWrittenNotRead(): Void {
		#if nodejs
		Assert.stringContains('a @:bare struct is written, never read', compileError('@:bare', 'var a: Array<Int>;', true));
		Assert.equals('', compileError('@:bare', 'var a: Array<Int>;', false));
		Assert.equals('', compileError('', '@:optional @:writeNull var a: Null<Int>;', true));
		#else
		Assert.pass('node only: spawns the compiler');
		#end
	}

	#if nodejs
	/** What compiling a `Shaped` schema of `fields` under `typeMeta` with its parser, or its writer, prints on failure. */
	private static function compileError(typeMeta: String, fields: String, parser: Bool): String {
		final build: String = parser ? 'buildParser(Shaped)' : 'buildWriter(Shaped, ShapedOptions)';
		final use: String = parser ? 'ShapedBuild.parse("[]")' : 'ShapedBuild.write({ a: null })';
		return SchemaCompile.errorOf('jsonwritemeta', [
			{
				name: 'Shaped.hx',
				source: '@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws $typeMeta typedef Shaped = { $fields };\n'
			},
			{ name: 'ShapedOptions.hx', source: 'typedef ShapedOptions = anyparse.format.WriteOptions & {};\n' },
			{
				name: 'Main.hx',
				source: '@:build(anyparse.macro.Build.$build) class ShapedBuild {}\n'
				+ 'class Main { static function main() { try $use catch (_: Any) {} } }\n'
			}
		]);
	}
	#end

}
