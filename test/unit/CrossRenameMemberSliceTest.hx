package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.CrossRenameMember;
import anyparse.query.CrossRename.CrossRenameResult;
import anyparse.query.CrossRename.FileChange;

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
		final a: String = 'class Foo {\n\tpublic static function util(x:Int):Int return x + 1;\n\tstatic function other():Int return Foo.util(2) + util(3);\n}';
		final b: String = 'class C {\n\tfunction m():Int return Foo.util(4);\n}';
		final expectedA: String = 'class Foo {\n\tpublic static function calc(x:Int):Int return x + 1;\n\tstatic function other():Int return Foo.calc(2) + calc(3);\n}';
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
		final a: String = 'class Foo {\n\tpublic function new() {}\n\tpublic function greet():String return \'hi\';\n\tpublic function talk(o:Foo):String return greet() + this.greet() + o.greet();\n}';
		final b: String = 'class C {\n\tfunction m() {\n\t\tvar f:Foo = new Foo();\n\t\tf.greet();\n\t}\n}';
		final expectedA: String = 'class Foo {\n\tpublic function new() {}\n\tpublic function hail():String return \'hi\';\n\tpublic function talk(o:Foo):String return hail() + this.hail() + o.hail();\n}';
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
		final expectedA: String = 'class Foo {\n\tpublic var total:Int = 0;\n\tpublic function bump():Void this.total = this.total + total;\n}';
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
		final o: String = 'class Bar {\n\tpublic function new() {}\n\tpublic function ping():Void {}\n\tfunction use(b:Bar):Void b.ping();\n}';
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
		final a: String = 'final class Foo {\n\tpublic function new() {}\n\tpublic final function seal():Void {}\n\tpublic function use():Void seal();\n}';
		final expectedA: String = 'final class Foo {\n\tpublic function new() {}\n\tpublic final function lock():Void {}\n\tpublic function use():Void lock();\n}';
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
		final a: String = 'class Foo {\n\tpublic function tag():Void {}\n\tpublic function pick(v:Any):Void {\n\t\tswitch v {\n\t\t\tcase tag: trace(0);\n\t\t\tcase _:\n\t\t}\n\t}\n}';
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
		for (c in changes) if (c.file == file) return c;
		return null;
	}

	/** 1-based line / col of the first character of `needle` in `src`. */
	private static function posOf(src: String, needle: String): { line: Int, col: Int } {
		final idx: Int = src.indexOf(needle);
		var line: Int = 1;
		var col: Int = 1;
		for (i in 0...idx) {
			if (StringTools.fastCodeAt(src, i) == '\n'.code) {
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

}
