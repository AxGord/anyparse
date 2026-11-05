package unit.check.common.types;

import anyparse.check.Severity;
import anyparse.check.common.types.UnresolvedTypeName;
import unit.cli.CliFixture;

/**
 * The `unresolved-type-name` check: a simple type name written in a type position that no import, package or std module
 * binds. Every decline is a pinned miss: a dotted path, a type parameter, an import of a module the index does not hold,
 * the std's toplevel, an imported std module.
 */
class UnresolvedTypeNameCheckTest extends Test {

	@:pin('control') @:killer('M-UNRESOLVED-NEVER-NOTHING')
	public function testUndeclaredTypeFlagged(): Void {
		final found: Array<Violation> = violations('package a; class C { var x: Missing; }');
		Assert.equals(1, found.length);
		Assert.equals(Severity.Warning, found[0].severity);
		Assert.stringContains('Missing', found[0].message);
	}

	public function testEveryTypePositionIsRead(): Void {
		final src: String = 'package a; class C extends Gone1 implements Gone2 { var m: Map<String, Gone3>; '
			+ 'function f(p: Gone4): Gone5 { final x: Gone6 = new Gone7(); try {} catch (e: Gone8) {} return cast(x, Gone9); } }';
		Assert.equals(9, violations(src).length);
	}

	public function testSiblingInPackageBinds(): Void {
		final found: Array<Violation> = violationsIn([
			{ file: 'a/Foo.hx', source: 'package a; class Foo {}' },
			{ file: 'a/C.hx', source: 'package a; class C { var x: Foo; }' }
		]);
		Assert.equals(0, found.length);
	}

	public function testImportBinds(): Void {
		final found: Array<Violation> = violationsIn([
			{ file: 'b/Foo.hx', source: 'package b; class Foo {}' },
			{ file: 'a/C.hx', source: 'package a; import b.Foo; class C { var x: Foo; }' }
		]);
		Assert.equals(0, found.length);
	}

	public function testDroppedImportFlagged(): Void {
		final found: Array<Violation> = violationsIn([
			{ file: 'b/Foo.hx', source: 'package b; class Foo {}' },
			{ file: 'a/C.hx', source: 'package a; class C { var x: Foo; }' }
		]);
		Assert.equals(1, found.length);
	}

	public function testOwnModuleSubTypeBinds(): Void {
		Assert.equals(0, violations('package a; class C { var x: Inner; } typedef Inner = { var y: Int; }').length);
	}

	@:pin('control') @:killer('M-UNRESOLVED-TOPLEVEL-STD-UNBOUND')
	public function testStdToplevelNotFlagged(): Void {
		Assert.equals(
			0, violations('package a; class C { var s: String; var a: Array<Int>; var m: Map<Int, Date>; var d: Dynamic; }').length
		);
	}

	@:pin('control') @:killer('M-UNRESOLVED-IMPORTED-STD-UNBOUND')
	public function testImportedStdModuleNotFlagged(): Void {
		Assert.equals(0, violations('package a; import haxe.io.Bytes; class C { var b: Bytes; }').length);
	}

	@:pin('control') @:killer('M-UNRESOLVED-STD-PACKAGE-UNBOUND')
	public function testStdModuleOfOwnPackageNotFlagged(): Void {
		final found: Array<Violation> = violationsIn([{ file: 'js/html/X.hx', source: 'package js.html; class X { var e: Element; }' }]);
		Assert.equals(0, found.length);
	}

	public function testImportOfModuleOutsideIndexNotFlagged(): Void {
		Assert.equals(0, violations('package a; import lib.Widget; class C { var w: Widget; }').length);
	}

	@:pin('control') @:killer('M-UNRESOLVED-TYPEPARAM-FLAGGED')
	public function testTypeParameterNotFlagged(): Void {
		Assert.equals(0, violations('package a; class C<T:String> { var x: T; function f<U>(u: U): T { return null; } }').length);
	}

	@:pin('control') @:killer('M-UNRESOLVED-DOTTED-FLAGGED')
	public function testDottedPathNotFlagged(): Void {
		Assert.equals(0, violations('package a; class C { var x: Missing.Inner; var y: pkg.sub.Missing; }').length);
	}

	public function testWildcardOutsideIndexNotFlagged(): Void {
		Assert.equals(0, violations('package a; import lib.*; class C { var w: Widget; }').length);
	}

	public function testUsingBindsTheModuleMainType(): Void {
		final found: Array<Violation> = violationsIn([
			{ file: 'b/Tools.hx', source: 'package b; class Tools {}' },
			{ file: 'a/C.hx', source: 'package a; using b.Tools; class C { var t: Tools; }' }
		]);
		Assert.equals(0, found.length);
	}

	public function testImportOfModuleBindsItsSecondaryType(): Void {
		final module: { file: String, source: String } = { file: 'b/M.hx', source: 'package b; class M {} class Helper {}' };
		Assert.equals(
			0, violationsIn([
				module,
				{ file: 'a/C.hx', source: 'package a; import b.M; class C { var h: Helper; }' }
			]).length
		);
		Assert.equals(1, violationsIn([module, { file: 'a/C.hx', source: 'package a; class C { var h: Helper; }' }]).length);
	}

	public function testAmbientImportBinds(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_unresolved_ambient', [
			{ name: 'b/M.hx', source: 'package b;\n\nclass M {}\n\nclass Helper {}\n' },
			{ name: 'c/import.hx', source: 'import b.M;\n' },
			{ name: 'c/d/X.hx', source: 'package c.d;\n\nclass X {\n\n\tvar h: Helper;\n\n}\n' }
		]);
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final files: Array<{ file: String, source: String }> = [
				for (name in ['b/M.hx', 'c/d/X.hx']) { file: '$root/$name', source: sys.io.File.getContent('$root/$name') }
			];
			Assert.equals(0, violationsIn(files).length);
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testGuardedImportNotFlagged(): Void {
		Assert.equals(0, violations('package a; #if js import lib.Y; #end class C { var y: Y; }').length);
	}

	public function testMacroReificationNotEntered(): Void {
		Assert.equals(0, violations('package a; class C { macro static function m() return macro : Unknown1; }').length);
	}

	public function testLowercaseNameNotFlagged(): Void {
		Assert.equals(0, violations('package a; class C { var x: foo; }').length);
	}

	private function violations(src: String): Array<Violation> {
		return violationsIn([{ file: 'a/C.hx', source: src }]);
	}

	private function violationsIn(files: Array<{ file: String, source: String }>): Array<Violation> {
		return CheckFixture.violationsIn(new UnresolvedTypeName(), files);
	}

}
