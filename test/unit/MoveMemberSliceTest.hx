package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.MoveMember;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.MoveSymbol.MoveResult;

/**
 * `MoveMember.move` — scope-correct move of one STATIC member between
 * same-package types: qualified `Src.member` callers rewritten across
 * scope, bare in-file callers qualified to the destination, bare
 * self-references kept, sibling references qualified back (with
 * `@:access` for private targets), visibility promotion, doc / meta
 * carriage, dependency-import carry, cross-package caller imports, and
 * the refusal boundary (instance members, `using`, static imports,
 * cross-package destinations, name collisions).
 *
 * Each test drives the PURE operation with an IN-MEMORY `scopeFiles`
 * array (no disk); `Ok` rewrites are re-parsed explicitly, refusals
 * assert `Err`.
 */
class MoveMemberSliceTest extends Test {

	public function testMoveStaticMethodRewritesQualifiedCallers(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int {\n\t\treturn x + 1;\n\t}\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final user: String = 'package pkg;\n\nclass User {\n\tfunction go():Int return A.util(1);\n}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
			{ file: 'pkg/User.hx', source: user },
		]);
		Assert.equals(3, changes.length);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		final newUser: String = changeFor(changes, 'pkg/User.hx').newSource;
		Assert.isFalse(StringTools.contains(newA, 'function util'), 'util should be gone from A');
		Assert.isTrue(StringTools.contains(newB, 'public static function util(x:Int):Int'), 'util should land in B');
		Assert.isTrue(StringTools.contains(newUser, 'B.util(1)'), 'qualified caller should repoint to B');
		Assert.isFalse(StringTools.contains(newUser, 'A.util'), 'no A.util left in User');
	}

	public function testBareInFileCallersQualifiedAndRecursionKept(): Void {
		final a: String = 'package pkg;\n\nclass A {\n' + '\tpublic static function run():Int return util(3);\n'
			+ '\tpublic static function util(x:Int):Int {\n\t\treturn x <= 0 ? 0 : util(x - 1);\n\t}\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
		]);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(StringTools.contains(newA, 'return B.util(3)'), 'bare in-file caller should qualify to B');
		Assert.isTrue(StringTools.contains(newB, 'util(x - 1)'), 'self-recursion should stay bare');
		Assert.isFalse(StringTools.contains(newB, 'B.util(x - 1)'), 'self-recursion must NOT be qualified');
	}

	public function testSiblingReferenceQualifiedWithAccess(): Void {
		final a: String = 'package pkg;\n\nclass A {\n' + '\tpublic static function util(x:Int):Int return scale(x) * 2;\n'
			+ '\tstatic function scale(x:Int):Int return x + 10;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
		]);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(StringTools.contains(newB, 'A.scale(x) * 2'), 'sibling call should qualify to A');
		Assert.isTrue(StringTools.contains(newB, '@:access(pkg.A)'), 'private sibling needs @:access');
	}

	public function testPublicSiblingNeedsNoAccess(): Void {
		final a: String = 'package pkg;\n\nclass A {\n' + '\tpublic static function util(x:Int):Int return scale(x) * 2;\n'
			+ '\tpublic static function scale(x:Int):Int return x + 10;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
		]);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(StringTools.contains(newB, 'A.scale(x)'), 'sibling call should qualify to A');
		Assert.isFalse(StringTools.contains(newB, '@:access'), 'public sibling needs no @:access');
	}

	public function testPrivatePromotedWhenCallersRemain(): Void {
		final a: String = 'package pkg;\n\nclass A {\n' + '\tpublic static function run():Int return util(3);\n'
			+ '\tprivate static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final result: MoveResult = move('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
		]);
		switch result {
			case Ok(changes, advisory):
				final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
				Assert.isTrue(StringTools.contains(newB, 'public static function util'), 'private should promote to public');
				Assert.isTrue(advisory != null && StringTools.contains(advisory, 'promoted'), 'advisory should mention promotion');
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	public function testPrivateKeptWithoutCallers(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tprivate static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
		]);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(StringTools.contains(newB, 'private static function util'), 'visibility should be kept');
	}

	public function testDocAndMetaMoveWithMember(): Void {
		final a: String = 'package pkg;\n\nclass A {\n'
			+ '\t/**\n\t * Doubles.\n\t */\n\t@:pure\n\tpublic static function util(x:Int):Int return x * 2;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
		]);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(StringTools.contains(newB, 'Doubles.'), 'doc comment should move');
		Assert.isTrue(StringTools.contains(newB, '@:pure'), 'meta should move');
		Assert.isFalse(StringTools.contains(newA, 'Doubles.'), 'doc comment should leave the source');
	}

	public function testDependencyImportCarried(): Void {
		final a: String = 'package pkg;\n\nimport haxe.io.Bytes;\n\nclass A {\n'
			+ '\tpublic static function util(b:Bytes):Int return b.length;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
		]);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(StringTools.contains(newB, 'import haxe.io.Bytes;'), 'dependency import should carry to B');
	}

	public function testCrossPackageCallerGainsImport(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final user: String = 'package app;\n\nimport pkg.A;\n\nclass User {\n\tfunction go():Int return A.util(1);\n}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
			{ file: 'app/User.hx', source: user },
		]);
		final newUser: String = changeFor(changes, 'app/User.hx').newSource;
		Assert.isTrue(StringTools.contains(newUser, 'B.util(1)'), 'cross-package caller should repoint');
		Assert.isTrue(StringTools.contains(newUser, 'import pkg.B;'), 'cross-package caller should gain the dest import');
	}

	public function testValueShadowedReceiverUntouched(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final user: String = 'package pkg;\n\nclass User {\n' + '\tfunction go(A:Dynamic):Int return A.util(1);\n'
			+ '\tfunction real():Int return A.util(2);\n}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
			{ file: 'pkg/User.hx', source: user },
		]);
		final newUser: String = changeFor(changes, 'pkg/User.hx').newSource;
		Assert.isTrue(StringTools.contains(newUser, 'go(A:Dynamic):Int return A.util(1)'), 'shadowed receiver stays');
		Assert.isTrue(StringTools.contains(newUser, 'real():Int return B.util(2)'), 'type receiver repoints');
	}

	public function testInstanceMemberRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		assertErr(move('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
		]));
	}

	public function testDestCollisionRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {\n\tpublic static function util(x:Int):Int return x * 9;\n}';
		assertErr(move('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
		]));
	}

	public function testUsingOfSourceTypeRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final user: String = 'package pkg;\n\nusing pkg.A;\n\nclass User {\n\tfunction go():Int return 1.util();\n}';
		assertErr(move('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
			{ file: 'pkg/User.hx', source: user },
		]));
	}

	public function testStaticImportRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final user: String = 'package app;\n\nimport pkg.A.util;\n\nclass User {\n\tfunction go():Int return util(1);\n}';
		assertErr(move('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
			{ file: 'app/User.hx', source: user },
		]));
	}

	public function testCrossPackageDestRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package other;\n\nclass B {}';
		assertErr(move('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'other/B.hx', source: b },
		]));
	}

	public function testUnknownMemberRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		assertErr(move('pkg/A.hx', 'A', 'nope', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
		]));
	}

	public function testUnknownDestRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		assertErr(move('pkg/A.hx', 'A', 'util', 'Nope', [{ file: 'pkg/A.hx', source: a }]));
	}

	public function testSameTypeRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		assertErr(move('pkg/A.hx', 'A', 'util', 'A', [{ file: 'pkg/A.hx', source: a }]));
	}

	public function testStaticVarMoves(): Void {
		final a: String = 'package pkg;\n\nclass A {\n' + '\tpublic static final LIMIT:Int = 42;\n'
			+ '\tpublic static function run():Int return LIMIT + 1;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'LIMIT', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
		]);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(StringTools.contains(newB, 'public static final LIMIT:Int = 42;'), 'const should land in B');
		Assert.isTrue(StringTools.contains(newA, 'return B.LIMIT + 1'), 'bare const read should qualify');
	}

	private function move(
		srcFile: String, srcType: String, member: String, destType: String, scopeFiles: Array<{ file: String, source: String }>
	): MoveResult {
		return MoveMember.move(srcFile, srcType, member, destType, scopeFiles, plugin(), typeRefShape());
	}

	private function okChanges(
		srcFile: String, srcType: String, member: String, destType: String, scopeFiles: Array<{ file: String, source: String }>
	): Array<MoveChange> {
		final result: MoveResult = move(srcFile, srcType, member, destType, scopeFiles);
		switch result {
			case Ok(changes, advisory):
				Assert.notNull(advisory);
				for (c in changes) {
					var parsed: Bool = true;
					try
						plugin().parseFile(c.newSource)
					catch (_: haxe.Exception)
						parsed = false;
					Assert.isTrue(parsed, 'rewritten ${c.file} should re-parse');
				}
				return changes;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return [];
		}
	}

	private function assertErr(result: MoveResult): Void {
		switch result {
			case Ok(changes, _):
				Assert.fail('expected Err, got Ok with ${changes.length} change(s)');
			case Err(_):
				Assert.pass();
		}
	}

	private function changeFor(changes: Array<MoveChange>, file: String): MoveChange {
		for (c in changes) if (c.file == file) return c;
		Assert.fail('no change for file $file');
		return { file: file, newSource: '' };
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

	private static function typeRefShape(): TypeRefShape {
		return new HaxeQueryPlugin().typeRefShape();
	}

	public function testTwoQualifiedCallsOnOneLine(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final user: String = 'package pkg;\n\nclass User {\n\tfunction go():Int return A.util(1) + A.util(2);\n}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
			{ file: 'pkg/User.hx', source: user },
		]);
		final newUser: String = changeFor(changes, 'pkg/User.hx').newSource;
		Assert.isTrue(StringTools.contains(newUser, 'B.util(1) + B.util(2)'), 'both same-line callers should repoint');
	}

	public function testSkipParseScopeFileRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		assertErr(move('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
			{ file: 'pkg/Broken.hx', source: 'class {{{' },
		]));
	}

	/**
	 * A switch case pattern binding the member's name: `Refs` cannot tell
	 * the capture from the member, so the move must refuse rather than
	 * silently rewrite match code.
	 */
	public function testCasePatternCaptureRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n' + '\tstatic function run(o:Null<Int>):Int return switch o {\n'
			+ '\t\tcase util: util;\n\t\tcase _: 0;\n\t}\n' + '\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		assertErr(move('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
		]));
	}

	/**
	 * Promotion of a default-visibility member carrying leading `@:meta`:
	 * `public` must land after the meta, before `static`.
	 */
	public function testMetaMemberPromotionLandsAfterMeta(): Void {
		final a: String = 'package pkg;\n\nclass A {\n' + '\tpublic static function run():Int return util(3);\n'
			+ '\t@:keep static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
		]);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(StringTools.contains(newB, '@:keep public static function util'), 'public should follow the meta');
	}

	public function testFullyQualifiedCallerRewritten(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final user: String = 'package app;\n\nclass User {\n\tfunction go():Int return pkg.A.util(1);\n}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
			{ file: 'app/User.hx', source: user },
		]);
		final newUser: String = changeFor(changes, 'app/User.hx').newSource;
		Assert.isTrue(StringTools.contains(newUser, 'pkg.B.util(1)'), 'fully-qualified caller should repoint');
	}

	public function testUsingOfDestTypeRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final user: String = 'package pkg;\n\nusing pkg.B;\n\nclass User {}';
		assertErr(move('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
			{ file: 'pkg/User.hx', source: user },
		]));
	}

	/**
	 * A caller inside the destination file becomes a same-type qualified
	 * access after the move — no promotion needed, visibility kept.
	 */
	public function testDestFileCallerStaysPrivate(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tprivate static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {\n\tpublic static function go():Int return A.util(5);\n}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
		]);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(StringTools.contains(newB, 'B.util(5)'), 'dest-file caller should repoint');
		Assert.isTrue(StringTools.contains(newB, 'private static function util'), 'no promotion for a dest-file caller');
	}

}
