package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.MoveMember;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.MoveSymbol.MoveResult;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * `MoveMember.move` on the shapes splitting a god type meets: a moved body naming a sub-module type of its own module,
 * a group of moved members sharing one private-access need, bare static callers kept bare through a module-static
 * wildcard, the fields a moved group alone owns, and receiver-qualified instance callers routed through the field that
 * holds the destination. Pure and in-memory, like `MoveMemberSliceTest`; every result shape is compile-proved on Haxe
 * 4.3.7 in its own test's doc.
 */
class MoveMemberSplitSliceTest extends Test {

	/**
	 * A moved body that names a SUB-module type of the source module (`typedef Pair` beside `class A`) reaches it with no
	 * statement: inside its own module it is visible bare, from any other file — a sibling of the same package included —
	 * it is `Type not found`. The move refused with "no import to carry"; the destination now gains `import pkg.A.Pair;`.
	 * Compile-proved on 4.3.7: the moved `sum` returns 3 from `pkg.B` as it did from `pkg.A`.
	 */
	@:pin('control')
	@:killer('M-CARRY-OWN-SUB-UNCARRIED')
	public function testASourceSubModuleTypeIsImportedAtTheDestination(): Void {
		final a: String = 'package pkg;\n\ntypedef Pair = {\n\tvar a:Int;\n\tvar b:Int;\n}\n\nclass A {\n'
			+ '\tpublic static function sum(p:Pair):Int return p.a + p.b;\n}';
		final newB: String = okSource(move('pkg/A.hx', 'A', 'sum', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {}' }
		]), 'pkg/B.hx');
		Assert.isTrue(newB.contains('import pkg.A.Pair;'), newB);
		Assert.isTrue(newB.contains('public static function sum(p:Pair):Int'), newB);
	}

	/**
	 * Two moved members reaching a private static of the source share ONE grant: `@:access(pkg.A)` on the destination type,
	 * below its doc, instead of the same line above each member. Compile-proved on 4.3.7 (`one` + `two` = 80 from `pkg.B`).
	 */
	@:pin('control')
	@:killer('M-ACCESS-GRANT-PER-MEMBER')
	public function testTwoMembersNeedingPrivateAccessShareOneTypeGrant(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tstatic function scale(x:Int):Int return x * 10;\n\n'
			+ '\tpublic static function one(x:Int):Int return scale(x);\n\n\tpublic static function two(x:Int):Int return scale(x) + one(x);\n}';
		final newB: String = okSource(move('pkg/A.hx', 'A', 'one,two', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\n/** The destination. */\nclass B {}' }
		]), 'pkg/B.hx');
		Assert.isTrue(newB.contains('/** The destination. */\n@:access(pkg.A)\nclass B {'), newB);
		Assert.equals(1, newB.split('@:access').length - 1, newB);
	}

	/**
	 * `--keep-bare`: a source that called the moved statics bare keeps calling them bare, through one
	 * `import pkg.B.*;`, instead of every caller turning into `B.util(…)`. Without the flag the callers are qualified as
	 * before. Compile-proved on 4.3.7: `run()` returns 8 before and after.
	 */
	@:pin('control')
	@:killer('M-KEEP-BARE-IGNORED')
	public function testKeepBareImportsTheDestinationStaticsInsteadOfQualifying(): Void {
		final scope: Array<{ file: String, source: String }> = [
			{
				file: 'pkg/A.hx',
				source: 'package pkg;\n\nclass A {\n\tpublic static function run():Int return util(3) + util(1);\n\n'
					+ '\tpublic static function util(x:Int):Int return x * 2;\n}'
			},
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {}' }
		];
		final kept: String = okSource(move('pkg/A.hx', 'A', 'util', 'B', scope, null, true), 'pkg/A.hx');
		Assert.isTrue(kept.contains('import pkg.B.*;'), kept);
		Assert.isTrue(kept.contains('return util(3) + util(1);'), kept);
		final qualified: String = okSource(move('pkg/A.hx', 'A', 'util', 'B', scope), 'pkg/A.hx');
		Assert.isTrue(qualified.contains('return B.util(3) + B.util(1);'), qualified);
	}

	/**
	 * The wildcard brings in EVERY static of the destination and binds a name only where the file's own resolution fails,
	 * so `--keep-bare` refuses whatever it cannot prove: an identifier of the source spelling another destination static
	 * (a local `hello` would survive, but a read of anything else so named might not), and a destination that is not the
	 * main class of its module (`import pkg.Mod.*;` brings in `Mod`'s statics, not `B`'s).
	 */
	@:pin('control')
	@:killer('M-KEEP-BARE-CLASH-BLIND') @:killer('M-KEEP-BARE-NOT-MAIN')
	public function testKeepBareRefusesWhatTheWildcardCouldRebind(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function run():Int {\n\t\tfinal hello:Int = 1;\n'
			+ '\t\treturn util(hello);\n\t}\n\n\tpublic static function util(x:Int):Int return x * 2;\n}';
		final clash: String = errMessage(move('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {\n\tpublic static function hello():Int return 0;\n}' }
		], null, true));
		Assert.isTrue(clash.contains('spells "hello"'), clash);
		final sub: String = errMessage(move('pkg/A.hx', 'A', 'util', 'B', [
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/Mod.hx', source: 'package pkg;\n\nclass Mod {}\n\nclass B {}' }
		], null, true));
		Assert.isTrue(sub.contains('is not the main class of its module'), sub);
	}

	/**
	 * A moved group takes along the fields it alone owns: `count` (a `var`) and `seen` (a `final` with an initializer) are
	 * read and written by `bump` and `total` only, so they move with them instead of refusing the move as "shared mutable
	 * state". Compile-proved on 4.3.7: `run()` prints 4 before and after.
	 */
	@:pin('control')
	@:killer('M-OWNED-FIELDS-OFF')
	public function testFieldsOnlyTheMovedGroupUsesMoveAlong(): Void {
		final result: MoveResult = move('p/Big.hx', 'Big', 'bump,total', 'Lib', bigScope(''));
		final big: String = okSource(result, 'p/Big.hx');
		final lib: String = okSource(result, 'p/Lib.hx');
		Assert.isFalse(big.contains('count') || big.contains('seen'), big);
		Assert.isTrue(lib.contains('private var count:Int = 0;') && lib.contains('private final seen:Array<Int> = [];'), lib);
		Assert.isTrue(big.contains('lib.bump();'), big);
		switch result {
			case Ok(_, advisory):
				Assert.isTrue(advisory != null && advisory.contains('moved along field(s) "count", "seen"'), advisory);
			case Err(_):
		}
	}

	/**
	 * A field something else reaches stays, and the move still refuses: a staying member reading it (named in the
	 * refusal, so the next step is obvious), a field access of its name outside the group (`b.count` in another file), and a
	 * property,
	 * whose accessors would stay behind.
	 */
	@:pin('control')
	@:killer('M-OWNED-FIELD-ANY-READER') @:killer('M-OWNED-FIELD-ACCESS-BLIND') @:killer('M-OWNED-FIELD-PROPERTY')
	@:killer('M-OWNED-READERS-UNNAMED')
	public function testAFieldSomethingElseReachesStaysAndRefuses(): Void {
		final read: String = errMessage(
			move('p/Big.hx', 'Big', 'bump,total', 'Lib', bigScope('\n\tpublic function peek():Int return count;\n'))
		);
		Assert.isTrue(read.contains('mutable instance field(s) "count"') && read.contains('staying member(s) "peek"'), read);
		final access: String = errMessage(move(
			'p/Big.hx', 'Big', 'bump,total', 'Lib',
			bigScope('')
				.concat([
					{ file: 'p/User.hx', source: 'package p;\n\nclass User {\n\tpublic static function peek(b:Big):Int return b.count;\n}' }
				])
		));
		Assert.isTrue(access.contains('mutable instance field(s) "count"'), access);
		final property: String = errMessage(move('p/Big.hx', 'Big', 'bump,total', 'Lib', [
			{
				file: 'p/Big.hx',
				source: 'package p;\n\nclass Big {\n\tpublic final lib:Lib;\n\tprivate var count(default, null):Int = 0;\n\n'
				+ '\tpublic function new() {\n\t\tlib = new Lib();\n\t}\n\n\tpublic function bump():Int {\n\t\tcount++;\n'
				+ '\t\treturn total();\n\t}\n\n\tprivate function total():Int return count;\n\n'
				+ '\tpublic function run():Int return bump();\n}'
			},
			{ file: 'p/Lib.hx', source: 'package p;\n\nclass Lib {\n\tpublic function new() {}\n}' }
		]));
		Assert.isTrue(property.contains('mutable instance field(s) "count"'), property);
	}

	/**
	 * A member moved into the object a field of the source holds (`library: Lib`) is reached through that field by every
	 * caller, not only the bare ones in the source: `_g.isPure(2)` in another class becomes `_g.library.isPure(2)`, a
	 * construction's `new G().isPure(3)` and `this.isPure(4)` likewise, and `s.length` on a `String` is someone else's
	 * member and is left alone. They were left as they were ("they fail the next compile loudly": `p.G has no field
	 * isPure`). Compile-proved on 4.3.7: both traces print `true` before and after.
	 */
	@:pin('control')
	@:killer('M-RECEIVER-ROUTING-OFF')
	public function testReceiverQualifiedCallersRouteThroughTheHoldingField(): Void {
		final result: MoveResult = move('p/G.hx', 'G', 'isPure', 'Lib', holderScope('public', ''));
		final g: String = okSource(result, 'p/G.hx');
		final user: String = okSource(result, 'p/User.hx');
		Assert.isTrue(g.contains('return library.isPure(1) && this.library.isPure(4);'), g);
		Assert.isTrue(user.contains('return _g.library.isPure(2) && new G().library.isPure(3) && s.length == 3;'), user);
	}

	/**
	 * A receiver the op cannot prove refuses the move rather than being guessed at: a `Dynamic` one, or one of no known type,
	 * may hold a `G`; a field
	 * the holding object is reached through must be public to serve a caller in another class; and a receiver of an
	 * unrelated type declaring a member of the same name is left alone, so that move goes through.
	 */
	@:pin('control')
	@:killer('M-RECEIVER-UNKNOWN-ROUTED') @:killer('M-RECEIVER-UNRELATED-ROUTED') @:killer('M-VIA-PRIVATE-REACHED')
	public function testAReceiverTheOpCannotProveRefusesTheMove(): Void {
		final catchAll: String = errMessage(move(
			'p/G.hx', 'G', 'isPure', 'Lib', holderScope('public', '\n\tpublic static function any(d:Dynamic):Bool return d.isPure(5);\n')
		));
		Assert.isTrue(catchAll.contains('cannot route `d.isPure`'), catchAll);
		final unknown: String = errMessage(move(
			'p/G.hx', 'G', 'isPure', 'Lib',
			holderScope(
				'public', '\n\tpublic static function any():Bool {\n' + '\t\tfinal g = Elsewhere.make();\n\t\treturn g.isPure(5);\n\t}\n'
			)
		));
		Assert.isTrue(unknown.contains('its receiver\'s type is not known'), unknown);
		final hidden: String = errMessage(move('p/G.hx', 'G', 'isPure', 'Lib', holderScope('private', '')));
		Assert.isTrue(hidden.contains('"library" is not public'), hidden);
		final other: String = okSource(
			move(
				'p/G.hx', 'G', 'isPure', 'Lib', holderScope('public', '').concat([
					{ file: 'p/Other.hx', source: 'package p;\n\nclass Other {\n\tpublic function isPure(x:Int):Bool return false;\n}' },
					{
						file: 'p/Use.hx',
						source: 'package p;\n\nclass Use {\n\tpublic static function f(o:Other):Bool return o.isPure(1);\n}'
					}
				])
			),
			'p/G.hx'
		);
		Assert.isFalse(other.contains('function isPure'), other);
	}

	/** The `G` / `Lib` / `User` scope of the receiver-routing tests: `G.library` with visibility `via`, `extra` members on `User`. */
	private static function holderScope(via: String, extra: String): Array<{ file: String, source: String }> {
		return [
			{
				file: 'p/G.hx',
				source: 'package p;\n\nclass G {\n\t$via final library:Lib;\n\n\tpublic function new() {\n\t\tlibrary = new Lib();\n\t}\n\n'
					+ '\tpublic function isPure(x:Int):Bool return x > 0;\n\n'
					+ '\tpublic function run():Bool return isPure(1) && this.isPure(4);\n}'
			},
			{ file: 'p/Lib.hx', source: 'package p;\n\nclass Lib {\n\tpublic function new() {}\n}' },
			{
				file: 'p/User.hx',
				source: 'package p;\n\nclass User {\n\tfinal _g:G;\n\n\tpublic function new(g:G) {\n\t\t_g = g;\n\t}\n\n'
					+ '\tpublic function check():Bool {\n\t\tfinal s:String = "abc";\n'
					+ '\t\treturn _g.isPure(2) && new G().isPure(3) && s.length == 3;\n\t}\n$extra}'
			}
		];
	}

	/** The `Big` / `Lib` scope of the owned-field tests, with `extra` members added to `Big`. */
	private static function bigScope(extra: String): Array<{ file: String, source: String }> {
		return [
			{
				file: 'p/Big.hx',
				source: 'package p;\n\nclass Big {\n\tpublic final lib:Lib;\n\tprivate var count:Int = 0;\n'
					+ '\tprivate final seen:Array<Int> = [];\n\n\tpublic function new() {\n\t\tlib = new Lib();\n\t}\n\n'
					+ '\tpublic function bump():Int {\n\t\tcount++;\n\t\tseen.push(count);\n\t\treturn total();\n\t}\n\n'
					+ '\tprivate function total():Int return count + seen.length;\n\n'
					+ '\tpublic function run():Int {\n\t\tbump();\n\t\treturn bump();\n\t}\n$extra}'
			},
			{ file: 'p/Lib.hx', source: 'package p;\n\nclass Lib {\n\tpublic function new() {}\n}' }
		];
	}

	private static function errMessage(result: MoveResult): String {
		return switch result {
			case Ok(changes, _):
				Assert.fail('expected Err, got Ok with ${changes.length} change(s)');
				'';
			case Err(message): message;
		};
	}

	private static function move(
		srcFile: String, srcType: String, members: String, destType: String, scopeFiles: Array<{ file: String, source: String }>,
		?via: String, ?keepBare: Bool
	): MoveResult {
		return MoveMember.move(
			srcFile, srcType, members.split(','), destType, via, false, false, scopeFiles, new HaxeQueryPlugin(),
			new HaxeQueryPlugin().typeRefShape(), keepBare == true
		);
	}

	/** The new source of `file` in an `Ok` result — every rewritten file re-parsed first — or a failed assertion. */
	private static function okSource(result: MoveResult, file: String): String {
		switch result {
			case Ok(changes, _):
				for (c in changes) {
					var parsed: Bool = true;
					try
						new HaxeQueryPlugin().parseFile(c.newSource)
					catch (_: haxe.Exception)
						parsed = false;
					Assert.isTrue(parsed, 'rewritten ${c.file} should re-parse');
				}
				final change: Null<MoveChange> = changes.find(c -> c.file == file);
				if (change != null) return change.newSource;
				Assert.fail('no change for file $file');
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
		return '';
	}

	/**
	 * A receiver whose type is not PROVEN a class or interface unrelated to the source refuses the move. A forwarding
	 * `enum abstract` over the source (`@:forward enum abstract A(G)`) reaches `G.isPure` through `a.isPure`, and a value
	 * of a structure declaring `isPure` may be a `G` (structural unification): both were read as unrelated and left alone,
	 * and the move then failed to compile on 4.3.7 (`p.A has no field isPure`; `p.G should be p.S`).
	 */
	@:pin('control')
	@:killer('M-RECEIVER-STRUCTURE-LEFT')
	public function testAReceiverNotProvenAnUnrelatedClassRefusesTheMove(): Void {
		final forward: String = errMessage(move(
			'p/G.hx', 'G', 'isPure', 'Lib', holderScope('public', '').concat([
				{ file: 'p/A.hx', source: 'package p;\n\n@:forward\nenum abstract A(G) {\n\tpublic inline function new(g:G) this = g;\n}' },
				{ file: 'p/Use.hx', source: 'package p;\n\nclass Use {\n\tpublic static function f(a:A):Bool return a.isPure(1);\n}' }
			])
		));
		Assert.isTrue(forward.contains('cannot route `a.isPure`'), forward);
		final structure: String = errMessage(move(
			'p/G.hx', 'G', 'isPure', 'Lib', holderScope('public', '').concat([
				{ file: 'p/S.hx', source: 'package p;\n\ntypedef S = {\n\tfunction isPure(x:Int):Bool;\n}' },
				{ file: 'p/Use.hx', source: 'package p;\n\nclass Use {\n\tpublic static function f(s:S):Bool return s.isPure(1);\n}' }
			])
		));
		Assert.isTrue(structure.contains('cannot route `s.isPure`'), structure);
	}

	/**
	 * A member the source's inheritance family declares stays where it is: moving an `override` leaves an override of
	 * nothing in the destination (its base outside the scope, so only the modifier tells), moving an interface method's
	 * implementation leaves the source short of it, and so may moving one of an interface the scope does not hold; moving
	 * a method a subclass overrides leaves that override overriding nothing. Each wrote a tree 4.3.7 rejects (`Field
	 * isPure is declared 'override' but doesn't override any field`; `Field isPure needed by p.I is missing`).
	 */
	@:pin('control')
	@:killer('M-MOVE-OVERRIDE-MEMBER') @:killer('M-MOVE-IMPLEMENTATION') @:killer('M-MOVE-OVERRIDDEN-MEMBER')
	@:killer('M-MOVE-UNRESOLVED-INTERFACE')
	public function testAMemberOfAnInheritanceFamilyRefusesTheMove(): Void {
		final lib: { file: String, source: String } = {
			file: 'p/Lib.hx',
			source: 'package p;\n\nclass Lib {\n\tpublic function new() {}\n}'
		};
		final g: (String, String) -> { file: String, source: String } = (head, modifier) -> {
			file: 'p/G.hx',
			source: 'package p;\n\nclass G$head {\n\tpublic final library:Lib;\n\n\tpublic function new() {\n\t\tlibrary = new Lib();\n\t}\n\n'
				+ '\t${modifier}public function isPure(x:Int):Bool return x > 0;\n}'
		};
		final overriding: String = errMessage(move('p/G.hx', 'G', 'isPure', 'Lib', [g(' extends q.Base', 'override '), lib]));
		Assert.isTrue(overriding.contains('"isPure"') && overriding.contains('overrides'), overriding);
		final implementing: String = errMessage(move('p/G.hx', 'G', 'isPure', 'Lib', [
			g(' implements I', ''),
			lib,
			{ file: 'p/I.hx', source: 'package p;\n\ninterface I {\n\tfunction isPure(x:Int):Bool;\n}' }
		]));
		Assert.isTrue(implementing.contains('"isPure"') && implementing.contains('"I"'), implementing);
		final unseen: String = errMessage(move('p/G.hx', 'G', 'isPure', 'Lib', [g(' implements q.Unseen', ''), lib]));
		Assert.isTrue(unseen.contains('"isPure"') && unseen.contains('does not resolve'), unseen);
		final overridden: String = errMessage(move('p/G.hx', 'G', 'isPure', 'Lib', [
			g('', ''),
			lib,
			{
				file: 'p/Sub.hx',
				source: 'package p;\n\nclass Sub extends G {\n\toverride public function isPure(x:Int):Bool return false;\n}'
			}
		]));
		Assert.isTrue(overridden.contains('"isPure"') && overridden.contains('overrid'), overridden);
	}

}
