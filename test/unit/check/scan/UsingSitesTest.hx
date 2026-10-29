package unit.check.scan;

import anyparse.check.Severity;
import anyparse.check.common.imports.UnusedImport;
import anyparse.check.scan.UsingSites;
import anyparse.query.SymbolIndex;

using Lambda;

/**
 * Whether a `using` takes part in an access `recv.name` — the one answer `unused-import`, `redundant-import`,
 * `hoist-common-import` and the move carry share (`UsingSites`), asked of the typing service per access. Each case that
 * reports a statement unused was compiled on Haxe 4.3.7 with the statement and without it, with the same output: a
 * rival `using` binding the access first, a candidate whose first parameter rejects the receiver, a static of the type
 * a type expression names.
 */
@:nullSafety(Strict)
class UsingSitesTest extends Test {

	/** The receiver types, a type with a static `zqqap`, and four modules each bringing one extension `zqqap`. */
	private static final TYPES: Array<{ file: String, source: String }> = [
		{ file: 'p/Zqqw.hx', source: 'package p;\n\nclass Zqqw {\n\tpublic function new() {}\n}\n' },
		{ file: 'p/Wqqw.hx', source: 'package p;\n\nclass Wqqw {\n\tpublic function new() {}\n}\n' },
		{ file: 'p/Kqqw.hx', source: 'package p;\n\nclass Kqqw {\n\tpublic static function zqqap(i:Int):Int return i;\n}\n' },
		{ file: 'p/ZapZqqw.hx', source: 'package p;\n\nclass ZapZqqw {\n\tpublic static function zqqap(z:Zqqw):Int return 1;\n}\n' },
		{ file: 'p/ZapWqqw.hx', source: 'package p;\n\nclass ZapWqqw {\n\tpublic static function zqqap(w:Wqqw):Int return 2;\n}\n' },
		{ file: 'p/ZapWqqwTwo.hx', source: 'package p;\n\nclass ZapWqqwTwo {\n\tpublic static function zqqap(w:Wqqw):Int return 3;\n}\n' },
		{ file: 'p/ZapAnyqqw.hx', source: 'package p;\n\nclass ZapAnyqqw {\n\tpublic static function zqqap(d:Dynamic):Int return 4;\n}\n' }
	];

	/**
	 * Where the access binds through no file `using` the typing service can name — the one that would is `#if`-guarded —
	 * a module whose every candidate rejects the receiver still takes no part in it.
	 */
	@:pin('control') @:killer('M-USING-OFFER-OPEN')
	public function testAModuleWhoseCandidatesRejectTheReceiverIsUnused(): Void {
		Assert.equals('p.ZapZqqw', unusedIn('using p.ZapZqqw;\n#if !zqqoff\nusing p.ZapWqqw;\n#end\n', 'f(w:Wqqw):Int return w.zqqap();'));
	}

	/** Two modules both accepting the receiver: the LAST `using` binds, and the one it outranks takes no part. */
	@:pin('control') @:killer('M-USING-BOUND-ELSEWHERE')
	public function testAModuleARivalOutranksIsUnused(): Void {
		Assert.equals('p.ZapWqqw', unusedIn('using p.ZapWqqw;\nusing p.ZapWqqwTwo;\n', 'f(w:Wqqw):Int return w.zqqap();'));
	}

	/** `Type.name` on a type expression binds the type's own static before any extension — even one taking `Dynamic`. */
	@:pin('control') @:killer('M-USING-STATIC-RECEIVER')
	public function testAStaticOfATypeExpressionIsNoUse(): Void {
		Assert.equals('p.ZapAnyqqw', unusedIn('using p.ZapAnyqqw;\n', 'f():Int return Kqqw.zqqap(1);'));
	}

	/**
	 * A field the enclosing type inherits, spelled like a type, is what the identifier names there, not the type:
	 * `Kqqw.zqqap()` reads the field's value and binds the extension (without the statement 4.3.7 reads `p.Wqqw has no field
	 * zqqap`).
	 */
	@:pin('control') @:killer('M-USING-STATIC-SHADOW')
	public function testAFieldSpelledLikeATypeIsNoTypeExpression(): Void {
		final scope: Array<{ file: String, source: String }> = TYPES.concat([
			{
				file: 'p/BaseQqw.hx',
				source: 'package p;\n\nclass BaseQqw {\n\tpublic var Kqqw:Wqqw = new Wqqw();\n\n\tpublic function new() {}\n}\n'
			},
			{
				file: 'p/Src.hx',
				source: 'package p;\n\nusing p.ZapWqqw;\n\nclass Src extends BaseQqw {\n\tpublic function f():Int return Kqqw.zqqap();\n}\n'
			}
		]);
		Assert.isFalse(CheckFixture.violationsIn(new UnusedImport(), scope).exists(v -> v.file == 'p/Src.hx'));
	}

	/**
	 * A `@:forward` abstract hands an access it does not declare to its underlying type, where that type's extensions bind:
	 * without the statement 4.3.7 reads `p.Fwdqqw has no field zqqap`. Neither the abstract nor a `typedef` of it decides the
	 * candidate, so the access stays a use.
	 */
	@:pin('control') @:killer('M-USING-FORWARD-DECIDED')
	public function testAForwardAbstractReceiverKeepsTheModule(): Void {
		final forward: Array<{ file: String, source: String }> = [
			{ file: 'p/Fwdqqw.hx', source: 'package p;\n\n@:forward abstract Fwdqqw(Wqqw) from Wqqw {}\n' },
			{ file: 'p/FwdAliasqqw.hx', source: 'package p;\n\ntypedef FwdAliasqqw = Fwdqqw;\n' }
		];
		Assert.equals('', unusedIn('using p.ZapWqqw;\n', 'f(x:Fwdqqw):Int return x.zqqap();', forward));
		Assert.equals('', unusedIn('using p.ZapWqqw;\n', 'f(x:FwdAliasqqw):Int return x.zqqap();', forward), 'through a typedef');
	}

	/**
	 * An identifier names a VALUE before a type: a module-level field, a static field imported by name or by a type's
	 * wildcard, an imported enum's constructor. `Kqqw.zqqap()` then reads that value and binds the extension — each form,
	 * without the statement, fails to compile on 4.3.7.
	 */
	@:pin('control') @:killer('M-USING-STATIC-SHADOW')
	public function testAValueSpelledLikeATypeIsNoTypeExpression(): Void {
		final values: Array<{ file: String, source: String }> = [
			{ file: 'p/Holdqqw.hx', source: 'package p;\n\nclass Holdqqw {\n\tpublic static var Kqqw:Wqqw = new Wqqw();\n}\n' },
			{ file: 'p/Shapeqqw.hx', source: 'package p;\n\nenum Shapeqqw {\n\tKqqw;\n}\n' },
			{
				file: 'p/ZapShapeqqw.hx',
				source: 'package p;\n\nclass ZapShapeqqw {\n\tpublic static function zqqap(s:Shapeqqw):Int return 7;\n}\n'
			}
		];
		final call: String = 'class Src {\n\tpublic static function f():Int return Kqqw.zqqap();\n}\n';
		Assert.equals(
			'', unusedInSource('package p;\n\nusing p.ZapWqqw;\n\nfinal Kqqw:Wqqw = new Wqqw();\n\n$call', values), 'module-level field'
		);
		Assert.equals('', unusedInSource('package p;\n\nimport p.Holdqqw.Kqqw;\n\nusing p.ZapWqqw;\n\n$call', values), 'field import');
		Assert.equals('', unusedInSource('package p;\n\nimport p.Holdqqw.*;\n\nusing p.ZapWqqw;\n\n$call', values), 'type wildcard');
		Assert.equals('', unusedInSource('package p;\n\nimport p.Shapeqqw;\n\nusing p.ZapShapeqqw;\n\n$call', values), 'enum constructor');
	}

	/** The access the statement does bind keeps it, and a receiver the run cannot type keeps it too. */
	@:pin('guard')
	public function testAnAccessTheModuleBindsOrCannotBeTypedKeepsIt(): Void {
		Assert.equals('', unusedIn('using p.ZapWqqw;\n', 'f(w:Wqqw):Int return w.zqqap();'));
		Assert.equals('', unusedIn('using p.ZapZqqw;\n', 'f(w:Unknownqqw):Int return w.zqqap();'));
		Assert.equals('', unusedIn('using p.ZapAnyqqw;\n', 'f(w:Wqqw):Int return w.zqqap();'), 'a first parameter taking anything');
	}

	/**
	 * A first parameter with a type argument is not decided by the service (on 4.3.7 `Boxqqw<String>` passes a `Boxqqw<Int>`
	 * over): the module that binds keeps its statement, and so — conservatively — does the one the compiler passes over.
	 */
	@:pin('guard')
	public function testATypeArgumentOnTheFirstParameterKeepsEveryModule(): Void {
		final generic: Array<{ file: String, source: String }> = [
			{ file: 'p/Boxqqw.hx', source: 'package p;\n\nclass Boxqqw<T> {\n\tpublic function new() {}\n}\n' },
			{
				file: 'p/ZapBoxS.hx',
				source: 'package p;\n\nclass ZapBoxS {\n\tpublic static function zqqap(b:Boxqqw<String>):Int return 5;\n}\n'
			},
			{
				file: 'p/ZapBoxI.hx',
				source: 'package p;\n\nclass ZapBoxI {\n\tpublic static function zqqap(b:Boxqqw<Int>):Int return 6;\n}\n'
			}
		];
		Assert.equals('', unusedIn('using p.ZapBoxI;\nusing p.ZapBoxS;\n', 'f(b:Boxqqw<Int>):Int return b.zqqap();', generic));
	}

	/**
	 * Two `using` statements contest an access only where both may offer it: a rival whose candidate rejects the receiver
	 * leaves the access where it was, one accepting it — or a receiver the run cannot type — contests it.
	 */
	@:pin('control') @:killer('M-USING-OFFER-OPEN') @:killer('M-USING-CONTEST-ANY')
	public function testARivalContestsOnlyAnAccessBothMayOffer(): Void {
		Assert.isFalse(contested('f(w:Wqqw):Int return w.zqqap();', 'p.ZapWqqw', 'p.ZapZqqw'));
		Assert.isTrue(contested('f(w:Wqqw):Int return w.zqqap();', 'p.ZapWqqw', 'p.ZapWqqwTwo'));
		Assert.isTrue(contested('f(w:Unknownqqw):Int return w.zqqap();', 'p.ZapWqqw', 'p.ZapZqqw'));
		Assert.isFalse(contested('f(w:Wqqw):Int return 0;', 'p.ZapWqqw', 'p.ZapWqqwTwo'), 'no access of the name');
	}

	/** The `unused using` paths `unused-import` reports on `p/Src.hx` holding `usings` and the static function `member`. */
	private static function unusedIn(usings: String, member: String, ?extra: Array<{ file: String, source: String }>): String {
		return unusedInSource(srcOf(usings, member), extra ?? []);
	}

	/** The `unused using` paths `unused-import` reports on `p/Src.hx` written as `source`, beside `TYPES` and `extra`. */
	private static function unusedInSource(source: String, extra: Array<{ file: String, source: String }>): String {
		final scope: Array<{ file: String, source: String }> = TYPES.concat(extra).concat([{ file: 'p/Src.hx', source: source }]);
		return [
			for (v in CheckFixture.violationsIn(new UnusedImport(), scope))
				if (v.file == 'p/Src.hx' && v.severity == Severity.Warning && v.message.indexOf('unused using') == 0)
					v.message.split('\'')[1]
		].join(',');
	}

	/** Whether `using <path>` and `using <other>` contest an access of `p/Src.hx` holding both and the static `member`. */
	private static function contested(member: String, path: String, other: String): Bool {
		final source: String = srcOf('using $path;\nusing $other;\n', member);
		final scope: Array<{ file: String, source: String }> = TYPES.concat([{ file: 'p/Src.hx', source: source }]);
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final index: SymbolIndex = CheckFixture.index(scope, plugin);
		final members: Map<String, Array<String>> = UsingSites.membersByModule(index);
		return new UsingSites(source, plugin, 'p/Src.hx', index).contested(path, other, raw -> members[raw]);
	}

	/** `p/Src.hx`: `usings`, then a class holding the static function `member`. */
	private static function srcOf(usings: String, member: String): String {
		return 'package p;\n\n${usings}\nclass Src {\n\tpublic static function $member\n}\n';
	}

}
