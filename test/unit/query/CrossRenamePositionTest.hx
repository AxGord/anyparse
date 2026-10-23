package unit.query;

import anyparse.query.CrossRename;

using Lambda;

/**
 * The type-reference POSITIONS `CrossRename.crossRenameType` must reach, one test per position
 * the census over a typechecked fixture found missed (anyparse N35): a struct extension, the type
 * path an access grant names, a qualified type used as a VALUE, an import whose path runs THROUGH
 * the type to a static field or a wildcard, and an aliased import's path.
 *
 * Every expectation follows the Haxe 4.3 compiler, checked with `haxe --interp` on a scratch
 * project: an access grant names a TYPE path (`@:access(p.Sub)` grants a sub-module type,
 * `@:access(p.M.Sub)` grants nothing), and a stale grant compiles silently, which is why it is the
 * one position here whose miss was not a compile error. Each test asserts a whole rewritten file,
 * so a fixture the unchanged input already satisfied cannot pass.
 */
class CrossRenamePositionTest extends Test {

	/** The main type `p.C`, its declaration's name at 3:7. */
	private static final C_SOURCE: String = 'package p;\n\nclass C {\n\tpublic static var K:Int = 1;\n\n\tpublic function new() {}\n}';

	/** `p.M`, declaring the sub-module type `Sub` at 5:7. */
	private static final M_SOURCE: String = 'package p;\n\nclass M {}\n\nclass Sub {\n\tstatic var secret:Int = 1;\n}';

	/** The typedef `p.P`, its declaration's name at 3:9. */
	private static final P_SOURCE: String = 'package p;\n\ntypedef P = {\n\tvar x:Int;\n}';

	/** A struct extension `> P` names a type, in a typedef body, an inline structure and a type parameter alike. */
	@:pin('control')
	@:killer('M-XREN-EXTENDS-HEAD-UNEMITTED', 'M-XREN-EXTENDS-KIND-DROPPED')
	public function testStructExtensionRenames(): Void {
		final use: String = 'package q;\n\nimport p.P;\n\ntypedef A = {\n\t> P,\n\tvar y:Int;\n}\n\ntypedef B = { > P, }\n\n'
			+ 'class U {\n\tvar s:{ > P, w:Int };\n\tvar t:Array<{ > P, }>;\n}';
		final expected: String = 'package q;\n\nimport p.Pp;\n\ntypedef A = {\n\t> Pp,\n\tvar y:Int;\n}\n\ntypedef B = { > Pp, }\n\n'
			+ 'class U {\n\tvar s:{ > Pp, w:Int };\n\tvar t:Array<{ > Pp, }>;\n}';
		Assert.equals(expected, renamed('p/P.hx', P_SOURCE, 3, 9, 'Pp', use));
	}

	/** A struct extension spelled through the module path, `> p.P`. */
	@:pin('control')
	@:killer('M-XREN-EXTENDS-KIND-DROPPED')
	public function testQualifiedStructExtensionRenames(): Void {
		final use: String = 'package q;\n\ntypedef A = { > p.P, var y:Int; }';
		Assert.equals('package q;\n\ntypedef A = { > p.Pp, var y:Int; }', renamed('p/P.hx', P_SOURCE, 3, 9, 'Pp', use));
	}

	/** `@:access` / `@:allow` name the TYPE path of the main type, and of a field through it. */
	public function testAccessGrantOfAMainTypeRenames(): Void {
		final use: String = 'package q;\n\n@:access(p.C)\n@:allow(p.C.K)\nclass U {}';
		Assert.equals('package q;\n\n@:access(p.Kk)\n@:allow(p.Kk.K)\nclass U {}', renamed('p/C.hx', C_SOURCE, 3, 7, 'Kk', use));
	}

	/**
	 * A sub-module type's grant is `pkg.Type`, not the module path: `@:access(p.Sub)` and
	 * `@:access(p.Sub.secret)` grant, `@:access(p.M.Sub)` grants nothing and is left as written.
	 */
	@:pin('control')
	@:killer('M-XREN-GRANT-UNREAD', 'M-XREN-GRANT-MODULE-PATH')
	public function testAccessGrantOfASubModuleTypeNamesItsTypePath(): Void {
		final use: String = 'package q;\n\n@:access(p.Sub)\n@:access(p.Sub.secret)\n@:allow(p.Sub)\nclass U {}';
		final expected: String = 'package q;\n\n@:access(p.Sb)\n@:access(p.Sb.secret)\n@:allow(p.Sb)\nclass U {}';
		Assert.equals(expected, renamed('p/M.hx', M_SOURCE, 5, 7, 'Sb', use));
	}

	/** A root-package type's grant is its bare name. */
	@:pin('control')
	@:killer('M-XREN-GRANT-UNREAD')
	public function testAccessGrantOfARootTypeRenames(): Void {
		final root: String = 'class R {\n\tstatic var s:Int = 1;\n}';
		final use: String = '@:access(R)\nclass U {}';
		Assert.equals('@:access(Rr)\nclass U {}', renamed('R.hx', root, 1, 7, 'Rr', use));
	}

	/** A metadata argument of another meta that spells the name — an operator, a forwarded FIELD — is no type path. */
	@:pin('control')
	@:killer('M-XREN-GRANT-ANY-META')
	public function testNonGrantMetadataIsNotRenamed(): Void {
		final root: String = 'class R {}';
		final use: String =
			'@:forward(R)\nabstract U(Int) {\n\t@:op(R + R) static function add(a:U, b:U):U return a;\n}\n\nclass V extends R {}';
		final expected: String =
			'@:forward(R)\nabstract U(Int) {\n\t@:op(R + R) static function add(a:U, b:U):U return a;\n}\n\nclass V extends Rr {}';
		Assert.equals(expected, renamed('R.hx', root, 1, 7, 'Rr', use));
	}

	/** A qualified type used as a VALUE — the `Class<T>` a dotted path evaluates to. */
	@:pin('control')
	@:killer('M-XREN-QUALIFIED-PATH-UNREAD')
	public function testQualifiedValueRenames(): Void {
		final use: String = 'package q;\n\nclass U {\n\tvar c:Class<p.C> = p.C;\n\tvar d:Class<Dynamic> = p.M.Sub;\n}';
		Assert.equals(
			'package q;\n\nclass U {\n\tvar c:Class<p.Kk> = p.Kk;\n\tvar d:Class<Dynamic> = p.M.Sub;\n}',
			renamed('p/C.hx', C_SOURCE, 3, 7, 'Kk', use)
		);
		Assert.equals(
			'package q;\n\nclass U {\n\tvar c:Class<p.C> = p.C;\n\tvar d:Class<Dynamic> = p.M.Sb;\n}',
			renamed('p/M.hx', M_SOURCE, 5, 7, 'Sb', use)
		);
	}

	/** A local that shadows the package root makes the dotted path a field read, not the type. */
	@:pin('control')
	@:killer('M-XREN-SHADOWED-ROOT-BLIND')
	public function testShadowedPackageRootIsNotRenamed(): Void {
		final use: String = 'class U {\n\tfunction f():Int {\n\t\tfinal p = { C: 1 };\n\t\treturn p.C;\n\t}\n\n\tvar c:p.C;\n}';
		final expected: String = 'class U {\n\tfunction f():Int {\n\t\tfinal p = { C: 1 };\n\t\treturn p.C;\n\t}\n\n\tvar c:p.Kk;\n}';
		Assert.equals(expected, renamed('p/C.hx', C_SOURCE, 3, 7, 'Kk', use));
	}

	/** An import whose path runs THROUGH the type — a static field, a wildcard over its statics, a sub-type's field. */
	@:pin('control')
	@:killer('M-XREN-THROUGH-IMPORT-UNREAD')
	public function testImportThroughTheTypeRenames(): Void {
		final use: String = 'package q;\n\nimport p.C.K;\nimport p.C.*;\nimport p.M.Sub.secret;\n\nclass U {}';
		Assert.equals(
			'package q;\n\nimport p.Kk.K;\nimport p.Kk.*;\nimport p.M.Sub.secret;\n\nclass U {}',
			renamed('p/C.hx', C_SOURCE, 3, 7, 'Kk', use)
		);
		Assert.equals(
			'package q;\n\nimport p.C.K;\nimport p.C.*;\nimport p.M.Sb.secret;\n\nclass U {}', renamed('p/M.hx', M_SOURCE, 5, 7, 'Sb', use)
		);
	}

	/** An aliased import's PATH renames; the alias it binds is another name and stays. */
	@:pin('control')
	@:killer('M-XREN-ALIAS-NAME-READ', 'M-XREN-THROUGH-IMPORT-UNREAD')
	public function testAliasedImportPathRenames(): Void {
		final use: String = 'package q;\n\nimport p.C as CC;\nimport p.C.K as kk;\n\nclass U {\n\tvar c:CC;\n}';
		Assert.equals(
			'package q;\n\nimport p.Kk as CC;\nimport p.Kk.K as kk;\n\nclass U {\n\tvar c:CC;\n}',
			renamed('p/C.hx', C_SOURCE, 3, 7, 'Kk', use)
		);
	}

	/** An import through a same-simple-named type of ANOTHER module stays, as does one through a longer name it prefixes. */
	@:pin('control')
	@:killer('M-XREN-THROUGH-NO-DOT')
	public function testImportThroughAnotherModuleIsNotRenamed(): Void {
		final use: String = 'package q;\n\nimport r.C.K;\nimport p.Cx.K;\nimport p.C;\n\nclass U {}';
		Assert.equals(
			'package q;\n\nimport r.C.K;\nimport p.Cx.K;\nimport p.Kk;\n\nclass U {}', renamed('p/C.hx', C_SOURCE, 3, 7, 'Kk', use)
		);
	}

	/**
	 * Rename the type declared at `line:col` of `declSource` (file `declFile`) to `newName` over a
	 * two-file scope, and return the rewritten `use` file — `use` unchanged when the rename did not
	 * touch it. A refused rename fails the test.
	 */
	private static function renamed(declFile: String, declSource: String, line: Int, col: Int, newName: String, use: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final scope: Array<{ file: String, source: String }> = [{ file: declFile, source: declSource }, { file: 'q/U.hx', source: use }];
		return switch CrossRename.crossRenameType(
			declFile, declSource, line, col, newName, scope, plugin, plugin.typeRefShape(), plugin.refShape()
		) {
			case Ok(changes, _): changes.find(c -> c.file == 'q/U.hx')?.newSource ?? use;
			case Err(message):
				Assert.fail('expected the rename to apply, got: $message');
				use;
		};
	}

}
