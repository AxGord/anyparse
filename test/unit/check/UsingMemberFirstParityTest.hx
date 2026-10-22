package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Severity;
import anyparse.check.UnusedImport;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.MoveMember;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.StdResolver;
import anyparse.query.StdTypes;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * One question asked twice: does a body need the `using` beside it? `unused-import` deletes the statement when the
 * answer is no, `move-member` leaves it behind, and both read it from `OccurrenceScan.usingExtensionCalled` over the
 * member-first door (`CheckScan.memberBoundAccesses`). Every case here runs BOTH on the same input and asserts they
 * agree, so the two answers cannot drift apart again.
 *
 * Haxe binds a member of the receiver's type before any static extension: verified on 4.3.7, under `using Lambda`
 * `[1].concat(list)` reads `haxe.ds.List<Int> should be Array<Int>` (the `Array` member, not `Lambda.concat`), and under
 * `using E` a `var s:String = d.tag()` on a `D` declaring — or inheriting — `tag():Int` reads `Int should be String`. A
 * STATIC `tag` of `D` does not shadow: the same line prints `ext`, the extension bound. So a body whose every call of
 * the module's methods is such a member call needs no `using`: N42's `move-member` carried `using Lambda;` beside
 * `a.concat(b)` and `unused-import` kept it, both on the text scan alone.
 *
 * RED at base: the three member cases (`std member`, `own member`, `inherited member`) — the lint reports nothing and
 * the move carries the line. Green at base by construction, the fail-closed controls: a static of the name, a receiver
 * the run cannot type, a member under `#if`, and a real extension call keep the statement in both.
 */
@:nullSafety(Strict)
class UsingMemberFirstParityTest extends Test {

	/** `p.Ext`: one static `tag` taking a `D` — what `using p.Ext;` brings. */
	private static final EXT: String = 'package p;\n\nclass Ext {\n\tpublic static function tag(d:D):String return "ext";\n}\n';

	/** The destination of every move: an empty class beside the source. */
	private static final DEST: String = 'package p;\n\nclass Dest {}\n';

	/** `Array.concat` under `using Lambda`, the N42 shape — needs the std, which declares both. */
	@:pin('control') @:killer('M-USING-MEMBER-FIRST-OFF')
	public function testAStdMemberCallNeedsNoUsing(): Void {
		if (StdResolver.stdDir() == null) {
			Assert.pass('no std discovered');
			return;
		}
		agree('Lambda', null, 'f(a:Array<Int>, b:Array<Int>):Array<Int> return a.concat(b);', false);
	}

	/** A member the receiver's own type declares. */
	@:pin('control') @:killer('M-USING-MEMBER-FIRST-OFF') @:killer('M-UNUSED-USING-NO-DOOR') @:killer('M-CARRY-USING-DOOR-OFFSET')
	public function testAnOwnMemberCallNeedsNoUsing(): Void {
		agree(
			'p.Ext', 'class D {\n\tpublic function new() {}\n\n\tpublic function tag():Int return 1;\n}', 'f(d:D):Int return d.tag();',
			false
		);
	}

	/** A member the receiver's type inherits. */
	@:pin('control') @:killer('M-USING-MEMBER-FIRST-OFF')
	public function testAnInheritedMemberCallNeedsNoUsing(): Void {
		agree(
			'p.Ext', 'class Base {\n\tpublic function new() {}\n\n\tpublic function tag():Int return 1;\n}\n\nclass D extends Base {}',
			'f(d:D):Int return d.tag();', false
		);
	}

	/** A STATIC of the name does not shadow the extension: the call is the extension, the statement stays. */
	@:pin('control') @:killer('M-MEMBER-BINDS-STATIC')
	public function testAStaticOfTheNameKeepsTheUsing(): Void {
		agree(
			'p.Ext', 'class D {\n\tpublic function new() {}\n\n\tpublic static function tag():Int return 1;\n}',
			'f(d:D):String return d.tag();', true
		);
	}

	/** A receiver whose type the run cannot read keeps the statement: fail closed. */
	public function testAnUntypedReceiverKeepsTheUsing(): Void {
		agree('p.Ext', 'class D {\n\tpublic function new() {}\n}', 'f(d:Unknown):String return d.tag();', true);
	}

	/** A member under `#if` binds in some builds only, and the extension in the rest. */
	@:pin('control') @:killer('M-MEMBER-BINDS-GUARDED')
	public function testAGuardedMemberKeepsTheUsing(): Void {
		agree(
			'p.Ext', 'class D {\n\tpublic function new() {}\n\n\t#if never\n\tpublic function tag():Int return 1;\n\t#end\n}',
			'f(d:D):String return d.tag();', true
		);
	}

	/** A receiver type declared in two `#if` branches, only one of them declaring the member. */
	@:pin('control') @:killer('M-MEMBER-BINDS-HOST-GUARDED')
	public function testATypeDeclaredPerBranchKeepsTheUsing(): Void {
		agree(
			'p.Ext',
			'#if never\nclass D {\n\tpublic function new() {}\n\n\tpublic function tag():Int return 1;\n}\n#else\nclass D {\n'
			+ '\tpublic function new() {}\n}\n#end',
			'f(d:D):String return d.tag();', true
		);
	}

	/** A real extension call: the receiver's type declares no `tag`. */
	public function testAnExtensionCallKeepsTheUsing(): Void {
		agree('p.Ext', 'class D {\n\tpublic function new() {}\n}', 'f(d:D):String return d.tag();', true);
	}

	/** A `@:forward` abstract hands an access it does not declare to its underlying type, whose extension binds: kept. */
	@:pin('guard')
	public function testAForwardAbstractReceiverKeepsTheUsing(): Void {
		agree(
			'p.Ext', 'class D {\n\tpublic function new() {}\n}\n\n@:forward abstract Fq(D) from D {}', 'f(x:Fq):String return x.tag();',
			true
		);
	}

	/**
	 * A project type sharing the std name the receiver's type spells keeps the statement: the std listing answers only
	 * for a name no project type takes (`NominalTypes.shadowedByNonStdType`), since the typer's nominal is a simple name.
	 */
	@:pin('control') @:killer('M-MEMBER-DOOR-SHADOW')
	public function testAProjectTypeSharingTheStdNameKeepsTheUsing(): Void {
		if (StdResolver.stdDir() == null) {
			Assert.pass('no std discovered');
			return;
		}
		agree(
			'Lambda', null, 'f(a:Array<Int>, b:Array<Int>):Array<Int> return a.concat(b);', true,
			[{ file: 'q/Array.hx', source: 'package q;\n\nclass Array {}\n' }]
		);
	}

	/**
	 * The std listing proves an INSTANCE member every std module of the name reaches: `String.charAt` yes, and `Map.exists`
	 * (the toplevel typedef and `haxe.ds.Map` both reach `haxe.ds.Map.exists`); `String.fromCharCode` is static (no
	 * shadow — 4.3.7 binds the extension past a static); `haxe.http.HttpJs` is declared under `#if js`, so its own `async`
	 * binds in some builds only; and `Http` names both `sys.Http`, which declares `fileTransfer`, and `haxe.Http`, a
	 * typedef per target that reaches nothing the listing can follow.
	 */
	@:pin('control') @:killer('M-STD-MEMBER-STATIC') @:killer('M-STD-MEMBER-VIA-GUARD') @:killer('M-STD-MEMBER-ANY-CANDIDATE')
	public function testTheStdListingProvesOnlyAnUnguardedInstanceMember(): Void {
		if (StdResolver.stdDir() == null) {
			Assert.pass('no std discovered');
			return;
		}
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.isTrue(StdTypes.declaresInstanceMember(plugin, 'String', 'charAt'));
		Assert.isTrue(StdTypes.declaresInstanceMember(plugin, 'Map', 'exists'));
		Assert.isFalse(StdTypes.declaresInstanceMember(plugin, 'String', 'fromCharCode'));
		Assert.isFalse(StdTypes.declaresInstanceMember(plugin, 'haxe.http.HttpJs', 'async'), 'a type under `#if`');
		Assert.isTrue(StdTypes.declaresInstanceMember(plugin, 'sys.Http', 'fileTransfer'));
		Assert.isFalse(StdTypes.declaresInstanceMember(plugin, 'Http', 'fileTransfer'), 'every module the simple name may mean');
	}

	/**
	 * Run both on one scope — `p/Src.hx` holding `using <path>;` and the static `<member>`, `p/D.hx` holding `types`,
	 * `p/Ext.hx`, `p/Dest.hx`, and any `extra` file — and assert each answers `kept`: the lint reports no `unused using`,
	 * the move carries it.
	 */
	private static function agree(
		path: String, types: Null<String>, member: String, kept: Bool, ?extra: Array<{ file: String, source: String }>
	): Void {
		final src: String = 'package p;\n\nusing $path;\n\nclass Src {\n\tpublic static function $member\n}\n';
		final scope: Array<{ file: String, source: String }> = [{ file: 'p/Src.hx', source: src }, { file: 'p/Dest.hx', source: DEST }];
		for (e in extra ?? []) scope.push(e);
		if (types != null) {
			scope.push({ file: 'p/D.hx', source: 'package p;\n\n$types\n' });
			scope.push({ file: 'p/Ext.hx', source: EXT });
		}
		final warned: Bool = CheckFixture.violationsIn(new UnusedImport(), scope).exists(v -> isUnusedUsing(v, path));
		final carried: Bool = destOf(scope).contains('using $path;');
		Assert.equals(!kept, warned, 'unused-import on `$member` under `using $path`');
		Assert.equals(kept, carried, 'move-member of `$member` under `using $path`');
	}

	/** Whether `v` is the verified `unused using` finding on `p/Src.hx`'s statement `using <path>;`. */
	private static function isUnusedUsing(v: Violation, path: String): Bool {
		return v.file == 'p/Src.hx' && v.severity == Severity.Warning && v.message == 'unused using \'$path\'';
	}

	/** The destination's source after moving `Src.f` to `Dest`, or '' (a failed assertion) when the move does not apply. */
	private static function destOf(scope: Array<{ file: String, source: String }>): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		switch MoveMember.move('p/Src.hx', 'Src', ['f'], 'Dest', null, false, false, scope, plugin, plugin.typeRefShape(), false) {
			case Ok(changes, _):
				final change: Null<MoveChange> = changes.find(c -> c.file == 'p/Dest.hx');
				if (change != null) return change.newSource;
				Assert.fail('the move changed no p/Dest.hx');
			case Err(message):
				Assert.fail('expected the move to apply: $message');
		}
		return '';
	}

}
