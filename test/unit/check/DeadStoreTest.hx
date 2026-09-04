package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.CheckScan;
import anyparse.check.DeadStore;
import anyparse.check.Linter;
import anyparse.check.NullFlow;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * The `dead-store` check: an assignment to a local / parameter whose value is
 * never read on any path (backward liveness, over-approximated — every
 * uncertainty makes more names live, so a report means dead-on-all-paths).
 * Partition with `unused-local`: a zero-reference binding is that check's
 * finding; a written-then-never-read one is this check's.
 */
class DeadStoreTest extends Test {

	public inline function testFixStripsDeadInitializer(): Void {
		// `var x = 1` is reassigned before any read — the initializer is stripped to `var x;`.
		assertFix('class C { function f():Int { var x = 1; x = 2; return x; } }', 'var x;', 'x = 1');
	}

	public inline function testFixRefusesBuildMacroFile(): Void {
		// Both shapes are legal Haxe, but a body under a build macro is consumed by something that may
		// model only the forms it was written for: `TplPut.hx` is built by
		// `Continuation.cpsByMeta(':async')`, which turns each declaration into a continuation whose
		// arity comes from the initializer, so stripping one produced
		// `(name : String) -> Void should be () -> Unknown<0>` out of a compiling file.
		assertNoFix('@:build(B.b()) class C { function f():Int { var x = 1; x = 2; return x; } }');
	}

	public inline function testFixDeletesDeadStoreBetweenReads(): Void {
		// `x = 99` dies between two live reads — deleting it must keep `trace(x)` and the return.
		assertFix('class C { function f(a:Int):Int { var x = a; trace(x); x = 99; x = a + 1; return x; } }', 'trace(x)', '99');
	}

	public inline function testFixDeletesTrailingStore(): Void {
		// A store followed only by the exit is deleted; the earlier live read stays.
		assertFix('class C { function f(a:Int):Void { var x = a; trace(x); x = a + 1; } }', 'trace(x)', 'a + 1');
	}

	public inline function testFixKeepsTypeOnStrippedInit(): Void {
		// The name and type are kept verbatim — only ` = e` is removed.
		assertFix('class C { function f():Int { var x:Int = 1; x = 2; return x; } }', 'var x:Int;', '= 1');
	}

	public inline function testFixRefusesCallRhs(): Void {
		// A call right-hand side may have side effects — the dead store stays a finding.
		assertNoFix('class C { function f(a:Int):Void { var x = a; trace(x); x = compute(); } }');
	}

	public inline function testFixStripsPureStdlibCallInitializer(): Void {
		// `Std.int(v)` is a provably-pure stdlib call — dropping it drops nothing, so the dead
		// initializer is stripped like any other pure one.
		assertFix('class C { function f(v:Float):Int { var x:Int = Std.int(v); x = 2; return x; } }', 'var x:Int;', 'Std.int(v)');
	}

	public inline function testFixRefusesNonDeterministicStdlibInitializer(): Void {
		// `Math.random()` is stdlib but not referentially transparent — the argument is walked,
		// so the outer `Std.int(...)` being pure does not launder it.
		assertNoFix('class C { function f(a:Int):Int { var x:Int = Std.int(Math.random()); x = a; return x; } }');
	}

	public inline function testFixRefusesNewRhs(): Void {
		// `new` runs a constructor — never deleted.
		assertNoFix('class C { function f(a:Int):Void { var y = a; trace(y); y = new Foo(); } }');
	}

	public inline function testFixRefusesBareBranchBody(): Void {
		// A dead store that is a bare (unbraced) branch body is left — deleting it would corrupt
		// the `if`; only a direct block statement is removed.
		assertNoFix('class C { function f(a:Int):Void { var z = a; trace(z); if (a > 0) z = 5; } }');
	}

	public inline function testFixRefusesEmptyingBranchBody(): Void {
		// Every statement of the `if` body is a deletable dead store; deleting them all would leave
		// `if (a > 0) {}`, so the whole block's deletions are dropped and the finding stays.
		assertNoFix('class C { function f(a:Int, s1:Int, s2:Int):Void { if (a > 0) { s1 = 1; s2 = 2; } } }');
	}

	public inline function testFixRefusesEmptyingBranchWithLiveElse(): Void {
		// The then-branch would empty while the `else` stays live, so dropping the whole `if` is not
		// available as a repair — the store is left rather than producing `if (…) {} else { … }`.
		assertNoFix('class C { function f(a:Int, s1:Int):Int { var r = 0; if (a > 0) { s1 = 1; } else { r = 2; } return r; } }');
	}

	public inline function testFixDeletesStoreWhenBlockKeepsAStatement(): Void {
		// A surviving statement means the block cannot empty — the dead store is deleted as usual.
		assertFix('class C { function f(a:Int, s1:Int):Void { if (a > 0) { s1 = 1; trace(a); } } }', 'trace(a)', 's1 = 1');
	}

	public inline function testFixEmptiesFunctionBodyBlock(): Void {
		// A function body is not a block `empty-block` flags and an emptied one strands no construct,
		// so the sole dead store still goes.
		assertFix('class C { function f(s1:Int):Void { s1 = 1; } }', 'function f(s1:Int):Void {}', 's1 = 1');
	}

	public inline function testFixRefusesCallInitializer(): Void {
		// An impure initializer is not stripped even when reassigned before a read.
		assertNoFix('class C { function f(a:Int):Int { var w = compute(); w = a; return w; } }');
	}

	public function testReassignedInitFlagged(): Void {
		// The initializer is overwritten before any read — one dead store (the init).
		Assert.equals(1, violations('class C { function f():Int { var x = 1; x = 2; return x; } }').length);
	}

	public function testMidChainStoreFlagged(): Void {
		// Init and the first reassignment both die before the only read.
		Assert.equals(2, violations('class C { function f(a:Int):Int { var w = a; w = a + 1; w = a + 2; return w; } }').length);
	}

	public function testTrailingStoreFlagged(): Void {
		// A store followed only by the function exit is dead.
		Assert.equals(1, violations('class C { function f(a:Int):Void { var x = a; trace(x); x = a + 1; } }').length);
	}

	public function testBothArmsOverwriteFlagged(): Void {
		// Both arms of the if overwrite before the read — the init is dead.
		Assert.equals(1, violations('class C { function f(a:Int):Int { var x = 1; if (a > 0) x = 2 else x = 3; return x; } }').length);
	}

	public function testParamStoreFlagged(): Void {
		// Parameters are own names — an overwritten param store is dead.
		Assert.equals(1, violations('class C { function f(a:Int):Int { a = 5; a = 6; return a; } }').length);
	}

	public function testWriteOnlyLocalBothFlagged(): Void {
		// A written-then-never-read local: `unused-local`'s text scan counts the write as a
		// reference, so both stores are this check's findings — the partition's other half.
		Assert.equals(2, violations('class C { function f():Void { var q = 1; q = 2; } }').length);
	}

	public function testSelfFeedingIncrementFlagged(): Void {
		// `x = x + 1` reads the old value (keeping the init alive) but its own result dies.
		Assert.equals(1, violations('class C { function f(a:Int):Void { var x = a; trace(x); x = x + 1; } }').length);
	}

	public function testShadowedNameExcluded(): Void {
		// A name bound more than once in the unit is excluded entirely — name-keyed
		// liveness cannot tell the bindings apart. The genuinely-dead outer init is a
		// deliberate safe miss (soundness over precision).
		Assert.equals(0, violations('class C { function f():Void { var x = 1; { var x = 2; trace(x); } } }').length);
	}

	public function testShadowTailReadNotFlagged(): Void {
		// Regression: the inner shadowing decl must not kill the OUTER binding's
		// liveness — the tail read keeps the outer init alive.
		Assert.equals(0, violations('class C { function f():Void { var x = 1; { var x = 2; trace(x); } trace(x); } }').length);
	}

	public function testParamShadowedByLocalExcluded(): Void {
		// A parameter shadowed by a local is the same collision — excluded.
		Assert.equals(0, violations('class C { function f(a:Int):Void { a = 1; { var a = 2; trace(a); } } }').length);
	}

	public function testSwitchSameBranchReassignFlagged(): Void {
		// Branchy conservatism seeds branch exits, but a kill WITHIN one branch still works.
		Assert.equals(
			1,
			violations('class C { function f(a:Int):Void { var x = 0; switch a { case 1: x = 1; x = 2; trace(x); case _: trace(x); } } }')
				.length
		);
	}

	public function testBranchReadNotFlagged(): Void {
		// The init survives on the fall-through arm — not dead.
		Assert.equals(0, violations('class C { function f(a:Int):Int { var x = 1; if (a > 0) x = 2; return x; } }').length);
	}

	public function testInterpolationReadNotFlagged(): Void {
		// A simple `$x` inside a single-quoted string projects as a distinct identifier kind — counted as a read.
		Assert.equals(0, violations("class C { function f(a:Int):Void { var x = a; trace('$x'); x = 5; trace('$x'); } }").length);
	}

	public function testCompoundAssignNotFlagged(): Void {
		// `+=` reads the old value — never a dead store, and it keeps the init alive.
		Assert.equals(0, violations('class C { function f(a:Int):Int { var x = a; x += 1; return x; } }').length);
	}

	public function testClosureUseExcluded(): Void {
		// A name a nested function reads is excluded entirely — the closure may run later.
		Assert.equals(0, violations('class C { function f(a:Int):Void { var x = a; final g = () -> trace(x); x = a + 1; g(); } }').length);
	}

	public function testBareArrowMemoStoresExcluded(): Void {
		// The `Cli.renderLintReport` memo shape: two locals a BARE-parameter arrow (`v -> …`) captures,
		// written last in the callback's own block. That spelling projects as `ThinArrow`, which was the
		// one function-value kind missing from `NullFlow.NESTED_FN_KINDS` — so the body was walked as
		// straight-line code and its own `return` cleared the backward liveness state, making both memo
		// writes read as dead on every path. `--fix` then deleted them: identical output, and the index
		// rebuilt per invocation (measured on this shape — 1 build vs 30 over 30 findings, byte-equal
		// results). That is the silent 31x regression this check once shipped.
		final src: String = 'class C { static function r(fs:Array<String>):Array<String> { var t:Null<String> = null;'
			+ ' var ix:Null<Array<String>> = null; return emit(fs, v -> { final tr = treeOf(v); var cur = ix;'
			+ ' if (cur == null || t != tr) { cur = build(tr); t = tr; ix = cur; } return cur[0]; }); } }';
		Assert.equals(0, violations(src).length);
	}

	public function testBareArrowMemoGetsNoEdit(): Void {
		// `fix` never re-derives liveness — it acts on `run`'s spans — so the report pin above and the
		// edit pin are separate failures. Pinning both keeps a report regression from turning straight
		// into a corrupting edit.
		final src: String = 'class C { static function r(fs:Array<String>):Array<String> { var t:Null<String> = null;'
			+ ' var ix:Null<Array<String>> = null; return emit(fs, v -> { final tr = treeOf(v); var cur = ix;'
			+ ' if (cur == null || t != tr) { cur = build(tr); t = tr; ix = cur; } return cur[0]; }); } }';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: DeadStore = new DeadStore();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		Assert.equals(0, vs.length);
		Assert.equals(0, check.fix(src, vs, plugin).length);
	}

	public function testBareArrowAccumulatorExcluded(): Void {
		// `ExplicitLocalType.inadmissibleType` in shape: an accumulator a driver's bare-arrow callback
		// writes, read after the driver returns. Both the initializer and the write were flagged, and
		// `--fix` stripped `var found:Bool = false` to `var found:Bool;` — which the compiler rejects
		// (`Local variable found used without being initialized`), so the next project-wide fixpoint run
		// would have broken the build of the check that gates every `explicit-local-type` annotation.
		final src: String = 'class C { static function bad(t:String):Bool { if (t == "Void") return true;'
			+ ' var found:Bool = false; runs(t, run -> { if (run == "Dynamic") found = true; return run; }); return found; } }';
		Assert.equals(0, violations(src).length);
	}

	public function testBareArrowNegatedAccumulatorExcluded(): Void {
		// The `ExplicitLocalType.spellable` twin of the same shape — the accumulator starts `true` and
		// the callback clears it, so a stripped initializer makes it answer "spellable" for every input
		// instead of abstaining on the unproven ones.
		final src: String = 'class C { static function s(p:String):Null<String> { var placed:Bool = true;'
			+ ' runs(p, run -> { if (run.indexOf(".") != -1) placed = false; return run; }); return placed ? p : null; } }';
		Assert.equals(0, violations(src).length);
	}

	public function testBareArrowReadKeepsOuterStoreLive(): Void {
		// WIDTH: the exclusion counts a name the closure READS, not only one it writes. Here the store is
		// OUTSIDE the lambda and its only read is INSIDE it — once the bare-arrow body stopped being
		// walked, a write-only exclusion would report `cb` dead and `--fix` would delete the value the
		// callback returns. The read half of the exclusion is what makes the walk's new blindness safe.
		Assert.equals(
			0, violations('class C { static function f(a:Int):Int { var cb = 0; cb = a + 1; return drive(v -> cb + v); } }').length
		);
	}

	public function testBareArrowElsewhereKeepsUnrelatedStoreFlagged(): Void {
		// The exclusion is per NAME, not per function: a bare-arrow callback in the same body that never
		// mentions `x` must not suppress `x`'s genuine dead initializer. Guards the over-refusal
		// direction, which a name-blind "this body contains a lambda" gate would fail.
		Assert.equals(
			1, violations('class C { static function f(a:Int):Int { var x = a; x = a + 1; drive(v -> v + 1); return x; } }').length
		);
	}

	public function testNestedFnKindsCoverEveryGrammarFunctionValue(): Void {
		// The gap this pin closes was a MISSING kind, not wrong logic: `ThinArrow` was absent from the
		// nested-function set while the grammar had declared it in `RefShape.lambdaKinds` all along.
		// Make the grammar the authority for completeness — a plugin that adds a function-value
		// spelling fails here instead of silently re-opening the hole in every consumer of that set.
		//
		// The declaration side only. It is now half structural — `nestedFunctionKinds` DERIVES the
		// union, so a piece cannot go missing from it — and the half that still bites is
		// `namedFnExprKind`, the seam this pin's own predecessor could not see: it was declared in no
		// kind-set at all, so a hand union assembled from the other four silently omitted it.
		// `testNestedFunctionKindsCoverEverySpellingTheGrammarProjects` covers the other direction,
		// against parsed source rather than against declarations.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final shape: RefShape = plugin.refShape();
		final authority: Array<String> = MemberKinds.nestedFunctionKinds(shape);
		final declared: Array<String> = (
			shape.lambdaKinds ?? []
		).concat(shape.localFunctionKinds ?? []).concat(shape.inlineFunctionKinds ?? []);
		for (kind in [shape.fnExprKind, shape.namedFnExprKind]) if (kind != null) declared.push(kind);
		Assert.isTrue(declared.length > 0, 'the plugin must declare at least one function-value kind');
		Assert.notNull(shape.namedFnExprKind, 'the Haxe plugin must declare its named function-literal kind');
		for (kind in declared)
			Assert.isTrue(authority.contains(kind), 'the nested-function authority is missing the grammar function-value kind $kind');
	}

	public function testNestedFunctionKindsCoverEverySpellingTheGrammarProjects(): Void {
		// The other direction, and the one a declaration-side pin cannot reach: parse each spelling of
		// a function value that Haxe can actually write, read the kind the grammar projects it as, and
		// require the authority to carry it. A renamed ctor fails the first assertion, a dropped kind
		// the second — neither can be satisfied by editing the plugin's declarations alone.
		//
		// `ParenLambdaExpr` (the Haxe-3 `(v) => e` fat arrow) has no row: Haxe 4 cannot spell it, so
		// the pin above is what keeps it in the set.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final authority: Array<String> = MemberKinds.nestedFunctionKinds(plugin.refShape());
		final spellings: Array<{ code: String, kind: String }> = [
			{ code: 'a.map(v -> t(v));', kind: 'ThinArrow' },
			{ code: 'a.map((v) -> t(v));', kind: 'ThinParenLambdaExpr' },
			{ code: 'a.map(function(v) return t(v));', kind: 'FnExpr' },
			{ code: 'var f = function nm(v) return t(v);', kind: 'NamedFnExpr' },
			{ code: 'function nm(v) return t(v);', kind: 'LocalFnStmt' },
			{ code: 'inline function nm(v) return t(v);', kind: 'LocalInlineFnStmt' }
		];
		for (s in spellings) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, 'class C { static function r(a:Array<Int>):Void { ${s.code} } }');
			Assert.notNull(tree, 'the spelling ${s.code} no longer parses');
			if (tree != null) Assert.isTrue(subtreeHasKind(tree, s.kind), 'the grammar no longer projects ${s.code} as ${s.kind}');
			Assert.isTrue(authority.contains(s.kind), 'the nested-function authority is missing ${s.kind} (${s.code})');
		}
	}

	public function testLoopBackEdgeNotFlagged(): Void {
		// A name read anywhere in the loop stays live throughout it — the back-edge is safe.
		Assert.equals(
			0, violations('class C { function f(n:Int):Int { var acc = 0; for (i in 0...n) acc = acc + i; return acc; } }').length
		);
	}

	public function testBreakPathNotFlagged(): Void {
		// The store carried out through `break` (a jump this walk does not model) stays live.
		Assert.equals(
			0,
			violations(
				'class C { function f(n:Int):Int { var x = 0; var i = 0; while (i < n) { x = i; if (x > 3) break; x = 0; i = i + 1; } '
				+ 'return x; } }'
			).length
		);
	}

	public function testTryCatchReadNotFlagged(): Void {
		// The catch arm reads the name — every store inside the construct stays live.
		Assert.equals(
			0, violations('class C { function f():Void { var x = 1; try { x = 2; risky(); } catch (e:Dynamic) { trace(x); } } }').length
		);
	}

	public function testShortCircuitRhsKillNotLeaked(): Void {
		// The `&&` right operand evaluates conditionally — its overwrite must not kill the skip path.
		Assert.equals(
			0,
			violations('class C { function f(a:Int):Int { var x = 1; final ok = a > 0 && (x = 2) > 0; return ok ? x : x + 1; } }').length
		);
	}

	public function testSafeNavCallArgNotLeaked(): Void {
		// A null-safe call's arguments evaluate conditionally — same guard as short-circuit.
		Assert.equals(0, violations('class C { function f(o:Null<Foo>):Int { var x = 1; o?.m(x = 2); return x; } }').length);
	}

	public function testMacroKeepsEverythingLive(): Void {
		// A reification subtree can splice a read of anything — every own name is live before it.
		Assert.equals(0, violations('class C { function f(b:Int):Dynamic { b = 5; final e = macro q(b); return e; } }').length);
	}

	public function testFinalInitNeverFlagged(): Void {
		// A `final` cannot be reassigned — a dead final init means zero reads, `unused-local`'s case.
		Assert.equals(0, violations('class C { function f():Void { final x = compute(); } }').length);
	}

	public function testZeroReferenceInitNotFlagged(): Void {
		// A binding never referenced at all is `unused-local`'s finding, not a dead store.
		Assert.equals(0, violations('class C { function f():Void { var x = 1; } }').length);
	}

	public function testAnonTypedDeclInitReadsCollected(): Void {
		// An anonymous-struct type annotation projects as a decl child BEFORE the init —
		// the initializer (and its reads) is the LAST child. Regression: the branch write
		// was flagged because the switch init (whose branches read the name) went unwalked.
		Assert.equals(
			0,
			violations(
				'class C { function f(s:Int, p:Null<String>):Dynamic { var c = mk(); if (!c && p != null) c = mk2(); final e:{ t:String '
				+ '} = switch s { case 1: { t: c ? "a" : "b" }; case _: { t: c ? "x" : "y" }; }; return e; } }'
			).length
		);
	}

	public function testMultiBindingInitReadsCollected(): Void {
		// `var a = q, b = 2` projects as ONE node; the first initializer's read of `q`
		// must still count — regression for the walked-only-last-child bug.
		Assert.equals(0, violations('class C { function f(p:Int):Int { var q = p; var a = q, b = 2; return a + b; } }').length);
	}

	public function testMultiBindingDeclNotReported(): Void {
		// A multi-binding decl's initializers cannot be attributed to its one projected
		// name — never reported, even when that name is overwritten before a read.
		Assert.equals(0, violations('class C { function f():Int { var a = 1, b = 2; a = 3; return a + b; } }').length);
	}

	public function testMultiBindingSingleChildNotReported(): Void {
		// `var a, b = 1` carries ONE init child that belongs to `b`, not to the
		// projected name `a` — the textual comma detection suppresses the report.
		Assert.equals(0, violations('class C { function f():Int { var a, b = 1; a = 2; trace(a); return a + b; } }').length);
	}

	public function testThrowKeepsCatchReadsLive(): Void {
		// A literal `throw` inside `try` continues at the (unmodeled) catch, which may
		// read anything — it must not clear liveness like a `return` does.
		Assert.equals(
			0, violations('class C { function f():Void { var x = 1; try { x = 2; throw mk(); } catch (e:Dynamic) { trace(x); } } }').length
		);
	}

	public function testSafeNavChainArgNotLeaked(): Void {
		// `o?.a.g(y = 1)` short-circuits the WHOLE chain — a `?.` anywhere in the
		// callee subtree makes the arguments conditional.
		Assert.equals(0, violations('class C { function f(o:Null<Foo>):Int { var y = 0; o?.a.g(y = 1); return y; } }').length);
	}

	public function testNestedFnDeclNotOwnName(): Void {
		// A local declared ONLY inside a nested function is that unit's binding — the
		// outer bare write goes to a same-named FIELD, which has unknowable readers.
		Assert.equals(
			0,
			violations(
				'class C { var x:Int; function f():Void { function g():Void { var x = 1; trace(x); } x = 5; g(); } function other():Int {'
				+ ' return x; } }'
			).length
		);
	}

	public function testMetaArgWriteDoesNotKill(): Void {
		// A metadata argument never runs — `@:m(y = 2)` is not a store and must not
		// kill the initializer's liveness before the real read.
		Assert.equals(0, violations('class C { function f():Void { var y = 1; @:m(y = 2) trace(y); } }').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('dead-store'));
	}

	public function testFixSkipParseNoEdit(): Void {
		// An unparseable source yields no edits (no crash).
		Assert.equals(0, new DeadStore().fix('class Bad { function f() { var x = ', [], new HaxeQueryPlugin()).length);
	}

	public function testFixKeepsBlockExprTailStore(): Void {
		// The dead store is the value-producing tail of a `{ … }` expression block — deleting it would
		// drop the block's value, so it is left in place even though it is a dead store (the init is
		// still stripped).
		final check: DeadStore = new DeadStore();
		final src: String = 'class C { static function f():Int { var x = 0; return { x = 2; }; } }';
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		switch CanonicalEdit.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('x = 2') >= 0);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	public function testFixStripsInheritedPlainFieldInit(): Void {
		// The dead initializer reads a plain field declared on a SUPERTYPE — `isPlainFieldRead`
		// proves it accessor-less through the index, so the initializer is stripped.
		final src: String = 'class Base { public var d:Int; } class Sub extends Base {} class C { static function f(s:Sub):Int {'
			+ ' var x = s.d; x = 1; return x; } }';
		Assert.equals(1, indexedFixEdits(src).length);
	}

	public function testFixKeepsInheritedGetterInit(): Void {
		// The same shape with a getter on the supertype: reading it runs code, so the init stays.
		final src: String = 'class Base { public var d(get, never):Int; } class Sub extends Base {} class C {'
			+ ' static function f(s:Sub):Int { var x = s.d; x = 1; return x; } }';
		Assert.equals(0, indexedFixEdits(src).length);
	}

	/**
	 * A store inside a lambda used to be analyzed by NOBODY. The enclosing unit REFUSES to walk a
	 * function value — `testBareArrowMemoStoresExcluded` above is the corruption that refusal
	 * prevents — and `forEachFunctionUnit` enumerated only `RefShape.functionKinds`, which names no
	 * lambda spelling. So the identical body reported at top level and inside `function nm(v)` (a
	 * `LocalFnStmt`, which IS in that set) and was silent inside `v -> { … }` and
	 * `function(v) { … }`: 2 of 4, measured on the base binary. Every function VALUE is a unit now.
	 */
	public function testLambdaBodyIsItsOwnAnalysisUnit(): Void {
		final src: String = 'class C { static function f(a:Array<Int>):Int { a.map(v -> { var x = v * 2; x = v * 3; return x; });'
			+ ' var g = function(v:Int) { var y = v; y = 5; return y; }; function nm(v:Int) { var z = v; z = 7; return z; }'
			+ ' var w = 1; w = 2; return w + g(1) + nm(2); } }';
		final names: Array<String> = [for (v in violations(src)) v.message.split("'")[1]];
		names.sort((a, b) -> a < b ? -1 : 1);
		Assert.equals('w, x, y, z', names.join(', '));
	}

	/**
	 * The two spellings whose host kind is in `RefactorSupport.nestedFunctionKinds` but NOT in
	 * `RefShape.functionKinds`, so they fell through the same hole as the lambdas: the local
	 * `inline function` (`LocalInlineFnStmt`, which the grammar gives its own ctor) and the named
	 * function LITERAL in value position (`NamedFnExpr`). Both were silent on the base binary.
	 */
	public function testInlineLocalAndNamedLiteralAreUnits(): Void {
		Assert.equals(
			1,
			violations(
				'class C { static function f(a:Int):Int { inline function li(q:Int):Int { var s = q; s = 1; return s; } return li(a); } }'
			).length
		);
		Assert.equals(
			1,
			violations(
				'class C { static function f(a:Int):Int { var g = function nn(v:Int):Int { var u = v; u = 2; return u; };'
				+ ' return g(a); } }'
			).length
		);
	}

	/**
	 * A lambda unit reports only its OWN names, so an outer local the lambda captures and writes is
	 * unreportable from BOTH sides — it is not an own name of the lambda unit, and the enclosing
	 * unit excludes every name the lambda touches. Without that, `x = 1` as a callback's last
	 * statement would read as dead on every path while the enclosing code reads it on the next
	 * invocation; the S54 memo and accumulator pins above are the measured cost of getting it wrong.
	 */
	public function testLambdaCapturedOuterLocalStaysUnreported(): Void {
		Assert.equals(
			0, violations('class C { static function f(a:Array<Int>):Int { var root = 0; a.map(r -> root = r); return root; } }').length
		);
	}

	/**
	 * `fix` never re-derives liveness — it acts on `run`'s spans — so the report and the edit are
	 * separate failures. The lambda-body initializer strips exactly like any other, and the result
	 * compiles (verified with `haxe --interp` on the four-spelling fixture: same output before and
	 * after).
	 */
	public function testLambdaDeadInitializerStrips(): Void {
		assertFix(
			'class C { static function f(a:Array<Int>):Void { a.map(v -> { var x = v * 2; x = v * 3; return x; }); } }', 'var x;',
			'var x = v * 2'
		);
	}

	/**
	 * The PARSED-source direction of unit discovery, the killer for "lambda kinds dropped from
	 * `forEachFunctionUnit`". Every function-value spelling the grammar projects must yield a body
	 * to `each`, and the two arrow forms are why the body cannot be found by
	 * `RefShape.functionBodyKinds` alone: they carry it BARE — `v -> v + 1` is
	 * `ThinArrow(Required v, Add)`, `(v) -> { … }` is `ThinParenLambdaExpr(Required v, BlockExpr)`, `(v, w = 1) => …` is
	 * `ParenLambdaExpr(Required v, Required w, …)` — while `function(v)` wraps it in `BlockBody` /
	 * `ExprBody`. All seven function-value spellings the Haxe grammar projects are here.
	 */
	public function testEveryFunctionValueSpellingBecomesAUnit(): Void {
		final src: String = 'class C { static function f(a:Array<Int>):Void { a.map(v -> v + 1); a.map((v) -> { return v; });'
			+ ' var p = (v, w = 1) => v + w; var e = function(v:Int) { return v; }; var n = function nn(v:Int) { return v; };'
			+ ' function lf(v:Int) { return v; } inline function li(v:Int) { return v; } } }';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, src);
		Assert.notNull(tree);
		final bodies: Array<String> = [];
		if (tree != null) NullFlow.forEachFunctionUnit(tree, plugin.refShape(), (body, params) -> bodies.push(body.kind));
		Assert.equals(8, bodies.length, 'unit bodies were: ' + bodies.join(', '));
	}

	private function violations(src: String): Array<Violation> {
		return new DeadStore().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function assertFix(src: String, present: String, absent: String): Void {
		final check: DeadStore = new DeadStore();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		switch CanonicalEdit.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf(present) >= 0);
				Assert.isTrue(text.indexOf(absent) == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	private function assertNoFix(src: String): Void {
		final check: DeadStore = new DeadStore();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.isTrue(vs.length > 0);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	private function indexedFixEdits(src: String): Array<{ span: Span, text: String }> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		final check: DeadStore = new DeadStore();
		final vs: Array<Violation> = check.run(files, plugin);
		Assert.isTrue(vs.length > 0, 'the dead store must be reported before its fix can be judged');
		return check.fix(src, vs, plugin, SymbolIndex.build(files, plugin));
	}

	/** Whether `node`'s subtree holds a node of kind `kind`. */
	private static function subtreeHasKind(node: QueryNode, kind: String): Bool {
		return node.kind == kind || node.children.exists(c -> subtreeHasKind(c, kind));
	}

}
