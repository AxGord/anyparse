package unit.check.haxe.types;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Severity;
import anyparse.check.haxe.types.AvoidHaxeJson;
import devkit.TempDir;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * The `avoid-haxe-json` check: a use of `Json.parse` or `Json.stringify`, called or taken as a function value, is flagged
 * `Warning`, report-only, with a message that names the project's own way to read and write a JSON document. Another member
 * of the type, another type's `parse`, and a `Json` the file binds to something else (a project type, a parameter, a type of
 * its package or another import outside the scan) are left alone.
 */
class AvoidHaxeJsonCheckTest extends Test {

	/** The std's `haxe.Json`, as the scan holds it where the run has no std of its own to resolve an import against. */
	private static final STD_JSON: Array<{ file: String, source: String }> = [
		{
			file: 'haxe/Json.hx',
			source: 'package haxe;\n\nclass Json {\n\tpublic static function parse(text:String):Dynamic return null;\n\n'
				+ '\tpublic static function stringify(value:Dynamic):String return "";\n}\n'
		}
	];

	public function testParseAndStringifyFlagged(): Void {
		final vs: Array<Violation> = violations(body('var a = Json.parse(s); var b = Json.stringify(v); var c = haxe.Json.parse(s);'));
		Assert.equals(3, vs.length);
		for (v in vs) {
			Assert.equals('avoid-haxe-json', v.rule);
			Assert.equals(Severity.Warning, v.severity);
			Assert.isTrue(v.message.contains('@:schema(JsonFormat)'));
		}
		Assert.isTrue(vs[0].message.contains('JValueParser') && !vs[0].message.contains('JValueWriter'));
		Assert.isTrue(vs[1].message.contains('Json.stringify'));
		Assert.isTrue(vs[1].message.contains('JValueWriter') && !vs[1].message.contains('JValueParser'));
	}

	public function testOtherCallsNotFlagged(): Void {
		Assert.equals(
			0, violations(body('var a = Xml.parse(s); var b = reader.parse(s); var c = Json.other(s); var d = parse(s);')).length
		);
	}

	public function testProjectTypeNamedJsonIsAnotherReceiver(): Void {
		final source: String = 'class Json {\n\tpublic static function parse(s:String):Int return 0;\n}\n\nclass C {\n'
			+ '\tfunction f(s:String):Int {\n\t\treturn Json.parse(s);\n\t}\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testNoFix(): Void {
		Assert.equals(0, CheckFixture.edits(new AvoidHaxeJson(), body('var a = Json.parse(s);')).length);
	}

	public function testRegisteredDefaultOff(): Void {
		Assert.notNull(Linter.byId('avoid-haxe-json'));
		Assert.isTrue(Std.isOfType(new AvoidHaxeJson(), DefaultOff));
	}

	/** A function value is a use too: no call node is needed. */
	public function testAFunctionValueIsFlagged(): Void {
		Assert.equals(2, violations(body('var p = Json.parse; var q = a.map(Json.parse);')).length);
		Assert.equals(1, violations(body('var q = a.map(Json.stringify);')).length);
	}

	/** A parameter called `Json` is a value; its `parse` is not the std's. */
	public function testAParameterNamedJsonIsAnotherReceiver(): Void {
		final source: String = 'import haxe.Json;\n\nclass C {\n\tfunction f(Json:{ function parse(s:String):Int; }, s:String):Int {\n'
			+ '\t\treturn Json.parse(s);\n\t}\n}';
		Assert.equals(0, violations(source).length);
	}

	/** A type of the file's own package that the scan does not hold still binds the bare name, ahead of the std. */
	public function testASamePackageTypeOutsideTheScanIsAnotherReceiver(): Void {
		TempDir.with(dir -> {
			FileSystem.createDirectory(dir.file('p'));
			File.saveContent(
				dir.file('p/Json.hx'), 'package p;\n\nclass Json {\n\tpublic static function parse(s:String):Int return 0;\n}\n'
			);
			final source: String = 'package p;\n\nclass Same {\n\tstatic function f(s:String):Int {\n\t\treturn Json.parse(s);\n\t}\n}';
			Assert.equals(0, CheckFixture.violationsIn(new AvoidHaxeJson(), [{ file: dir.file('p/Same.hx'), source: source }]).length);
		});
	}

	/** An import of another `Json` binds the bare name, whether or not the scan holds that module. */
	public function testAnImportOfAnotherJsonOutsideTheScanIsAnotherReceiver(): Void {
		TempDir.with(dir -> {
			FileSystem.createDirectory(dir.file('p'));
			FileSystem.createDirectory(dir.file('q'));
			File.saveContent(
				dir.file('p/Json.hx'), 'package p;\n\nclass Json {\n\tpublic static function parse(s:String):Int return 0;\n}\n'
			);
			final source: String =
				'package q;\n\nimport p.Json;\n\nclass Imp {\n\tstatic function f(s:String):Int {\n\t\treturn Json.parse(s);\n\t}\n}';
			Assert.equals(0, CheckFixture.violationsIn(new AvoidHaxeJson(), [{ file: dir.file('q/Imp.hx'), source: source }]).length);
		});
	}

	/** The motivating form: the std's `Json` imported from outside the index, as a run with no std of its own sees it. */
	public function testABareJsonImportedFromOutsideTheScanIsFlagged(): Void {
		final vs: Array<Violation> = violations(
			'import haxe.Json;\n\nclass C {\n\tfunction f(p:String):Any {\n\t\tfinal root: Any = Json.parse(p);\n\t\treturn root;\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.equals(1, violations('import haxe.Json as J;\n\nclass C {\n\tfunction f(s:String):Any return J.parse(s);\n}').length);
	}

	/** The same import where the scan holds the declaration: the bare name binds it in the index. */
	public function testAnIndexedStdJsonIsFlagged(): Void {
		final src: String = 'import haxe.Json;\n\nclass C {\n\tfunction f(s:String):Any return Json.parse(s);\n}';
		Assert.equals(1, CheckFixture.violationsIn(new AvoidHaxeJson(), [{ file: 'C.hx', source: src }].concat(STD_JSON)).length);
	}

	private function body(statements: String): String {
		return 'import haxe.Json;\n\nclass C {\n\tfunction f(s:String, v:Dynamic, a:Array<String>):Void {\n\t\t$statements\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new AvoidHaxeJson(), src);
	}

}
