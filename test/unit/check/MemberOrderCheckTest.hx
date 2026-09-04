package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.MemberOrder;
import anyparse.check.MemberSpacing;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

using StringTools;
using Lambda;

/**
 * The `member-order` check: a type whose members are not in canonical order
 * (constants, properties, fields, constructor, accessors, instance methods, static methods; public before private) is flagged
 * `Info` and `--fix` reorders them. Reordering bails when a field initializer is side-effecting or reads a sibling field in a way the sort would reverse - counting only flips with INITIALIZED fields, since an init-less field runs no code in the init phase. Within one rank `inline` members sort first, then initialized fields before init-less ones.
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
		final src: String =
			'class C { private static final A = mk(); public static final B = mk(); static function mk():Int { return 1; } }';
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
		final src: String = 'class C { public function m():Void {} '
			+ 'private static var log:Int = 0; public static var first:Int = push(); static function push():Int { return log; } }';
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
		final src: String = 'class C {\n\tpublic var x:Int = 0;\n\n\tpublic function m():Void {}\n\n\tpublic static final K:Int = make();\n'
			+ '\n\tstatic function make():Int {\n\t\treturn 1;\n\t}\n}';
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
			'class C {\n\t#if SYS\n\tpublic function a():Void {}\n\n\t#if SYS\n\tpublic function b():Void {}\n\t#end\n\t#end\n\n'
			+ '\tpublic var x:Int = 0;\n}'
		);
		final between: String = fixed.substring(fixed.indexOf('function a'), fixed.indexOf('function b'));
		Assert.isTrue(between.indexOf('#if') < 0 && between.indexOf('#end') < 0, 'a and b share one coalesced #if SYS block: $fixed');
		Assert.isTrue(fixed.indexOf('var x') < fixed.indexOf('function a'), 'field moved before the methods: $fixed');
		Assert.isTrue(parses(fixed), 'rebuilt output parses: $fixed');
	}

	/** Differently-guarded nesting flattens to a parenthesised conjunction the grammar's `#if` accepts. */
	public function testNestedDifferentConditionConjunction(): Void {
		final fixed: String = fixedSource(
			'class C {\n\t#if A\n\tpublic function a():Void {}\n\n\t#if B\n\tpublic function b():Void {}\n\t#end\n\t#end\n\n'
			+ '\tpublic var x:Int = 0;\n}'
		);
		Assert.isTrue(fixed.indexOf('#if ((A) && (B))') >= 0, 'nested different conds become a parenthesised conjunction: $fixed');
		Assert.isTrue(fixed.indexOf('((A) && (B))') < fixed.indexOf('function b'), 'b is under the conjunction: $fixed');
		Assert.isTrue(parses(fixed), 'rebuilt output parses through the grammar #if: $fixed');
	}

	/** A branched conditional travels to its section end as ONE unit - the `#else` is regenerated, not flattened away. */
	public function testConditionalElseBlockMovesToSectionEnd(): Void {
		final src: String = 'class C {\n\t#if X\n\tpublic function a():Void {}\n\t#else\n\tpublic function b():Void {}\n\t#end\n\n'
			+ '\tpublic var x:Int = 0;\n}';
		Assert.isTrue(violations(src).length > 0);
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('var x') < fixed.indexOf('#if X'), 'the field moved ahead of the whole guarded block: $fixed');
		Assert.isTrue(fixed.indexOf('function a') < fixed.indexOf('#else'), 'then-branch member stays in the then branch: $fixed');
		Assert.isTrue(fixed.indexOf('#else') < fixed.indexOf('function b'), 'else-branch member stays in the else branch: $fixed');
		Assert.isTrue(parses(fixed), 'parses: $fixed');
		Assert.equals(0, violations(canonicalizedFix(src)).length, 'converges: $fixed');
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
		final src: String = 'class C {\n\t#if (sys || nodejs)\n\tpublic function real():Void {}\n\n'
			+ '\tprivate static function fixture():Int { return 1; }\n\t#else\n\tpublic function stub():Void {}\n\t#end\n}';
		Assert.equals(0, violations(src).length);
	}

	/** Disorder WITHIN one conditional branch is still flagged. */
	public function testDisorderInsideBranchStillFlagged(): Void {
		final src: String = 'class C {\n\t#if (sys || nodejs)\n\tprivate static function fixture():Int { return 1; }\n'
			+ '\tpublic function real():Void {}\n\t#end\n}';
		Assert.equals(1, violations(src).length);
	}

	/** (a) A member-level `abstract` modifier must travel WITH its bodyless decl during reorder - never migrate onto a neighbour or strand as an orphan line. */
	public function testAbstractModifierTravelsWithMember(): Void {
		final src: String =
			'abstract class C {\n\tpublic function m():Void {}\n\tabstract public function area():Float;\n\tpublic var x:Int;\n}';
		final fixed: String = fixedSource(src);
		Assert.isTrue(parses(fixed), 'reordered output parses: $fixed');
		final areaLine: Null<String> = memberLine(fixed, 'area');
		final mLine: Null<String> = memberLine(fixed, 'function m');
		Assert.isTrue(areaLine != null && areaLine.indexOf('abstract') >= 0, 'abstract stays attached to area: $fixed');
		Assert.isTrue(mLine != null && mLine.indexOf('abstract') < 0, 'm never gains a stray abstract: $fixed');
		Assert.isFalse(fixed.split('\n').exists(line -> StringTools.trim(line) == 'abstract'), 'no orphaned bare abstract line: $fixed');
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
		final src: String = 'abstract class C {\n\tpublic var x:Int;\n\tpublic function new() {}\n\tabstract function get_x():Int;\n'
			+ '\tabstract function set_x(v:Int):Int;\n\tfunction handler():Void {}\n\tabstract public function process():Void;\n}';
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

	/** Property fields sub-split: read-only prop, then getter prop, then plain var - each rank group blank-separated after the fix. */
	public function testPropertyRankOrder(): Void {
		final src: String = 'class C {\n\tpublic var s:Bool;\n\tpublic var r(default, null):Int;\n\tpublic var i(get, never):Int;\n}';
		Assert.equals(1, violations(src).length, 'property fields out of order flagged');
		final fixed: String = fixedSource(src);
		Assert.equals('class C {\n\tpublic var r(default, null):Int;\n\npublic var i(get, never):Int;\n\npublic var s:Bool;\n}', fixed);
		Assert.equals(0, violations(fixed).length, 'fix converges: $fixed');
	}

	/** Property fields sort before `final`, which sorts before plain `var`. */
	public function testPropertiesBeforeFinalBeforeVar(): Void {
		final src: String = 'class C {\n\tpublic var v:Int;\n\tpublic final f:Int = 0;\n\tpublic var g(get, never):Int;\n'
			+ '\tpublic var ro(default, null):Int;\n}';
		Assert.equals(
			'class C {\n\tpublic var ro(default, null):Int;\n\npublic var g(get, never):Int;\n\npublic final f:Int = 0;\n\n'
			+ 'public var v:Int;\n}',
			fixedSource(src)
		);
	}

	/** Canonical order but no blank between a property group and the var group is flagged; the fix inserts exactly one blank. */
	public function testMissingGroupBlankFlagged(): Void {
		final src: String = 'class C {\n\tpublic var ro(default, null):Int;\n\tpublic var v:Int;\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length, 'missing group blank flagged');
		Assert.equals('rank groups are not separated by a blank line', vs[0].message);
		final fixed: String = fixedSource(src);
		Assert.equals('class C {\n\tpublic var ro(default, null):Int;\n\npublic var v:Int;\n}', fixed);
		Assert.equals(0, violations(fixed).length, 'fix converges: $fixed');
	}

	/** A stray blank line within one rank group is flagged; the fix removes it. */
	public function testStrayBlankWithinGroupFlagged(): Void {
		final src: String = 'class C {\n\tpublic var a:Int;\n\n\tpublic var b:Int;\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length, 'stray blank within group flagged');
		Assert.equals('members of one rank group are separated by a blank line', vs[0].message);
		final fixed: String = fixedSource(src);
		Assert.equals('class C {\n\tpublic var a:Int;\npublic var b:Int;\n}', fixed);
		Assert.equals(0, violations(fixed).length, 'fix converges: $fixed');
	}

	/** A blank line before a same-rank member's doc comment is allowed - not flagged as a stray blank. */
	public function testBlankBeforeDocCommentAllowed(): Void {
		final src: String = 'class C {\n\tpublic var a:Int;\n\n\t/** doc */\n\tpublic var b:Int;\n}';
		Assert.equals(0, violations(src).length, 'blank before doc comment not flagged');
	}

	/** An unrelated reorder keeps a same-rank field's leading doc and its blank line. */
	public function testReorderKeepsDocBlank(): Void {
		final src: String = 'class C {\n\tpublic function m():Void {}\n\tpublic var a:Int;\n\n\t/** doc */\n\tpublic var b:Int;\n}';
		Assert.equals(
			'class C {\n\tpublic var a:Int;\n\n\t/** doc */\n\tpublic var b:Int;\n\npublic function m():Void {}\n}', fixedSource(src)
		);
	}

	/** A stray `;` between out-of-order members forces the fallback slot-swap: members reorder, the `;` is not deleted. */
	public function testStraySemicolonGuard(): Void {
		final src: String = 'class C {\n\tpublic function m():Void {}\n\t;\n\tpublic var x:Int = 0;\n}';
		Assert.equals('class C {\n\tpublic var x:Int = 0;\n\t;\n\tpublic function m():Void {}\n}', fixedSource(src));
	}

	/** Private symmetry: a private getter-property sorts before a private final field. */
	public function testPrivateGetterBeforePrivateFinal(): Void {
		final src: String = 'class C {\n\tprivate final pf:Int = 0;\n\tprivate var pg(get, never):Int;\n}';
		Assert.equals('class C {\n\tprivate var pg(get, never):Int;\n\nprivate final pf:Int = 0;\n}', fixedSource(src));
	}

	/** Regression: a plain-field-only class (no properties) in canonical order and spacing still passes. */
	public function testPlainFieldsCanonicalStillPasses(): Void {
		final src: String = 'class C {\n\tpublic var a:Int = 0;\n\n\tprivate var b:Int = 0;\n\n\tpublic function m():Void {}\n}';
		Assert.equals(0, violations(src).length);
	}

	/** A blank line after a doc-commented same-rank PREDECESSOR is allowed - the writer itself inserts it, so flagging it could never converge. */
	public function testBlankAfterDocPredecessorAllowed(): Void {
		final src: String = 'class C {\n\t/** doc */\n\tpublic static final A:Int = 0;\n\n\tpublic static final B:Int = 0;\n}';
		Assert.equals(0, violations(src).length);
	}

	/** A reorder involving a doc-commented member converges through the PRODUCTION canonicalization: the writer re-inserts the blank after the doc-commented slot, and the check must accept it. */
	public function testDocPredecessorFixConvergesCanonical(): Void {
		final src: String = 'class C {\n\tpublic function m():Void {}\n\n\t/** doc */\n\tpublic static final A:Int = 0;\n\n'
			+ '\tpublic static final B:Int = 0;\n}';
		Assert.isTrue(violations(src).length > 0, 'order violation flagged');
		final fixed: String = canonicalizedFix(src);
		Assert.equals(0, violations(fixed).length, 'converges through writeRoundTrip: $fixed');
	}

	/** The stray-`;` slot-swap fallback converges through the PRODUCTION canonicalization: the check skips spacing on such a container instead of flagging what the fixer will never normalize. */
	public function testStraySemicolonFixConvergesCanonical(): Void {
		final src: String = 'class C {\n\tpublic function m():Void {}\n\t;\n\tpublic var x:Int = 0;\n}';
		Assert.isTrue(violations(src).length > 0, 'order violation flagged');
		final fixed: String = canonicalizedFix(src);
		Assert.equals(0, violations(fixed).length, 'converges through writeRoundTrip: $fixed');
	}

	/** Two `#if X` field blocks (a final and a var, split by plain fields) merge into ONE block at the field-section end, final before var, blank-separated. */
	public function testConditionalFieldBlockMergesFinalThenVar(): Void {
		final src: String = 'class C {\n\tpublic final a:Int = 0;\n\n\t#if X\n\tprivate final g1:Int = 0;\n\t#end\n\n'
			+ '\tprivate var b:Int = 0;\n\n\t#if X\n\tprivate var g2:Int = 0;\n\t#end\n\n\tpublic function new() {}\n}';
		Assert.isTrue(violations(src).length > 0, 'unmerged conditional blocks flagged');
		final fixed: String = fixedSource(src);
		final between: String = fixed.substring(fixed.indexOf('g1'), fixed.indexOf('g2'));
		Assert.isTrue(between.indexOf('#end') < 0 && between.indexOf('#if') < 0, 'g1 and g2 share one #if X block: $fixed');
		Assert.isTrue(fixed.indexOf('g1') < fixed.indexOf('g2'), 'final g1 before var g2: $fixed');
		Assert.isTrue(fixed.indexOf('b:Int') < fixed.indexOf('#if X'), 'plain fields before the conditional block: $fixed');
		Assert.isTrue(fixed.indexOf('#end') < fixed.indexOf('function new'), 'block closed before the constructor: $fixed');
		Assert.isTrue(parses(fixed), 'rebuilt parses: $fixed');
		Assert.equals(0, violations(canonicalizedFix(src)).length, 'converges: $fixed');
	}

	/** Two distinct conditions form two SEPARATE `#if` blocks at the section end, ordered by first occurrence, each blank-separated. */
	public function testTwoDistinctConditionBlocks(): Void {
		final src: String = 'class C {\n\t#if A\n\tpublic function fa():Void {}\n\t#end\n\n\t#if B\n\tpublic function fb():Void {}\n'
			+ '\t#end\n\n\tpublic var x:Int = 0;\n}';
		Assert.isTrue(violations(src).length > 0, 'field-after-methods flagged');
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('x:Int') < fixed.indexOf('#if A'), 'field before the conditional method blocks: $fixed');
		Assert.isTrue(fixed.indexOf('#if A') < fixed.indexOf('#if B'), 'block A before block B (first occurrence): $fixed');
		Assert.isTrue(fixed.indexOf('fa') < fixed.indexOf('fb'), 'fa before fb: $fixed');
		final between: String = fixed.substring(fixed.indexOf('fa'), fixed.indexOf('fb'));
		Assert.isTrue(between.indexOf('#end') >= 0 && between.indexOf('#if B') >= 0, 'fa and fb stay in SEPARATE blocks: $fixed');
		Assert.isTrue(parses(fixed), 'parses: $fixed');
		Assert.equals(0, violations(canonicalizedFix(src)).length, 'converges: $fixed');
	}

	/**
	 * A conditional block with an `#else` between member slots is exempt from the new grouping - the whole container bails, the block never moves.
	 * A guarded method mixed among plain methods moves to the END of the methods section (unconditional methods first).
	 */
	public function testGuardedMethodsGoToMethodsSectionEnd(): Void {
		final src: String = 'class C {\n\tpublic var x:Int = 0;\n\n\t#if DEBUG\n\tpublic function dbg():Void {}\n\t#end\n\n'
			+ '\tpublic function a():Void {}\n\n\tpublic function b():Void {}\n}';
		Assert.isTrue(violations(src).length > 0, 'conditional method before plain methods flagged');
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('function a') < fixed.indexOf('#if DEBUG'), 'plain methods before the conditional block: $fixed');
		Assert.isTrue(fixed.indexOf('function b') < fixed.indexOf('function dbg'), 'both plain methods before the guarded one: $fixed');
		Assert.isTrue(parses(fixed), 'parses: $fixed');
		Assert.equals(0, violations(canonicalizedFix(src)).length, 'converges: $fixed');
	}

	/** A member-level `#end` abutting the constructor (no blank line) is flagged; the fix sets the block off with a blank after `#end`. */
	public function testGuardedFieldBeforeCtorSpacing(): Void {
		final src: String = 'class C {\n\t#if X\n\tvar g:Int = 0;\n\t#end\n\tpublic function new() {}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length, 'missing blank after #end flagged');
		Assert.isTrue(vs[0].message.indexOf('#end') >= 0, 'directive-spacing message: ${vs[0].message}');
		Assert.equals(0, violations(canonicalizedFix(src)).length, 'converges through writeRoundTrip');
	}

	/** A member-level `#if` opening right after a plain member (no blank line) is flagged; the fix inserts the blank before `#if`. */
	public function testGuardedBlockAfterFieldSpacing(): Void {
		final src: String = 'class C {\n\tpublic var x:Int = 0;\n\t#if X\n\tpublic function m():Void {}\n\t#end\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length, 'missing blank before #if flagged');
		Assert.isTrue(vs[0].message.indexOf('#if') >= 0, 'directive-spacing message: ${vs[0].message}');
		Assert.equals(0, violations(canonicalizedFix(src)).length, 'converges through writeRoundTrip');
	}

	/**
	 * A reorder-unsafe container (the side-effecting `final` init would flip past
	 * the `var` fields) degrades to spacing-only edits: the missing blank line
	 * between the rank groups is inserted, the order stays untouched, and the fix
	 * applied to its own output emits nothing - the order finding remains as a
	 * report-only advisory.
	 */
	public function testUnsafeReorderDegradesToSpacingOnly(): Void {
		final src: String = 'class C {\n\tpublic var a:Int = 0;\n\tpublic var b:Int;\n\tpublic final t:T = new T();\n\n'
			+ '\tpublic function new() {\n\t\ta = 0;\n\t}\n}';
		assertOrderAdvisoryOnly(violations(src));
		Assert.equals(
			'class C {\n\tpublic var a:Int = 0;\n\tpublic var b:Int;\n\n\tpublic final t:T = new T();\n\n\tpublic function new() {\n'
			+ '\t\ta = 0;\n\t}\n}',
			fixedSource(src)
		);
		final fixed: String = canonicalizedFix(src);
		Assert.equals(0, edits(fixed).length, 'fix applied to its own output emits no edits: $fixed');
		assertOrderAdvisoryOnly(violations(fixed));
	}

	/**
	 * The spacing-only fallback also collapses a stray blank line WITHIN a rank
	 * group while inserting the missing one between groups - both arms of the
	 * spacing policy apply over the original member order.
	 */
	public function testUnsafeReorderCollapsesStrayBlankWithinGroup(): Void {
		final src: String = 'class C {\n\tpublic var a:Int = 0;\n\n\tpublic var b:Int;\n\tpublic final t:T = new T();\n\n'
			+ '\tpublic function new() {\n\t\ta = 0;\n\t}\n}';
		assertOrderAdvisoryOnly(violations(src));
		Assert.equals(
			'class C {\n\tpublic var a:Int = 0;\n\tpublic var b:Int;\n\n\tpublic final t:T = new T();\n\n\tpublic function new() {\n'
			+ '\t\ta = 0;\n\t}\n}',
			fixedSource(src)
		);
	}

	/**
	 * The spacing-only fallback honours the `spacingDisabled` guard: a
	 * non-conditional container with non-whitespace in an inter-slot gap (a stray
	 * `;`) gets NO spacing edits when the reorder bails - the check's spacing rule
	 * is disabled there too, so such an edit could never converge.
	 */
	public function testUnsafeReorderStrayGapEmitsNoSpacingEdits(): Void {
		final src: String = 'class C {\n\tpublic var a:Int = 0;\n\t;\n\tpublic var b:Int;\n\tpublic final t:T = new T();\n\n'
			+ '\tpublic function new() {\n\t\ta = 0;\n\t}\n}';
		assertOrderAdvisoryOnly(violations(src));
		Assert.equals(0, edits(src).length);
	}

	/**
	 * A reorder-unsafe container (the guarded `new` field would flip past the
	 * trailing `var`) whose single-member `#if` block lacks its surrounding blank
	 * lines degrades to spacing-only edits that STILL set the `#if`/`#end` block
	 * off with a blank line before it and after it; the order stays a report-only
	 * advisory and the fix converges on its own output (the CheckBox shape).
	 */
	public function testUnsafeReorderSpacesConditionalBlock(): Void {
		final src: String = 'class C {\n\tprivate final b:S = new S();\n\t#if !mobile\n\tprivate final h:S = new S();\n\t#end\n'
			+ '\tprivate var ht:Float = 0;\n}';
		assertOrderAdvisoryOnly(violations(src));
		Assert.equals(
			'class C {\n\tprivate final b:S = new S();\n\n\t#if !mobile\n\tprivate final h:S = new S();\n\t#end\n\n'
			+ '\tprivate var ht:Float = 0;\n}',
			fixedSource(src)
		);
		final fixed: String = canonicalizedFix(src);
		Assert.equals(0, edits(fixed).length, 'fix applied to its own output emits no edits: $fixed');
		assertOrderAdvisoryOnly(violations(fixed));
	}

	/**
	 * With the opt-in `movableArglessNew` option a field whose initializer is a pure argless
	 * `new T()` becomes order-movable: the `final t = new T()` reorders ahead of the `var`
	 * fields it belongs before, instead of degrading to spacing-only. Reordered output parses
	 * and converges through the production canonicalization.
	 */
	public function testMovableArglessNewReordersUnderOption(): Void {
		final src: String = 'class C {\n\tpublic var a:Int = 0;\n\tpublic var b:Int;\n\tpublic final t:T = new T();\n\n'
			+ '\tpublic function new() {\n\t\ta = 0;\n\t}\n}';
		final fixed: String = fixedSource(src, movableArglessNewResolver());
		Assert.isTrue(fixed.indexOf('final t') < fixed.indexOf('var a'), 'argless-new final moved before the vars: $fixed');
		Assert.isTrue(parses(fixed), 'reordered output parses: $fixed');
		Assert.equals(0, violations(canonicalizedFix(src, movableArglessNewResolver())).length, 'converges through writeRoundTrip: $fixed');
	}

	/**
	 * Option OFF (the default) is byte-identical to the pre-option behaviour: the same
	 * `final t = new T()` container degrades to spacing-only edits, its order untouched.
	 */
	public function testMovableArglessNewOffByteIdentical(): Void {
		final src: String = 'class C {\n\tpublic var a:Int = 0;\n\tpublic var b:Int;\n\tpublic final t:T = new T();\n\n'
			+ '\tpublic function new() {\n\t\ta = 0;\n\t}\n}';
		Assert.equals(
			'class C {\n\tpublic var a:Int = 0;\n\tpublic var b:Int;\n\n\tpublic final t:T = new T();\n\n\tpublic function new() {\n'
			+ '\t\ta = 0;\n\t}\n}',
			fixedSource(src)
		);
	}

	/** An argful `new T(0)` initializer stays blocking even with the option on - only ZERO-argument allocations are movable. */
	public function testArgfulNewStillBlocksUnderOption(): Void {
		final src: String =
			'class C {\n\tpublic var a:Int = 0;\n\tpublic var b:Int;\n\tpublic final t:T = new T(0);\n\n\tpublic function new() {}\n}';
		assertOrderAdvisoryOnly(violations(src));
		final fixed: String = fixedSource(src, movableArglessNewResolver());
		Assert.isTrue(fixed.indexOf('var b') < fixed.indexOf('final t'), 'argful new NOT moved before the vars: $fixed');
	}

	/**
	 * A `new T(a)` whose argument references a sibling field keeps blocking under the option -
	 * the whole init expression references a class-bound ident, so it is not a pure allocation.
	 */
	public function testFieldReferencingNewStillBlocksUnderOption(): Void {
		final src: String =
			'class C {\n\tpublic var a:Int = 0;\n\tpublic var b:Int;\n\tpublic final t:T = new T(a);\n\n\tpublic function new() {}\n}';
		assertOrderAdvisoryOnly(violations(src));
		final fixed: String = fixedSource(src, movableArglessNewResolver());
		Assert.isTrue(fixed.indexOf('var b') < fixed.indexOf('final t'), 'field-referencing new NOT moved before the vars: $fixed');
	}

	/** The option does not relax the sibling-read guard: a non-`new` init reading a sibling field still blocks. */
	public function testSiblingReadStillBlocksUnderOption(): Void {
		final src: String = 'class C { public function m():Void {} private var y:Int = 0; public var x:Int = y; }';
		Assert.isTrue(violations(src).length > 0);
		Assert.equals(0, edits(src, movableArglessNewResolver()).length, 'sibling-referencing init still blocks under the option');
	}

	/**
	 * A single-member `#if` block wrapping an argless-`new` field moves atomically with its
	 * guard under the option: the unconditional argless-new final sorts ahead of the plain
	 * `var`, and the guarded one moves to the section end still wrapped in its `#if`.
	 */
	public function testConditionalArglessNewReordersUnderOption(): Void {
		final src: String =
			'class C {\n\tprivate final b:S = new S();\n\t#if !mobile\n\tprivate final h:S = new S();\n\t#end\n\tprivate var ht:Float;\n}';
		final fixed: String = fixedSource(src, movableArglessNewResolver());
		Assert.isTrue(fixed.indexOf('final b') < fixed.indexOf('var ht'), 'unconditional final before the var: $fixed');
		Assert.isTrue(fixed.indexOf('var ht') < fixed.indexOf('#if !mobile'), 'guarded final moved to the section end: $fixed');
		Assert.isTrue(fixed.indexOf('#if !mobile') < fixed.indexOf('final h'), 'guarded final still opens its #if: $fixed');
		Assert.isTrue(parses(fixed), 'parses: $fixed');
		Assert.equals(0, violations(canonicalizedFix(src, movableArglessNewResolver())).length, 'converges: $fixed');
	}

	/** A static const (immutable) directly followed by a static var (mutable) is a rank boundary: the missing blank is flagged and the fix inserts exactly one. */
	public function testStaticImmutableBeforeStaticMutableBlank(): Void {
		final src: String = 'class C {\n\tpublic static final A:Int = 0;\n\tpublic static var b:Int;\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length, 'const-to-var missing blank flagged');
		Assert.equals('rank groups are not separated by a blank line', vs[0].message);
		Assert.equals('class C {\n\tpublic static final A:Int = 0;\n\npublic static var b:Int;\n}', fixedSource(src));
		Assert.equals(0, violations(fixedSource(src)).length, 'fix converges');
	}

	/** Two same-rank static consts stay free - grouping within a rank is the author's, no blank demanded. */
	public function testStaticSameRankNoBlank(): Void {
		Assert.equals(0, violations('class C {\n\tpublic static final A:Int = 0;\n\tpublic static final B:Int = 0;\n}').length);
	}

	/** The reorder path emits rank boundaries too: a static var before a static const reorders after it, blank-separated. */
	public function testStaticVarReordersAfterConstWithBlank(): Void {
		final src: String = 'class C {\n\tprivate static var v:Float = 30;\n\tprivate static final A:Float = 1;\n}';
		Assert.isTrue(violations(src).length > 0, 'var-before-const flagged');
		Assert.equals('class C {\n\tprivate static final A:Float = 1;\n\nprivate static var v:Float = 30;\n}', fixedSource(src));
	}

	/** A rank boundary coinciding with a member-level #if composes to ONE blank, not two (spacing bails cross-condition; directive spacing owns the gap). */
	public function testStaticRankConditionalComposesNoDoubleBlank(): Void {
		final src: String = 'class C {\n\tpublic static final A:Int = 0;\n\t#if X\n\tpublic static var b:Int;\n\t#end\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length, 'missing blank before #if flagged');
		Assert.isTrue(vs[0].message.indexOf('#if') >= 0, 'directive-spacing message: ${vs[0].message}');
		final fixed: String = canonicalizedFix(src);
		Assert.isTrue(fixed.indexOf('\n\n\n') < 0, 'no double blank at the composed boundary: $fixed');
		Assert.equals(0, violations(fixed).length, 'converges through writeRoundTrip');
	}

	/** The static-rank spacing fix converges through the production canonicalization (writeRoundTrip re-indents, the check accepts the result). */
	public function testStaticRankSpacingConvergesCanonical(): Void {
		final src: String = 'class C {\n\tpublic static final A:Int = 0;\n\tpublic static var b:Int;\n}';
		Assert.isTrue(violations(src).length > 0, 'boundary flagged');
		Assert.equals(0, violations(canonicalizedFix(src)).length, 'converges through writeRoundTrip');
	}

	/**
	 * A conditional with an `#else` reorders like any other guarded block: the whole
	 * `#if`/`#else`/`#end` travels to its section end with each branch keeping its own
	 * members - the branch a member was declared in is part of its identity, not a
	 * detail the projection may flatten away.
	 */
	public function testConditionalElseReorders(): Void {
		final src: String =
			'class C {\n\tpublic function m():Void {}\n\n\t#if X\n\tpublic var a:Int = 0;\n\t#else\n\tpublic var b:Int = 0;\n\t#end\n}';
		Assert.isTrue(violations(src).length > 0, 'field-after-method flagged');
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('#if X') < fixed.indexOf('function m'), 'the guarded field block moved before the method: $fixed');
		Assert.isTrue(fixed.indexOf('var a') < fixed.indexOf('#else'), 'then-branch member stays in the then branch: $fixed');
		Assert.isTrue(fixed.indexOf('#else') < fixed.indexOf('var b'), 'else-branch member stays in the else branch: $fixed');
		Assert.isTrue(parses(fixed), 'parses: $fixed');
	}

	/**
	 * The `APIRequest2` shape: one `#else` mid-class must not degrade the whole container to
	 * spraying rank-group blank lines over the ORIGINAL order. With alternating ranks
	 * (var, readonly-prop, var) that fallback separates every neighbour and shreds the class.
	 */
	public function testElseContainerGroupsAlternatingRanks(): Void {
		final src: String = 'class C {\n\tpublic var url:String;\n\tpublic var httpMethod(default, null):String;\n'
			+ '\tpublic var data:Dynamic;\n\n\t#if X\n\tpublic var loader:Int;\n\t#else\n\tpublic var loader:String;\n\t#end\n}';
		Assert.isTrue(violations(src).length > 0, 'alternating ranks flagged');
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('httpMethod') < fixed.indexOf('url'), 'the readonly property leads the field section: $fixed');
		Assert.isTrue(fixed.indexOf('url') < fixed.indexOf('#if X'), 'plain vars grouped before the guarded block: $fixed');
		final vars: String = fixed.substring(fixed.indexOf('url'), fixed.indexOf('data'));
		Assert.isTrue(vars.indexOf('\n\n') < 0, 'the two plain vars are one tight group, not blank-separated: $fixed');
		Assert.isTrue(parses(fixed), 'parses: $fixed');
	}

	/** Three branches (`#if` / `#elseif` / `#else`, the IAPStore shape) all survive the move, each directive regenerated in order. */
	public function testElseIfBranchesReorder(): Void {
		final src: String = 'class C {\n\tpublic function m():Void {}\n\n\t#if ios\n\tstatic final K:String = "a";\n'
			+ '\t#elseif android\n\tstatic final K:String = "b";\n\t#else\n\tstatic final K:String = "c";\n\t#end\n}';
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('#if ios') < fixed.indexOf('function m'), 'the const block moved ahead of the method: $fixed');
		Assert.isTrue(fixed.indexOf('"a"') < fixed.indexOf('#elseif android'), 'first branch keeps its member: $fixed');
		Assert.isTrue(fixed.indexOf('#elseif android') < fixed.indexOf('"b"'), 'second branch keeps its member: $fixed');
		final tail: Int = fixed.indexOf('#else', fixed.indexOf('#elseif android') + 1);
		Assert.isTrue(fixed.indexOf('"b"') < tail, 'the #else opens after the #elseif branch: $fixed');
		Assert.isTrue(tail < fixed.indexOf('"c"'), 'third branch keeps its member: $fixed');
		Assert.isTrue(parses(fixed), 'parses: $fixed');
		Assert.equals(0, violations(canonicalizedFix(src)).length, 'converges: $fixed');
	}

	/** A conditional NESTED inside a branch is not modelled - the construct is refused and the container keeps its order. */
	public function testNestedConditionalInsideBranchBails(): Void {
		final src: String = 'class C {\n\tpublic function m():Void {}\n\n\t#if X\n\t#if Y\n\tpublic var a:Int = 0;\n\t#end\n\t#else\n'
			+ '\tpublic var b:Int = 0;\n\t#end\n}';
		Assert.isTrue(violations(src).length > 0, 'field-after-method still flagged');
		Assert.equals(0, edits(src).length, 'nested conditional inside a branch bails');
	}

	/**
	 * A construct whose branches land in DIFFERENT sections is refused: moving it would have to
	 * split one `#if` into two, or emit a branch with no members. Both stay out of scope.
	 */
	public function testElseSpanningTwoSectionsSplits(): Void {
		final src: String = 'class C {\n\tpublic function m():Void {}\n\n\t#if X\n\tpublic var a:Int = 0;\n\t#else\n'
			+ '\tpublic function b():Void {}\n\t#end\n}';
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('var a') < fixed.indexOf('function m'), 'the guarded FIELD leads, in its own block: $fixed');
		Assert.isTrue(fixed.indexOf('function m') < fixed.indexOf('function b'), 'the guarded METHOD trails the plain one: $fixed');
		final second: Int = fixed.indexOf('#if X', fixed.indexOf('#if X') + 1);
		Assert.isTrue(second > 0, 'the construct became TWO blocks, one per section: $fixed');
		Assert.isTrue(
			fixed.indexOf('#else') > second, 'only the method block needs the #else - the field block has no else member: $fixed'
		);
		Assert.isTrue(parses(fixed), 'parses: $fixed');
	}

	/** A construct whose FIRST branch is empty is refused - its directive sits between an outside member and an inside one. */
	public function testEmptyLeadingBranchReorders(): Void {
		final src: String =
			'class C {\n\tpublic function m():Void {}\n\n\t#if X\n\t#else\n\tpublic var b:Int = 0;\n\t#end\n\n\tpublic final x:Int = 0;\n}';
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('final x') < fixed.indexOf('#if X'), 'the higher-ranked field leads: $fixed');
		Assert.isTrue(
			fixed.indexOf('#if X') < fixed.indexOf('#else'), 'the empty then-branch is re-emitted as the author wrote it: $fixed'
		);
		Assert.isTrue(fixed.indexOf('#else') < fixed.indexOf('var b'), 'the member stays in the else branch: $fixed');
		Assert.isTrue(fixed.indexOf('var b') < fixed.indexOf('function m'), 'the guarded field precedes the method: $fixed');
		Assert.isTrue(parses(fixed), 'parses: $fixed');
	}

	/**
	 * An expression-bodied member whose node span the parser stretches over the trailing trivia
	 * (a body that is an `if`, measured on this grammar) must not swallow the NEXT member's doc
	 * comment. Two slots would then OVERLAP, and every consumer reads that wrong: the gap scan
	 * reports the swallowed comment as a non-whitespace gap (`String.substring` swaps reversed
	 * bounds), which routes the container to the in-place swap path, where two overlapping edits
	 * splice into text that does not parse - `src/pony/db/mysql/haxe/MySQL.hx` on the Pony tree.
	 */
	public function testAbsorbedTrailingDocKeepsSlotsDisjoint(): Void {
		final src: String = 'class C {\n\tprivate function init(r: Bool): Void if (r) trace(1);\n\n\t/**\n\t * Close.\n\t */\n'
			+ '\tpublic function destroy(): Void {\n\t\ttrace(2);\n\t}\n\n}';
		final fixed: String = fixedSource(src);
		Assert.isTrue(parses(fixed), 'the rebuilt region parses: $fixed');
		Assert.isTrue(fixed.indexOf('function destroy') < fixed.indexOf('function init'), 'the public method leads: $fixed');
		Assert.isTrue(fixed.indexOf('Close.') < fixed.indexOf('function destroy'), 'the doc travelled WITH destroy: $fixed');
		Assert.equals(1, fixed.split('Close.').length - 1, 'the doc was not duplicated into the moved slot: $fixed');
	}

	/**
	 * A type whose interface carries `@:autoBuild` keeps the relative order of its ANNOTATED
	 * members. Pony's `DeclaratorBuilder` turns `@:arg` fields into constructor PARAMETERS in
	 * declaration order, so swapping two of them rewrites the signature for every caller with no
	 * error at the declaration - the container degrades to spacing-only and the finding stays
	 * report-only. The gate needs the lint SCOPE: with no `index` the sort still runs, which the
	 * second half asserts so the two paths cannot be confused.
	 */
	public function testMacroBuiltTypeKeepsAnnotatedOrder(): Void {
		final src: String =
			'class C implements Declarator {\n\n\t@:arg private var updateSignal: Int;\n\n\t@:arg public var time: Int = 0;\n\n}';
		Assert.isTrue(violations(src).length > 0, 'the container is flagged either way');
		final gated: String = fixedWithBuildMacroIndex(src);
		Assert.isTrue(gated.indexOf('updateSignal') < gated.indexOf('time'), 'the two `@:arg` fields kept their order: $gated');
		final ungated: String = fixedSource(src);
		Assert.isTrue(ungated.indexOf('time') < ungated.indexOf('updateSignal'), 'without the index the sort still flips them: $ungated');
	}

	/**
	 * A NESTED `#if` whose members span two sections keeps its container's order. `groupKey` carries
	 * the section, so such a construct becomes two blocks: the guarded fields lift out of the region
	 * their author wrote, away from the method that uses them, and the nested condition is re-derived
	 * as a conjunct at the new site (`#if !openfl` inside `#if !macro` re-emitted as
	 * `#if ((!macro) && (!openfl))` - `src/pony/flash/FLTools.hx` on the Pony tree). Members in
	 * different BRANCHES of one construct are mutually exclusive and keep splitting, which
	 * `testElseSpanningTwoSectionsSplits` pins.
	 */
	public function testCoexistingRegionSpanningSectionsKeepsOrder(): Void {
		final src: String = 'class C {\n\tpublic function m(): Void {}\n\n\t#if A\n\tpublic function a(): Void {}\n\n'
			+ '\t#if B\n\tprivate static var t: Int;\n\n\tpublic static function u(): Void t = 1;\n\t#end\n\t#end\n}';
		Assert.isTrue(violations(src).length > 0, 'the container is still flagged - the finding is report-only');
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('#if ((A) && (B))') < 0, 'the nested condition was not re-derived: $fixed');
		Assert.isTrue(
			fixed.indexOf('function m') < fixed.indexOf('var t'), 'the guarded field was not lifted into the field section: $fixed'
		);
		Assert.isTrue(fixed.indexOf('var t') < fixed.indexOf('function u'), 'the field stayed next to its user: $fixed');
		Assert.isTrue(parses(fixed), 'parses: $fixed');
	}

	/**
	 * An `@:meta` run written on the line before a member-level `#if` belongs to NO member slot -
	 * `collectInto` reads the modifier flags before the guard and resets them across it, and
	 * `absorbLeadDoc` absorbs comments only - so a rebuild regenerating the region from slots plus
	 * directives drops the annotation outright, silently (two `@SuppressWarnings` lines deleted from
	 * Pony's `tools/src/module/Module.hx`, one from `src/pony/ui/xml/HeapsXmlUi.hx`, both still
	 * parsing). The container degrades to spacing-only instead.
	 */
	public function testMetaAboveConditionalSurvives(): Void {
		final src: String = 'class C {\n\tpublic function m(): Void {}\n\n\t@:noCompletion\n\t#if A\n\tpublic var a: Int = 0;\n\t#end\n}';
		Assert.isTrue(violations(src).length > 0, 'the container is still flagged - the finding is report-only');
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('@:noCompletion') >= 0, 'the annotation survives the pass: $fixed');
		Assert.isTrue(parses(fixed), 'parses: $fixed');
	}

	/**
	 * A member's OWN body may hold `#if` / `#else`; those lines sit inside the enclosing
	 * construct's span but are not branch boundaries. Counting them shifts every later member
	 * into a branch that does not exist and the rebuild emits source that no longer parses.
	 */
	public function testElseInMethodBodyIsNotABranch(): Void {
		final src: String = 'class C {\n\tpublic var x:Int = 0;\n\n\t#if X\n\tpublic function a():Void {\n\t\t#if Y\n\t\ttrace(1);\n'
			+ '\t\t#else\n\t\ttrace(2);\n\t\t#end\n\t}\n\t#else\n\tpublic function b():Void {}\n\t#end\n\n\tpublic function c():Void {}\n}';
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('function c') < fixed.indexOf('#if X'), 'the plain method moved ahead of the guarded block: $fixed');
		final outerElse: Int = fixed.indexOf('#else', fixed.indexOf('trace(2)'));
		Assert.isTrue(fixed.indexOf('function a') < outerElse, 'a stays in the then branch: $fixed');
		Assert.isTrue(outerElse < fixed.indexOf('function b'), 'b stays in the else branch: $fixed');
		Assert.isTrue(parses(fixed), 'parses - counting the body directives as branches breaks the rebuild: $fixed');
	}

	/**
	 * A doc written above a BRANCHED `#if` describes the whole construct - every branch declares
	 * the same symbol - so it stays above the regenerated `#if`. Absorbing it inside, the way an
	 * unbranched block's lead doc travels in (`testLeadDocBeforeIfTravels`), would leave it
	 * documenting the then-branch alone and every other branch undocumented.
	 */
	public function testLeadDocStaysAboveBranchedIf(): Void {
		final src: String = 'class C {\n\tpublic function m():Void {}\n\n\t/** the pad */\n\t#if mobile\n'
			+ '\tstatic inline final PAD:Int = 8;\n\t#else\n\tstatic inline final PAD:Int = 1;\n\t#end\n}';
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('the pad') < fixed.indexOf('#if mobile'), 'the doc stays above the #if: $fixed');
		Assert.isTrue(fixed.indexOf('#if mobile') < fixed.indexOf('PAD:Int = 8'), 'the then-branch member is still inside: $fixed');
		Assert.isTrue(fixed.indexOf('#if mobile') < fixed.indexOf('function m'), 'the const block moved ahead of the method: $fixed');
		Assert.isTrue(parses(fixed), 'parses: $fixed');
		Assert.equals(0, violations(canonicalizedFix(src)).length, 'converges: $fixed');
	}

	/**
	 * A conditional block whose members all carry ONE rank sorts AT that rank among the plain
	 * members of its section instead of trailing everything: the guarded `public var` (rank 7)
	 * lands after the `public final` (rank 6) and before the `private var` (rank 11) it
	 * outranks - the `Main.iapStore` shape - still wrapped in its own `#if`.
	 */
	public function testSingleRankConditionalBlockSortsByContent(): Void {
		final src: String = contentRankedBlockSource();
		Assert.isTrue(violations(src).length > 0, 'the guarded field out of rank order is flagged');
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('var s') < fixed.indexOf('final a'), 'the static var still leads: $fixed');
		Assert.isTrue(fixed.indexOf('final a') < fixed.indexOf('#if'), 'the public final precedes the guarded block: $fixed');
		Assert.isTrue(fixed.indexOf('#if') < fixed.indexOf('private var p'), 'the guarded block precedes the private var: $fixed');
		Assert.isTrue(fixed.indexOf('iap') < fixed.indexOf('#end'), 'the guarded field stays inside its #if: $fixed');
		Assert.isTrue(parses(fixed), 'rebuilt output parses: $fixed');
		Assert.equals(0, violations(canonicalizedFix(src)).length, 'converges: $fixed');
	}

	/**
	 * A conditional block whose members span MORE than one rank stays PINNED at its section
	 * end: content ranking never splits a construct, so atomicity wins and the block keeps its
	 * pre-existing placement behind every unconditional field, sorting only internally.
	 */
	public function testMixedRankConditionalBlockStaysPinned(): Void {
		final src: String = 'class C {\n\tpublic final a:S;\n\n\t#if X\n\tpublic var g:Int = 0;\n\n\tprivate var h:Int = 0;\n'
			+ '\t#end\n\n\tprivate var p:Int = 0;\n}';
		Assert.isTrue(violations(src).length > 0, 'the private var before the guarded block is flagged');
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('private var p') < fixed.indexOf('#if X'), 'the mixed-rank block stays at the section end: $fixed');
		Assert.isTrue(fixed.indexOf('var g') < fixed.indexOf('var h'), 'the block still sorts internally: $fixed');
		Assert.isTrue(parses(fixed), 'rebuilt output parses: $fixed');
		Assert.equals(0, violations(canonicalizedFix(src)).length, 'converges: $fixed');
	}

	public function testInlineConditionalBlockLeadsInitializedField(): Void {
		final src: String = 'class C {\n\tpublic static inline final A:Int = 1;\n\n\tpublic static final n:N = new N();\n'
			+ '\n\t#if release\n\tpublic static inline final U:Int = 1;\n\t#else\n\tpublic static inline final U:Int = 2;\n\t#end\n}';
		Assert.isTrue(violations(src).length > 0, 'the guarded inline constants below the initialized field are flagged');
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('#if release') < fixed.indexOf('final A'), 'the inline block leads the plain constants: $fixed');
		Assert.isTrue(fixed.indexOf('final A') < fixed.indexOf('final n'), 'the plain constant still leads the initialized field: $fixed');
		Assert.isTrue(fixed.indexOf('final U') < fixed.indexOf('#end'), 'the constants stay inside their branches: $fixed');
		Assert.isTrue(parses(fixed), 'rebuilt output parses: $fixed');
		Assert.equals(0, violations(canonicalizedFix(src)).length, 'converges: $fixed');
	}

	public function testMixedInlineConditionalBlockTrailsRank(): Void {
		final src: String = 'class C {\n\tpublic static inline final A:Int = 1;\n\n\t#if release\n\tpublic static inline final U:Int = 1;\n'
			+ '\n\tpublic static final V:Int = 2;\n\t#end\n\n\tpublic static final n:Int = 3;\n}';
		Assert.isTrue(violations(src).length > 0, 'the block mixing inline and non-inline members above the plain field is flagged');
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('final n') < fixed.indexOf('#if release'), 'the block of mixed inline-ness trails its rank: $fixed');
		Assert.isTrue(fixed.indexOf('final U') < fixed.indexOf('final V'), 'the block still sorts internally: $fixed');
		Assert.isTrue(parses(fixed), 'rebuilt output parses: $fixed');
		Assert.equals(0, violations(canonicalizedFix(src)).length, 'converges: $fixed');
	}

	public function testInlineConditionalMethodBlockStillTrailsRank(): Void {
		final src: String = 'class C {\n\t#if X\n\tpublic inline function g():Void {}\n\t#end\n\n\tpublic function f():Void {}\n}';
		Assert.isTrue(violations(src).length > 0, 'the guarded method block above the plain method is flagged');
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('function f') < fixed.indexOf('#if X'), 'an inline METHOD block still trails its rank: $fixed');
		Assert.isTrue(parses(fixed), 'rebuilt output parses: $fixed');
		Assert.equals(0, violations(canonicalizedFix(src)).length, 'converges: $fixed');
	}

	/**
	 * A guarded static whose initializer READS a sibling static keeps its block pinned. Without the
	 * gate the block would earn rank 1 and outrank `base` (rank 3), and the whole container would
	 * then degrade to spacing-only - `hasSiblingReadFlip` catches the flip the ranking introduced -
	 * so the unconditional `K` would never reach the top and the finding would never converge. The
	 * discriminating assertions are therefore the const lift and the convergence, not the pin: with
	 * the gate reverted `base` still precedes the `#if`, because nothing is reordered at all.
	 */
	public function testDependentStaticConditionalBlockStaysPinned(): Void {
		final src: String = 'class C {\n\tprivate static var base:Int = 1;\n\n\t#if X\n\tpublic static var derived:Int = base;\n'
			+ '\t#end\n\n\tpublic static final K:Int = 0;\n}';
		Assert.isTrue(violations(src).length > 0, 'the static const after the vars is flagged');
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('static final K') < fixed.indexOf('base:Int'), 'the unconditional const still leads: $fixed');
		Assert.isTrue(fixed.indexOf('base:Int') < fixed.indexOf('#if X'), 'the dependent block stays pinned: $fixed');
		Assert.isTrue(parses(fixed), 'rebuilt output parses: $fixed');
		Assert.equals(0, violations(canonicalizedFix(src)).length, 'converges: $fixed');
	}

	/**
	 * Opaque content inside a conditional region - a stray `;`, which projects as
	 * `EmptySemiMember` and is no collected member - pins the block AND bails the reorder: the
	 * rebuild regenerates the region from member slots and directives only, so those bytes
	 * would be dropped. The order finding stays a report-only advisory.
	 */
	public function testOpaqueConditionalContentPinsAndBails(): Void {
		final src: String =
			'class C {\n\tpublic final a:S;\n\n\t#if X\n\tpublic var g:Int = 0;\n\t;\n\t#end\n\n\tprivate var p:Int = 0;\n}';
		assertOrderAdvisoryOnly(violations(src));
		Assert.equals(0, edits(src).length, 'the reorder bails rather than dropping the stray semicolon');
	}

	/** The content-ranked reorder is a FIXED POINT: its own canonicalized output yields no further edits and no further findings. */
	public function testContentRankedBlockFixIsIdempotent(): Void {
		final fixed: String = canonicalizedFix(contentRankedBlockSource());
		Assert.equals(0, edits(fixed).length, 'second pass emits zero edits: $fixed');
		Assert.equals(0, violations(fixed).length, 'second pass reports nothing: $fixed');
	}

	/**
	 * A block moved into the MIDDLE of a rank region keeps the directive-spacing policy:
	 * exactly one blank line before its `#if` and exactly one after its `#end`, never two.
	 */
	@:access(anyparse.check.MemberOrder)
	public function testMovedBlockKeepsSingleBlankLines(): Void {
		final fixed: String = canonicalizedFix(contentRankedBlockSource());
		Assert.isTrue(fixed.indexOf('\n\n\n') < 0, 'no double blank anywhere: $fixed');
		Assert.equals(
			1, MemberSpacing.blankLineCount(fixed.substring(fixed.indexOf('final a'), fixed.indexOf('#if'))),
			'one blank before #if: $fixed'
		);
		Assert.equals(
			1, MemberSpacing.blankLineCount(fixed.substring(fixed.indexOf('#end'), fixed.indexOf('private var p'))),
			'one blank after #end: $fixed'
		);
	}

	/**
	 * A note on the `#end` line pins the block and bails the reorder. The conditional region
	 * ends right after `#end`, so that comment sits OUTSIDE it: moving the block would leave
	 * the note where it is and re-attach it to whichever member ends up last - the rebuild
	 * replaces the whole member region, not the comment after it.
	 */
	public function testEndLineCommentPinsAndBails(): Void {
		final src: String = 'class C {\n\tpublic static var s:Int = 0;\n\n\tpublic final a:S;\n\n\tprivate var p:Int = 0;\n'
			+ '\n\t#if (mobile || APPSTORE)\n\tpublic var iap:I;\n\t#end // trailing note\n}';
		Assert.equals(0, violations(src).length, 'the pinned block leaves the container canonical: $src');
		Assert.equals(0, edits(src).length, 'no edit can strand the note');
	}

	/**
	 * A note on a DIRECTIVE line pins the block too: the rebuild re-emits `#if` / `#else` from the
	 * recorded condition and branch shape alone, so the note would have nowhere to go. The pin
	 * (assertion 1) is what this gate buys - the edit assertion is belt-and-braces, held up by
	 * `hasOrphanComment` even with the gate reverted.
	 */
	public function testDirectiveLineCommentPinsBlock(): Void {
		final src: String =
			'class C {\n\tpublic final a:S;\n\n\tprivate var p:Int = 0;\n\n\t#if X // why\n\tpublic var g:Int = 0;\n\t#end\n}';
		Assert.equals(0, violations(src).length, 'the pinned block leaves the container canonical: $src');
		Assert.equals(0, edits(src).length, 'no edit can drop the note');
	}

	/**
	 * One condition guarding BOTH a field and a method splits into one block per section, and
	 * each is ranked on its own: the guarded field sorts among the instance fields while the
	 * guarded method sorts among the methods. Keying blocks without the section would merge the
	 * two into one mixed-rank bucket and pin both - the `#if mobile` fields plus `#if mobile`
	 * methods shape, which is the common one.
	 */
	public function testSameConditionFieldAndMethodBlocksRankSeparately(): Void {
		final src: String = 'class C {\n\tpublic final a:S;\n\n\tprivate var p:Int = 0;\n\n\t#if X\n\tpublic var g:Int = 0;\n\t#end\n'
			+ '\n\tpublic function m():Void {}\n\n\t#if X\n\tpublic function r():Void {}\n\t#end\n}';
		Assert.isTrue(violations(src).length > 0, 'the guarded field behind the private var is flagged');
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('var g') < fixed.indexOf('private var p'), 'the guarded field outranks the private var: $fixed');
		Assert.isTrue(fixed.indexOf('private var p') < fixed.indexOf('function m'), 'the fields still precede the methods: $fixed');
		Assert.isTrue(fixed.indexOf('function m') < fixed.indexOf('function r'), 'the guarded method trails the plain one: $fixed');
		Assert.isTrue(parses(fixed), 'rebuilt output parses: $fixed');
		Assert.equals(0, violations(canonicalizedFix(src)).length, 'converges: $fixed');
	}

	/**
	 * An unconditional initializer that READS a field inside the block pins it: the gate refuses in
	 * both directions, since moving the block past that initializer changes what it sees. The pin
	 * (assertion 1) is what this gate buys - the edit assertion is belt-and-braces, held up by
	 * `hasSiblingReadFlip` even with the gate reverted.
	 */
	public function testOutsideInitReadingBlockFieldPinsBlock(): Void {
		final src: String =
			'class C {\n\tprivate static var uses:Int = guarded;\n\n\t#if X\n\tpublic static var guarded:Int = 5;\n\t#end\n}';
		Assert.equals(0, violations(src).length, 'the pinned block leaves the container canonical: $src');
		Assert.equals(0, edits(src).length, 'no edit can reverse the read');
	}

	/** A side-effecting init whose only sort flips are with fields that have NO initializer reorders — an init-less field runs no code in the init phase. */
	public function testSideEffectFlipWithUninitFieldReorders(): Void {
		final src: String = 'class C { private var b:Float; private final s:Foo = new Foo(1); }';
		Assert.isTrue(violations(src).length > 0);
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('final s') < fixed.indexOf('var b'), 'side-effecting final moved above the init-less var: $fixed');
	}

	/** A side-effecting init still refuses to flip with an INITIALIZED same-phase field — only init-less fields are exempt. */
	public function testSideEffectFlipWithInitializedFieldStillBails(): Void {
		final src: String = 'class C { private var b:Float = 0; private final s:Foo = new Foo(1); }';
		Assert.isTrue(violations(src).length > 0);
		Assert.equals(0, edits(src).length);
	}

	/** Within one rank an initialized field sorts above an init-less one. */
	public function testInitializedFieldFirstWithinRank(): Void {
		final src: String = 'class C { private final a:Int; private final b:Int = 1; }';
		Assert.equals(1, violations(src).length);
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('final b') < fixed.indexOf('final a'), 'initialized final above the init-less one: $fixed');
	}

	/** Initialized-before-init-less within a rank is canonical — not flagged. */
	public function testInitializedFirstCanonicalNotFlagged(): Void {
		Assert.equals(0, violations('class C { private final b:Int = 1; private final a:Int; }').length);
	}

	/** Within one method rank an `inline` member sorts above a non-inline one. */
	public function testInlineMethodFirstWithinRank(): Void {
		final src: String = 'class C { function m():Void {} inline function i():Void {} }';
		Assert.equals(1, violations(src).length);
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('function i') < fixed.indexOf('function m'), 'inline method above the plain one: $fixed');
	}

	/** Inline-before-plain within a rank is canonical — not flagged. */
	public function testInlineFirstCanonicalNotFlagged(): Void {
		Assert.equals(0, violations('class C { inline function i():Void {} function m():Void {} }').length);
	}

	/** A static inline constant sorts above its non-inline same-rank sibling. */
	public function testStaticInlineConstFirstWithinRank(): Void {
		final fixed: String = fixedSource('class C { static final A:Int = 1; static inline final B:Int = 2; }');
		Assert.isTrue(fixed.indexOf('final B') < fixed.indexOf('final A'), 'inline const above the plain one: $fixed');
	}

	/** Accessor pairs keep source order — the inline sub-key must not tear a non-inline getter from its inline setter. */
	public function testAccessorPairNotSplitByInline(): Void {
		final src: String =
			'class C { public var x(get, set):Int; function get_x():Int { return 0; } inline function set_x(v:Int):Int { return v; } }';
		Assert.equals(0, violations(src).length);
	}

	/** The Cropping11Popup shape: a side-effecting final flips only with init-less members; the fix converges canonical. */
	public function testUninitFlipFixConvergesCanonical(): Void {
		final src: String = 'class C {\n\tprivate final a:Int;\n\n\tprivate var b:Float;\n\n\tprivate final s:Foo = new Foo(1);\n'
			+ '\tprivate final c:Point;\n}';
		final fixed: String = canonicalizedFix(src);
		Assert.equals(0, violations(fixed).length, 'converges: $fixed');
		Assert.isTrue(fixed.indexOf('final s') < fixed.indexOf('final a'), 'initialized final leads its rank: $fixed');
		Assert.isTrue(fixed.indexOf('final c') < fixed.indexOf('var b'), 'vars after finals: $fixed');
	}

	/** A sibling read of an INLINE constant is compile-time folded — the reader reorders across it freely (the ShareControl shape). */
	public function testSiblingReadOfInlineConstantReorders(): Void {
		final src: String = 'class C { private static inline final P:Int = 16; public static inline final W:Int = (116 + P) * 2; }';
		Assert.equals(1, violations(src).length);
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('final W') < fixed.indexOf('final P'), 'reader moved above the inline constant it reads: $fixed');
	}

	/** A side-effecting init crosses an INLINE constant freely — the constant is folded at compile time, no runtime flip exists. */
	public function testSideEffectFlipWithInlineConstantReorders(): Void {
		final src: String = 'class C { private static final _log:L = Logger.get(); private static inline final MAX:Int = 10; }';
		Assert.equals(1, violations(src).length);
		final fixed: String = fixedSource(src);
		Assert.isTrue(
			fixed.indexOf('final MAX') < fixed.indexOf('final _log'), 'inline constant moved above the side-effecting init: $fixed'
		);
	}

	/** A textual read of an INIT-LESS sibling is no order dependency — the sibling runs no init code, the reader sees the default either way. */
	public function testSiblingReadOfUninitFieldReorders(): Void {
		final src: String = 'class C { private static var total:Int; private static var seed:Int = f(total); }';
		Assert.equals(1, violations(src).length);
		final fixed: String = fixedSource(src);
		Assert.isTrue(
			fixed.indexOf('var seed') < fixed.indexOf('var total'), 'initialized reader moved above the init-less field it reads: $fixed'
		);
	}

	/**
	 * The reorder is a PERMUTATION of the whole member list, so one misplaced member rewrites
	 * every member between it and its slot. On `Cli.hx` that turned ONE `info` finding into an
	 * 812-line diff, which S11 and S49 each reverted by hand. Past `MAX_RELOCATED_LINES` the fix
	 * now emits the spacing part only and leaves the order alone; the finding is still reported,
	 * so nothing is hidden — only the 800-line rewrite is declined.
	 */
	public function testAnOversizedRelocationIsDeclined(): Void {
		final src: String = swapWithBody(300);
		Assert.equals(1, violations(src).length, 'the finding is still reported');
		Assert.equals(src, fixedSource(src), 'and the order is left exactly as it was');
	}

	/**
	 * CONTROL: the SAME shape under the budget still reorders. Without this arm the one above
	 * would pass on a fix that had simply stopped working.
	 */
	public function testARelocationUnderTheBudgetStillApplies(): Void {
		final src: String = swapWithBody(3);
		Assert.equals(1, violations(src).length);
		Assert.notEquals(src, fixedSource(src), 'a small reorder is still applied');
	}

	/** The `Main.iapStore` shape: a single-rank guarded `public var` written behind the private instance field it outranks. */
	private inline function contentRankedBlockSource(): String {
		return 'class C {\n\tpublic static var s:Int = 0;\n\n\tpublic final a:S;\n\n\tprivate var p:Int = 0;\n'
			+ '\n\t#if (mobile || APPSTORE)\n\tpublic var iap:I;\n\t#end\n}';
	}

	/**
	 * A class whose FIRST member is a private static method with `body` filler lines and whose
	 * second is a public instance method — canonical order wants them swapped, so the relocated
	 * extent is the big method plus the small one.
	 */
	private function swapWithBody(body: Int): String {
		final filler: String = [for (i in 0...body) '\t\tvar v$i:Int = $i;'].join('\n');
		return 'class C {\n\tprivate static function big():Void {\n$filler\n\t}\n\n\tpublic function small():Void {}\n}\n';
	}

	private function violations(src: String): Array<Violation> {
		final check: MemberOrder = new MemberOrder();
		check.setConfigResolver(emptyConfigResolver());
		return check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String, ?resolve: (String) -> LintConfig): Array<{ span: Span, text: String }> {
		final check: MemberOrder = new MemberOrder();
		check.setConfigResolver(resolve ?? emptyConfigResolver());
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
	}

	private function fixedSource(src: String, ?resolve: (String) -> LintConfig): String {
		return CheckFixture.applyEdits(src, edits(src, resolve));
	}

	/**
	 * `fixedSource` with a `SymbolIndex` whose scope also holds an interface carrying
	 * `@:autoBuild` and implemented by `src`'s type - the shape `transitivelyCarriesBuildMacro`
	 * answers true for, and the only way the build-macro gate can fire (the CLI's fix driver
	 * always passes an index; a direct `check.fix` never does).
	 */
	private function fixedWithBuildMacroIndex(src: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final files: Array<{ file: String, source: String }> = [
			{ file: 'Declarator.hx', source: 'package;\n\n@:autoBuild(B.build())\ninterface Declarator {}\n' },
			{ file: 'C.hx', source: src }
		];
		final check: MemberOrder = new MemberOrder();
		check.setConfigResolver(emptyConfigResolver());
		return CheckFixture.applyEdits(
			src, check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin, SymbolIndex.build(files, plugin))
		);
	}

	/** A config resolver that enables the opt-in `movableArglessNew` member-order option for every file. */
	private function movableArglessNewResolver(): (String) -> LintConfig {
		final cfg: LintConfig = LintConfig.parse('{"rules": {"member-order": {"movableArglessNew": true}}}');
		return _ -> cfg;
	}

	/** A resolver pinning the EMPTY config, so a test run's verdicts cannot depend on an `apqlint.json` discovered from the process cwd. */
	private function emptyConfigResolver(): (String) -> LintConfig {
		final cfg: LintConfig = LintConfig.parse('{}');
		return _ -> cfg;
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
	private function memberLine(src: String, needle: String): Null<String> return src.split('\n').find(line -> line.indexOf(needle) >= 0);

	/**
	 * Apply the check's fix edits and run the result through the production
	 * canonicalization (splice + `writeRoundTrip`) - the seam `fixedSource`'s raw
	 * splice skips, which is exactly where a writer-reinserted blank line can undo
	 * a naive spacing fix.
	 */
	private function canonicalizedFix(src: String, ?resolve: (String) -> LintConfig): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: MemberOrder = new MemberOrder();
		check.setConfigResolver(resolve ?? emptyConfigResolver());
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		return switch CanonicalEdit.canonicalize(src, check.fix(src, vs, plugin), true, plugin) {
			case Ok(text): text;
			case Err(message):
				Assert.fail(message);
				src;
		};
	}

	/**
	 * Asserts `vs` is exactly the one canonical-order Info (the advisory the
	 * spacing-only fallback leaves report-only), with no spacing finding alongside.
	 */
	private function assertOrderAdvisoryOnly(vs: Array<Violation>): Void {
		Assert.equals(1, vs.length);
		Assert.equals('member-order', vs[0].rule);
		Assert.isTrue(
			vs[0].message.startsWith('type member \'') && vs[0].message.contains('is out of canonical order: '),
			'the order advisory names the member and its reason, got: ${vs[0].message}'
		);
	}

}
