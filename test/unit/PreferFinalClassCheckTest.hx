package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferFinalClass;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `prefer-final-class` check: a class declaration carrying the `@:final` meta is flagged
 * `Info` and rewritten to `final class` — the meta removed and a `final` modifier inserted
 * before the `class` keyword. A redundant `@:final final class` keeps the modifier and drops
 * the meta only. Interfaces, enums, enum abstracts, `abstract class`es (`final abstract class`
 * is not valid Haxe), typedefs, final methods, and a plain `final class` are safe misses.
 * Multi-meta order variants and a doc comment between the meta and the class are handled cleanly.
 */
class PreferFinalClassCheckTest extends Test {

	public function testFlagged(): Void {
		final source: String = '@:final class C {}';
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.equals('prefer-final-class', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('use the final class modifier instead of the @:final meta', vs[0].message);
		Assert.equals('@:final', source.substring(vs[0].span.from, vs[0].span.to));
	}

	public function testBasicFix(): Void {
		Assert.equals('final class C {}', applyFix('@:final class C {}'));
	}

	public function testFinalClassNotFlagged(): Void {
		Assert.equals(0, violations('final class C {}').length);
	}

	public function testPlainClassNotFlagged(): Void {
		Assert.equals(0, violations('class C {}').length);
	}

	public function testInterfaceNotFlagged(): Void {
		Assert.equals(0, violations('@:final interface I {}').length);
	}

	public function testEnumNotFlagged(): Void {
		Assert.equals(0, violations('@:final enum E { A; }').length);
	}

	public function testEnumAbstractNotFlagged(): Void {
		Assert.equals(0, violations('@:final enum abstract EA(Int) { final X = 0; }').length);
	}

	public function testAbstractClassNotFlagged(): Void {
		// `final abstract class` is not valid Haxe, so an `@:final abstract class` is left alone.
		Assert.equals(0, violations('@:final abstract class AC {}').length);
	}

	public function testTypedefNotFlagged(): Void {
		Assert.equals(0, violations('@:final typedef T = Int;').length);
	}

	public function testFinalMethodNotFlagged(): Void {
		// `@:final` on a method (a final method) decorates a member, not a class.
		Assert.equals(0, violations('class C {\n\t@:final function f():Void {}\n}').length);
	}

	public function testRedundantFinalClassMetaRemovedOnly(): Void {
		final vs: Array<Violation> = violations('@:final final class C {}');
		Assert.equals(1, vs.length);
		Assert.equals('redundant @:final meta on an already-final class — remove it', vs[0].message);
		Assert.equals('final class C {}', applyFix('@:final final class C {}'));
	}

	public function testMultiMetaFinalFirst(): Void {
		Assert.equals(1, violations('@:final @:keep class C {}').length);
		Assert.equals('@:keep final class C {}', applyFix('@:final @:keep class C {}'));
	}

	public function testMultiMetaFinalLast(): Void {
		final source: String = '@:keep @:final class C {}';
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		// The flagged token is the @:final meta, not the leading @:keep.
		Assert.equals('@:final', source.substring(vs[0].span.from, vs[0].span.to));
		Assert.equals('@:keep final class C {}', applyFix(source));
	}

	public function testDocBetweenMetaAndClassPreserved(): Void {
		// A canonical layout where the doc sits between the meta and the class keyword — the
		// removal must not swallow the doc, and `final ` still lands before `class`.
		Assert.equals('/** doc */\nfinal class C {}', applyFix('@:final\n/** doc */\nclass C {}'));
	}

	public function testDocBeforeMetaPreserved(): Void {
		Assert.equals('/** doc */\nfinal class C {}', applyFix('/** doc */\n@:final class C {}'));
	}

	public function testMultipleClassesBothFixed(): Void {
		final source: String = '@:final class A {}\n@:final class B {}';
		Assert.equals(2, violations(source).length);
		Assert.equals('final class A {}\nfinal class B {}', applyFix(source));
	}

	public function testSecondTypeOnlyFlagged(): Void {
		// The @:final decorates the SECOND class; the first is untouched.
		final source: String = 'class A {}\n@:final class B {}';
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.equals('class A {}\nfinal class B {}', applyFix(source));
	}

	public function testMetaBeforeTypedefNotAttributedToLaterClass(): Void {
		// The @:final belongs to the typedef between it and the class — neither is flagged.
		Assert.equals(0, violations('@:final typedef T = Int;\nclass B {}').length);
	}

	public function testApplyFixByteExact(): Void {
		Assert.equals('final class C {}', applyFix('@:final class C {}'));
		Assert.equals('final class C {}', applyFix('@:final final class C {}'));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-final-class'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-final-class'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f(').length);
	}

	public function testFinalMetaWithArgRemovesFullMeta(): Void {
		// The whole @:final(true) meta — arg list included — is removed, no dangling `(true)`.
		final source: String = '@:final(true) class C {}';
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.equals('@:final(true)', source.substring(vs[0].span.from, vs[0].span.to));
		Assert.equals('final class C {}', applyFix(source));
	}

	private function violations(source: String): Array<Violation> {
		return new PreferFinalClass().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function applyFix(source: String): String {
		final check: PreferFinalClass = new PreferFinalClass();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			source, check.run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = source;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
