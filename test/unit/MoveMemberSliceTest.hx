package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.MoveMember;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.MoveSymbol.MoveResult;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `MoveMember.move` — scope-correct move of one or more members between
 * same-package types. Static: qualified `Src.member` callers rewritten
 * across scope, bare in-file callers qualified to the destination, bare
 * self-references kept, sibling references qualified back (with
 * `@:access` for private targets), visibility promotion, doc / meta
 * carriage, dependency-import carry, cross-package caller imports.
 * Instance (sibling-fields contract): remaining bare callers rewired
 * through a `--via` field (auto-detected when unique), final-field
 * reads kept bare when the destination declares the same field, calls
 * inside the moved set kept bare. Refusal boundary: `this` references,
 * instance siblings staying behind, mutable field deps, `using`, static
 * imports, cross-package destinations, name collisions, constructors.
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
			{ file: 'pkg/User.hx', source: user }
		]);
		Assert.equals(3, changes.length);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		final newUser: String = changeFor(changes, 'pkg/User.hx').newSource;
		Assert.isFalse(newA.contains('function util'), 'util should be gone from A');
		Assert.isTrue(newB.contains('public static function util(x:Int):Int'), 'util should land in B');
		Assert.isTrue(newUser.contains('B.util(1)'), 'qualified caller should repoint to B');
		Assert.isFalse(newUser.contains('A.util'), 'no A.util left in User');
	}

	public function testBareInFileCallersQualifiedAndRecursionKept(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function run():Int return util(3);\n'
			+ '\tpublic static function util(x:Int):Int {\n\t\treturn x <= 0 ? 0 : util(x - 1);\n\t}\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newA.contains('return B.util(3)'), 'bare in-file caller should qualify to B');
		Assert.isTrue(newB.contains('util(x - 1)'), 'self-recursion should stay bare');
		Assert.isFalse(newB.contains('B.util(x - 1)'), 'self-recursion must NOT be qualified');
	}

	public function testSiblingReferenceQualifiedWithAccess(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return scale(x) * 2;\n'
			+ '\tstatic function scale(x:Int):Int return x + 10;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newB.contains('A.scale(x) * 2'), 'sibling call should qualify to A');
		Assert.isTrue(newB.contains('@:access(pkg.A)'), 'private sibling needs @:access');
	}

	public function testPublicSiblingNeedsNoAccess(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return scale(x) * 2;\n'
			+ '\tpublic static function scale(x:Int):Int return x + 10;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newB.contains('A.scale(x)'), 'sibling call should qualify to A');
		Assert.isFalse(newB.contains('@:access'), 'public sibling needs no @:access');
	}

	public function testPrivatePromotedWhenCallersRemain(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function run():Int return util(3);\n'
			+ '\tprivate static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final result: MoveResult = move('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		switch result {
			case Ok(changes, advisory):
				final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
				Assert.isTrue(newB.contains('public static function util'), 'private should promote to public');
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
			{ file: 'pkg/B.hx', source: b }
		]);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newB.contains('private static function util'), 'visibility should be kept');
	}

	public function testDocAndMetaMoveWithMember(): Void {
		final a: String =
			'package pkg;\n\nclass A {\n\t/**\n\t * Doubles.\n\t */\n\t@:pure\n\tpublic static function util(x:Int):Int return x * 2;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newB.contains('Doubles.'), 'doc comment should move');
		Assert.isTrue(newB.contains('@:pure'), 'meta should move');
		Assert.isFalse(newA.contains('Doubles.'), 'doc comment should leave the source');
	}

	public function testDependencyImportCarried(): Void {
		final a: String =
			'package pkg;\n\nimport haxe.io.Bytes;\n\nclass A {\n\tpublic static function util(b:Bytes):Int return b.length;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newB.contains('import haxe.io.Bytes;'), 'dependency import should carry to B');
	}

	/**
	 * The carry when the moved signature names its dependency ONLY inside an
	 * anonymous structure — the shape `pushImportEdits` could not see while the
	 * type-refs projection dropped the whole struct.
	 */
	public function testDependencyImportInsideAnAnonymousStructureCarried(): Void {
		final a: String = 'package pkg;\n\nimport haxe.io.Bytes;\n\nclass A {\n'
			+ '\tpublic static function util(b:Array<{node:Bytes}>):Int return b.length;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newB.contains('import haxe.io.Bytes;'), 'the anon field type dependency should carry to B');
		Assert.isTrue(newB.contains('b:Array<{node:Bytes}>'), 'the moved signature should land in B');
	}

	public function testCrossPackageCallerGainsImport(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final user: String = 'package app;\n\nimport pkg.A;\n\nclass User {\n\tfunction go():Int return A.util(1);\n}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
			{ file: 'app/User.hx', source: user }
		]);
		final newUser: String = changeFor(changes, 'app/User.hx').newSource;
		Assert.isTrue(newUser.contains('B.util(1)'), 'cross-package caller should repoint');
		Assert.isTrue(newUser.contains('import pkg.B;'), 'cross-package caller should gain the dest import');
	}

	public function testValueShadowedReceiverUntouched(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final user: String =
			'package pkg;\n\nclass User {\n\tfunction go(A:Dynamic):Int return A.util(1);\n\tfunction real():Int return A.util(2);\n}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
			{ file: 'pkg/User.hx', source: user }
		]);
		final newUser: String = changeFor(changes, 'pkg/User.hx').newSource;
		Assert.isTrue(newUser.contains('go(A:Dynamic):Int return A.util(1)'), 'shadowed receiver stays');
		Assert.isTrue(newUser.contains('real():Int return B.util(2)'), 'type receiver repoints');
	}

	public function testDestCollisionRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {\n\tpublic static function util(x:Int):Int return x * 9;\n}';
		assertErr(move('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]));
	}

	public function testUsingOfSourceTypeRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final user: String = 'package pkg;\n\nusing pkg.A;\n\nclass User {\n\tfunction go():Int return 1.util();\n}';
		assertErr(move('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
			{ file: 'pkg/User.hx', source: user }
		]));
	}

	public function testStaticImportRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final user: String = 'package app;\n\nimport pkg.A.util;\n\nclass User {\n\tfunction go():Int return util(1);\n}';
		assertErr(move('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
			{ file: 'app/User.hx', source: user }
		]));
	}

	public function testCrossPackageInstanceRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic function new() {}\n\tpublic function util():Int return 1;\n}';
		final b: String = 'package other;\n\nclass B {}';
		assertErr(move('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'other/B.hx', source: b }
		]));
	}

	public function testCrossPackageStaticSucceeds(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package other;\n\nclass B {}';
		final user: String = 'package pkg;\n\nimport pkg.A;\n\nclass User {\n\tfunction go():Int return A.util(1);\n}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'other/B.hx', source: b },
			{ file: 'pkg/User.hx', source: user }
		]);
		final newB: String = changeFor(changes, 'other/B.hx').newSource;
		final newUser: String = changeFor(changes, 'pkg/User.hx').newSource;
		Assert.isTrue(newB.contains('function util'), 'util lands in B');
		Assert.isTrue(newUser.contains('B.util(1)'), 'caller repointed to B');
		Assert.isTrue(newUser.contains('import other.B;'), 'cross-package caller gains the dest import');
	}

	public function testUnknownMemberRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		assertErr(move('pkg/A.hx', 'A', 'nope', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]));
	}

	/**
	 * A member declared inside a `#if` region is FOUND — the scan is branch-aware — and refused
	 * anyway: cutting it out of its branch and pasting it into the destination unguarded hands it to
	 * builds that never declared it, and leaves the emptied directives behind. The refusal names the
	 * region, where the branch-blind scan used to answer "type A has no member util".
	 */
	public function testGuardedMemberRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\t#if !mobile\n\tpublic static function util(x:Int):Int return x;\n\t#end\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		assertErrContains(move('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]), 'conditional-compilation region');
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
		final a: String =
			'package pkg;\n\nclass A {\n\tpublic static final LIMIT:Int = 42;\n\tpublic static function run():Int return LIMIT + 1;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'LIMIT', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newB.contains('public static final LIMIT:Int = 42;'), 'const should land in B');
		Assert.isTrue(newA.contains('return B.LIMIT + 1'), 'bare const read should qualify');
	}

	public function testInstanceMoveSelfContained(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tfunction norm(x:Int):Int {\n\t\treturn x + 1;\n\t}\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'norm', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isFalse(newA.contains('function norm'), 'norm should be gone from A');
		Assert.isTrue(newB.contains('function norm(x:Int):Int'), 'norm should land in B');
		Assert.isFalse(newB.contains('static function norm'), 'norm must stay an instance member');
	}

	public function testInstanceBareCallersRewiredThroughAutoVia(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tprivate final _calc:B;\n\tfunction run(x:Int):Int return norm(x);\n'
			+ '\tfunction norm(x:Int):Int return x + 1;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'norm', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newA.contains('return _calc.norm(x)'), 'bare caller should rewire through _calc');
		Assert.isTrue(newB.contains('public function norm'), 'called instance member should be promoted public');
	}

	public function testInstanceCallersWithoutViaFieldRefused(): Void {
		final a: String =
			'package pkg;\n\nclass A {\n\tfunction run(x:Int):Int return norm(x);\n\tfunction norm(x:Int):Int return x + 1;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		assertErrContains(move('pkg/A.hx', 'A', 'norm', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]), 'no field of type "B"');
	}

	public function testInstanceViaAmbiguousRefusedExplicitPicks(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tprivate final _p:B;\n\tprivate final _q:B;\n'
			+ '\tfunction run(x:Int):Int return norm(x);\n\tfunction norm(x:Int):Int return x + 1;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final scope: Array<{ file: String, source: String }> = [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		];
		assertErrContains(move('pkg/A.hx', 'A', 'norm', 'B', scope), 'multiple fields of type "B"');
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'norm', 'B', scope, '_q');
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		Assert.isTrue(newA.contains('return _q.norm(x)'), '--via should pick _q');
	}

	public function testInstanceFieldDepSatisfiedStaysBare(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tprivate final _k:Int;\n\tfunction m():Int return _k + 1;\n}';
		final b: String = 'package pkg;\n\nclass B {\n\tprivate final _k:Int;\n}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'm', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newB.contains('return _k + 1'), 'final-field read should stay bare');
		Assert.isFalse(newB.contains('A._k'), 'final-field read must NOT be qualified');
	}

	public function testInstanceFieldDepMissingOnDestRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tprivate final _k:Int;\n\tfunction m():Int return _k + 1;\n}';
		final scope: Array<{ file: String, source: String }> = [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {}' }
		];
		assertErr(move('pkg/A.hx', 'A', 'm', 'B', scope));
		final scopeVar: Array<{ file: String, source: String }> = [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {\n\tprivate var _k:Int;\n}' }
		];
		assertErr(move('pkg/A.hx', 'A', 'm', 'B', scopeVar));
	}

	public function testInstanceMutableFieldDepRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tprivate var _n:Int;\n\tfunction m():Int return _n + 1;\n}';
		final b: String = 'package pkg;\n\nclass B {\n\tprivate var _n:Int;\n}';
		assertErrContains(move('pkg/A.hx', 'A', 'm', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]), 'mutable instance field(s) "_n"');
	}

	public function testInstanceSiblingInstanceCallRefused(): Void {
		final a: String =
			'package pkg;\n\nclass A {\n\tfunction m(x:Int):Int return helper(x) * 2;\n\tfunction helper(x:Int):Int return x + 1;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		assertErrContains(move('pkg/A.hx', 'A', 'm', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]), 'instance member(s) "helper"');
	}

	public function testInstanceStaticSiblingQualifiedWithAccess(): Void {
		final a: String =
			'package pkg;\n\nclass A {\n\tfunction m(x:Int):Int return scale(x) * 2;\n\tstatic function scale(x:Int):Int return x + 10;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'm', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newB.contains('A.scale(x) * 2'), 'static sibling call should qualify to A');
		Assert.isTrue(newB.contains('@:access(pkg.A)'), 'private static sibling needs @:access');
	}

	public function testThisReferenceRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tprivate final _k:Int;\n\tfunction m():Int return this._k;\n}';
		final b: String = 'package pkg;\n\nclass B {\n\tprivate final _k:Int;\n}';
		assertErrContains(move('pkg/A.hx', 'A', 'm', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]), 'references "this"');
	}

	public function testGroupMoveMutualRecursionStaysBare(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tfunction even(n:Int):Bool return n == 0 ? true : odd(n - 1);\n'
			+ '\tfunction odd(n:Int):Bool return n == 0 ? false : even(n - 1);\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'even,odd', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isFalse(newA.contains('function even'), 'even should be gone from A');
		Assert.isFalse(newA.contains('function odd'), 'odd should be gone from A');
		Assert.isTrue(newB.contains('odd(n - 1)'), 'cross-call inside the moved set should stay bare');
		Assert.isFalse(newB.contains('.odd(n - 1)'), 'cross-call must NOT be qualified');
	}

	public function testGroupMoveMixedStaticAndInstance(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tprivate final _h:B;\n\tstatic function util(x:Int):Int return x * 2;\n'
			+ '\tfunction m(x:Int):Int return util(x) + 1;\n\tfunction go(x:Int):Int return m(x);\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util,m', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newA.contains('return _h.m(x)'), 'instance caller should rewire through _h');
		Assert.isTrue(newB.contains('return util(x) + 1'), 'moved-set static call should stay bare');
		Assert.isTrue(newB.contains('static function util'), 'util should stay static');
	}

	public function testGroupMoveKeepsSourceOrder(): Void {
		final a: String =
			'package pkg;\n\nclass A {\n\tstatic function first(x:Int):Int return x;\n\tstatic function second(x:Int):Int return x * 2;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'second,first', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		final firstAt: Int = newB.indexOf('function first');
		final secondAt: Int = newB.indexOf('function second');
		Assert.isTrue(firstAt >= 0, 'first should land in B');
		Assert.isTrue(secondAt >= 0, 'second should land in B');
		Assert.isTrue(firstAt < secondAt, 'moved members should land in source order, not list order');
	}

	public function testMoveConstructorRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic function new() {}\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		assertErrContains(move('pkg/A.hx', 'A', 'new', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]), 'cannot move a constructor');
	}

	public function testDuplicateMemberListRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tstatic function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		assertErrContains(move('pkg/A.hx', 'A', 'util,util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]), 'listed twice');
	}

	public function testClosureAutoExpandsInstanceCallSet(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tprivate final _calc:B;\n\tfunction run(x:Int):Int return top(x);\n'
			+ '\tfunction top(x:Int):Int return mid(x) + 1;\n\tfunction mid(x:Int):Int return leaf(x) * 2;\n'
			+ '\tfunction leaf(x:Int):Int return x + 3;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		// Without --closure: moving only `top` refuses on `mid` staying behind.
		assertErrContains(move('pkg/A.hx', 'A', 'top', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]), 'instance member(s) "mid"');
		// With --closure: `top` pulls in mid + leaf transitively.
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'top', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		], null, true);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isFalse(newA.contains('function top'), 'top should be gone from A');
		Assert.isFalse(newA.contains('function mid'), 'mid pulled into closure, gone from A');
		Assert.isFalse(newA.contains('function leaf'), 'leaf pulled into closure, gone from A');
		Assert.isTrue(newA.contains('function run'), 'run stays on A (not called by the moved set)');
		Assert.isTrue(newB.contains('return mid(x) + 1'), 'moved-set call stays bare');
		Assert.isTrue(newB.contains('return leaf(x) * 2'), 'transitive moved-set call stays bare');
		Assert.isTrue(newA.contains('return _calc.top(x)'), 'external caller rewired through _calc');
	}

	public function testClosureNoDepsIsNoop(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tstatic function util(x:Int):Int return x + 1;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		], null, true);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newB.contains('static function util'), 'lone static member moves unchanged under --closure');
	}

	public function testClosureStillRefusesThis(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tprivate final _k:Int;\n\tfunction m():Int return this._k + helper();\n'
			+ '\tfunction helper():Int return 1;\n}';
		final b: String = 'package pkg;\n\nclass B {\n\tprivate final _k:Int;\n}';
		// Closure pulls in `helper`, but the surviving `this` still refuses.
		assertErrContains(move('pkg/A.hx', 'A', 'm', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		], null, true), 'references "this"');
	}

	public function testScaffoldGeneratesDestFieldsCtorAndVia(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tprivate final _k:Int;\n\tpublic function new(k:Int) {\n\t\t_k = k;\n\t}\n'
			+ '\tfunction run():Int return m();\n\tfunction m():Int return _k + 1;\n}';
		final b: String = 'package pkg;\n\nclass B {\n\tpublic function new() {}\n}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'm', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		], null, null, true);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		// Dest: mirrored final field + constructor replacing the trivial new().
		Assert.isTrue(newB.contains('private final _k: Int;'), 'dest should get the mirrored final field');
		Assert.isTrue(newB.contains('public function new(k: Int) {'), 'dest should get a constructor over the field');
		Assert.isTrue(newB.contains('_k = k;'), 'dest constructor should assign the field');
		Assert.isFalse(newB.contains('function new() {}'), 'the trivial ctor should be gone');
		Assert.isTrue(newB.contains('return _k + 1'), 'moved body reads the mirrored field bare');
		// Src: via field + wiring in the constructor.
		Assert.isTrue(newA.contains('private final _b: B;'), 'src should get the via field');
		Assert.isTrue(newA.contains('_b = new B(_k);'), 'src ctor should wire the via field');
		Assert.isTrue(newA.contains('return _b.m()'), 'bare instance caller rewired through the via field');
	}

	public function testScaffoldExplicitViaName(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tprivate final _k:Int;\n\tpublic function new(k:Int) {\n\t\t_k = k;\n\t}\n'
			+ '\tfunction run():Int return m();\n\tfunction m():Int return _k + 1;\n}';
		final b: String = 'package pkg;\n\nclass B {\n\tpublic function new() {}\n}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'm', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		], '_helper', null, true);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		Assert.isTrue(newA.contains('private final _helper: B;'), '--via name should be honored');
		Assert.isTrue(newA.contains('_helper = new B(_k);'), 'wiring uses the --via name');
		Assert.isTrue(newA.contains('return _helper.m()'), 'callers rewired through --via name');
	}

	public function testScaffoldNoCtorOnDestPrepends(): Void {
		// Dest declared with --raw style (no constructor at all).
		final a: String = 'package pkg;\n\nclass A {\n\tprivate final _k:Int;\n\tpublic function new(k:Int) {\n\t\t_k = k;\n\t}\n'
			+ '\tfunction m():Int return _k + 1;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'm', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		], null, null, true);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newB.contains('private final _k: Int;'), 'dest with no ctor still gets the field');
		Assert.isTrue(newB.contains('public function new(k: Int) {'), 'dest with no ctor gets a constructor');
	}

	public function testScaffoldRefusesNonTrivialDestCtor(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tprivate final _k:Int;\n\tpublic function new(k:Int) {\n\t\t_k = k;\n\t}\n'
			+ '\tfunction m():Int return _k + 1;\n}';
		final b: String = 'package pkg;\n\nclass B {\n\tvar n:Int;\n\tpublic function new() {\n\t\tn = 5;\n\t}\n}';
		assertErrContains(move('pkg/A.hx', 'A', 'm', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		], null, null, true), 'already has a constructor');
	}

	public function testScaffoldWithoutFlagStillRefuses(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tprivate final _k:Int;\n\tpublic function new(k:Int) {\n\t\t_k = k;\n\t}\n'
			+ '\tfunction m():Int return _k + 1;\n}';
		final b: String = 'package pkg;\n\nclass B {\n\tpublic function new() {}\n}';
		assertErrContains(move('pkg/A.hx', 'A', 'm', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]), 'or pass --scaffold');
	}

	public function testScaffoldViaNameCollisionRefused(): Void {
		// Src already has a member named `_b` (the derived via name for dest B).
		final a: String = 'package pkg;\n\nclass A {\n\tprivate final _k:Int;\n\tprivate final _b:String;\n\tpublic function new(k:Int) {\n'
			+ '\t\t_k = k;\n\t\t_b = "x";\n\t}\n\tfunction run():Int return m();\n\tfunction m():Int return _k + 1;\n}';
		final b: String = 'package pkg;\n\nclass B {\n\tpublic function new() {}\n}';
		assertErrContains(move('pkg/A.hx', 'A', 'm', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		], null, null, true), 'already declares a member');
	}

	public function testScaffoldCallerInsideCtorRefused(): Void {
		// A rewired caller sits inside Src's ctor — via field would be read
		// before it is initialized.
		final a: String = 'package pkg;\n\nclass A {\n\tprivate final _k:Int;\n\tpublic function new(k:Int) {\n\t\t_k = k;\n\t\tm();\n\t}\n'
			+ '\tfunction m():Int return _k + 1;\n}';
		final b: String = 'package pkg;\n\nclass B {\n\tpublic function new() {}\n}';
		assertErrContains(move('pkg/A.hx', 'A', 'm', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		], null, null, true), 'read before it is initialized');
	}

	public function testScaffoldCommentOnlyDestCtorRefused(): Void {
		// Dest ctor body has a comment (not a statement) — must NOT be
		// treated as trivial and clobbered.
		final a: String = 'package pkg;\n\nclass A {\n\tprivate final _k:Int;\n\tpublic function new(k:Int) {\n\t\t_k = k;\n\t}\n'
			+ '\tfunction m():Int return _k + 1;\n}';
		final b: String = 'package pkg;\n\nclass B {\n\tpublic function new() {\n\t\t// IMPORTANT: keep\n\t}\n}';
		assertErrContains(move('pkg/A.hx', 'A', 'm', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		], null, null, true), 'already has a constructor');
	}

	public function testTwoQualifiedCallsOnOneLine(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final user: String = 'package pkg;\n\nclass User {\n\tfunction go():Int return A.util(1) + A.util(2);\n}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
			{ file: 'pkg/User.hx', source: user }
		]);
		final newUser: String = changeFor(changes, 'pkg/User.hx').newSource;
		Assert.isTrue(newUser.contains('B.util(1) + B.util(2)'), 'both same-line callers should repoint');
	}

	public function testSkipParseScopeFileRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		assertErr(move('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
			{ file: 'pkg/Broken.hx', source: 'class {{{' }
		]));
	}

	/**
	 * A switch case pattern binding the member's name: `Refs` cannot tell
	 * the capture from the member, so the move must refuse rather than
	 * silently rewrite match code.
	 */
	public function testCasePatternCaptureRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tstatic function run(o:Null<Int>):Int return switch o {\n\t\tcase util: util;\n'
			+ '\t\tcase _: 0;\n\t}\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		assertErr(move('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]));
	}

	/**
	 * Promotion of a default-visibility member carrying leading `@:meta`:
	 * `public` must land after the meta, before `static`.
	 */
	public function testMetaMemberPromotionLandsAfterMeta(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function run():Int return util(3);\n'
			+ '\t@:keep static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newB.contains('@:keep public static function util'), 'public should follow the meta');
	}

	/** A paren-bearing `@:name(args)` meta (MetaCall) above the moved member: the promotion `public` must land AFTER it, like the paren-less form. */
	public function testMetaCallMemberPromotionLandsAfterMeta(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function run():Int return util(3);\n'
			+ '\t@:nowarn("x") static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newB.contains('@:nowarn("x") public static function util'), 'public should follow the MetaCall meta: $newB');
	}

	public function testFullyQualifiedCallerRewritten(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final user: String = 'package app;\n\nclass User {\n\tfunction go():Int return pkg.A.util(1);\n}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
			{ file: 'app/User.hx', source: user }
		]);
		final newUser: String = changeFor(changes, 'app/User.hx').newSource;
		Assert.isTrue(newUser.contains('pkg.B.util(1)'), 'fully-qualified caller should repoint');
	}

	public function testUsingOfDestTypeRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final user: String = 'package pkg;\n\nusing pkg.B;\n\nclass User {}';
		assertErr(move('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
			{ file: 'pkg/User.hx', source: user }
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
			{ file: 'pkg/B.hx', source: b }
		]);
		final newB: String = changeFor(changes, 'pkg/B.hx').newSource;
		Assert.isTrue(newB.contains('B.util(5)'), 'dest-file caller should repoint');
		Assert.isTrue(newB.contains('private static function util'), 'no promotion for a dest-file caller');
	}

	public function testCrossPackageFqnCallerRepoints(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n}';
		final b: String = 'package other;\n\nclass B {}';
		final user: String = 'package pkg;\n\nclass User {\n\tstatic function go():Int return pkg.A.util(1) + A.util(2);\n}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'other/B.hx', source: b },
			{ file: 'pkg/User.hx', source: user }
		]);
		final newUser: String = changeFor(changes, 'pkg/User.hx').newSource;
		Assert.isTrue(
			newUser.contains('other.B.util(1)'), 'a dotted caller takes the whole destination path, package segment and all:\n$newUser'
		);
		Assert.isTrue(newUser.contains('+ B.util(2)'), 'a bare caller stays bare:\n$newUser');
		Assert.isTrue(newUser.contains('import other.B;'), 'only the bare caller owes the destination import:\n$newUser');
	}

	/**
	 * A bare caller spelled as a braceless `$TAG` interpolation cannot take the `B.`
	 * prefix an ordinary one takes — `$` binds to a bare identifier, so the prefix would
	 * emit the literal text `B.` plus an interpolation of a name A no longer declares.
	 * The whole `$TAG` span becomes `${B.TAG}` instead. The braced `${TAG}` beside it goes
	 * through the ordinary path, and the escaped `$$TAG` is literal text and stays put.
	 */
	public function testBareInterpolationCallerBraced(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static final TAG:String = "t";\n'
			+ '\tpublic static function label():String return \'[$$TAG] $${TAG}b $$$$TAG\';\n}';
		final b: String = 'package pkg;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'TAG', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b }
		]);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		Assert.isTrue(newA.contains('\'[$${B.TAG}] $${B.TAG}b $$$$TAG\''), 'braced qualification expected:\n$newA');
	}

	public function testEnumAbstractValueRefusedInsteadOfViaFieldError(): Void {
		final colour: String = 'package pal;\n\nenum abstract Colour(Int) {\n\tvar RED = 1;\n\tvar BLUE = 2;\n\n'
			+ '\tpublic static function isRed(c:Colour):Bool return c == RED;\n}';
		final palette: String = 'package pal;\n\nclass Palette {\n\tpublic static var COUNT = 0;\n}';
		assertErrContains(move('pal/Colour.hx', 'Colour', 'RED', 'Palette', [
			{ file: 'pal/Colour.hx', source: colour },
			{ file: 'pal/Palette.hx', source: palette }
		]), 'carries no `static` modifier yet is static anyway');
	}

	public function testEnumAbstractValueNotSilentlyMovedAsInstanceField(): Void {
		final colour: String = 'package pal;\n\nenum abstract Colour(Int) {\n\tvar RED = 1;\n\tvar BLUE = 2;\n}';
		final palette: String = 'package pal;\n\nclass Palette {\n\tpublic static var COUNT = 0;\n}';
		final user: String = 'package pal;\n\nclass User {\n\tpublic static function pick():Colour return Colour.RED;\n}';
		assertErrContains(move('pal/Colour.hx', 'Colour', 'RED', 'Palette', [
			{ file: 'pal/Colour.hx', source: colour },
			{ file: 'pal/Palette.hx', source: palette },
			{ file: 'pal/User.hx', source: user }
		]), 'carries no `static` modifier yet is static anyway');
	}

	public function testAbstractModifierlessPropertyRefused(): Void {
		final meters: String =
			'package pkg;\n\nabstract Meters(Int) {\n\tpublic var length(get, never):Int;\n\n\tfunction get_length():Int return 0;\n}';
		final box: String = 'package pkg;\n\nclass Box {}';
		assertErrContains(move('pkg/Meters.hx', 'Meters', 'length', 'Box', [
			{ file: 'pkg/Meters.hx', source: meters },
			{ file: 'pkg/Box.hx', source: box }
		]), 'carries no `static` modifier yet is static anyway');
	}

	public function testExplicitStaticInsideEnumAbstractStillMoves(): Void {
		final colour: String =
			'package pal;\n\nenum abstract Colour(Int) {\n\tvar RED = 1;\n\n\tpublic static function hue():Int return 7;\n}';
		final palette: String = 'package pal;\n\nclass Palette {\n\tpublic static var COUNT = 0;\n}';
		final user: String = 'package pal;\n\nclass User {\n\tpublic static function pick():Int return Colour.hue();\n}';
		final changes: Array<MoveChange> = okChanges('pal/Colour.hx', 'Colour', 'hue', 'Palette', [
			{ file: 'pal/Colour.hx', source: colour },
			{ file: 'pal/Palette.hx', source: palette },
			{ file: 'pal/User.hx', source: user }
		]);
		final newPalette: String = changeFor(changes, 'pal/Palette.hx').newSource;
		Assert.isTrue(newPalette.contains('public static function hue'), 'hue should land in Palette:\n$newPalette');
		Assert.isTrue(changeFor(changes, 'pal/User.hx').newSource.contains('Palette.hue()'), 'the caller should repoint');
		Assert.isTrue(changeFor(changes, 'pal/Colour.hx').newSource.contains('var RED = 1'), 'the enum value must stay put');
	}

	public function testQualifiedReceiverRepointsOnlyTheDeclaringModule(): Void {
		final boxes: String = 'package pkg;\n\nclass Boxes {\n\tpublic static function tag():Int return 5;\n}';
		final foreign: String = 'package other;\n\nclass Boxes {\n\tpublic static function tag():Int return 7;\n}';
		final dest: String = 'package pkg;\n\nclass Dest {}';
		final main: String = 'package pkg;\n\nclass Main {\n\tstatic function run():Int return pkg.Boxes.tag() + other.Boxes.tag();\n}';
		final changes: Array<MoveChange> = okChanges('pkg/Boxes.hx', 'Boxes', 'tag', 'Dest', [
			{ file: 'pkg/Boxes.hx', source: boxes },
			{ file: 'pkg/Dest.hx', source: dest },
			{ file: 'pkg/Main.hx', source: main },
			{ file: 'other/Boxes.hx', source: foreign }
		]);
		final newMain: String = changeFor(changes, 'pkg/Main.hx').newSource;
		Assert.isTrue(newMain.contains('pkg.Dest.tag()'), 'the declaring module should repoint:\n$newMain');
		Assert.isTrue(newMain.contains('other.Boxes.tag()'), 'a same-named module in another package must be left alone:\n$newMain');
		Assert.isFalse(newMain.contains('other.Dest'), 'no "other.Dest" may be produced:\n$newMain');
	}

	public function testCrossPackageRepointIgnoresAForeignModule(): Void {
		final boxes: String = 'package pkg;\n\nclass Boxes {\n\tpublic static function tag():Int return 5;\n}';
		final foreign: String = 'package other;\n\nclass Boxes {\n\tpublic static function tag():Int return 7;\n}';
		final dest: String = 'package dst;\n\nclass Dest {}';
		final main: String =
			'package app;\n\nimport pkg.Boxes;\n\nclass Main {\n\tstatic function run():Int return Boxes.tag() + other.Boxes.tag();\n}';
		final changes: Array<MoveChange> = okChanges('pkg/Boxes.hx', 'Boxes', 'tag', 'Dest', [
			{ file: 'pkg/Boxes.hx', source: boxes },
			{ file: 'dst/Dest.hx', source: dest },
			{ file: 'app/Main.hx', source: main },
			{ file: 'other/Boxes.hx', source: foreign }
		]);
		final newMain: String = changeFor(changes, 'app/Main.hx').newSource;
		Assert.isTrue(newMain.contains('Dest.tag()'), 'the bare caller should repoint:\n$newMain');
		Assert.isTrue(newMain.contains('other.Boxes.tag()'), 'the foreign module must be left alone:\n$newMain');
	}

	public function testSubModuleSourceQualifiedCallerRepointsWholePath(): Void {
		final mod: String = 'package pkg;\n\nclass Mod {}\n\nclass Helper {\n\tpublic static function tag():Int return 5;\n}';
		final dest: String = 'package pkg;\n\nclass Dest {}';
		final user: String = 'package app;\n\nclass User {\n\tstatic function go():Int return pkg.Mod.Helper.tag();\n}';
		final changes: Array<MoveChange> = okChanges('pkg/Mod.hx', 'Helper', 'tag', 'Dest', [
			{ file: 'pkg/Mod.hx', source: mod },
			{ file: 'pkg/Dest.hx', source: dest },
			{ file: 'app/User.hx', source: user }
		]);
		final newUser: String = changeFor(changes, 'app/User.hx').newSource;
		Assert.isTrue(newUser.contains('pkg.Dest.tag()'), 'the whole receiver path must become the destination path:\n$newUser');
		Assert.isFalse(newUser.contains('pkg.Mod.Dest'), '"Dest" is not a sub-module of "pkg.Mod":\n$newUser');
		Assert.isFalse(newUser.contains('import '), 'a root-anchored path carries itself — no import is owed:\n$newUser');
	}

	public function testSubModuleSourceModuleShortCallerRepointsWholePath(): Void {
		final mod: String = 'package pkg;\n\nclass Mod {}\n\nclass Helper {\n\tpublic static function tag():Int return 5;\n}';
		final dest: String = 'package pkg;\n\nclass Dest {}';
		final near: String = 'package pkg;\n\nclass Near {\n\tstatic function go():Int return Mod.Helper.tag();\n}';
		final changes: Array<MoveChange> = okChanges('pkg/Mod.hx', 'Helper', 'tag', 'Dest', [
			{ file: 'pkg/Mod.hx', source: mod },
			{ file: 'pkg/Dest.hx', source: dest },
			{ file: 'pkg/Near.hx', source: near }
		]);
		final newNear: String = changeFor(changes, 'pkg/Near.hx').newSource;
		Assert.isTrue(newNear.contains('pkg.Dest.tag()'), 'the short module spelling must repoint to the destination path:\n$newNear');
		Assert.isFalse(newNear.contains('Mod.Dest'), '"Dest" is not a sub-module of "Mod":\n$newNear');
	}

	public function testSubModuleSourceBareCallerStaysShort(): Void {
		final mod: String = 'package pkg;\n\nclass Mod {}\n\nclass Helper {\n\tpublic static function tag():Int return 5;\n}';
		final dest: String = 'package pkg;\n\nclass Dest {}';
		final user: String = 'package app;\n\nimport pkg.Mod.Helper;\n\nclass User {\n\tstatic function go():Int return Helper.tag();\n}';
		final changes: Array<MoveChange> = okChanges('pkg/Mod.hx', 'Helper', 'tag', 'Dest', [
			{ file: 'pkg/Mod.hx', source: mod },
			{ file: 'pkg/Dest.hx', source: dest },
			{ file: 'app/User.hx', source: user }
		]);
		final newUser: String = changeFor(changes, 'app/User.hx').newSource;
		Assert.isTrue(newUser.contains('Dest.tag()'), 'a bare receiver should repoint to the bare destination name:\n$newUser');
		Assert.isFalse(newUser.contains('pkg.Dest.tag()'), 'a bare receiver stays bare — the import carries the path:\n$newUser');
		Assert.isTrue(newUser.contains('import pkg.Dest;'), 'a bare caller still needs the destination import:\n$newUser');
	}

	public function testSubModuleDestQualifiedCallerGainsModuleSegment(): Void {
		final mod: String = 'package pkg;\n\nclass Mod {\n\tpublic static function tag():Int return 5;\n}';
		final box: String = 'package pkg;\n\nclass Box {}\n\nclass Dest {}';
		final near: String = 'package pkg;\n\nclass Near {\n\tstatic function go():Int return pkg.Mod.tag();\n}';
		final changes: Array<MoveChange> = okChanges('pkg/Mod.hx', 'Mod', 'tag', 'Dest', [
			{ file: 'pkg/Mod.hx', source: mod },
			{ file: 'pkg/Box.hx', source: box },
			{ file: 'pkg/Near.hx', source: near }
		]);
		final newNear: String = changeFor(changes, 'pkg/Near.hx').newSource;
		Assert.isTrue(newNear.contains('pkg.Box.Dest.tag()'), 'a sub-module destination needs its module segment:\n$newNear');
		Assert.isFalse(newNear.contains('pkg.Dest.tag()'), 'there is no module "pkg.Dest":\n$newNear');
	}

	public function testDestIsSourceModuleMainTypeCollapsesPath(): Void {
		final mod: String = 'package pkg;\n\nclass Mod {}\n\nclass Helper {\n\tpublic static function tag():Int return 5;\n}';
		final user: String = 'package app;\n\nclass User {\n\tstatic function go():Int return pkg.Mod.Helper.tag();\n}';
		final changes: Array<MoveChange> = okChanges('pkg/Mod.hx', 'Helper', 'tag', 'Mod', [
			{ file: 'pkg/Mod.hx', source: mod },
			{ file: 'app/User.hx', source: user }
		]);
		final newUser: String = changeFor(changes, 'app/User.hx').newSource;
		Assert.isTrue(newUser.contains('pkg.Mod.tag()'), 'the module main type is spelled by the module path alone:\n$newUser');
		Assert.isFalse(newUser.contains('pkg.Mod.Mod'), 'the main type must not be appended to its own module path:\n$newUser');
	}

	public function testSubModuleSiblingDestKeepsModulePath(): Void {
		final mod: String =
			'package pkg;\n\nclass Mod {}\n\nclass Helper {\n\tpublic static function tag():Int return 5;\n}\n\nclass Other {}';
		final user: String = 'package app;\n\nclass User {\n\tstatic function go():Int return pkg.Mod.Helper.tag();\n}';
		final changes: Array<MoveChange> = okChanges('pkg/Mod.hx', 'Helper', 'tag', 'Other', [
			{ file: 'pkg/Mod.hx', source: mod },
			{ file: 'app/User.hx', source: user }
		]);
		final newUser: String = changeFor(changes, 'app/User.hx').newSource;
		Assert.isTrue(newUser.contains('pkg.Mod.Other.tag()'), 'a sibling sub-module destination keeps the module path:\n$newUser');
		Assert.isFalse(newUser.contains('import '), 'the path is unchanged, so no import is owed:\n$newUser');
	}

	public function testSubModuleRepointLeavesAForeignModuleAlone(): Void {
		final mod: String = 'package pkg;\n\nclass Mod {}\n\nclass Helper {\n\tpublic static function tag():Int return 5;\n}';
		final foreign: String = 'package other;\n\nclass Mod {}\n\nclass Helper {\n\tpublic static function tag():Int return 7;\n}';
		final dest: String = 'package pkg;\n\nclass Dest {}';
		final user: String =
			'package app;\n\nclass User {\n\tstatic function go():Int return pkg.Mod.Helper.tag() + other.Mod.Helper.tag();\n}';
		final changes: Array<MoveChange> = okChanges('pkg/Mod.hx', 'Helper', 'tag', 'Dest', [
			{ file: 'pkg/Mod.hx', source: mod },
			{ file: 'pkg/Dest.hx', source: dest },
			{ file: 'app/User.hx', source: user },
			{ file: 'other/Mod.hx', source: foreign }
		]);
		final newUser: String = changeFor(changes, 'app/User.hx').newSource;
		Assert.isTrue(newUser.contains('pkg.Dest.tag()'), 'the declaring module should repoint:\n$newUser');
		Assert.isTrue(newUser.contains('other.Mod.Helper.tag()'), 'a same-named module in another package must be left alone:\n$newUser');
		Assert.isFalse(newUser.contains('other.Dest'), 'no "other.Dest" may be produced:\n$newUser');
	}

	public function testRootPackageDestinationRepointsToTheBareModule(): Void {
		final mod: String = 'class Mod {}\n\nclass Helper {\n\tpublic static function tag():Int return 5;\n}';
		final dest: String = 'class Dest {}';
		final user: String = 'package app;\n\nclass User {\n\tstatic function go():Int return Mod.Helper.tag();\n}';
		final changes: Array<MoveChange> = okChanges('Mod.hx', 'Helper', 'tag', 'Dest', [
			{ file: 'Mod.hx', source: mod },
			{ file: 'Dest.hx', source: dest },
			{ file: 'app/User.hx', source: user }
		]);
		final newUser: String = changeFor(changes, 'app/User.hx').newSource;
		Assert.isTrue(newUser.contains('Dest.tag()'), 'a root-package module is named by its basename alone:\n$newUser');
		Assert.isFalse(newUser.contains('Mod.Dest'), 'the source module segment must go:\n$newUser');
		Assert.isFalse(newUser.contains('import '), 'a root-package module is visible everywhere — no import is owed:\n$newUser');
	}

	public function testSubModuleDestBareCallerInPackageGainsImport(): Void {
		final mod: String = 'package pkg;\n\nclass Mod {\n\tpublic static function tag():Int return 5;\n}';
		final box: String = 'package pkg;\n\nclass Box {}\n\nclass Dest {}';
		final near: String = 'package pkg;\n\nclass Near {\n\tstatic function go():Int return Mod.tag();\n}';
		final foreign: String = 'package other;\n\nclass Box {}\n\nclass Keep {}';
		final changes: Array<MoveChange> = okChanges('pkg/Mod.hx', 'Mod', 'tag', 'Dest', [
			{ file: 'pkg/Mod.hx', source: mod },
			{ file: 'pkg/Box.hx', source: box },
			{ file: 'pkg/Near.hx', source: near },
			{ file: 'other/Box.hx', source: foreign }
		]);
		final newNear: String = changeFor(changes, 'pkg/Near.hx').newSource;
		Assert.isTrue(newNear.contains('Dest.tag()'), 'a bare receiver repoints to the bare destination name:\n$newNear');
		Assert.isTrue(
			newNear.contains('import pkg.Box.Dest;'),
			'a sub-module destination does not resolve bare, not even from its own package:\n$newNear'
		);
		Assert.isFalse(newNear.contains('other.Box.Dest'), 'the import path comes from the resolved destination module:\n$newNear');
	}

	public function testSubModuleDestSourceFileGainsImport(): Void {
		final mod: String = 'package pkg;\n\nclass Mod {\n\tpublic static function tag():Int return 5;\n\n\t'
			+ 'public static function use():Int return tag();\n}';
		final box: String = 'package pkg;\n\nclass Box {}\n\nclass Dest {}';
		final changes: Array<MoveChange> = okChanges('pkg/Mod.hx', 'Mod', 'tag', 'Dest', [
			{ file: 'pkg/Mod.hx', source: mod },
			{ file: 'pkg/Box.hx', source: box }
		]);
		final newMod: String = changeFor(changes, 'pkg/Mod.hx').newSource;
		Assert.isTrue(newMod.contains('Dest.tag()'), 'the remaining caller is qualified with the destination:\n$newMod');
		Assert.isTrue(
			newMod.contains('import pkg.Box.Dest;'), 'the source file names a sub-module destination bare, so it owes the import:\n$newMod'
		);
	}

	public function testSubModuleSourceDestFileGainsImport(): Void {
		final mod: String = 'package pkg;\n\nclass Mod {}\n\nclass Helper {\n\tpublic static function tag():Int return other();\n\n\t'
			+ 'public static function other():Int return 6;\n}';
		final dest: String = 'package pkg;\n\nclass Dest {}';
		final foreign: String = 'package other;\n\nclass Mod {}\n\nclass Helper {\n\tpublic static function other():Int return 9;\n}';
		final changes: Array<MoveChange> = okChanges('pkg/Mod.hx', 'Helper', 'tag', 'Dest', [
			{ file: 'pkg/Mod.hx', source: mod },
			{ file: 'pkg/Dest.hx', source: dest },
			{ file: 'other/Mod.hx', source: foreign }
		]);
		final newDest: String = changeFor(changes, 'pkg/Dest.hx').newSource;
		Assert.isTrue(newDest.contains('Helper.other()'), 'the moved body qualifies the sibling it left behind:\n$newDest');
		Assert.isTrue(
			newDest.contains('import pkg.Mod.Helper;'),
			'a sub-module source does not resolve bare from a sibling file in its own package:\n$newDest'
		);
		Assert.isFalse(newDest.contains('other.Mod.Helper'), 'the import path comes from the resolved source module:\n$newDest');
	}

	public function testSamePackageMainTypeDestOwesNoImport(): Void {
		final mod: String = 'package pkg;\n\nclass Mod {\n\tpublic static function tag():Int return 5;\n\n\t'
			+ 'public static function use():Int return tag();\n}';
		final dest: String = 'package pkg;\n\nclass Dest {}';
		final near: String = 'package pkg;\n\nclass Near {\n\tstatic function go():Int return Mod.tag();\n}';
		final changes: Array<MoveChange> = okChanges('pkg/Mod.hx', 'Mod', 'tag', 'Dest', [
			{ file: 'pkg/Mod.hx', source: mod },
			{ file: 'pkg/Dest.hx', source: dest },
			{ file: 'pkg/Near.hx', source: near }
		]);
		final newNear: String = changeFor(changes, 'pkg/Near.hx').newSource;
		final newMod: String = changeFor(changes, 'pkg/Mod.hx').newSource;
		Assert.isTrue(newNear.contains('Dest.tag()'), 'the caller still repoints to the destination:\n$newNear');
		Assert.isFalse(newNear.contains('import '), 'a main type resolves bare inside its own package:\n$newNear');
		Assert.isTrue(newMod.contains('Dest.tag()'), 'the source file qualifies its remaining caller too:\n$newMod');
		Assert.isFalse(newMod.contains('import '), 'the source file reaches a same-package main type bare too:\n$newMod');
	}

	public function testMoveInsideOneModuleOwesNoImport(): Void {
		final mod: String = 'package pkg;\n\nclass Mod {}\n\nclass Helper {\n\tpublic static function tag():Int return other();\n\n\t'
			+ 'public static function other():Int return 6;\n}';
		final changes: Array<MoveChange> = okChanges('pkg/Mod.hx', 'Helper', 'tag', 'Mod', [{ file: 'pkg/Mod.hx', source: mod }]);
		final newMod: String = changeFor(changes, 'pkg/Mod.hx').newSource;
		Assert.isTrue(newMod.contains('Helper.other()'), 'the moved body still qualifies its old sibling:\n$newMod');
		Assert.isFalse(newMod.contains('import '), 'types of one module see each other — a module must not import itself:\n$newMod');
	}

	public function testCrossPackageSubModuleEndpointsWireBothImports(): Void {
		final mod: String = 'package pkg;\n\nclass Mod {}\n\nclass Helper {\n\tpublic static function tag():Int return other();\n\n\t'
			+ 'public static function other():Int return 6;\n}';
		final box: String = 'package far;\n\nclass Box {}\n\nclass Dest {}';
		final near: String = 'package pkg;\n\nclass Near {\n\tstatic function go():Int return Mod.Helper.tag();\n}';
		final changes: Array<MoveChange> = okChanges('pkg/Mod.hx', 'Helper', 'tag', 'Dest', [
			{ file: 'pkg/Mod.hx', source: mod },
			{ file: 'far/Box.hx', source: box },
			{ file: 'pkg/Near.hx', source: near }
		]);
		final newNear: String = changeFor(changes, 'pkg/Near.hx').newSource;
		final newBox: String = changeFor(changes, 'far/Box.hx').newSource;
		Assert.isTrue(newNear.contains('far.Box.Dest.tag()'), 'the module-short spelling takes the whole destination path:\n$newNear');
		Assert.isFalse(newNear.contains('import '), 'a whole path carries itself:\n$newNear');
		Assert.isTrue(newBox.contains('import pkg.Mod.Helper;'), 'the destination reaches the sub-module source by import:\n$newBox');
	}

	public function testRootPackageMainTypeDestGainsImportOutsideRoot(): Void {
		final mod: String = 'package pkg;\n\nclass Mod {\n\tpublic static function tag():Int return 5;\n}';
		final dest: String = 'class Dest {}';
		final user: String = 'package app;\n\nimport pkg.Mod;\n\nclass User {\n\tstatic function go():Int return Mod.tag();\n}';
		final root: String = 'import pkg.Mod;\n\nclass Root {\n\tstatic function go():Int return Mod.tag();\n}';
		final changes: Array<MoveChange> = okChanges('pkg/Mod.hx', 'Mod', 'tag', 'Dest', [
			{ file: 'pkg/Mod.hx', source: mod },
			{ file: 'Dest.hx', source: dest },
			{ file: 'app/User.hx', source: user },
			{ file: 'Root.hx', source: root }
		]);
		final newUser: String = changeFor(changes, 'app/User.hx').newSource;
		final newRoot: String = changeFor(changes, 'Root.hx').newSource;
		Assert.isTrue(newUser.contains('Dest.tag()'), 'the bare caller repoints to the bare destination name:\n$newUser');
		Assert.isTrue(
			newUser.contains('import Dest;'), 'a root-package name a foreign package could shadow is pinned by an import:\n$newUser'
		);
		Assert.isTrue(newRoot.contains('Dest.tag()'), 'the root-package caller repoints too:\n$newRoot');
		Assert.isFalse(newRoot.contains('import Dest;'), 'a caller in the destination\'s own package owes nothing:\n$newRoot');
	}

	public function testRootPackageSourceShadowedInDestPackageGainsImport(): Void {
		final src: String =
			'class Src {\n\tpublic static function tag():Int return other();\n\n\tpublic static function other():Int return 6;\n}';
		final shadow: String = 'package app;\n\nclass Src {\n\tpublic static function other():Int return 99;\n}';
		final dest: String = 'package app;\n\nclass Dest {}';
		final changes: Array<MoveChange> = okChanges('Src.hx', 'Src', 'tag', 'Dest', [
			{ file: 'Src.hx', source: src },
			{ file: 'app/Src.hx', source: shadow },
			{ file: 'app/Dest.hx', source: dest }
		]);
		final newDest: String = changeFor(changes, 'app/Dest.hx').newSource;
		Assert.isTrue(newDest.contains('Src.other()'), 'the moved body qualifies the sibling it left behind:\n$newDest');
		Assert.isTrue(
			newDest.contains('import Src;'), 'without the import the bare name binds to the destination package\'s own "Src":\n$newDest'
		);
	}

	public function testDottedOnlySourceReferenceOwesNoImport(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function util(x:Int):Int return x;\n\n\t'
			+ 'public static function self():Int return pkg.A.util(3);\n}';
		final b: String = 'package other;\n\nclass B {}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'other/B.hx', source: b }
		]);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		Assert.isTrue(newA.contains('other.B.util(3)'), 'the dotted caller takes the whole destination path:\n$newA');
		Assert.isFalse(newA.contains('import '), 'a whole path carries itself — the source file owes nothing:\n$newA');
	}

	public function testScaffoldViaFieldOfSubModuleDestGainsImport(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tprivate final _k:Int;\n\tpublic function new(k:Int) {\n\t\t_k = k;\n\t}\n'
			+ '\tfunction run():Int return m();\n\tfunction m():Int return _k + 1;\n}';
		final box: String = 'package pkg;\n\nclass Box {}\n\nclass Dest {\n\tpublic function new() {}\n}';
		final changes: Array<MoveChange> = okChanges('pkg/A.hx', 'A', 'm', 'Dest', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/Box.hx', source: box }
		], null, null, true);
		final newA: String = changeFor(changes, 'pkg/A.hx').newSource;
		Assert.isTrue(newA.contains('private final _dest: Dest;'), 'the scaffolded via field is typed by the destination:\n$newA');
		Assert.isTrue(
			newA.contains('import pkg.Box.Dest;'), 'the via field names a sub-module type bare, so the source file owes its import:\n$newA'
		);
	}

	/**
	 * `move-member` shares `MoveSymbol.dependencyImportLinesToCarry` with `move`, so it shared the
	 * silent-miscompile too: measured on 11f22a25 and compile-run on Haxe 4.3.7, moving a static
	 * whose body reaches `q.Dep` into a destination holding `import r.Dep;` wrote both files with
	 * rc 0 and no diagnostic, and the DESTINATION's own `Dest.local()` came back `q.Dep` where it
	 * had been `r.Dep`. The gate lives at the shared seat, so both ops refuse on the same sentence;
	 * the control is the same carry with nothing at the destination to collide with.
	 */
	public function testCarriedImportCollidingWithADestinationBindingRefused(): Void {
		inline function scope(destImport: String, destMember: String): Array<{ file: String, source: String }> {
			return [
				{ file: 'q/Dep.hx', source: 'package q;\n\nclass Dep {}' },
				{ file: 'r/Dep.hx', source: 'package r;\n\nclass Dep {}' },
				{
					file: 'p/Src.hx',
					source: 'package p;\n\nimport q.Dep;\n\nclass Src {\n\tpublic static function make():Dep return null;\n}'
				},
				{
					file: 'p/Dest.hx',
					source: 'package p;\n\n${destImport}class Dest {\n\tpublic static function local():$destMember return null;\n}'
				}
			];
		}
		assertErrContains(move('p/Src.hx', 'Src', 'make', 'Dest', scope('import r.Dep;\n\n', 'Dep')), 'already binds "Dep" to r.Dep');
		// The control's destination neither binds NOR names `Dep`. It used to name it with nothing in
		// the scope binding it — source Haxe rejects outright (`Type not found : Dep`, 4.3.7) — and the
		// ambient-shadowing arm now refuses that correctly.
		final changes: Array<MoveChange> = okChanges('p/Src.hx', 'Src', 'make', 'Dest', scope('', 'Null<Int>'));
		Assert.isTrue(changeFor(changes, 'p/Dest.hx').newSource.contains('import q.Dep;'), 'the uncontested carry still happens');
	}

	private function move(
		srcFile: String, srcType: String, members: String, destType: String, scopeFiles: Array<{ file: String, source: String }>,
		?via: String, ?closure: Bool, ?scaffold: Bool
	): MoveResult {
		return MoveMember.move(
			srcFile, srcType, members.split(','), destType, via, closure == true, scaffold == true, scopeFiles, plugin(), typeRefShape()
		);
	}

	private function okChanges(
		srcFile: String, srcType: String, members: String, destType: String, scopeFiles: Array<{ file: String, source: String }>,
		?via: String, ?closure: Bool, ?scaffold: Bool
	): Array<MoveChange> {
		final result: MoveResult = move(srcFile, srcType, members, destType, scopeFiles, via, closure, scaffold);
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

	private function assertErrContains(result: MoveResult, needle: String): Void {
		switch result {
			case Ok(changes, _):
				Assert.fail('expected Err, got Ok with ${changes.length} change(s)');
			case Err(message):
				Assert.isTrue(StringTools.contains(message, needle), 'Err "$message" should mention "$needle"');
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

}
