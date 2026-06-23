package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.MemberOrder;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `member-order` check: a type whose members are not in canonical order
 * (constants, fields, constructor, methods; public before private) is flagged
 * `Info` and `--fix` reorders them. Reordering bails when a field initializer is
 * side-effecting or reads a sibling field in a way the sort would reverse.
 */
class MemberOrderCheckTest extends Test {

	public function testOutOfOrderFlagged(): Void {
		final vs: Array<Violation> = violations('class C { public function m():Void {} public var x:Int = 0; }');
		Assert.equals(1, vs.length);
		Assert.equals('member-order', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testInOrderNotFlagged(): Void {
		Assert.equals(0, violations('class C { public var x:Int = 0; public function m():Void {} }').length);
	}

	/** Field before method, public before private, static method last. */
	public function testFixReorders(): Void {
		final fixed: String = fixedSource(
			'class C { static function s():Void {} private function p():Void {} public function m():Void {} public var x:Int = 0; }'
		);
		Assert.isTrue(fixed.indexOf('var x') < fixed.indexOf('function m'), 'field before public method: $fixed');
		Assert.isTrue(fixed.indexOf('function m') < fixed.indexOf('function p'), 'public method before private: $fixed');
		Assert.isTrue(fixed.indexOf('function p') < fixed.indexOf('function s'), 'instance before static method: $fixed');
	}

	/** A const built with `new` reorders — same-rank statics keep relative order under a stable sort. */
	public function testNewConstReorders(): Void {
		final fixed: String = fixedSource(
			'class C { public function m():Void {} static final A = new Foo(); static final B = new Foo(); }'
		);
		Assert.isTrue(fixed.indexOf('A = new') < fixed.indexOf('function m'), 'consts before method: $fixed');
		Assert.isTrue(fixed.indexOf('A = new') < fixed.indexOf('B = new'), 'A stays before B (stable): $fixed');
	}

	/** Two side-effecting field inits whose canonical sort flips their order are reported but NOT auto-reordered. */
	public function testSideEffectingFieldInitNotFixed(): Void {
		final src: String = 'class C { private static final A = mk(); public static final B = mk(); static function mk():Int { return 1; } }';
		Assert.isTrue(violations(src).length > 0);
		Assert.equals(0, edits(src).length);
	}

	/** A field that reads a sibling declared before it, where the sort would flip them, is reported but NOT auto-reordered. */
	public function testSiblingRefFieldInitNotFixed(): Void {
		final src: String = 'class C { public function m():Void {} private var y:Int = 0; public var x:Int = y; }';
		Assert.isTrue(violations(src).length > 0);
		Assert.equals(0, edits(src).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('member-order'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('member-order'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { public var x = ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new MemberOrder().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: MemberOrder = new MemberOrder();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
	}

	private function fixedSource(src: String): String {
		final sorted: Array<{ span: Span, text: String }> = edits(src).copy();
		sorted.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in sorted) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

	/** A field init whose CALL reads a sibling (indirect dep) must not be reordered across that sibling. */
	public function testIndirectFieldDepNotFixed(): Void {
		final src: String = 'class C { public function m():Void {} private static var log:Int = 0; public static var first:Int = push(); static function push():Int { return log; } }';
		Assert.isTrue(violations(src).length > 0);
		Assert.equals(0, edits(src).length);
	}

	/** A leading line comment travels WITH its member during the reorder (it is part of the member's slot). */
	public function testLeadingCommentTravelsWithMember(): Void {
		final fixed: String = fixedSource(
			'class C {\n\tpublic function m():Void {}\n\n\t// note about the field\n\tpublic var x:Int = 0;\n}'
		);
		Assert.isTrue(fixed.indexOf('// note about the field') < fixed.indexOf('var x'), 'note still immediately before x: $fixed');
		Assert.isTrue(fixed.indexOf('var x') < fixed.indexOf('function m'), 'field (with its note) moved before the method: $fixed');
	}

	/** A side-effecting static const reorders past INSTANCE fields — independent init phase (the ParseError.backtrack case). */
	public function testCrossPhaseStaticReorders(): Void {
		final src: String = 'class C {\n\tpublic var x:Int = 0;\n\n\tpublic function m():Void {}\n\n\tpublic static final K:Int = make();\n\n\tstatic function make():Int {\n\t\treturn 1;\n\t}\n}';
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('static final K') < fixed.indexOf('var x'), 'static const moved before instance field: $fixed');
	}

}
