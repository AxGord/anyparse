package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.CrossRenameMember;
import anyparse.query.CrossRename.CrossRenameResult;
import anyparse.query.CrossRename.FileChange;

using StringTools;
using Lambda;

/**
 * `CrossRenameMember.crossRenameMember` — scope-correct, format-preserving
 * cross-file rename of a METHOD or FIELD (the value/method counterpart of
 * `CrossRename`, which renames a TYPE). Both are reached through
 * `apq rename --scope`.
 *
 * Each test drives the PURE operation with an IN-MEMORY `scopeFiles`
 * array (no disk), points a cursor at a member declaration in one file,
 * and asserts the EXACT rewritten text. The op re-parses every rewrite
 * before returning; the tests re-parse each `newSource` to make the
 * guarantee explicit. Refusal cases assert `Err`.
 *
 * Coverage: static member (decl + bare in-file callers + `Src.member`
 * across scope), instance member (decl + `this.member` + bare +
 * `obj.member` with `obj` typed as the source type), field, final
 * method; zero-false-positive guards (a same-named member on a DIFFERENT
 * type, an unresolved receiver, and a shadowed static receiver are left
 * alone); refusals (override, name collision, ambiguous type, case-
 * capture collision, constructor, cursor off a member, no-op, invalid
 * name, skip-parse scope file).
 */
class CrossRenameMemberSliceTest extends Test {

	/**
	 * Static method across two files: the decl, a bare in-file caller and
	 * a qualified `Foo.util` in the source file, and `Foo.util` in another
	 * file all rename; a sibling method's name is untouched.
	 */
	public function testStaticMethodAcrossScope(): Void {
		final a: String = 'class Foo {\n\tpublic static function util(x:Int):Int return x + 1;\n'
			+ '\tstatic function other():Int return Foo.util(2) + util(3);\n}';
		final b: String = 'class C {\n\tfunction m():Int return Foo.util(4);\n}';
		final expectedA: String = 'class Foo {\n\tpublic static function calc(x:Int):Int return x + 1;\n'
			+ '\tstatic function other():Int return Foo.calc(2) + calc(3);\n}';
		final expectedB: String = 'class C {\n\tfunction m():Int return Foo.calc(4);\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'util', 'calc', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedA, changeFor(changes, 'a.hx').newSource);
		Assert.equals(3, changeFor(changes, 'a.hx').count);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * Instance method: the decl, a bare implicit-`this` call, a
	 * `this.member` access and a same-type `o.member` (o typed `Foo`) in
	 * the source file, plus a `f.member` (f typed `Foo`) in another file.
	 */
	public function testInstanceMethodAcrossScope(): Void {
		final a: String = 'class Foo {\n\tpublic function new() {}\n\tpublic function greet():String return \'hi\';\n'
			+ '\tpublic function talk(o:Foo):String return greet() + this.greet() + o.greet();\n}';
		final b: String = 'class C {\n\tfunction m() {\n\t\tvar f:Foo = new Foo();\n\t\tf.greet();\n\t}\n}';
		final expectedA: String = 'class Foo {\n\tpublic function new() {}\n\tpublic function hail():String return \'hi\';\n'
			+ '\tpublic function talk(o:Foo):String return hail() + this.hail() + o.hail();\n}';
		final expectedB: String = 'class C {\n\tfunction m() {\n\t\tvar f:Foo = new Foo();\n\t\tf.hail();\n\t}\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'greet', 'hail', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedA, changeFor(changes, 'a.hx').newSource);
		Assert.equals(4, changeFor(changes, 'a.hx').count);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * Field: the decl, both `this.count` accesses and a bare implicit-`this`
	 * read rename in the source file; a `f.count` (f typed `Foo`) in
	 * another file renames too.
	 */
	public function testInstanceFieldAcrossScope(): Void {
		final a: String = 'class Foo {\n\tpublic var count:Int = 0;\n\tpublic function bump():Void this.count = this.count + count;\n}';
		final b: String = 'class C {\n\tfunction m(f:Foo):Int return f.count;\n}';
		final expectedA: String =
			'class Foo {\n\tpublic var total:Int = 0;\n\tpublic function bump():Void this.total = this.total + total;\n}';
		final expectedB: String = 'class C {\n\tfunction m(f:Foo):Int return f.total;\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'count', 'total', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedA, changeFor(changes, 'a.hx').newSource);
		Assert.equals(4, changeFor(changes, 'a.hx').count);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * Zero false positive across types: a DIFFERENT type declares a member
	 * of the same name and calls it on its own instance. Renaming the
	 * source type's member touches ONLY its own declaration — the other
	 * type is left byte-for-byte untouched.
	 */
	public function testSameNameOtherTypeUntouched(): Void {
		final a: String = 'class Foo {\n\tpublic function new() {}\n\tpublic function ping():Void {}\n}';
		final o: String =
			'class Bar {\n\tpublic function new() {}\n\tpublic function ping():Void {}\n\tfunction use(b:Bar):Void b.ping();\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'ping', 'poke', [
			{ file: 'a.hx', source: a },
			{ file: 'o.hx', source: o },
		]);
		Assert.equals(1, changes.length);
		Assert.equals('class Foo {\n\tpublic function new() {}\n\tpublic function poke():Void {}\n}', changeFor(changes, 'a.hx').newSource);
		Assert.isNull(changeOrNull(changes, 'o.hx'));
	}

	/**
	 * An instance receiver whose type does not resolve (an un-annotated
	 * parameter) is left alone — a miss surfaces as a compile error, never
	 * a wrong rewrite. Only the declaration renames.
	 */
	public function testUnresolvedReceiverUntouched(): Void {
		final a: String = 'class Foo {\n\tpublic function new() {}\n\tpublic function zap():Void {}\n}';
		final b: String = 'class C {\n\tfunction m(x):Void x.zap();\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'zap', 'boom', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(1, changes.length);
		Assert.isNull(changeOrNull(changes, 'b.hx'));
	}

	/**
	 * A static receiver SHADOWED by a local value of the same name as the
	 * type is not renamed (mirrors `CrossRename`). Only the declaration
	 * renames.
	 */
	public function testShadowedStaticReceiverUntouched(): Void {
		final a: String = 'class Foo {\n\tpublic static function run():Void {}\n}';
		final b: String = 'class C {\n\tfunction m() {\n\t\tvar Foo = make();\n\t\tFoo.run();\n\t}\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'run', 'go', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(1, changes.length);
		Assert.isNull(changeOrNull(changes, 'b.hx'));
	}

	/**
	 * A `final` method (the `FinalModifiedMember` form) renames like a
	 * plain method — decl plus a bare in-file caller.
	 */
	public function testFinalMethod(): Void {
		final a: String = 'final class Foo {\n\tpublic function new() {}\n\tpublic final function seal():Void {}\n'
			+ '\tpublic function use():Void seal();\n}';
		final expectedA: String = 'final class Foo {\n\tpublic function new() {}\n\tpublic final function lock():Void {}\n'
			+ '\tpublic function use():Void lock();\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'seal', 'lock', [{ file: 'a.hx', source: a },]);
		Assert.equals(1, changes.length);
		Assert.equals(expectedA, changeFor(changes, 'a.hx').newSource);
		Assert.equals(2, changeFor(changes, 'a.hx').count);
	}

	/** An `override` member is refused — rename the base declaration. */
	public function testOverrideRefused(): Void {
		final sub: String = 'class Sub extends Base {\n\toverride public function speak():Void {}\n}';
		final base: String = 'class Base {\n\tpublic function speak():Void {}\n}';
		assertErr(run('sub.hx', sub, 'speak', 'talk', [
			{ file: 'sub.hx', source: sub },
			{ file: 'base.hx', source: base },
		]));
	}

	/**
	 * Renaming the BASE carries its override — the counterpart of `testOverrideRefused`, which points
	 * at the same pair from the other end and tells the caller to come here. The override's own
	 * declaration, the subtype's own call and a SUBTYPE-typed receiver all move with the base; leaving
	 * any of them behind produces code that does not compile.
	 */
	public function testBaseRenameCarriesOverrideFamily(): Void {
		final base: String = 'class Base {\n\tpublic function new() {}\n\tpublic function speak():Void {}\n}';
		final sub: String = 'class Sub extends Base {\n\tpublic function new() { super(); }\n'
			+ '\toverride public function speak():Void {}\n\tpublic function again():Void speak();\n}';
		final caller: String = 'class C {\n\tfunction m(s:Sub):Void s.speak();\n}';
		final expectedSub: String = 'class Sub extends Base {\n\tpublic function new() { super(); }\n'
			+ '\toverride public function talk():Void {}\n\tpublic function again():Void talk();\n}';
		final changes: Array<FileChange> = okChanges('base.hx', base, 'speak', 'talk', [
			{ file: 'base.hx', source: base },
			{ file: 'sub.hx', source: sub },
			{ file: 'c.hx', source: caller },
		]);
		Assert.equals(3, changes.length);
		Assert.equals(
			'class Base {\n\tpublic function new() {}\n\tpublic function talk():Void {}\n}', changeFor(changes, 'base.hx').newSource
		);
		Assert.equals(expectedSub, changeFor(changes, 'sub.hx').newSource);
		Assert.equals(2, changeFor(changes, 'sub.hx').count);
		// A receiver typed as the SUBTYPE reaches the same member — an exact-type match left it behind.
		Assert.equals('class C {\n\tfunction m(s:Sub):Void s.talk();\n}', changeFor(changes, 'c.hx').newSource);
	}

	/**
	 * A type declaring the same member whose relation to the source type cannot be PROVEN refuses the
	 * rename outright. `Foreign` extends a type the scope does not declare, so it is neither provably
	 * family nor provably unrelated — and renaming the base while guessing about it is exactly how a
	 * half-applied family gets emitted.
	 */
	public function testUnprovableFamilyRefused(): Void {
		final base: String = 'class Root {\n\tpublic function ping():Void {}\n}';
		final foreign: String = 'class Foreign extends Absent {\n\toverride public function ping():Void {}\n}';
		assertErr(run('base.hx', base, 'ping', 'pong', [
			{ file: 'base.hx', source: base },
			{ file: 'foreign.hx', source: foreign },
		]));
	}

	/** A destination name already declared on the type is refused. */
	public function testNameCollisionRefused(): Void {
		final a: String = 'class Foo {\n\tpublic function alpha():Void {}\n\tpublic function beta():Void {}\n}';
		assertErr(run('a.hx', a, 'alpha', 'beta', [{ file: 'a.hx', source: a },]));
	}

	/** A source type declared in more than one scope file is refused. */
	public function testAmbiguousTypeRefused(): Void {
		final a: String = 'class Foo {\n\tpublic function probe():Void {}\n}';
		final dup: String = 'class Foo {\n\tpublic function probe():Void {}\n}';
		assertErr(run('a.hx', a, 'probe', 'scan', [
			{ file: 'a.hx', source: a },
			{ file: 'dup.hx', source: dup },
		]));
	}

	/**
	 * A member whose name is also a `case`-pattern capture in the
	 * declaring file is refused (sibling case-branch captures flatten into
	 * one scope frame, so a bare reference could be mis-attributed).
	 */
	public function testCaseCaptureCollisionRefused(): Void {
		final a: String = 'class Foo {\n\tpublic function tag():Void {}\n\tpublic function pick(v:Any):Void {\n\t\tswitch v {\n'
			+ '\t\t\tcase tag: trace(0);\n\t\t\tcase _:\n\t\t}\n\t}\n}';
		assertErr(run('a.hx', a, 'tag', 'label', [{ file: 'a.hx', source: a },]));
	}

	/** Renaming a constructor (`new`) is refused. */
	public function testConstructorRefused(): Void {
		final a: String = 'class Foo {\n\tpublic function new() {}\n}';
		assertErr(run('a.hx', a, 'new', 'init', [{ file: 'a.hx', source: a },]));
	}

	/** A cursor not on a member declaration (a local var) is refused. */
	public function testCursorNotOnMemberRefused(): Void {
		final a: String = 'class Foo {\n\tpublic function m():Void {\n\t\tvar local = 1;\n\t\ttrace(local);\n\t}\n}';
		assertErr(run('a.hx', a, 'local', 'x', [{ file: 'a.hx', source: a },]));
	}

	/** A no-op rename (same name) is refused. */
	public function testNoOpRefused(): Void {
		final a: String = 'class Foo {\n\tpublic function keep():Void {}\n}';
		assertErr(run('a.hx', a, 'keep', 'keep', [{ file: 'a.hx', source: a },]));
	}

	/** An invalid new name is rejected. */
	public function testInvalidNewNameRefused(): Void {
		final a: String = 'class Foo {\n\tpublic function keep():Void {}\n}';
		assertErr(run('a.hx', a, 'keep', '1bad', [{ file: 'a.hx', source: a },]));
	}

	/**
	 * A multi-line receiver with an INTERIOR comment that mentions the
	 * member: the comment text must NOT win the race for the member token.
	 * The real `.value` access renames; the comment and a nearby string
	 * literal of the same text stay byte-for-byte.
	 */
	public function testInteriorCommentNotMistakenForMemberToken(): Void {
		final a: String = 'class Src {\n\tpublic var value:Int = 0;\n}';
		final b: String = 'class Use {\n\tpublic function new() {}\n\tpublic function go(s:Src):Void {\n\t\ts\n\t\t\t// reset value\n'
			+ '\t\t\t.value = 1;\n\t\ttrace(s.value);\n\t\ttrace(\'value\');\n\t}\n}';
		final expectedB: String = 'class Use {\n\tpublic function new() {}\n\tpublic function go(s:Src):Void {\n\t\ts\n'
			+ '\t\t\t// reset value\n\t\t\t.total = 1;\n\t\ttrace(s.total);\n\t\ttrace(\'value\');\n\t}\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'value', 'total', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(2, changeFor(changes, 'b.hx').count);
	}

	/**
	 * The same interior-comment shape on the STATIC path (`Src.member` with
	 * the type used as a namespace): the comment is left alone and the real
	 * `.value` token renames.
	 */
	public function testStaticInteriorCommentNotMistakenForMemberToken(): Void {
		final a: String = 'class Src {\n\tpublic static var value:Int = 0;\n}';
		final b: String = 'class Use {\n\tfunction go():Void {\n\t\tSrc\n\t\t\t// reset value\n\t\t\t.value = 1;\n\t}\n}';
		final expectedB: String = 'class Use {\n\tfunction go():Void {\n\t\tSrc\n\t\t\t// reset value\n\t\t\t.total = 1;\n\t}\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'value', 'total', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * A `#if`-guarded access is CONDITIONAL code, not comment trivia — it
	 * still renames.
	 */
	public function testConditionalGuardedAccessRenames(): Void {
		final a: String = 'class Src {\n\tpublic var value:Int = 0;\n}';
		final b: String = 'class Use {\n\tfunction go(s:Src):Void {\n\t\t#if debug\n\t\ttrace(s.value);\n\t\t#end\n\t}\n}';
		final expectedB: String = 'class Use {\n\tfunction go(s:Src):Void {\n\t\t#if debug\n\t\ttrace(s.total);\n\t\t#end\n\t}\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'value', 'total', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * An access written inside a `${ }` string interpolation is live code —
	 * it renames like any other access (double-quoted fixtures so the test
	 * source itself does not interpolate).
	 */
	public function testInterpolatedAccessRenames(): Void {
		final a: String = 'class Src {\n\tpublic var value:Int = 0;\n}';
		final b: String = "class Use {\n\tfunction go(s:Src):Void trace('${s.value}');\n}";
		final expectedB: String = "class Use {\n\tfunction go(s:Src):Void trace('${s.total}');\n}";
		final changes: Array<FileChange> = okChanges('a.hx', a, 'value', 'total', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/** A scope file that does not parse refuses the whole rename. */
	public function testSkipParseScopeFileRefused(): Void {
		final a: String = 'class Foo {\n\tpublic function keep():Void {}\n}';
		final broken: String = 'class @@@ not valid @@@';
		assertErr(run('a.hx', a, 'keep', 'hold', [
			{ file: 'a.hx', source: a },
			{ file: 'broken.hx', source: broken },
		]));
	}

	/**
	 * A regex literal whose body legally contains a comment opener used to open
	 * a phantom block comment running to EOF, so every access after it looked
	 * like comment trivia and `activeCodeIdentTokenOffset` reported NOT FOUND -
	 * refusing the whole scope. Fail-safe, but the rename was impossible in any
	 * file holding such a literal.
	 */
	public function testRegexCommentOpenerDoesNotRefuseScope(): Void {
		final a: String = 'class Foo {\n\tpublic static var name:Int = 1;\n}';
		final b: String = 'class Bar {\n\tpublic function f():Void {\n\t\tvar re = ~/[\\/*]/;\n\t\tFoo.name = 2;\n\t\ttrace(re);\n\t}\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'name', 'title', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		final newB: String = changeFor(changes, 'b.hx').newSource;
		Assert.isTrue(newB.contains('Foo.title = 2;'), 'the access is renamed: <$newB>');
		Assert.isTrue(newB.contains('~/[\\/*]/'), 'the regex is left verbatim: <$newB>');
	}

	/**
	 * Drive a successful rename: assert `Ok`, the advisory is present, and
	 * every rewrite re-parses. `needle` locates the cursor at the first
	 * occurrence of the member name (each source declares the member
	 * before it is used, so that occurrence is the declaration).
	 */
	private function okChanges(
		cursorFile: String, cursorSource: String, needle: String, newName: String, scopeFiles: Array<{ file: String, source: String }>
	): Array<FileChange> {
		switch run(cursorFile, cursorSource, needle, newName, scopeFiles) {
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

	private function run(
		cursorFile: String, cursorSource: String, needle: String, newName: String, scopeFiles: Array<{ file: String, source: String }>
	): CrossRenameResult {
		final p: { line: Int, col: Int } = posOf(cursorSource, needle);
		return CrossRenameMember.crossRenameMember(cursorFile, cursorSource, p.line, p.col, newName, scopeFiles, plugin(), refShape());
	}

	private function assertErr(result: CrossRenameResult): Void {
		switch result {
			case Ok(changes, _):
				Assert.fail('expected Err, got Ok with ${changes.length} change(s)');
			case Err(_):
				Assert.pass();
		}
	}

	private function changeFor(changes: Array<FileChange>, file: String): FileChange {
		for (c in changes) if (c.file == file) return c;
		Assert.fail('no change for file $file');
		return { file: file, newSource: '', count: 0 };
	}

	private function changeOrNull(changes: Array<FileChange>, file: String): Null<FileChange> {
		return changes.find(c -> c.file == file);
	}

	/** 1-based line / col of the first character of `needle` in `src`. */
	private static function posOf(src: String, needle: String): { line: Int, col: Int } {
		final idx: Int = src.indexOf(needle);
		var line: Int = 1;
		var col: Int = 1;
		for (i in 0...idx) {
			if (src.fastCodeAt(i) == '\n'.code) {
				line++;
				col = 1;
			} else {
				col++;
			}
		}
		return { line: line, col: col };
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

	private static function refShape(): RefShape {
		return new HaxeQueryPlugin().refShape();
	}

	/**
	 * An `enum abstract` value carries no `Static` modifier, yet a data member of an abstract
	 * IS static — Haxe rejects an instance one outright. The rename must therefore take the
	 * STATIC path and rewrite `Colour.RED` across the scope; the instance path it used to take
	 * looks for a receiver BOUND to a value of the type and never matches a type used as a
	 * namespace, so the declaration was renamed alone and the result did not compile.
	 */
	public function testEnumAbstractValueRenamesQualifiedAccesses(): Void {
		final a: String = 'enum abstract Colour(Int) {\n\tvar RED = 0;\n\tvar GREEN = 1;\n}';
		final b: String = 'class Palette {\n\tpublic static function pick(f:Bool):Colour return f ? Colour.RED : Colour.GREEN;\n}';
		final expectedA: String = 'enum abstract Colour(Int) {\n\tvar CRIMSON = 0;\n\tvar GREEN = 1;\n}';
		final expectedB: String =
			'class Palette {\n\tpublic static function pick(f:Bool):Colour return f ? Colour.CRIMSON : Colour.GREEN;\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'RED', 'CRIMSON', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedA, changeFor(changes, 'a.hx').newSource);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
	}

	/**
	 * The `switch` an `enum abstract` writes over its OWN values is the idiomatic shape, and
	 * the bare `case RED:` in it used to refuse the whole rename as a case-pattern capture.
	 * Haxe never BINDS an upper-case pattern identifier, so that pattern is a reference to the
	 * value; the single-file occurrence pass already rewrote it once the refusal was lifted.
	 */
	public function testEnumAbstractValueRenamesBarePatternInDeclaringFile(): Void {
		final a: String = 'enum abstract Colour(Int) {\n\tvar RED = 0;\n\tvar GREEN = 1;\n'
			+ '\tpublic function label():String return switch (cast this : Colour) {\n\t\tcase RED: \'r\';\n\t\tcase GREEN: \'g\';\n\t}\n}';
		final expectedA: String = 'enum abstract Colour(Int) {\n\tvar CRIMSON = 0;\n\tvar GREEN = 1;\n'
			+ '\tpublic function label():String return switch (cast this : Colour) {\n\t\tcase CRIMSON: \'r\';\n\t\tcase GREEN: \'g\';\n\t}\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'RED', 'CRIMSON', [{ file: 'a.hx', source: a }]);
		Assert.equals(1, changes.length);
		Assert.equals(expectedA, changeFor(changes, 'a.hx').newSource);
	}

	/**
	 * A bare `case RED:` in ANOTHER file renames only where the switch SUBJECT proves the type.
	 * Both switches here spell `RED`; only the one over a `Colour` subject is the value being
	 * renamed, and the `Fruit` one — a different `enum abstract` declaring the same name — must
	 * survive untouched. One expected source carries both halves, so neither can pass alone.
	 */
	public function testBarePatternRenamesOnlyWhereTheSubjectProvesTheType(): Void {
		final a: String = 'enum abstract Colour(Int) {\n\tvar RED = 0;\n\tvar GREEN = 1;\n}';
		final f: String = 'enum abstract Fruit(Int) {\n\tvar RED = 10;\n\tvar YELLOW = 11;\n}';
		final b: String = 'class Palette {\n\tpublic static function colour(c:Colour):String return switch (c) {\n'
			+ '\t\tcase RED: \'c\';\n\t\tcase GREEN: \'g\';\n\t}\n'
			+ '\tpublic static function fruit(x:Fruit):String return switch (x) {\n'
			+ '\t\tcase RED: \'f\';\n\t\tcase YELLOW: \'y\';\n\t}\n}';
		final expectedB: String = 'class Palette {\n\tpublic static function colour(c:Colour):String return switch (c) {\n'
			+ '\t\tcase CRIMSON: \'c\';\n\t\tcase GREEN: \'g\';\n\t}\n'
			+ '\tpublic static function fruit(x:Fruit):String return switch (x) {\n'
			+ '\t\tcase RED: \'f\';\n\t\tcase YELLOW: \'y\';\n\t}\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'RED', 'CRIMSON', [
			{ file: 'a.hx', source: a },
			{ file: 'f.hx', source: f },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * A LOWER-case member name a `case` pattern binds still refuses: the language does let a
	 * pattern declare it, so the resolver cannot tell that binding from the member and the
	 * rewrite would mis-attribute it. The narrowing that unblocked the upper-case values must
	 * not reach this shape.
	 */
	public function testLowerCasePatternCaptureStillRefuses(): Void {
		final a: String = 'class Config {\n\tpublic static var limit = 5;\n'
			+ '\tpublic static function tag(v:Int):String return switch (v) {\n\t\tcase limit: \'x\';\n\t}\n}';
		assertErr(run('a.hx', a, 'limit', 'cap', [{ file: 'a.hx', source: a }]));
	}

}
