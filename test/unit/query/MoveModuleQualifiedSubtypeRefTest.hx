package unit.query;

import anyparse.query.MoveSymbol;

using Lambda;
using StringTools;

/**
 * A module-qualified reference `D.Sub` to a secondary type moved out of module `D` must be repointed
 * to the destination or the move refused naming it; a silent write leaves the tree uncompilable.
 */
class MoveModuleQualifiedSubtypeRefTest extends Test {

	private static final SOURCE_D: String = 'package p;\n\nclass D {\n\tpublic static function f():Int return 1;\n}\n\nclass Sub {\n'
		+ '\tpublic static function h():Int\n\t\treturn 2;\n}\n';

	@:pin('control')
	@:killer('M-MOVE-MODULE-QUALIFIED-DENOTES-NONE')
	public function testModuleQualifiedSubtypeRefNotLeftDangling(): Void {
		final result: MoveResult = MoveSymbol.moveType('p/D.hx', 7, 7, 'q/E.hx', [
			{
				file: 'p/D.hx',
				source: 'package p;\n\nclass D {\n\tpublic static function f():Int return 1;\n}\n\nclass Sub {\n'
				+ '\tpublic static function h():Int\n\t\treturn 2;\n}\n'
			},
			{ file: 'q/E.hx', source: 'package q;\n\nclass E {}\n' },
			{ file: 'p/C.hx', source: 'package p;\n\nclass C {\n\tpublic static function g():Int return D.Sub.h();\n}\n' }
		], new HaxeQueryPlugin(), new HaxeQueryPlugin().typeRefShape());
		switch result {
			case Ok(changes, _):
				final c: Null<MoveChange> = changes.find(ch -> ch.file == 'p/C.hx');
				Assert.notNull(c, 'C.hx spelling D.Sub must be rewritten, got no change for it');
				if (c != null) Assert.isFalse(c.newSource.contains('D.Sub'), c.newSource);
			case Err(message):
				Assert.isTrue(message.contains('D.Sub'), 'Err "$message" should name D.Sub');
		}
	}

	/** A file whose `D` is ANOTHER package's module spells `D.Sub` about a different type: the move proceeds. */
	@:pin('control')
	@:killer('M-MOVE-MODULE-QUALIFIED-DENOTES-ALL')
	public function testOtherModuleOfTheSameNameDoesNotRefuse(): Void {
		final result: MoveResult = MoveSymbol.moveType('p/D.hx', 7, 7, 'q/E.hx', [
			{
				file: 'p/D.hx',
				source: 'package p;\n\nclass D {\n\tpublic static function f():Int return 1;\n}\n\nclass Sub {\n'
				+ '\tpublic static function h():Int\n\t\treturn 2;\n}\n'
			},
			{ file: 'q/E.hx', source: 'package q;\n\nclass E {}\n' },
			{ file: 'r/D.hx', source: 'package r;\n\nclass D {\n\tpublic static final Sub: Dynamic = null;\n}\n' },
			{ file: 'r/C.hx', source: 'package r;\n\nclass C {\n\tpublic static function g():Int return D.Sub.h();\n}\n' }
		], new HaxeQueryPlugin(), new HaxeQueryPlugin().typeRefShape());
		switch result {
			case Ok(_, _):
				Assert.pass();
			case Err(message):
				Assert.fail('unexpected refusal: $message');
		}
	}

	/** A sub-package resolves `D` through its parent package `p`. */
	@:pin('control')
	@:killer('M-MOVE-MODULE-QUALIFIED-DENOTES-NONE')
	public function testParentPackageSpellingRefuses(): Void {
		assertRefusesNaming(moveSub([
			{ file: 'p/x/C.hx', source: 'package p.x;\n\nclass C {\n\tpublic static function g():Int return D.Sub.h();\n}\n' }
		]), 'D.Sub');
	}

	/** An alias of the module is a binding of it: `DD.Sub` is named in the refusal. */
	@:pin('control')
	@:killer('M-MOVE-MODULE-QUALIFIED-DENOTES-NONE')
	public function testAliasSpellingRefuses(): Void {
		assertRefusesNaming(moveSub([
			{
				file: 'r/C.hx',
				source: 'package r;\n\nimport p.D as DD;\n\nclass C {\n\tpublic static function g():Int return DD.Sub.h();\n}\n'
			}
		]), 'DD.Sub');
	}

	/** A MAIN type is never spelled `Module.Main`, so an unrelated `b.D` beside its package does not refuse its move. */
	@:pin('guard')
	public function testNestedMainTypeMoveIgnoresPackageSegmentSpelling(): Void {
		assertMoves(MoveSymbol.moveType('a/b/D.hx', 3, 7, 'q/E.hx', [
			{ file: 'a/b/D.hx', source: 'package a.b;\n\nclass D {}\n' },
			{ file: 'q/E.hx', source: 'package q;\n\nclass E {}\n' },
			{
				file: 'a/X.hx',
				source: 'package a;\n\nclass X {\n\tstatic var b = {D: 1};\n\n\tpublic static function g():Int return b.D;\n}\n'
			}
		], new HaxeQueryPlugin(), new HaxeQueryPlugin().typeRefShape()));
	}

	/** An import of another module named `D` shadows the same-package `p.D`, so its `D.Sub` is not the moved type. */
	@:pin('control')
	@:killer('M-MOVE-MODULE-QUALIFIED-DENOTES-ALL')
	public function testShadowingImportDoesNotRefuse(): Void {
		assertMoves(moveSub([
			{ file: 'r/D.hx', source: 'package r;\n\nclass D {\n\tpublic static final Sub: Dynamic = null;\n}\n' },
			{ file: 'p/C.hx', source: 'package p;\n\nimport r.D;\n\nclass C {\n\tpublic static function g():Dynamic return D.Sub;\n}\n' }
		]));
	}

	private function moveSub(extra: Array<{ file: String, source: String }>): MoveResult {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'p/D.hx', source: SOURCE_D },
			{ file: 'q/E.hx', source: 'package q;\n\nclass E {}\n' }
		];
		return MoveSymbol.moveType(
			'p/D.hx', 7, 7, 'q/E.hx', files.concat(extra), new HaxeQueryPlugin(), new HaxeQueryPlugin().typeRefShape()
		);
	}

	private function assertRefusesNaming(result: MoveResult, spelling: String): Void {
		switch result {
			case Ok(_, _):
				Assert.fail('expected a refusal naming $spelling');
			case Err(message):
				Assert.isTrue(message.contains('"$spelling"'), message);
		}
	}

	private function assertMoves(result: MoveResult): Void {
		switch result {
			case Ok(_, _):
				Assert.pass();
			case Err(message):
				Assert.fail('unexpected refusal: $message');
		}
	}

}
