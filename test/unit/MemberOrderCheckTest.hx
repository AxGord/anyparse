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

	/** A guarded member reorders into canonical position and stays wrapped in its `#if`. */
	public function testConditionalReordersAndStaysWrapped(): Void {
		final fixed: String = fixedSource('class C {\n\t#if X\n\tpublic function a():Void {}\n\t#end\n\n\tpublic var x:Int = 0;\n}');
		Assert.isTrue(fixed.indexOf('var x') < fixed.indexOf('function a'), 'public field before public method: $fixed');
		Assert.isTrue(fixed.indexOf('#if X') < fixed.indexOf('function a'), 'method still opens its #if: $fixed');
		Assert.isTrue(fixed.indexOf('function a') < fixed.indexOf('#end'), 'method still closed by #end: $fixed');
		Assert.isTrue(parses(fixed), 'rebuilt output parses: $fixed');
	}

	/** A `#if X` nested in another `#if X` (the Cli shape) collapses to one block — the members stay together. */
	public function testNestedSameConditionCoalesces(): Void {
		final fixed: String = fixedSource(
			'class C {\n\t#if SYS\n\tpublic function a():Void {}\n\n\t#if SYS\n\tpublic function b():Void {}\n\t#end\n\t#end\n\n\tpublic var x:Int = 0;\n}'
		);
		final between: String = fixed.substring(fixed.indexOf('function a'), fixed.indexOf('function b'));
		Assert.isTrue(between.indexOf('#if') < 0 && between.indexOf('#end') < 0, 'a and b share one coalesced #if SYS block: $fixed');
		Assert.isTrue(fixed.indexOf('var x') < fixed.indexOf('function a'), 'field moved before the methods: $fixed');
		Assert.isTrue(parses(fixed), 'rebuilt output parses: $fixed');
	}

	/** Differently-guarded nesting flattens to a parenthesised conjunction the grammar's `#if` accepts. */
	public function testNestedDifferentConditionConjunction(): Void {
		final fixed: String = fixedSource(
			'class C {\n\t#if A\n\tpublic function a():Void {}\n\n\t#if B\n\tpublic function b():Void {}\n\t#end\n\t#end\n\n\tpublic var x:Int = 0;\n}'
		);
		Assert.isTrue(fixed.indexOf('#if ((A) && (B))') >= 0, 'nested different conds become a parenthesised conjunction: $fixed');
		Assert.isTrue(fixed.indexOf('((A) && (B))') < fixed.indexOf('function b'), 'b is under the conjunction: $fixed');
		Assert.isTrue(parses(fixed), 'rebuilt output parses through the grammar #if: $fixed');
	}

	/** A conditional with an `#else` is flagged but NOT auto-reordered (v1 cannot split then/else bodies). */
	public function testConditionalElseBailsNotFixed(): Void {
		final src: String = 'class C {\n\t#if X\n\tpublic function a():Void {}\n\t#else\n\tpublic function b():Void {}\n\t#end\n\n\tpublic var x:Int = 0;\n}';
		Assert.isTrue(violations(src).length > 0);
		Assert.equals(0, edits(src).length);
	}

	/** An orphan comment stranded between a member and its `#end` (no member to absorb it) bails the reorder. */
	public function testConditionalOrphanCommentBails(): Void {
		final src: String = 'class C {\n\t#if A\n\tpublic function a():Void {}\n\t// orphan in block\n\t#end\n\n\tpublic var x:Int = 0;\n}';
		Assert.isTrue(violations(src).length > 0);
		Assert.equals(0, edits(src).length);
	}

	/** A doc comment written before a member's `#if` (the Cli pattern) moves inside the regenerated `#if`, with its member. */
	public function testLeadDocBeforeIfTravels(): Void {
		final fixed: String = fixedSource(
			'class C {\n\t/** docs for r */\n\t#if SYS\n\tpublic function r():Void {}\n\t#end\n\n\tpublic var x:Int = 0;\n}'
		);
		Assert.isTrue(fixed.indexOf('var x') < fixed.indexOf('#if SYS'), 'field reordered before the #if block: $fixed');
		Assert.isTrue(fixed.indexOf('#if SYS') < fixed.indexOf('docs for r'), 'doc moved inside the #if: $fixed');
		Assert.isTrue(fixed.indexOf('docs for r') < fixed.indexOf('function r'), 'doc still immediately before its member: $fixed');
		Assert.isTrue(parses(fixed), 'rebuilt output parses: $fixed');
	}

	/**
	 * An `#else` branch is an ALTERNATIVE, not a successor: a private helper at
	 * the end of the `#if` branch followed by a public method in the `#else`
	 * branch must not read as public-after-private (the FmtSliceTest false flag).
	 */
	public function testElseBranchResetsOrder(): Void {
		final src: String = 'class C {\n\t#if (sys || nodejs)\n\tpublic function real():Void {}\n'
			+ '\tprivate static function fixture():Int { return 1; }\n' + '\t#else\n' + '\tpublic function stub():Void {}\n' + '\t#end\n'
			+ '}';
		Assert.equals(0, violations(src).length);
	}

	/** Disorder WITHIN one conditional branch is still flagged. */
	public function testDisorderInsideBranchStillFlagged(): Void {
		final src: String = 'class C {\n\t#if (sys || nodejs)\n\tprivate static function fixture():Int { return 1; }\n'
			+ '\tpublic function real():Void {}\n' + '\t#end\n' + '}';
		Assert.equals(1, violations(src).length);
	}

	/** (a) A member-level `abstract` modifier must travel WITH its bodyless decl during reorder - never migrate onto a neighbour or strand as an orphan line. */
	public function testAbstractModifierTravelsWithMember(): Void {
		final src: String = 'abstract class C {\n\tpublic function m():Void {}\n\tabstract public function area():Float;\n\tpublic var x:Int;\n}';
		final fixed: String = fixedSource(src);
		Assert.isTrue(parses(fixed), 'reordered output parses: $fixed');
		final areaLine: Null<String> = memberLine(fixed, 'area');
		final mLine: Null<String> = memberLine(fixed, 'function m');
		Assert.isTrue(areaLine != null && areaLine.indexOf('abstract') >= 0, 'abstract stays attached to area: $fixed');
		Assert.isTrue(mLine != null && mLine.indexOf('abstract') < 0, 'm never gains a stray abstract: $fixed');
		Assert.isFalse(
			Lambda.exists(fixed.split('\n'), line -> StringTools.trim(line) == 'abstract'), 'no orphaned bare abstract line: $fixed'
		);
	}

	/** (b) A `@:access` / `@:meta` on its own line above a member must MOVE WITH that member during reorder, staying immediately before it. */
	public function testMetaCallTravelsWithMember(): Void {
		final src: String = 'class C {\n\t@:access(Bar.secret)\n\tpublic function useSecret():Void {}\n\tpublic var x:Int;\n}';
		final fixed: String = fixedSource(src);
		Assert.isTrue(parses(fixed), 'reordered output parses: $fixed');
		final varx: Int = fixed.indexOf('var x');
		final meta: Int = fixed.indexOf('@:access');
		final use: Int = fixed.indexOf('useSecret');
		Assert.isTrue(varx < meta, 'field reordered before the annotated method: $fixed');
		Assert.isTrue(meta < use && fixed.substring(meta, use).indexOf('var ') < 0, '@:access stays immediately before useSecret: $fixed');
	}

	/** (c) Fixer output must be checker-canonical: a class with abstract accessors + a public abstract method must be flag-free after ONE fix pass. */
	public function testAbstractAccessorFixConverges(): Void {
		final src: String = 'abstract class C {\n\tpublic var x:Int;\n\tpublic function new() {}\n'
			+ '\tabstract function get_x():Int;\n\tabstract function set_x(v:Int):Int;\n'
			+ '\tfunction handler():Void {}\n\tabstract public function process():Void;\n}';
		Assert.isTrue(violations(src).length > 0, 'initial disorder flagged');
		final fixed: String = fixedSource(src);
		Assert.isTrue(parses(fixed), 'reordered output parses: $fixed');
		// The public abstract method keeps its `abstract`; the private handler never gains one.
		final procLine: Null<String> = memberLine(fixed, 'process');
		Assert.isTrue(procLine != null && procLine.indexOf('abstract') >= 0, 'process keeps its abstract modifier: $fixed');
		final handlerLine: Null<String> = memberLine(fixed, 'handler');
		Assert.isTrue(handlerLine != null && handlerLine.indexOf('abstract') < 0, 'handler never gains a stray abstract: $fixed');
		// Fixer output is checker-canonical: no violation and no further edits on a second pass.
		Assert.equals(0, violations(fixed).length, 'no violation after one fix pass (converges): $fixed');
		Assert.equals(0, edits(fixed).length, 'second pass emits zero edits: $fixed');
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

	/** Whether `src` parses — used to assert a conditional-reorder rebuild round-trips through the parse gate `canonicalize` applies (which `fixedSource`'s raw splice skips). */
	private function parses(src: String): Bool {
		return try {
			new HaxeQueryPlugin().parseFile(src);
			true;
		} catch (exception: haxe.Exception) false;
	}


	/**
	 * The single member line containing `needle`, or null - lets an assertion
	 * inspect one member's own modifiers without the class header's `abstract`
	 * keyword or a sibling member polluting a naive whole-source substring scan.
	 */
	private function memberLine(src: String, needle: String): Null<String>
		return Lambda.find(src.split('\n'), line -> line.indexOf(needle) >= 0);

}
