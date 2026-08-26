package unit;

import anyparse.query.Cli;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

/**
 * End-to-end tests for `apq rename` WITHOUT `--scope` when the cursor sits on a TYPE
 * declaration.
 *
 * `Rename` resolves through the VALUE namespace, so on a type it used to rewrite the
 * declaration's name token and nothing else - `:T`, `new T()`, `extends T` and
 * `T.CONST` are type positions it never binds, and the emitted file did not compile.
 * The in-file path now routes a type cursor through the same `CrossRename` op
 * `--scope` uses, with the cursor file as the whole scope.
 *
 * Every assertion spans the DECLARATION and a USE in one string, so an untransformed
 * input cannot satisfy it: the old behaviour rewrote the decl alone and would still
 * fail each of these.
 */
class RenameTypeInFileCliTest extends Test {

	/** `class Foo` + a type hint + a `new` — all three occurrences are the type namespace. */
	public function testPlainClassRenamesDeclAndUses(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write(
			'rn_type_plain', 'class Foo {\n\tpublic function new() {}\n}\n\nclass Use {\n\tvar f:Foo = new Foo();\n}\n'
		);
		final rc: Int = Cli.run(['rename', path, '--select', 'ClassDecl:Foo', 'Bar', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('class Bar {') >= 0 && out.indexOf('var f:Bar = new Bar();') >= 0);
		Assert.equals(-1, out.indexOf('Foo'));
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `final class Foo` addressed at the coordinate `apq refs --decls` PRINTS for it -
	 * the inner `ClassForm`'s span start, which is the `class` keyword, not the name
	 * token. `resolveTypeDeclAtCursor` used to accept only the name token or the OUTER
	 * `FinalDecl` start, so the documented "copy the position from refs --decls"
	 * convention resolved no type declaration here and fell through to the
	 * value-namespace rename.
	 */
	public function testFinalClassAtDeclCoordinateRenamesDeclAndUses(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write(
			'rn_type_final', 'final class Foo {\n\tpublic function new() {}\n}\n\nclass Use {\n\tvar f:Foo = new Foo();\n}\n'
		);
		// 1:7 is `class` — what `apq refs Foo --decls` reports for this shape.
		final rc: Int = Cli.run(['rename', path, '1:7', 'Bar', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('final class Bar {') >= 0 && out.indexOf('var f:Bar = new Bar();') >= 0);
		Assert.equals(-1, out.indexOf('Foo'));
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `abstract class Foo` — the `extends` clause is a type position too. */
	public function testAbstractClassRenamesDeclAndExtends(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write(
			'rn_type_absclass',
			'abstract class Foo {\n\tpublic function new() {}\n}\n\nclass Impl extends Foo {\n\tvar self:Foo = this;\n}\n'
		);
		final rc: Int = Cli.run(['rename', path, '--select', 'AbstractClassDecl:Foo', 'Bar', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('abstract class Bar {') >= 0 && out.indexOf('class Impl extends Bar {') >= 0);
		Assert.equals(-1, out.indexOf('Foo'));
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `enum abstract Foo(Int)` — the static receiver `Foo.Red` is the type as a namespace. */
	public function testEnumAbstractRenamesDeclAndStaticReceiver(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write(
			'rn_type_enumabs', 'enum abstract Foo(Int) {\n\tfinal Red = 1;\n}\n\nclass Use {\n\tvar f:Foo = Foo.Red;\n}\n'
		);
		final rc: Int = Cli.run(['rename', path, '--select', 'EnumAbstractDecl:Foo', 'Bar', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('enum abstract Bar(Int) {') >= 0 && out.indexOf('var f:Bar = Bar.Red;') >= 0);
		Assert.equals(-1, out.indexOf('Foo'));
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A VALUE binding must still take the `Rename` path: the local `total` is renamed
	 * while the same-named field stays verbatim - scope correctness the type-namespace
	 * op does not model and would destroy if the dispatch fired on every cursor.
	 */
	public function testValueCursorStillUsesScopeCorrectRename(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write(
			'rn_type_value', 'class C {\n\tvar total:Int = 0;\n\tfunction f():Int {\n\t\tvar total:Int = 1;\n\t\treturn total;\n\t}\n}\n'
		);
		final rc: Int = Cli.run(['rename', path, '--select', 'FnMember:f >> VarStmt:total', 'sum', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('var total:Int = 0;') >= 0 && out.indexOf('var sum:Int = 1;') >= 0 && out.indexOf('return sum;') >= 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
