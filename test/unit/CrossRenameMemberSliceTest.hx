package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CrossRename.CrossRenameResult;
import anyparse.query.CrossRename.FileChange;
import anyparse.query.CrossRenameMember;
import anyparse.query.GrammarPlugin.RefShape;
import utest.Assert;
import utest.Test;

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
 * method; zero-false-positive guards (a same-named member on a DIFFERENT type, an
 * unresolved receiver, a shadowed static receiver, a same-named MODULE in another
 * package reached through a dotted receiver, a foreign instance receiver — annotated,
 * `new`-built, or homonymous through a conditional-compilation header — and a
 * function-typed receiver whose written type merely starts with the source type are
 * left alone; the module-relative `Mod.Sub` spelling of a sub-module type is not);
 * refusals (override, name collision, ambiguous type, case-capture
 * collision, constructor, cursor off a member, no-op, invalid name,
 * skip-parse scope file).
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
	 * An instance receiver is proven by RESOLVING its written annotation, not by comparing simple
	 * names: `pkg.Other` and a foreign `other.Other` share a last segment and only the first is the
	 * type at the cursor. Both halves sit in ONE asserted source, so the renamed access cannot be
	 * satisfied by the unchanged input and the foreign one cannot be satisfied by a last-segment
	 * matcher.
	 */
	public function testInstanceReceiverQualifiedAnnotationRenamesOnlyTheDeclaringModule(): Void {
		final a: String = 'package pkg;\n\nclass Other {\n\tpublic function new() {}\n\tpublic function tag():Void {}\n}';
		final b: String = 'class Z {\n\tfunction m(p:pkg.Other, w:other.Other):Void {\n\t\tp.tag();\n\t\tw.tag();\n\t}\n}';
		final expectedB: String = 'class Z {\n\tfunction m(p:pkg.Other, w:other.Other):Void {\n\t\tp.mark();\n\t\tw.tag();\n\t}\n}';
		final changes: Array<FileChange> = okChanges('pkg/Other.hx', a, 'tag', 'mark', [
			{ file: 'pkg/Other.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * A `new pkg.Other()` receiver names its type through the WHOLE module path, which the
	 * projection keeps on the node's name — so proving it needs the same resolution the annotated
	 * receivers go through, not a comparison against the type's simple name. The foreign
	 * `new other.Other()` is the other half of the same expected source.
	 */
	public function testNewExprReceiverQualifiedPathRenamesOnlyTheDeclaringModule(): Void {
		final a: String = 'package pkg;\n\nclass Other {\n\tpublic function new() {}\n\tpublic function tag():Void {}\n}';
		final b: String = 'class Z {\n\tfunction m():Void {\n\t\tnew pkg.Other().tag();\n\t\tnew other.Other().tag();\n\t}\n}';
		final expectedB: String = 'class Z {\n\tfunction m():Void {\n\t\tnew pkg.Other().mark();\n\t\tnew other.Other().tag();\n\t}\n}';
		final changes: Array<FileChange> = okChanges('pkg/Other.hx', a, 'tag', 'mark', [
			{ file: 'pkg/Other.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * The AST, not the source text, decides whether an annotation is nominal. `g:pkg.Other<Int>`
	 * is a receiver of the source type and renames; `f:pkg.Other<Int> -> Void` is a FUNCTION,
	 * and a first-`<` split of its text reads it as the nominal `pkg.Other`. Both halves sit in
	 * ONE asserted source, so the generic receiver's coverage and the arrow's exclusion each need
	 * the other to hold.
	 */
	public function testInstanceReceiverGenericRenamesButArrowTypeDoesNot(): Void {
		final a: String = 'package pkg;\n\nclass Other<T> {\n\tpublic function new() {}\n\tpublic function tag():Void {}\n}';
		final b: String = 'class Z {\n\tfunction m(g:pkg.Other<Int>, f:pkg.Other<Int> -> Void):Void {\n\t\tg.tag();\n\t\tf.tag();\n\t}\n}';
		final expectedB: String =
			'class Z {\n\tfunction m(g:pkg.Other<Int>, f:pkg.Other<Int> -> Void):Void {\n\t\tg.mark();\n\t\tf.tag();\n\t}\n}';
		final changes: Array<FileChange> = okChanges('pkg/Other.hx', a, 'tag', 'mark', [
			{ file: 'pkg/Other.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * The MODULE-RELATIVE spelling of a sub-module type — `Mod.Sub`, legal wherever the module is
	 * in simple-name scope — is a third spelling beside the bare and the root-relative one, and
	 * it resolves only FROM the reading file (`SymbolIndex.moduleRelativeRefAll`). Annotation and `new` forms both rename. The visibility rule is the MODULE's, not a bare type
	 * name's, and it is narrower: compiled on 4.3.7, `import pkg.*;` reaches `Mod.Sub` while
	 * `import pkg.Mod;` does NOT (`Type not found : Mod`). Both arms are asserted here, alongside
	 * the root-relative `other.Mod.Sub` of another package, which resolves to nothing.
	 */
	public function testInstanceReceiverModuleRelativeSubModulePathRenames(): Void {
		final a: String = 'package pkg;\n\nclass Mod {\n\tpublic function new() {}\n}\n\n'
			+ 'class Sub {\n\tpublic function new() {}\n\tpublic function tag():Void {}\n}';
		final b: String = 'package pkg;\n\nclass Z {\n\tfunction m(p:Mod.Sub):Void {\n\t\tp.tag();\n'
			+ '\t\tnew Mod.Sub().tag();\n\t\tnew other.Mod.Sub().tag();\n\t}\n}';
		final expectedB: String = 'package pkg;\n\nclass Z {\n\tfunction m(p:Mod.Sub):Void {\n\t\tp.mark();\n'
			+ '\t\tnew Mod.Sub().mark();\n\t\tnew other.Mod.Sub().tag();\n\t}\n}';
		final wild: String = 'package app;\n\nimport pkg.*;\n\nclass W {\n\tfunction m(p:Mod.Sub):Void p.tag();\n}';
		final plain: String = 'package app;\n\nimport pkg.Mod;\n\nclass P {\n\tfunction m(p:Mod.Sub):Void p.tag();\n}';
		final changes: Array<FileChange> = okChanges('pkg/Mod.hx', a, 'tag', 'mark', [
			{ file: 'pkg/Mod.hx', source: a },
			{ file: 'pkg/Z.hx', source: b },
			{ file: 'app/W.hx', source: wild },
			{ file: 'app/P.hx', source: plain },
		]);
		Assert.equals(3, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'pkg/Z.hx').newSource);
		Assert.equals(2, changeFor(changes, 'pkg/Z.hx').count);
		Assert.equals(
			'package app;\n\nimport pkg.*;\n\nclass W {\n\tfunction m(p:Mod.Sub):Void p.mark();\n}',
			changeFor(changes, 'app/W.hx').newSource
		);
		Assert.isNull(changeOrNull(changes, 'app/P.hx'));
	}

	/**
	 * A same-named type declared by a CONDITIONAL-compilation header (`#if js class Other {
	 * #else class Other implements Iface { #end`) is invisible to `checkTypeUniqueness` —
	 * `RefactorSupport.typeDeclOf` does not know the shared-body decl kind — so the uniqueness
	 * refusal never fires and the receiver proof is the ONLY thing standing between the rename
	 * and a foreign `w.tag()`. It holds because the resolved declaration must live in the CURSOR's
	 * file, the conjunct nothing else in this suite can flip.
	 */
	public function testConditionalHomonymInAnotherPackageUntouched(): Void {
		final a: String = 'package pkg;\n\nclass Other {\n\tpublic function new() {}\n\tpublic function tag():Void {}\n}';
		final foreign: String = 'package other;\n\n#if js\nclass Other {\n#else\nclass Other implements Iface {\n#end\n'
			+ '\tpublic function new() {}\n\tpublic function ping():Void {}\n}';
		final use: String = 'package other;\n\nclass Use {\n\tfunction m(w:Other):Void w.tag();\n}';
		final changes: Array<FileChange> = okChanges('pkg/Other.hx', a, 'tag', 'mark', [
			{ file: 'pkg/Other.hx', source: a },
			{ file: 'other/Other.hx', source: foreign },
			{ file: 'other/Use.hx', source: use },
		]);
		Assert.equals(1, changes.length);
		Assert.equals(
			'package pkg;\n\nclass Other {\n\tpublic function new() {}\n\tpublic function mark():Void {}\n}',
			changeFor(changes, 'pkg/Other.hx').newSource
		);
		Assert.isNull(changeOrNull(changes, 'other/Use.hx'));
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
		final expectedA: String = 'enum abstract Colour(Int) {\n\tvar CRIMSON = 0;\n\tvar GREEN = 1;\n\tpublic function label():String '
			+ 'return switch (cast this : Colour) {\n\t\tcase CRIMSON: \'r\';\n\t\tcase GREEN: \'g\';\n\t}\n}';
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
		final b: String = 'class Palette {\n\tpublic static function colour(c:Colour):String return switch (c) {\n\t\tcase RED: \'c\';\n'
			+ '\t\tcase GREEN: \'g\';\n\t}\n\tpublic static function fruit(x:Fruit):String return switch (x) {\n\t\tcase RED: \'f\';\n'
			+ '\t\tcase YELLOW: \'y\';\n\t}\n}';
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

	/**
	 * A qualified static access is matched by the WHOLE module path, not the last segment.
	 * Both halves sit in ONE asserted expression, so the renamed one cannot be satisfied by
	 * the unchanged input and the foreign one cannot be satisfied by a last-segment matcher.
	 */
	public function testStaticMemberQualifiedPathRenamesOnlyTheDeclaringModule(): Void {
		final a: String = 'package pkg;\n\nclass Boxes {\n\tpublic static final CONST:Int = 5;\n}';
		final b: String = 'class Z {\n\tvar n:Int = pkg.Boxes.CONST + other.Boxes.CONST;\n}';
		final expectedB: String = 'class Z {\n\tvar n:Int = pkg.Boxes.LIMIT + other.Boxes.CONST;\n}';
		final changes: Array<FileChange> = okChanges('pkg/Boxes.hx', a, 'CONST', 'LIMIT', [
			{ file: 'pkg/Boxes.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * The same whole-path rule one level deeper: a SUB-MODULE type, reached as
	 * `pkg.Mod.Helper.CONST`. `other.Mod.Helper.CONST` shares every segment but the package.
	 */
	public function testStaticMemberQualifiedSubModulePathRenamesOnlyTheDeclaringModule(): Void {
		final a: String =
			'package pkg;\n\nclass Mod {\n\tpublic function new() {}\n}\n\nclass Helper {\n\tpublic static final CONST:Int = 1;\n}';
		final b: String = 'class Z {\n\tvar n:Int = pkg.Mod.Helper.CONST + other.Mod.Helper.CONST;\n}';
		final expectedB: String = 'class Z {\n\tvar n:Int = pkg.Mod.Helper.LIMIT + other.Mod.Helper.CONST;\n}';
		final changes: Array<FileChange> = okChanges('pkg/Mod.hx', a, 'CONST', 'LIMIT', [
			{ file: 'pkg/Mod.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * The short `Mod.Helper` spelling is legal ONLY from the module's own package, so the
	 * IDENTICAL text in another package names a different (root-package) module and must be
	 * left alone. Acceptance and refusal are asserted separately — neither half implies the other.
	 */
	public function testStaticMemberShortModulePathRenamesOnlyInsideTheModulesOwnPackage(): Void {
		final a: String =
			'package pkg;\n\nclass Mod {\n\tpublic function new() {}\n}\n\nclass Helper {\n\tpublic static final CONST:Int = 1;\n}';
		final inPkg: String = 'package pkg;\n\nclass User {\n\tvar n:Int = Mod.Helper.CONST;\n}';
		final outside: String = 'package zzz;\n\nclass Other {\n\tvar n:Int = Mod.Helper.CONST;\n}';
		final changes: Array<FileChange> = okChanges('pkg/Mod.hx', a, 'CONST', 'LIMIT', [
			{ file: 'pkg/Mod.hx', source: a },
			{ file: 'pkg/User.hx', source: inPkg },
			{ file: 'zzz/Other.hx', source: outside },
		]);
		Assert.equals(2, changes.length);
		Assert.equals('package pkg;\n\nclass User {\n\tvar n:Int = Mod.Helper.LIMIT;\n}', changeFor(changes, 'pkg/User.hx').newSource);
		Assert.isNull(changeOrNull(changes, 'zzz/Other.hx'));
	}

	/**
	 * Haxe resolves an unqualified `enum abstract` value from the EXPECTED type, so a bare
	 * `return SAME;` names the value of whatever type the function is declared to return. TWO
	 * abstracts here declare `SAME`, and two functions differing ONLY in their declared return
	 * spell the identical `return SAME;` — the `Colour` one renames, the `Shade` one must not.
	 * One expected source carries both halves, so neither assertion is satisfied by the input.
	 */
	public function testExpectedReturnRenamesOnlyTheDeclaredReturnType(): Void {
		final a: String = 'enum abstract Colour(Int) {\n\tvar SAME = 0;\n\tvar RED = 1;\n}';
		final s: String = 'enum abstract Shade(Int) {\n\tvar SAME = 10;\n\tvar DARK = 11;\n}';
		final b: String = 'class Palette {\n\tpublic static function colour():Colour return SAME;\n'
			+ '\tpublic static function shade():Shade return SAME;\n}';
		final expectedB: String = 'class Palette {\n\tpublic static function colour():Colour return EQUAL;\n'
			+ '\tpublic static function shade():Shade return SAME;\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'SAME', 'EQUAL', [
			{ file: 'a.hx', source: a },
			{ file: 's.hx', source: s },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * Every TYPE-TRANSPARENT slot under a `return` carries the declared return type down
	 * unchanged: a parenthesis, BOTH arms of a ternary and of an `if` expression (one fixture
	 * apiece, so neither arm index can be dropped without a failure), the last statement of a
	 * `switch`-expression arm, and a `Null<…>` wrapper (Haxe propagates the expected type
	 * through it). All seven rewrite; the sibling returning the OTHER abstract that declares the
	 * same value does not.
	 */
	public function testExpectedReturnRewritesTypeTransparentSlots(): Void {
		final a: String = 'enum abstract Colour(Int) {\n\tvar SAME = 0;\n\tvar RED = 1;\n}';
		final s: String = 'enum abstract Shade(Int) {\n\tvar SAME = 10;\n\tvar DARK = 11;\n}';
		final b: String = 'class Palette {\n\tpublic static function par():Colour return (SAME);\n'
			+ '\tpublic static function ternThen(f:Bool):Colour return f ? SAME : RED;\n'
			+ '\tpublic static function ternElse(f:Bool):Colour return f ? RED : SAME;\n\tpublic static function iffThen(f:Bool):Colour {\n'
			+ '\t\treturn if (f) SAME else RED;\n\t}\n\tpublic static function iffElse(f:Bool):Colour {\n\t\treturn if (f) RED else SAME;\n'
			+ '\t}\n\tpublic static function sw(i:Int):Colour {\n\t\treturn switch (i) {\n\t\t\tcase 1: SAME;\n\t\t\tcase _: RED;\n\t\t}\n'
			+ '\t}\n\tpublic static function nul():Null<Colour> return SAME;\n\tpublic static function other():Shade return SAME;\n}';
		final expectedB: String = 'class Palette {\n\tpublic static function par():Colour return (EQUAL);\n'
			+ '\tpublic static function ternThen(f:Bool):Colour return f ? EQUAL : RED;\n\tpublic static function ternElse(f:Bool):Colour '
			+ 'return f ? RED : EQUAL;\n\tpublic static function iffThen(f:Bool):Colour {\n\t\treturn if (f) EQUAL else RED;\n\t}\n'
			+ '\tpublic static function iffElse(f:Bool):Colour {\n\t\treturn if (f) RED else EQUAL;\n\t}\n'
			+ '\tpublic static function sw(i:Int):Colour {\n\t\treturn switch (i) {\n\t\t\tcase 1: EQUAL;\n\t\t\tcase _: RED;\n\t\t}\n\t}\n'
			+ '\tpublic static function nul():Null<Colour> return EQUAL;\n\tpublic static function other():Shade return SAME;\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'SAME', 'EQUAL', [
			{ file: 'a.hx', source: a },
			{ file: 's.hx', source: s },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(7, changeFor(changes, 'b.hx').count);
	}

	/**
	 * A DOTTED return type must name the declaring module WHOLE, never merely share its last
	 * segment — the defect `f3b46467` removed from the static-receiver match and `64a4ae5a` from
	 * `move-member`. Both functions here are written `.Colour`; only the one spelling THIS
	 * module's path renames, and the foreign `other.Colour` one survives byte-for-byte.
	 */
	public function testExpectedReturnDottedTypeMatchesTheWholeModulePath(): Void {
		final a: String = 'package pkg;\n\nenum abstract Colour(Int) {\n\tvar SAME = 0;\n\tvar RED = 1;\n}';
		final b: String =
			'class Z {\n\tstatic function near():pkg.Colour return SAME;\n\tstatic function far():other.Colour return SAME;\n}';
		final expectedB: String =
			'class Z {\n\tstatic function near():pkg.Colour return EQUAL;\n\tstatic function far():other.Colour return SAME;\n}';
		final changes: Array<FileChange> = okChanges('pkg/Colour.hx', a, 'SAME', 'EQUAL', [
			{ file: 'pkg/Colour.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * A member INHERITED from a base class SHADOWS the expected-type resolution — verified on
	 * Haxe 4.3.7, `class Main extends Base` whose `Base` declares `public var SAME:Colour` prints
	 * the FIELD's value from `function inherited():Colour return SAME;`. `Refs` resolves
	 * lexically, in one file, and cannot see that declaration, so the index is asked instead. The
	 * sibling class that inherits nothing still renames, so the input satisfies neither half.
	 */
	public function testExpectedReturnLeavesAnInheritedShadowAlone(): Void {
		final a: String = 'enum abstract Colour(Int) {\n\tvar SAME = 0;\n\tvar RED = 1;\n}';
		final base: String = 'class Base {\n\tpublic var SAME:Colour = Colour.RED;\n\tpublic function new() {}\n}';
		final b: String = 'class Holder extends Base {\n\tpublic function new() super();\n\tpublic function pick():Colour return SAME;\n}\n'
			+ '\nclass Free {\n\tpublic static function pick():Colour return SAME;\n}';
		final expectedB: String = 'class Holder extends Base {\n\tpublic function new() super();\n\tpublic function pick():Colour return '
			+ 'SAME;\n}\n\nclass Free {\n\tpublic static function pick():Colour return EQUAL;\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'SAME', 'EQUAL', [
			{ file: 'a.hx', source: a },
			{ file: 'base.hx', source: base },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * A NESTED function owns its own return type, so the outer function's proof stops at it. The
	 * inner one returning the OTHER abstract and the one declaring no return type at all both
	 * keep the old name, while the outer function's own `return` renames.
	 */
	public function testExpectedReturnStopsAtANestedFunction(): Void {
		final a: String = 'enum abstract Colour(Int) {\n\tvar SAME = 0;\n\tvar RED = 1;\n}';
		final s: String = 'enum abstract Shade(Int) {\n\tvar SAME = 10;\n\tvar DARK = 11;\n}';
		final b: String = 'class Z {\n\tstatic function outer():Colour {\n'
			+ '\t\tvar inner = function():Shade return SAME;\n\t\tvar bare = function() return SAME;\n\t\treturn SAME;\n\t}\n}';
		final expectedB: String = 'class Z {\n\tstatic function outer():Colour {\n'
			+ '\t\tvar inner = function():Shade return SAME;\n\t\tvar bare = function() return SAME;\n\t\treturn EQUAL;\n\t}\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'SAME', 'EQUAL', [
			{ file: 'a.hx', source: a },
			{ file: 's.hx', source: s },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * A NAMED function expression (`function g():Shade …`) is in neither the grammar's function
	 * nor its lambda kind list, so the boundary is derived from the function-BODY child instead
	 * of a kind name. Without that derivation its `return SAME;` would be attributed to the
	 * enclosing `Colour` function and rewritten into another abstract's value.
	 */
	public function testExpectedReturnStopsAtANamedFunctionExpression(): Void {
		final a: String = 'enum abstract Colour(Int) {\n\tvar SAME = 0;\n\tvar RED = 1;\n}';
		final s: String = 'enum abstract Shade(Int) {\n\tvar SAME = 10;\n\tvar DARK = 11;\n}';
		final b: String =
			'class Z {\n\tstatic function outer():Colour {\n\t\tvar named = function g():Shade return SAME;\n\t\treturn SAME;\n\t}\n}';
		final expectedB: String =
			'class Z {\n\tstatic function outer():Colour {\n\t\tvar named = function g():Shade return SAME;\n\t\treturn EQUAL;\n\t}\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'SAME', 'EQUAL', [
			{ file: 'a.hx', source: a },
			{ file: 's.hx', source: s },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * A LOCAL of the same name binds the identifier, so `return SAME;` under it reads that local
	 * and not the member — Haxe binds a local ahead of the expected type. The sibling function
	 * with no such local still renames.
	 */
	public function testExpectedReturnLeavesALocalBindingAlone(): Void {
		final a: String = 'enum abstract Colour(Int) {\n\tvar SAME = 0;\n\tvar RED = 1;\n}';
		final b: String = 'class Z {\n\tstatic function shadowed():Colour {\n'
			+ '\t\tfinal SAME:Colour = Colour.RED;\n\t\treturn SAME;\n\t}\n\tstatic function plain():Colour return SAME;\n}';
		final expectedB: String = 'class Z {\n\tstatic function shadowed():Colour {\n'
			+ '\t\tfinal SAME:Colour = Colour.RED;\n\t\treturn SAME;\n\t}\n\tstatic function plain():Colour return EQUAL;\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'SAME', 'EQUAL', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * Only an `enum abstract` VALUE is expected-type-resolvable. Measured on Haxe 4.3.7, a PLAIN
	 * abstract's static is not — `abstract Plain(Int) { public static final PX:Plain; }` with
	 * `function f():Plain return PX;` is `Unknown identifier : PX` — so the scan must not claim
	 * that site, whose bare `PX` cannot be this member under any reading.
	 */
	public function testPlainAbstractStaticIsNotAnExpectedTypeValue(): Void {
		final a: String = 'abstract Plain(Int) {\n\tpublic static final PX:Plain = cast 5;\n\tpublic static final QX:Plain = cast 6;\n}';
		final b: String = 'class Z {\n\tstatic function get():Plain return PX;\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'PX', 'ZX', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(1, changes.length);
		Assert.isNull(changeOrNull(changes, 'b.hx'));
	}

	/**
	 * A supertype the index CANNOT SEE refuses the whole enclosing type. `supertypeDeclaresMember`
	 * answers `false` both when no ancestor declares the name and when the ancestor is not indexed,
	 * and only the first reading is a proof — compiled and run with `Base` outside the scope, the
	 * rewrite silently changed the returned value from the inherited field to the constant. The
	 * sibling class that inherits nothing still renames, so the gate is not simply switched off.
	 */
	public function testExpectedReturnLeavesAnUnprovableSupertypeChainAlone(): Void {
		final a: String = 'enum abstract Colour(Int) {\n\tvar SAME = 0;\n\tvar RED = 1;\n}';
		final b: String = 'class Holder extends Base {\n\tpublic function new() super();\n\tpublic function pick():Colour return SAME;\n}\n'
			+ '\nclass Free {\n\tpublic static function pick():Colour return SAME;\n}';
		final expectedB: String = 'class Holder extends Base {\n\tpublic function new() super();\n\tpublic function pick():Colour return '
			+ 'SAME;\n}\n\nclass Free {\n\tpublic static function pick():Colour return EQUAL;\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'SAME', 'EQUAL', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * A MODULE-level VALUE binding of the name shadows the expected type — measured on Haxe 4.3.7, a
	 * module-level `var SAME:Colour` wins over `function pick():Colour return SAME;` both from a
	 * module function and from a class method in the same file, and `Refs` binds neither read. The whole FILE is refused, in all five spellings the gate has to reach: a plain `var`; a `#if`-
	 * GUARDED one, which is a child of the REGION rather than of the module; a `final`, which is a
	 * child of the `final` keyword's own dispatch node (`FinalDecl(VarForm …)`) and slipped the gate
	 * entirely while the descent keyed on the region kind alone — the rewrite then retargeted a read
	 * of that binding to the constant and still compiled, a program printing 1 printing 3 after the
	 * rename; a guarded `final`, two wrappers deep; and a module-level `function`, the third value kind. A file with no module-level
	 * binding still renames.
	 *
	 * The `function` arm is the one whose fixture cannot also COMPILE: a bare read of a module
	 * function in a `: Colour` return is a type error, so no valid program reaches the gate through
	 * it. It is pinned structurally anyway — the name IS bound at module level, and a vocabulary
	 * that dropped the kind would rewrite the read instead of refusing it, which is the wrong answer
	 * to keep available for the day the surrounding types change.
	 */
	public function testExpectedReturnRefusesAFileDeclaringAModuleBinding(): Void {
		final a: String = 'enum abstract Colour(Int) {\n\tvar SAME = 0;\n\tvar RED = 1;\n}';
		final m: String = 'var SAME:Colour = Colour.RED;\n\nfunction pick():Colour return SAME;\n\nclass Z {\n'
			+ '\tpublic static function grab():Colour return SAME;\n}';
		final g: String =
			'#if !js\nvar SAME:Colour = Colour.RED;\n#end\n\nclass Guarded {\n\tpublic static function grab():Colour return SAME;\n}';
		final f: String = 'final SAME:Colour = Colour.RED;\n\nclass Held {\n\tpublic static function grab():Colour return SAME;\n}';
		final gf: String = '#if !js\nfinal SAME:Colour = Colour.RED;\n#end\n\n'
			+ 'class GuardedHeld {\n\tpublic static function grab():Colour return SAME;\n}';
		final fn: String =
			'function SAME():Colour return Colour.RED;\n\nclass Calls {\n\tpublic static function grab():Colour return SAME;\n}';
		final b: String = 'class Clean {\n\tpublic static function pick():Colour return SAME;\n}';
		final expectedB: String = 'class Clean {\n\tpublic static function pick():Colour return EQUAL;\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'SAME', 'EQUAL', [
			{ file: 'a.hx', source: a },
			{ file: 'm.hx', source: m },
			{ file: 'g.hx', source: g },
			{ file: 'f.hx', source: f },
			{ file: 'gf.hx', source: gf },
			{ file: 'fn.hx', source: fn },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.isNull(changeOrNull(changes, 'm.hx'));
		Assert.isNull(changeOrNull(changes, 'g.hx'));
		Assert.isNull(changeOrNull(changes, 'f.hx'));
		Assert.isNull(changeOrNull(changes, 'gf.hx'));
		Assert.isNull(changeOrNull(changes, 'fn.hx'));
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * A module-level TYPE of the value's name shadows NOTHING. Compiled and run on Haxe 4.3.7: with
	 * `class File` in the reading module and `enum abstract Colour { var File = 3; }`,
	 * `function pick():Colour return File;` prints 3 — the value wins. The gate asked
	 * `declHostKinds`, whose type-declaration kinds refused the whole file, and the correct rewrite
	 * was thrown away; it asks `RefShape.moduleValueDeclKinds` now. The expectation names the
	 * untouched type declaration and the rewritten return in ONE string, so neither half can be
	 * satisfied alone.
	 */
	public function testExpectedReturnIgnoresAModuleTypeOfTheValueName(): Void {
		final a: String = 'enum abstract Colour(Int) {\n\tvar File = 0;\n\tvar RED = 1;\n}';
		final b: String =
			'class File {\n\tpublic function new() {}\n}\n\nclass Reader {\n\tpublic static function pick():Colour return File;\n}';
		final expectedB: String =
			'class File {\n\tpublic function new() {}\n}\n\nclass Reader {\n\tpublic static function pick():Colour return Doc;\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'File', 'Doc', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
	}

	/**
	 * A TYPE-PARAMETER CONSTRAINT projects into the same slot as a return type —
	 * `function f<T:Colour>()` and `function f():Colour` give byte-identical trees — so the slot
	 * alone would read an un-annotated generic function as returning the abstract. The parameter
	 * list still stands between a constraint and the body, which is what separates them.
	 *
	 * Three functions, because two of them do not discriminate on their own: the constraint-only one
	 * must refuse and the annotation-only one must rename, and a gate refusing EVERY generic function
	 * satisfies both. The third carries BOTH — its slot holds the annotation, its parameter list
	 * stands before it — and renames, which only the real discriminator gets right.
	 */
	public function testExpectedReturnIgnoresATypeParameterConstraint(): Void {
		final a: String = 'enum abstract Colour(Int) {\n\tvar SAME = 0;\n\tvar RED = 1;\n}';
		final b: String = 'class Z {\n\tstatic function generic<T:Colour>() return SAME;\n'
			+ '\tstatic function both<T:Colour>():Colour return SAME;\n\tstatic function annotated():Colour return SAME;\n}';
		final expectedB: String = 'class Z {\n\tstatic function generic<T:Colour>() return SAME;\n\tstatic function '
			+ 'both<T:Colour>():Colour return EQUAL;\n\tstatic function annotated():Colour return EQUAL;\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'SAME', 'EQUAL', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(2, changeFor(changes, 'b.hx').count);
	}

	/**
	 * A COMMENT between the return annotation and the body is not a parameter list. The slot's
	 * discriminator is the `(` a type-parameter constraint's own parameter list leaves there
	 * (`RefactorSupport.isReturnTypeSlot`), and a `(` written inside a comment used to count as one:
	 * a block comment after the annotation and a trailing line comment on the next line each carried
	 * the whole function out of the proof, silently. The generic sibling — a constraint, no
	 * annotation, the same comment after its parameter list — still refuses, so skipping comments did
	 * not erase the discriminator.
	 */
	public function testExpectedReturnSeesPastACommentBeforeTheBody(): Void {
		final a: String = 'enum abstract Colour(Int) {\n\tvar SAME = 0;\n\tvar RED = 1;\n}';
		final b: String = 'class Z {\n\tstatic function block():Colour /* (note) */ return SAME;\n\tstatic function line():Colour\n'
			+ '\t\t// (note)\n\t\treturn SAME;\n\tstatic function generic<T:Colour>() /* (note) */ return SAME;\n}';
		final expectedB: String = 'class Z {\n\tstatic function block():Colour /* (note) */ return EQUAL;\n'
			+ '\tstatic function line():Colour\n\t\t// (note)\n\t\treturn EQUAL;\n'
			+ '\tstatic function generic<T:Colour>() /* (note) */ return SAME;\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'SAME', 'EQUAL', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(2, changeFor(changes, 'b.hx').count);
	}

	/**
	 * An EXPLICIT `static` inside an `enum abstract` is not a value: measured on Haxe 4.3.7,
	 * `public static final PX:Colour = RED;` with `function f():Colour return PX;` is
	 * `Identifier 'PX' is not part of Colour`. The host kind alone accepts it, so the modifier is
	 * read as well — the twin of the plain-abstract guard, one host kind over.
	 */
	public function testEnumAbstractExplicitStaticIsNotAnExpectedTypeValue(): Void {
		final a: String = 'enum abstract Colour(Int) {\n\tvar RED = 1;\n\tvar BLUE = 2;\n\n\tpublic static final PX:Colour = RED;\n}';
		final b: String = 'class Z {\n\tstatic function get():Colour return PX;\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'PX', 'ZX', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(1, changes.length);
		Assert.isNull(changeOrNull(changes, 'b.hx'));
	}

	/**
	 * A `#if`-bodied function keeps its return type: the region projects as a conditional BODY
	 * holding each branch's own body, which the function-boundary derivation would otherwise read
	 * as a nested function of its own — with no return type — and every `return` inside it would
	 * go unproven. Both branches rewrite, which is the only correct answer: rewriting one leaves
	 * the other build target naming a value that no longer exists.
	 */
	public function testExpectedReturnCoversAConditionalFunctionBody(): Void {
		final a: String = 'enum abstract Colour(Int) {\n\tvar SAME = 0;\n\tvar RED = 1;\n}';
		final b: String = 'class Z {\n\tstatic function pick():Colour\n\t#if js\n\t\treturn SAME;\n\t#else\n\t\treturn SAME;\n\t#end\n}';
		final expectedB: String =
			'class Z {\n\tstatic function pick():Colour\n\t#if js\n\t\treturn EQUAL;\n\t#else\n\t\treturn EQUAL;\n\t#end\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'SAME', 'EQUAL', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(2, changeFor(changes, 'b.hx').count);
	}

	/**
	 * Only a NULLABLE wrapper is unwrapped. Haxe propagates the expected type through
	 * `Null<Colour>` (verified by compiling and running one), and through nothing else the
	 * nullability vocabulary happens to list: `Dynamic<Colour>` does not resolve a bare value at
	 * all, so a rewrite there would be claiming a site the language never gave this member.
	 */
	public function testExpectedReturnUnwrapsOnlyANullableWrapper(): Void {
		final a: String = 'enum abstract Colour(Int) {\n\tvar SAME = 0;\n\tvar RED = 1;\n}';
		final b: String =
			'class Z {\n\tstatic function nul():Null<Colour> return SAME;\n\tstatic function dyn():Dynamic<Colour> return SAME;\n}';
		final expectedB: String =
			'class Z {\n\tstatic function nul():Null<Colour> return EQUAL;\n\tstatic function dyn():Dynamic<Colour> return SAME;\n}';
		final changes: Array<FileChange> = okChanges('a.hx', a, 'SAME', 'EQUAL', [
			{ file: 'a.hx', source: a },
			{ file: 'b.hx', source: b },
		]);
		Assert.equals(2, changes.length);
		Assert.equals(expectedB, changeFor(changes, 'b.hx').newSource);
		Assert.equals(1, changeFor(changes, 'b.hx').count);
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

}
