package unit;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferArrowCallback;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `prefer-arrow-callback` check: an anonymous `function` literal in call-argument
 * position is flagged `Info` and rewritten to the arrow form. The fix is gated on the
 * type-drift hazard: a type-preserving body shape converts structurally; an open tail
 * (implicit last-expression return) converts only when the callee's parameter signature
 * resolves to a `Void`-returning function type; a return that resolves to a callee type
 * parameter is proven generic and not even reported; an unresolvable callee stays a
 * report-only finding.
 */
class PreferArrowCallbackCheckTest extends Test {

	// ---- structural type-preserving shapes (no resolution needed) ----

	/** A `return expr` expression body converts to the bare-expression arrow. */
	public function testExprBodyFixed(): Void {
		Assert.equals('x -> x + 1', fixText(wrap('take(function(x) return x + 1);')));
	}

	/** A block ending in an explicit `return` pins the type in both forms — converted, multi-statement block kept. */
	public function testReturnTailBlockFixed(): Void {
		Assert.equals('(a, b) -> { trace(a); return a - b; }', fixText(wrap('take(function(a, b) { trace(a); return a - b; });')));
	}

	/** A block holding ONLY a `return expr;` collapses to the bare-expression arrow. */
	public function testSingleReturnCollapses(): Void {
		Assert.equals('(a, b) -> a - b', fixText(wrap('take(function(a, b) { return a - b; });')));
	}

	/** An `if` WITHOUT `else` as the last statement is `Void`-typed — converted without resolving the callee. */
	public function testVoidTailIfFixed(): Void {
		Assert.equals('(x:Int) -> { if (x > 0) go(x); }', fixText(wrap('take(function(x:Int) { if (x > 0) go(x); });')));
	}

	/** An `if`/`else` tail is an expression whose type could drift — unresolvable callee stays report-only. */
	public function testIfElseTailGateRefuses(): Void {
		assertGateRefuses(wrap('take(function(x:Int) { if (x > 0) go(x); else go(0); });'));
	}

	/** An empty body is `Void` in both forms. */
	public function testEmptyBodyFixed(): Void {
		Assert.equals('() -> {}', fixText(wrap('take(function() {});')));
	}

	/** A `:Void` hint over a syntactically-`Void` tail drops as a no-op. */
	public function testHintVoidVoidTailFixed(): Void {
		Assert.equals('() -> { for (i in 0...2) go(i); }', fixText(wrap('take(function():Void { for (i in 0...2) go(i); });')));
	}

	/** A `:Void` hint over an OPEN tail needs the expected type — unresolvable callee stays report-only. */
	public function testHintVoidOpenTailGateRefuses(): Void {
		assertGateRefuses(wrap('take(function():Void { go(0); });'));
	}

	/** An open tail with an unresolvable callee is reported but not fixed. */
	public function testOpenTailUnresolvedGateRefuses(): Void {
		assertGateRefuses(wrap('take(function() { go(0); });'));
	}

	// ---- resolved expected types ----

	/** A bare-identifier callee resolving to a same-class member with a `Void`-returning parameter converts. */
	public function testSameClassMemberResolvedFixed(): Void {
		Assert.equals('() -> go(0)', fixText(hostClass('cb(function() { go(0); });')));
	}

	/** A `this.member(…)` callee resolves the same way. */
	public function testThisMemberResolvedFixed(): Void {
		Assert.equals('() -> go(0)', fixText(hostClass('this.cb(function() { go(0); });')));
	}

	/** The single-expression block collapses and the wrapping call keeps its other arguments. */
	public function testSingleExprCollapses(): Void {
		Assert.equals('() -> go(1)', fixText(hostClass('cb(function() { go(1); });')));
	}

	/** A multi-statement block is kept verbatim behind the arrow. */
	public function testMultiStmtBlockKept(): Void {
		Assert.equals('() -> { go(1); go(2); }', fixText(hostClass('cb(function() { go(1); go(2); });')));
	}

	/** A local `function helper(cb:Void->Void)` callee resolves through its in-tree declaration. */
	public function testLocalFnCalleeResolvedFixed(): Void {
		final src: String = 'class C {\n\tfunction m():Void {\n\t\tfunction helper(cb:Void->Void):Void {}\n'
			+ '\t\thelper(function() { fire(); });\n\t}\n\tfunction fire():Void {}\n}';
		Assert.equals('() -> fire()', fixText(src));
	}

	/** A callee that is a VALUE of function type (`run:(Void->Void)->Void`) resolves through its annotation. */
	public function testValueCalleeResolvedFixed(): Void {
		final src: String =
			'class C {\n\tfunction m(run:(Void->Void)->Void):Void {\n\t\trun(function() { fire(); });\n\t}\n\tfunction fire():Void {}\n}';
		Assert.equals('() -> fire()', fixText(src));
	}

	/** A typed field receiver resolves the member through the supertype chain (indexed, cross-file). */
	public function testReceiverSupertypeChainFixed(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'Disp.hx', source: 'class Disp {\n\tpublic function on(f:Int->Void):Void {}\n}' },
			{ file: 'Sub.hx', source: 'class Sub extends Disp {}' },
			{
				file: 'UseC.hx',
				source: 'class UseC {\n\tvar d:Sub;\n\tfunction m():Void {\n\t\td.on(function(i) { go(i); });\n\t}\n'
					+ '\tfunction go(i:Int):Void {}\n}'
			}
		];
		Assert.equals('i -> go(i)', fixTextIndexed(files, 'UseC.hx'));
	}

	/** A dotted static callee (`pkg.MyTimer.delayX`) resolves through the import path (indexed, cross-file). */
	public function testStaticDottedResolvedFixed(): Void {
		final files: Array<{ file: String, source: String }> = [
			timerFixture(),
			{
				file: 'UseT.hx',
				source: 'class UseT {\n\tfunction m():Void {\n\t\tpkg.MyTimer.delayX(function() { go(); }, 5);\n\t}\n'
					+ '\tfunction go():Void {}\n}'
			}
		];
		Assert.equals('() -> go()', fixTextIndexed(files, 'UseT.hx'));
	}

	/** An IMPORTED simple-name static callee resolves the same way. */
	public function testStaticImportedResolvedFixed(): Void {
		final files: Array<{ file: String, source: String }> = [
			timerFixture(),
			{
				file: 'UseI.hx',
				source: 'import pkg.MyTimer;\n\nclass UseI {\n\tfunction m():Void {\n\t\tMyTimer.delayX(function() { go(); }, 5);\n\t}\n'
					+ '\tfunction go():Void {}\n}'
			}
		];
		Assert.equals('() -> go()', fixTextIndexed(files, 'UseI.hx'));
	}

	/** A constructor argument resolves through the target type's `new` (indexed, cross-file). */
	public function testConstructorResolvedFixed(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'Took.hx', source: 'class Took {\n\tpublic function new(cb:Void->Void) {}\n}' },
			{
				file: 'UseN.hx',
				source: 'class UseN {\n\tfunction m():Void {\n\t\tnew Took(function() { go(); });\n\t}\n\tfunction go():Void {}\n}'
			}
		];
		Assert.equals('() -> go()', fixTextIndexed(files, 'UseN.hx'));
	}

	/** A typedef parameter type hops to its function-type alias (indexed, cross-file). */
	public function testTypedefHopResolvedFixed(): Void {
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'TU.hx',
				source: 'typedef Cb = Void->Void;\n\nclass TU {\n\tpublic static function go2(cb:Cb):Void {}\n}'
			},
			{
				file: 'UseTd.hx',
				source: 'class UseTd {\n\tfunction m():Void {\n\t\tTU.go2(function() { fire(); });\n\t}\n\tfunction fire():Void {}\n}'
			}
		];
		Assert.equals('() -> fire()', fixTextIndexed(files, 'UseTd.hx'));
	}

	/** A declaration fully wrapped in an `#if` region (openfl-style) still yields its member signature. */
	public function testConditionalWrappedDeclResolvedFixed(): Void {
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'Disp2.hx',
				source: '#if !flash\nclass Disp2 {\n\tpublic function on(f:Int->Void):Void {}\n}\n#end'
			},
			{
				file: 'UseC2.hx',
				source: 'class UseC2 {\n\tvar d:Disp2;\n\tfunction m():Void {\n\t\td.on(function(i) { go(i); });\n\t}\n'
					+ '\tfunction go(i:Int):Void {}\n}'
			}
		];
		Assert.equals('i -> go(i)', fixTextIndexed(files, 'UseC2.hx'));
	}

	/** Two same-module declarations (a vendored std fork next to the real one) that AGREE on the verdict still convert. */
	public function testAmbiguousAgreeingCandidatesFixed(): Void {
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'std/haxe/TimerA.hx',
				source: 'package haxe;\n\nclass TimerA {\n\tpublic static function delay(f:Void->Void, t:Int):Void {}\n}'
			},
			{
				file: 'vendor/haxe/TimerA.hx',
				source: 'package haxe;\n\nclass TimerA {\n\tpublic static function delay(f:Void->Void, t:Int):Void {}\n}'
			},
			{
				file: 'UseA.hx',
				source: 'class UseA {\n\tfunction m():Void {\n\t\thaxe.TimerA.delay(function() { go(); }, 5);\n\t}\n'
					+ '\tfunction go():Void {}\n}'
			}
		];
		Assert.equals('() -> go()', fixTextIndexed(files, 'UseA.hx'));
	}

	/** Two candidates that DISAGREE (one generic, one `Void`) stay report-only. */
	public function testAmbiguousDisagreeingCandidatesGateRefuses(): Void {
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'std/haxe/TimerB.hx',
				source: 'package haxe;\n\nclass TimerB {\n\tpublic static function delay<S>(f:Void->S, t:Int):Void {}\n}'
			},
			{
				file: 'vendor/haxe/TimerB.hx',
				source: 'package haxe;\n\nclass TimerB {\n\tpublic static function delay(f:Void->Void, t:Int):Void {}\n}'
			},
			{
				file: 'UseB.hx',
				source: 'class UseB {\n\tfunction m():Void {\n\t\thaxe.TimerB.delay(function() { go(); }, 5);\n\t}\n'
					+ '\tfunction go():Void {}\n}'
			}
		];
		Assert.equals(1, violationsMulti(files, 'UseB.hx').length);
		Assert.equals('<0 edits>', fixTextIndexed(files, 'UseB.hx'));
	}

	/** A `final class` declaration (a `FinalDecl` wrapper around the class node) still resolves cross-file. */
	public function testFinalClassCtorResolvedFixed(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'TookF.hx', source: 'final class TookF {\n\tpublic function new(cb:()->Void) {}\n}' },
			{
				file: 'UseF.hx',
				source: 'class UseF {\n\tfunction m():Void {\n\t\tnew TookF(function():Void { go(); });\n\t}\n\tfunction go():Void {}\n}'
			}
		];
		Assert.equals('() -> go()', fixTextIndexed(files, 'UseF.hx'));
	}

	/** A `throw` tail is NOT type-preserving (arrow infers an open monomorph) — unresolvable callee stays report-only. */
	public function testThrowTailGateRefuses(): Void {
		assertGateRefuses(wrap("take(function() { throw 'boom'; });"));
	}

	/** A `throw` tail still converts when the callee resolves to a `Void`-returning parameter. */
	public function testThrowTailResolvedFixed(): Void {
		Assert.equals("() -> { throw 'boom'; }", fixText(hostClass("cb(function() { throw 'boom'; });")));
	}

	/** A `return;` tail is type-preserving — converted without resolving the callee. */
	public function testVoidReturnTailFixed(): Void {
		Assert.equals('() -> { go(0); return; }', fixText(wrap('take(function() { go(0); return; });')));
	}

	/** A `new T<Int>(…)` type argument is not an argument — the constructor still resolves. */
	public function testCtorTypeArgNominalFixed(): Void {
		Assert.equals('() -> go()', fixTextIndexed(genericCtorFixture('new TookG<Int>(function() { go(); });'), 'UseGN.hx'));
	}

	/** A `new T<Void->Void>(…)` FUNCTION-TYPE type argument (an `Arrow` child) must not shift the argument index. */
	public function testCtorTypeArgFnTypeFixed(): Void {
		Assert.equals('() -> go()', fixTextIndexed(genericCtorFixture('new TookG<Void->Void>(function() { go(); });'), 'UseGN.hx'));
	}

	/** A `macro { … }` reification subtree is opaque — its code splices into a different context, never flagged. */
	public function testMacroReificationSkipped(): Void {
		final src: String = 'class C {\n\tstatic function build():Dynamic {\n\t\treturn macro { cb(function() { fire(); }); };\n\t}\n'
			+ '\tstatic function cb(f:Void->Void):Void {}\n\tstatic function fire():Void {}\n}';
		Assert.equals(0, violations(src).length);
	}

	/** A generic callee whose short name hides inside a modifier keyword (`n` in `function`) is still proven generic — silent. */
	public function testGenericShortNameSilent(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'G.hx', source: 'class G {\n\tpublic static function n<S>(f:Void->S):Void {}\n}' },
			{
				file: 'UseGS.hx',
				source: 'class UseGS {\n\tfunction m():Void {\n\t\tG.n(function() { go(); });\n\t}\n\tfunction go():Void {}\n}'
			}
		];
		Assert.equals(0, violationsMulti(files, 'UseGS.hx').length);
	}

	/** A callback in a LATER argument slot resolves to the right parameter. */
	public function testSecondArgResolvedFixed(): Void {
		final src: String = 'class C {\n\tfunction m():Void {\n\t\tcb2(1, function(x:Int) { go(x); });\n\t}\n'
			+ '\tfunction cb2(a:Int, f:Int->Void):Void {}\n\tfunction go(i:Int):Void {}\n}';
		Assert.equals('(x:Int) -> go(x)', fixText(src));
	}

	/** A safe-navigation callee (`d?.on(…)`) resolves like a plain member access. */
	public function testSafeNavCalleeResolvedFixed(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'DispS.hx', source: 'class DispS {\n\tpublic function on(f:Int->Void):Void {}\n}' },
			{
				file: 'UseS.hx',
				source: 'class UseS {\n\tvar d:Null<DispS>;\n\tfunction m():Void {\n\t\td?.on(function(i) { go(i); });\n\t}\n'
					+ '\tfunction go(i:Int):Void {}\n}'
			}
		];
		Assert.equals('i -> go(i)', fixTextIndexed(files, 'UseS.hx'));
	}

	/** A non-`Void` return hint is dropped when the expected return resolves to `Void` (any return unifies with it). */
	public function testNonVoidHintResolvedFixed(): Void {
		Assert.equals('() -> 1', fixText(hostClass('cb(function():Int { return 1; });')));
	}

	// ---- the body carried whole ----

	/** An ASSIGNMENT expression body converts WHOLE — the arrow drops the `function` syntax, never the operand. */
	public function testAssignmentExprBodyFixed(): Void {
		final src: String = 'class C {\n\tfunction m():Void {\n\t\tvar v:String;\n\t\tsink(function(r) v = r);\n\t}\n'
			+ '\tfunction sink(f:String->Void):Void {}\n}';
		Assert.equals('r -> v = r', fixText(src));
	}

	/** A call body carrying arguments the literal never declared converts WHOLE — this rule never eta-reduces. */
	public function testExtraArgumentCallBodyFixed(): Void {
		final src: String = 'class C {\n\tfunction m():Void {\n\t\tvar v:String;\n\t\tsink(function(s) other(s, v));\n\t}\n'
			+ '\tfunction sink(f:String->Void):Void {}\n\tfunction other(a:String, b:String):Void {}\n}';
		Assert.equals('s -> other(s, v)', fixText(src));
	}

	/** A `throw` EXPRESSION body keeps its keyword — the block-bodied twin is `testThrowTailResolvedFixed`. */
	public function testThrowExprBodyResolvedFixed(): Void {
		Assert.equals("() -> throw 'boom'", fixText(hostClass("cb(function() throw 'boom');")));
	}

	// ---- the generic hazard ----

	/** A parameter whose function-type RETURN is a callee type parameter is proven generic — not even reported. */
	public function testGenericReturnSilent(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'BoxG.hx', source: 'class BoxG<T> {\n\tpublic function each<S>(f:T->S):Void {}\n}' },
			{
				file: 'UseG.hx',
				source: 'class UseG {\n\tvar b:BoxG<Int>;\n\tfunction m():Void {\n\t\tb.each(function(x) { fire(); });\n\t}\n'
					+ '\tfunction fire():Void {}\n}'
			}
		];
		Assert.equals(0, violationsMulti(files, 'UseG.hx').length);
	}

	/** A generic-return callee still converts a TYPE-PRESERVING body (explicit return pins the type). */
	public function testGenericReturnPreservingBodyFixed(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'BoxH.hx', source: 'class BoxH<T> {\n\tpublic function each<S>(f:T->S):Void {}\n}' },
			{
				file: 'UseH.hx',
				source: 'class UseH {\n\tvar b:BoxH<Int>;\n\tfunction m():Void {\n\t\tb.each(function(x) { return x + 1; });\n\t}\n}'
			}
		];
		Assert.equals('x -> x + 1', fixTextIndexed(files, 'UseH.hx'));
	}

	// ---- alignment / shape gates ----

	/** A skippable optional parameter before the callback makes positional alignment ambiguous — report-only. */
	public function testOptionalSkipAmbiguityGateRefuses(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'OptT.hx', source: 'class OptT {\n\tpublic static function go3(a:Int, ?b:Bool, cb:Void->Void):Void {}\n}' },
			{
				file: 'UseO.hx',
				source: 'class UseO {\n\tfunction m():Void {\n\t\tOptT.go3(1, function() { fire(); });\n\t}\n\tfunction fire():Void {}\n}'
			}
		];
		Assert.equals(1, violationsMulti(files, 'UseO.hx').length);
		Assert.equals('<0 edits>', fixTextIndexed(files, 'UseO.hx'));
	}

	/** A comment between the dropped `function` syntax and the body blocks the rewrite (it would be stranded). */
	public function testStrandedCommentGateRefuses(): Void {
		assertGateRefuses(hostClass('cb(function() /* why */ { go(0); });'));
	}

	/** A comment INSIDE a single-expression block survives by keeping the block form. */
	public function testInteriorCommentKeepsBlock(): Void {
		Assert.equals('() -> { /* k */ go(0); }', fixText(hostClass('cb(function() { /* k */ go(0); });')));
	}

	// ---- out-of-scope shapes ----

	/** A local named `function` statement is a declaration, not a callback — never flagged. */
	public function testLocalNamedFnNotFlagged(): Void {
		Assert.equals(0, violations(wrap('function local():Void { go(0); }')).length);
	}

	/** A `var f = function() {}` initializer is out of scope by policy. */
	public function testVarInitializerNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var v = function() { go(0); };')).length);
	}

	/** Only the OUTERMOST candidate is flagged per pass; the nested one converts on the next fixed-point pass. */
	public function testNestedOuterOnly(): Void {
		final src: String = hostClass('cb(function() { cb(function() { go(0); }); });');
		Assert.equals(1, violations(src).length);
		Assert.equals('() -> cb(function() { go(0); })', fixText(src));
	}

	// ---- framework wiring ----

	public function testMessageAndSeverity(): Void {
		final vs: Array<Violation> = violations(wrap('take(function() {});'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-arrow-callback', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this function-literal callback can be an arrow lambda', vs[0].message);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-arrow-callback'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-arrow-callback'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	// ---- helpers ----

	/** A minimal host whose callee is unresolvable (`take` / `take2` undeclared). */
	private function wrap(stmt: String): String {
		return 'class C {\n\tfunction m():Void {\n\t\t$stmt\n\t}\n\tfunction go(i:Int):Void {}\n}';
	}

	/** A host class declaring `cb(f:Void->Void)` so bare / `this.` callees resolve to a `Void` return. */
	private function hostClass(stmt: String): String {
		return 'class C {\n\tfunction m():Void {\n\t\t$stmt\n\t}\n\tfunction cb(f:Void->Void):Void {}\n\tfunction go(i:Int):Void {}\n}';
	}

	/** A generic-arity ctor fixture: `TookG<T>` whose ctor takes a `Void`-returning callback. */
	private function genericCtorFixture(stmt: String): Array<{ file: String, source: String }> {
		return [
			{ file: 'TookG.hx', source: 'class TookG<T> {\n\tpublic function new(cb:Void->Void) {}\n}' },
			{
				file: 'UseGN.hx',
				source: 'class UseGN {\n\tfunction m():Void {\n\t\t$stmt\n\t}\n\tfunction go():Void {}\n}'
			}
		];
	}

	private function timerFixture(): { file: String, source: String } {
		return {
			file: 'pkg/MyTimer.hx',
			source: 'package pkg;\n\nclass MyTimer {\n\tpublic static function delayX(f:Void->Void, t:Int):Void {}\n}'
		};
	}

	private function violations(src: String): Array<Violation> {
		return new PreferArrowCallback().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function violationsMulti(files: Array<{ file: String, source: String }>, target: String): Array<Violation> {
		return new PreferArrowCallback().run(files, new HaxeQueryPlugin()).filter(v -> v.file == target);
	}

	private function fixText(src: String): String {
		return fixTextIndexed([{ file: 'C.hx', source: src }], 'C.hx');
	}

	/** Assert `src` is reported (one finding) yet gate-refused (no fix edit). */
	private function assertGateRefuses(src: String): Void {
		Assert.equals(1, violations(src).length);
		Assert.equals('<0 edits>', fixText(src));
	}

	/** Run over `files`, fix `target` with a full index threaded, and return the single edit's text. */
	private function fixTextIndexed(files: Array<{ file: String, source: String }>, target: String): String {
		final check: PreferArrowCallback = new PreferArrowCallback();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		var source: Null<String> = null;
		for (f in files) if (f.file == target) source = f.source;
		final src: Null<String> = source;
		if (src == null) return '<no target>';
		final own: Array<Violation> = check.run(files, plugin).filter(v -> v.file == target);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, own, plugin, index);
		return edits.length == 1 ? edits[0].text : '<${edits.length} edits>';
	}

}
