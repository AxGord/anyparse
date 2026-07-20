package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.ExtractConstant;
import anyparse.query.RefactorSupport.EditResult;
import haxe.Exception;

/**
 * `ExtractConstant.extractConstant` — replace a repeated plain
 * single-quoted string literal inside a type with a `private static final`
 * constant. Each test drives the PURE op on an in-memory source (with
 * `reformat` so the raw string need not be canonical); `Ok` results are
 * re-parsed, refusals assert `Err`.
 */
class ExtractConstantSliceTest extends Test {

	/** Every occurrence is replaced and one constant is spliced in. */
	public function testBasicExtract(): Void {
		final src: String = "package pkg;\n\nclass K {\n\tstatic function f(k:String, j:String):Bool {\n\t\treturn k == 'base.ref' || j == 'base.ref';\n\t}\n}";
		final text: String = okExtract(src, 'K', 'BASE_REF', 'base.ref');
		Assert.isTrue(StringTools.contains(text, "private static final BASE_REF:String = 'base.ref'"), 'constant declared');
		Assert.isTrue(StringTools.contains(text, 'k == BASE_REF'), 'first occurrence replaced');
		Assert.isTrue(StringTools.contains(text, 'j == BASE_REF'), 'second occurrence replaced');
		Assert.isFalse(StringTools.contains(text, "== 'base.ref'"), 'no literal left at a use site');
	}

	/** The constant becomes the type's first member. */
	public function testConstantIsFirstMember(): Void {
		final src: String = "package pkg;\n\nclass K {\n\tstatic function f(k:String):Bool {\n\t\treturn k == 'x.y';\n\t}\n}";
		final text: String = okExtract(src, 'K', 'X_Y', 'x.y');
		final constIdx: Int = text.indexOf('private static final X_Y');
		final fnIdx: Int = text.indexOf('function f');
		Assert.isTrue(constIdx >= 0 && constIdx < fnIdx, 'constant is spliced before the first method');
	}

	/** A single occurrence still extracts. */
	public function testSingleOccurrence(): Void {
		final src: String = "package pkg;\n\nclass K {\n\tstatic function f(k:String):Bool {\n\t\treturn k == 'solo';\n\t}\n}";
		final text: String = okExtract(src, 'K', 'SOLO', 'solo');
		Assert.isTrue(StringTools.contains(text, 'k == SOLO'), 'occurrence replaced');
	}

	/** A name colliding with an existing member is refused. */
	public function testNameCollisionRefused(): Void {
		final src: String = "package pkg;\n\nclass K {\n\tstatic function f(k:String):Bool {\n\t\treturn k == 'dup';\n\t}\n\tstatic function DUP():Void {}\n}";
		assertErr(ExtractConstant.extractConstant(src, 'K', 'DUP', 'dup', true, plugin()));
	}

	/** A literal that does not occur is refused. */
	public function testNoOccurrenceRefused(): Void {
		final src: String = "package pkg;\n\nclass K {\n\tstatic function f(k:String):Bool {\n\t\treturn k == 'present';\n\t}\n}";
		assertErr(ExtractConstant.extractConstant(src, 'K', 'ABSENT', 'absent', true, plugin()));
	}

	/** A name that is not a valid identifier is refused. */
	public function testInvalidNameRefused(): Void {
		final src: String = "package pkg;\n\nclass K {\n\tstatic function f(k:String):Bool {\n\t\treturn k == 'x';\n\t}\n}";
		assertErr(ExtractConstant.extractConstant(src, 'K', '9BAD', 'x', true, plugin()));
	}

	/** A double-quoted literal is not matched (single-quoted only). */
	public function testDoubleQuotedNotMatched(): Void {
		final src: String = 'package pkg;\n\nclass K {\n\tstatic function f(k:String):Bool {\n\t\treturn k == "base.ref";\n\t}\n}';
		assertErr(ExtractConstant.extractConstant(src, 'K', 'BASE_REF', 'base.ref', true, plugin()));
	}

	/** An interpolated string is not matched (it is not a constant value). */
	public function testInterpolatedNotMatched(): Void {
		final src: String = "package pkg;\n\nclass K {\n\tstatic function f(y:String):String {\n\t\treturn 'x$y';\n\t}\n}";
		assertErr(ExtractConstant.extractConstant(src, 'K', 'X', 'x', true, plugin()));
	}

	/** A missing / non-unique type is refused. */
	public function testUnknownTypeRefused(): Void {
		final src: String = "package pkg;\n\nclass K {\n\tstatic function f(k:String):Bool {\n\t\treturn k == 'x';\n\t}\n}";
		assertErr(ExtractConstant.extractConstant(src, 'Missing', 'X', 'x', true, plugin()));
	}

	/** The first member's doc comment stays on that member, not on the constant. */
	public function testFirstMemberKeepsDoc(): Void {
		final src: String = "package pkg;\n\nclass K {\n\t/** the worker */\n\tstatic function f(k:String):Bool {\n\t\treturn k == 'base.ref';\n\t}\n}";
		final text: String = okExtract(src, 'K', 'BASE_REF', 'base.ref');
		final constIdx: Int = text.indexOf('private static final BASE_REF');
		final docIdx: Int = text.indexOf('/** the worker */');
		final fnIdx: Int = text.indexOf('function f');
		Assert.isTrue(constIdx >= 0 && constIdx < docIdx && docIdx < fnIdx, 'constant precedes the doc, which stays on the method');
	}

	/** A literal inside member metadata is left as a literal, not rewritten. */
	public function testMetadataLiteralUntouched(): Void {
		final src: String = "package pkg;\n\nclass K {\n\t@:native('base.ref')\n\tstatic function f(k:String):Bool {\n\t\treturn k == 'base.ref';\n\t}\n}";
		final text: String = okExtract(src, 'K', 'BASE_REF', 'base.ref');
		Assert.isTrue(StringTools.contains(text, "@:native('base.ref')"), 'metadata literal untouched');
		Assert.isTrue(StringTools.contains(text, 'k == BASE_REF'), 'body occurrence replaced');
	}

	/** A non-unique type name is refused. */
	public function testNonUniqueTypeRefused(): Void {
		final src: String = "package pkg;\n\nclass K {\n\tstatic function f(k:String):Bool {\n\t\treturn k == 'x';\n\t}\n}\n\nclass K {\n\tstatic function g():Void {}\n}";
		assertErr(ExtractConstant.extractConstant(src, 'K', 'X', 'x', true, plugin()));
	}

	/** The constant reuses the verbatim source token (embedded quotes preserved). */
	public function testVerbatimToken(): Void {
		final src: String = "package pkg;\n\nclass K {\n\tstatic function f(k:String):Bool {\n\t\treturn k == 'a\"b' && k == 'a\"b';\n\t}\n}";
		final text: String = okExtract(src, 'K', 'AB', 'a"b');
		Assert.isTrue(StringTools.contains(text, "private static final AB:String = 'a\"b'"), 'verbatim token preserved');
	}

	private function okExtract(src: String, typeName: String, name: String, literal: String): String {
		switch ExtractConstant.extractConstant(src, typeName, name, literal, true, plugin()) {
			case Ok(text):
				var parsed: Bool = true;
				try
					plugin().parseFile(text)
				catch (_: Exception)
					parsed = false;
				Assert.isTrue(parsed, 'result should re-parse');
				return text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return '';
		}
	}

	private function assertErr(result: EditResult): Void {
		switch result {
			case Ok(_):
				Assert.fail('expected Err, got Ok');
			case Err(_):
				Assert.pass();
		}
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

}
