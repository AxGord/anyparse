package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.ExtractConstant;
import anyparse.query.RefactorSupport.EditResult;
import haxe.Exception;
import anyparse.query.ExtractConstant.ExtractIntoResult;

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

	/** Two same-package files sharing a literal both change; the module is created; neither file gets an import. */
	public function testCrossFileCreatesModuleSamePackageNoImport(): Void {
		final a: String = "package pkg;\n\nclass A {\n\tstatic function f(k: String): Bool {\n\t\treturn k == 'base.ref';\n\t}\n}";
		final b: String = "package pkg;\n\nclass B {\n\tstatic function g(k: String): Bool {\n\t\treturn k == 'base.ref';\n\t}\n}";
		final res: IntoOk = okInto(
			[{ file: 'A.hx', source: a }, { file: 'B.hx', source: b }], 'pkg', 'Keys', false, null, 'BASE_REF', 'base.ref'
		);
		Assert.equals(2, res.changes.length);
		Assert.isTrue(res.created, 'module created');
		Assert.isTrue(
			StringTools.contains(res.moduleSource, "public static final BASE_REF:String = 'base.ref'"), 'const declared on module'
		);
		Assert.isTrue(StringTools.contains(res.moduleSource, 'private function new()'), 'module has a private constructor');
		for (c in res.changes) {
			Assert.isTrue(StringTools.contains(c.newSource, 'k == Keys.BASE_REF'), 'occurrence replaced with module ref');
			Assert.isFalse(StringTools.contains(c.newSource, 'import '), 'same-package file gets no import');
		}
	}

	/** A scope file in a different package than the module gains an import. */
	public function testCrossPackageFileGetsImport(): Void {
		final a: String = "package one;\n\nclass A {\n\tstatic function f(k: String): Bool {\n\t\treturn k == 'base.ref';\n\t}\n}";
		final res: IntoOk = okInto([{ file: 'A.hx', source: a }], 'keys', 'Keys', false, null, 'BASE_REF', 'base.ref');
		final changed: String = res.changes[0].newSource;
		Assert.isTrue(StringTools.contains(changed, 'import keys.Keys;'), 'cross-package file gets the module import');
		Assert.isTrue(StringTools.contains(changed, 'k == Keys.BASE_REF'), 'occurrence replaced');
	}

	/** An existing module is extended with the new constant, keeping its members. */
	public function testExtendExistingModule(): Void {
		final a: String = "package pkg;\n\nclass A {\n\tstatic function f(k: String): Bool {\n\t\treturn k == 'new.key';\n\t}\n}";
		final module: String = "package pkg;\n\nfinal class Keys {\n\tpublic static final OLD:String = 'old';\n\n\tprivate function new() {}\n}";
		final res: IntoOk = okInto([{ file: 'A.hx', source: a }], 'pkg', 'Keys', true, module, 'NEW_KEY', 'new.key');
		Assert.isFalse(res.created, 'module extended, not created');
		Assert.isTrue(StringTools.contains(res.moduleSource, "public static final NEW_KEY:String = 'new.key'"), 'new constant added');
		Assert.isTrue(StringTools.contains(res.moduleSource, "public static final OLD:String = 'old'"), 'existing constant kept');
		Assert.isTrue(StringTools.contains(res.changes[0].newSource, 'k == Keys.NEW_KEY'), 'occurrence replaced');
		Assert.isTrue(
			res.moduleSource.indexOf('NEW_KEY') < res.moduleSource.indexOf('function new('),
			'new constant is in the constants rank, before the private constructor'
		);
	}

	/** A name colliding with an existing module member is refused. */
	public function testModuleMemberCollisionRefused(): Void {
		final a: String = "package pkg;\n\nclass A {\n\tstatic function f(k: String): Bool {\n\t\treturn k == 'x.y';\n\t}\n}";
		final module: String = "package pkg;\n\nfinal class Keys {\n\tpublic static final DUP:String = 'dup';\n\n\tprivate function new() {}\n}";
		assertErrInto(
			ExtractConstant.extractInto([{ file: 'A.hx', source: a }], 'pkg', 'Keys', true, module, 'DUP', 'x.y', true, plugin())
		);
	}

	/** A literal that does not occur anywhere in the scope is refused. */
	public function testCrossFileZeroOccurrenceRefused(): Void {
		final a: String = "package pkg;\n\nclass A {\n\tstatic function f(k: String): Bool {\n\t\treturn k == 'present';\n\t}\n}";
		assertErrInto(ExtractConstant.extractInto(
			[{ file: 'A.hx', source: a }], 'pkg', 'Keys', false, null, 'ABSENT', 'absent', true, plugin()
		));
	}

	/** A name that is not a valid identifier is refused. */
	public function testCrossFileInvalidNameRefused(): Void {
		final a: String = "package pkg;\n\nclass A {\n\tstatic function f(k: String): Bool {\n\t\treturn k == 'x';\n\t}\n}";
		assertErrInto(ExtractConstant.extractInto([{ file: 'A.hx', source: a }], 'pkg', 'Keys', false, null, '9BAD', 'x', true, plugin()));
	}

	/** A metadata literal is left untouched; only the body occurrence is counted and replaced. */
	public function testCrossFileMetadataLiteralUntouched(): Void {
		final a: String = "package pkg;\n\nclass A {\n\t@:native('base.ref')\n\tstatic function f(k: String): Bool {\n\t\treturn k == 'base.ref';\n\t}\n}";
		final res: IntoOk = okInto([{ file: 'A.hx', source: a }], 'pkg', 'Keys', false, null, 'BASE_REF', 'base.ref');
		final changed: String = res.changes[0].newSource;
		Assert.isTrue(StringTools.contains(changed, "@:native('base.ref')"), 'metadata literal untouched');
		Assert.isTrue(StringTools.contains(changed, 'k == Keys.BASE_REF'), 'body occurrence replaced');
		Assert.equals(1, res.changes[0].count, 'only the body occurrence is counted');
	}

	/** A cross-package consumer that already imports the module keeps a SINGLE import (no duplicate, no abort). */
	public function testAlreadyImportedModuleNotDuplicated(): Void {
		final a: String = "package one;\n\nimport pkg.Keys;\n\nclass A {\n\tstatic function f(k: String): Bool {\n\t\treturn k == 'base.ref';\n\t}\n}";
		final res: IntoOk = okInto([{ file: 'A.hx', source: a }], 'pkg', 'Keys', false, null, 'BASE_REF', 'base.ref');
		final imports: Int = res.changes[0].newSource.split('import pkg.Keys').length - 1;
		Assert.equals(1, imports, 'existing import kept, not duplicated');
		Assert.isTrue(StringTools.contains(res.changes[0].newSource, 'k == Keys.BASE_REF'), 'occurrence replaced');
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

	private function okInto(
		scopeFiles: Array<{ file: String, source: String }>, modulePkg: String, moduleClass: String, moduleExists: Bool,
		moduleSource: Null<String>, name: String, literal: String
	): IntoOk {
		switch ExtractConstant.extractInto(scopeFiles, modulePkg, moduleClass, moduleExists, moduleSource, name, literal, true, plugin()) {
			case Ok(changes, moduleSrc, created):
				for (c in changes) Assert.isTrue(parses(c.newSource), 'changed file re-parses');
				Assert.isTrue(parses(moduleSrc), 'module re-parses');
				return { changes: changes, moduleSource: moduleSrc, created: created };
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return { changes: [], moduleSource: '', created: false };
		}
	}

	private function assertErrInto(result: ExtractIntoResult): Void {
		switch result {
			case Ok(_, _, _):
				Assert.fail('expected Err, got Ok');
			case Err(_):
				Assert.pass();
		}
	}

	private function parses(src: String): Bool {
		var ok: Bool = true;
		try
			plugin().parseFile(src)
		catch (_: Exception)
			ok = false;
		return ok;
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

}

/** Unpacked `Ok` payload of `ExtractConstant.extractInto`, for the cross-file tests. */
typedef IntoOk = {
	changes: Array<{ file: String, newSource: String, count: Int }>,
	moduleSource: String,
	created: Bool
};
