package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.FieldInitAtDeclaration;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `field-init-at-declaration` check: an instance field (`var` or `final`) with no
 * declaration initializer whose write is one unconditional top-level constructor
 * statement with a context-free right-hand side is flagged `Info`, and the fix moves
 * `= expr` onto the declaration and deletes the constructor statement. A field whose
 * cross-file write count differs from one (the `dispose()` null-out shape) still moves
 * on the ACCEPTED-CANDIDATE CHAIN: every constructor statement before its init must be
 * another accepted candidate's init. Foreign code MAY run in such a prefix — `new T()`
 * qualifies — so the chain rests on a per-right-hand-side test instead: no init sharing
 * the constructor prologue may read in-class state AT ALL, demanded of the chained
 * candidate, of every sole-write init accepted on the legacy path and of every field
 * that already carries a declaration initializer, so none of them can observe an
 * in-class static another one's foreign code writes. A `#if` member region refuses the
 * whole container (its interior is trivia here). An explicit `super(...)` ANYWHERE in
 * the constructor refuses the candidate on both paths: declaration initializers run in
 * the prologue, ahead of the base constructor. A static field, a property, a
 * right-hand side referencing a constructor parameter / `this` / another instance
 * member, a conditional / read-before-init write, a multi-write field behind a broken
 * chain or an in-class-reading co-mover, and a class without a single constructor are
 * left alone. What the gate does NOT decide — what the invoked code DOES, and anything
 * at all on the legacy path, which also reorders against arbitrary earlier constructor
 * statements — is the class doc's "Known gaps".
 */
class FieldInitAtDeclarationCheckTest extends Test {

	public function testInstanceVarMoved(): Void {
		final vs: Array<Violation> = violations('class C { private var _a:Array<Int>; public function new() { _a = new Array<Int>(); } }');
		Assert.equals(1, vs.length);
		Assert.equals('field-init-at-declaration', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testInstanceFinalMoved(): Void {
		Assert.equals(1, violations('class C { private final _b:Array<Int>; public function new() { _b = new Array<Int>(); } }').length);
	}

	/** The repro shape: a no-init field initialised with `new Array<Int>()` in the constructor. */
	public function testNewArrayMoved(): Void {
		Assert.equals(
			1, violations('class C { private var _nums:Array<Int>; public function new() { _nums = new Array<Int>(); } }').length
		);
	}

	/** A static field's init timing is unrelated to instance construction — left alone. */
	public function testStaticNotMoved(): Void {
		Assert.equals(0, violations('class C { static var _s:Int; public function new() { _s = 5; } }').length);
	}

	/** A property (a `(` in the declaration head) is skipped. */
	public function testPropertyNotMoved(): Void {
		Assert.equals(0, violations('class C { public var x(default, null):Int; public function new() { x = 5; } }').length);
	}

	/** A right-hand side referencing a constructor parameter is order-dependent — left alone. */
	public function testCtorParamRefNotMoved(): Void {
		Assert.equals(0, violations('class C { private var _x:Int; public function new(p:Int) { _x = p; } }').length);
	}

	/** A right-hand side referencing another instance member is order-dependent — left alone. */
	public function testInstanceMemberRefNotMoved(): Void {
		Assert.equals(0, violations('class C { var _a:Int = 1; var _x:Int; public function new() { _x = _a; } }').length);
	}

	/** A right-hand side referencing `this` is order-dependent — left alone. */
	public function testThisRefNotMoved(): Void {
		Assert.equals(0, violations('class C { private var _self:C; public function new() { _self = this; } }').length);
	}

	/** A field with no constructor at all has no init to move — left alone. */
	public function testNoConstructorNotMoved(): Void {
		Assert.equals(0, violations('class C { private var _x:Int; }').length);
	}

	/** A field written twice in the constructor is not single-write — left alone. */
	public function testWrittenTwiceNotMoved(): Void {
		Assert.equals(0, violations('class C { private var _x:Int; public function new() { _x = 1; _x = 2; } }').length);
	}

	/** A field assigned only conditionally (not a top-level constructor statement) — left alone. */
	public function testConditionalNotMoved(): Void {
		Assert.equals(0, violations('class C { private var _x:Int; public function new(c:Bool) { if (c) _x = 1; } }').length);
	}

	/**
	 * Nothing precedes the init, so the chain is trivially unbroken and no code in this
	 * constructor can reach the writer method before the moved value lands; moved.
	 */
	public function testMethodWriterInitFirstMoved(): Void {
		Assert.equals(
			1, violations('class C { private var _x:Int; public function new() { _x = 1; } function s():Void { _x = 2; } }').length
		);
	}

	/** A `dispose()` null-out is a second write, but the constructor init still leads the body — moved. */
	public function testDisposeNullWriteMoved(): Void {
		final src: String = 'class C { private var _x:Array<Int>; public function new() { _x = new Array<Int>(); }'
			+ ' public function dispose():Void { _x = null; } }';
		Assert.equals(1, violations(src).length);
	}

	/**
	 * The flagship shape: three fields whose allocations resolve nothing in-class, each
	 * init chaining off the previous one, all three nulled in `dispose()` — all moved.
	 */
	public function testAllocationChainMoved(): Void {
		final src: String = 'class C { private var _a:Array<Int>; private var _b:Array<Int>; private var _c:Array<Int>;'
			+ ' public function new() { _a = new Array<Int>(); _b = new Array<Int>(); _c = new Array<Int>(); }'
			+ ' public function dispose():Void { _a = null; _b = null; _c = null; } }';
		Assert.equals(3, violations(src).length);
	}

	/** A leading call statement is not a candidate init, so the chain breaks — left alone. */
	public function testWriterCallBeforeInitNotMoved(): Void {
		final src: String = 'class C { private var _x:Int; public function new() { setup(); _x = 1; }'
			+ ' function setup():Void { _x = 2; } }';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * A leading `super(...)` is now refused TWICE over. The base-constructor gate rejects the
	 * candidate outright — Haxe emits declaration initializers ahead of the `super()` call — and it
	 * runs BEFORE the chain walk, so the chain break this fixture originally pinned (a `super(...)`
	 * is not a candidate init) no longer decides the outcome. Both refusals hold; only the first one
	 * is reached.
	 */
	public function testSuperBeforeInitNotMoved(): Void {
		final src: String = 'class C extends B { private var _x:Int; public function new() { super(); _x = 1; }'
			+ ' function s():Void { _x = 2; } }';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * A leading assignment to a PROPERTY is not a candidate init (a `(` in the
	 * declaration head bars the field) — the chain breaks, so its setter can never
	 * run inside the moved window; left alone.
	 */
	public function testPropertyTargetBeforeInitNotMoved(): Void {
		final src: String = 'class C { public var y(default, set):Int; private var _x:Int;'
			+ ' function set_y(v:Int):Int { _x = 2; return y = v; } public function new() { y = 5; _x = 1; } }';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * A leading assignment to a name this container does not declare (an inherited
	 * field, possibly a property) is not a candidate init — the chain breaks; left alone.
	 */
	public function testUnresolvedTargetBeforeInitNotMoved(): Void {
		final src: String = 'class C extends B { private var _x:Int; public function new() { w = 5; _x = 1; }'
			+ ' function s():Void { _x = 2; } }';
		Assert.equals(0, violations(src).length);
	}

	/** A leading local declaration is not a candidate init, so the chain breaks — left alone. */
	public function testLocalDeclBeforeInitNotMoved(): Void {
		final src: String = 'class C { private var _x:Int; public function new() { var t:Int = 1; _x = 1; }'
			+ ' function s():Void { _x = 2; } }';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * A leading write to a same-class STATIC is not a candidate init (statics never
	 * are), so the chain breaks. The right-hand side resolves nothing in-class, so this
	 * fixture turns on the chain gate alone; left alone.
	 */
	public function testStaticTargetBeforeInitNotMoved(): Void {
		final src: String = 'class C { static var s:Int = 0; private var _a:Array<Int>;'
			+ ' public function new() { s = 5; _a = new Array<Int>(); } function d():Void { _a = null; } }';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * The live refutation that drove the order gate: moved inits land in the prologue in
	 * a sequence the compiler picks, so `_b = bump()` can perturb what `_a = n` observes.
	 * `_a` is refused — redundantly, by BOTH order terms (its own right-hand side reads
	 * in-class, and so does its sole-write co-mover) — while `_b` still moves on the
	 * legacy path. The terms are isolated separately by `testInClassReadRhsChainPartial`
	 * and `testSoleWriteCoMoverBlocksChain`.
	 */
	public function testStaticReadRhsChainPartial(): Void {
		final src: String = 'class C { static var n:Int = 0; static function bump():Int { n++; return 0; }'
			+ ' private var _b:Int; private var _a:Int; public function new() { _b = bump(); _a = n; }'
			+ ' public function d():Void { _a = 0; } }';
		assertSoleViolationOn(src, '_b');
	}

	/**
	 * Declaration order need not track constructor-statement order. Both right-hand
	 * sides resolve nothing in-class, so neither can observe the other whichever way
	 * the compiler permutes the prologue — both move, and the fix lands both inits on
	 * their declarations.
	 */
	public function testDeclOrderMismatchMoved(): Void {
		final src: String = 'class C {\n\tvar _a:Array<Int>;\n\tvar _b:Array<Int>;\n'
			+ '\tpublic function new() {\n\t\t_b = new Array<Int>();\n\t\t_a = new Array<Int>();\n\t}\n'
			+ '\tpublic function dispose():Void {\n\t\t_a = null;\n\t\t_b = null;\n\t}\n}';
		Assert.equals(2, violations(src).length);
		final fixed: String = fixedSource(src);
		Assert.isTrue(fixed.indexOf('var _a:Array<Int> = new Array<Int>();') >= 0);
		Assert.isTrue(fixed.indexOf('var _b:Array<Int> = new Array<Int>();') >= 0);
		Assert.equals(-1, fixed.indexOf('_a = new'));
		Assert.equals(-1, fixed.indexOf('_b = new'));
	}

	/**
	 * A SOLE-WRITE candidate co-moves on the legacy path with no chain gate of its own,
	 * so a chained candidate is refused whenever any co-mover reads in-class state:
	 * here `_a = s` would be hopped over by `new Foo()`, whose constructor writes `s`.
	 * Only the sole-write `_a` moves, which is what the rule did before the chain.
	 */
	public function testSoleWriteCoMoverBlocksChain(): Void {
		final src: String = 'class C { public static var s:Int = 1; private var _a:Int; private var _b:Foo;'
			+ ' public function new() { _a = s; _b = new Foo(); } public function d():Void { _b = null; } }';
		assertSoleViolationOn(src, '_a');
	}

	/**
	 * With no sole-write co-mover in the constructor, a chained candidate is judged on
	 * its OWN right-hand side: `_a`'s allocation resolves nothing in-class and moves,
	 * while `_b = n` reads a static of this class — another moved init could assign it,
	 * so `_b` stays. Isolates the per-candidate half of the order gate.
	 */
	public function testInClassReadRhsChainPartial(): Void {
		final src: String = 'class C { static var n:Int = 0; private var _a:Array<Int>; private var _b:Int;'
			+ ' public function new() { _a = new Array<Int>(); _b = n; }' + ' public function dispose():Void { _a = null; _b = 0; } }';
		assertSoleViolationOn(src, '_a');
	}

	/**
	 * An EXISTING declaration initializer shares the prologue a chained candidate moves
	 * into, so it counts as a co-mover: `_a:Int = s` reads a static this class declares,
	 * and `new Foo()` may assign it, so `_b` stays in the constructor. This is the state
	 * `--fix` reaches after moving `_a` in an earlier pass — without the gate the
	 * fixpoint would keep going and reorder the two.
	 */
	public function testExistingDeclInitReadBlocksChain(): Void {
		final src: String = 'class C { public static var s:Int = 1; private var _a:Int = s; private var _b:Foo;'
			+ ' public function new() { _b = new Foo(); } public function d():Void { _b = null; } }';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * A `#if` member REGION projects as one node whose interior stays trivia, so a
	 * declaration initializer inside it is invisible to the co-mover fold. It fails
	 * closed: any conditional member block refuses every chained candidate. Without
	 * that arm this fixture would move `_b` while the identical code without `#if`
	 * refuses it.
	 */
	public function testConditionalMemberBlocksChain(): Void {
		final src: String = 'class C { public static var s:Int = 0; #if debug private var _p:Int = s; #end private var _b:Bar;'
			+ ' public function new() { _b = new Bar(); } public function d():Void { _b = null; } }';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * The EXPRESSION-position `#if` is a different shape: the conditional sits inside a
	 * real initializer whose children the walk reaches, so `s` is seen and `_b` is
	 * refused for the ordinary reason. Guards against a future fold that treats every
	 * conditional as opaque.
	 */
	public function testConditionalInitializerExpressionIsSeen(): Void {
		final src: String = 'class C { public static var s:Int = 0; private var _p:Int = #if debug s #else 0 #end;'
			+ ' private var _b:Bar; public function new() { _b = new Bar(); } public function d():Void { _b = null; } }';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * DOCUMENTED GAP, not a guarantee: `orderSafe` only proves a right-hand side reads
	 * nothing in-class, never what the code it invokes does. Both allocations here pass
	 * and both move, even though `new Bump()` may write state `new Reader()` observes.
	 * Asserted for visibility — if a future gate refuses these, update the class doc's
	 * "Known gaps" with it.
	 */
	public function testForeignWriteThroughCallIsAnAcceptedGap(): Void {
		final src: String = 'class C { private var _a:Bump; private var _b:Reader;'
			+ ' public function new() { _a = new Bump(); _b = new Reader(); }'
			+ ' public function dispose():Void { _a = null; _b = null; } }';
		Assert.equals(2, violations(src).length);
	}

	/** A leading reassignment of an already decl-initialized field is not a candidate init — chain breaks; left alone. */
	public function testDeclInitializedLeadingReassignNotMoved(): Void {
		final src: String = 'class C { private var _y:Int = 0; private var _x:Array<Int>;'
			+ ' public function new() { _y = 5; _x = new Array<Int>(); }' + ' public function dispose():Void { _x = null; } }';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * A suppressed prefix candidate must freeze the whole run: dropping the first
	 * field's violation (as a `// noqa` would) leaves the later two in the constructor
	 * rather than hopping them over an init that stays put.
	 */
	public function testSuppressedPrefixSkipsFix(): Void {
		final src: String = 'class C {\n\tvar _a:Array<Int>;\n\tvar _b:Array<Int>;\n\tvar _c:Array<Int>;\n'
			+ '\tpublic function new() {\n\t\t_a = new Array<Int>();\n\t\t_b = new Array<Int>();\n\t\t_c = new Array<Int>();\n\t}\n'
			+ '\tpublic function dispose():Void {\n\t\t_a = null;\n\t\t_b = null;\n\t\t_c = null;\n\t}\n}';
		final check: FieldInitAtDeclaration = new FieldInitAtDeclaration();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final all: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		Assert.equals(3, all.length);
		Assert.equals(0, check.fix(src, all.slice(1), plugin).length);
	}

	/** A static reference in the right-hand side is available at declaration-init time — moved. */
	public function testStaticRefMoved(): Void {
		Assert.equals(1, violations('class C { static var _base:Int = 5; var _x:Int; public function new() { _x = _base; } }').length);
	}

	/** The fix inserts `= expr` on the declaration and deletes the constructor statement. */
	public function testFixMovesInit(): Void {
		final fixed: String = fixedSource(
			'class C {\n\tprivate var _a:Array<Int>;\n\tpublic function new() {\n\t\t_a = new Array<Int>();\n\t}\n}'
		);
		Assert.isTrue(fixed.indexOf('private var _a:Array<Int> = new Array<Int>();') >= 0);
		Assert.equals(-1, fixed.indexOf('_a = new'));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('field-init-at-declaration'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('field-init-at-declaration'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { var _x = ').length);
	}

	/** A field READ in the constructor before its assignment would change value if moved — left alone. */
	public function testReadBeforeWriteNotMoved(): Void {
		Assert.equals(0, violations('class C { private var _x:Int; public function new() { trace(_x); _x = 5; } }').length);
	}

	/** A field read only AFTER its constructor assignment is safe to move — flagged. */
	public function testReadAfterWriteMoved(): Void {
		Assert.equals(1, violations('class C { private var _x:Int; public function new() { _x = 5; trace(_x); } }').length);
	}

	/** A `this.field = expr` target is recognised — flagged. */
	public function testThisTargetMoved(): Void {
		Assert.equals(1, violations('class C { private var _y:Int; public function new() { this._y = 7; } }').length);
	}

	/** A right-hand side calling an instance method is order-dependent — left alone. */
	public function testInstanceMethodCallRhsNotMoved(): Void {
		Assert.equals(
			0, violations('class C { private var _x:Int; function h():Int return 1; public function new() { _x = h(); } }').length
		);
	}

	/** A `new T(param)` whose argument references a constructor parameter is order-dependent — left alone. */
	public function testNewWithParamArgNotMoved(): Void {
		Assert.equals(0, violations('class C { private var _o:Foo; public function new(p:Int) { _o = new Foo(p); } }').length);
	}

	public function testInterpolatedCtorParamRefNotMoved(): Void {
		// `$p` inside a single-quoted string projects as the interp `Ident` kind,
		// not `IdentExpr` - the context-free walk must still see it as a ctor-param
		// reference (the `${p}` block form was already caught via its inner IdentExpr).
		final bare: String = "class C { private final _f:String; public function new(p:String) { _f = 'x/$p.log'; } }";
		Assert.equals(0, violations(bare).length);
		final block: String = "class C { private final _f:String; public function new(p:String) { _f = 'x/${p}.log'; } }";
		Assert.equals(0, violations(block).length);
	}

	public function testInheritedMemberRefNotMoved(): Void {
		// `_w` is an INHERITED field - invisible to the single-file resolver, so an
		// unresolved lowercase ident in a subclass is indistinguishable from an
		// inherited member and must fail closed ("Cannot access this or other
		// member field in variable initialization" once moved). Uppercase roots
		// (type refs like `Colors.WHITE`) stay movable. Neither constructor calls
		// `super()`: an explicit base-constructor call is its own refusal now (see
		// `testSuperCallInCtorNotMoved`), and it would mask the resolver arm this
		// fixture exists to discriminate.
		final sub: String = 'class C extends B { private var _a:X; public function new() { _a = new X(_w / 2); } }';
		Assert.equals(0, violations(sub).length);
		final upper: String = 'class C extends B { private var _a:X; public function new() { _a = new X(Colors.WHITE); } }';
		Assert.equals(1, violations(upper).length);
	}

	/**
	 * THE live regression, anonymized. An early-return guard sits between the constructor's
	 * first statement and the init, so the constructor may exit before ever reaching it — but a
	 * declaration initializer runs in the PROLOGUE, unconditionally, which turned a guarded
	 * asset load into an unguarded one. Nothing downstream catches it: the moved code still
	 * type-checks and still parses. `RefactorSupport.ctorPrefixUnconditional` refuses it.
	 */
	public function testEarlyReturnGuardBeforeInitNotMoved(): Void {
		final src: String = 'class C { static inline final USE_CACHE:Bool = false; static var _instance:C; var asset:Movie;'
			+ ' public function new() { _instance = this; if (!USE_CACHE) return; asset = Loader.get("pack:item");'
			+ ' asset.cached = false; build(); } }';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * The positive control for the fixture above: the SAME class with the guard deleted is
	 * still flagged. The leading `_instance = this;` is a straight-line statement the whitelist
	 * accepts, so the guard is the only difference between the two — which is what proves the
	 * refusal above belongs to the new prefix gate and not to some older one.
	 */
	public function testUnconditionalPrefixStillMoved(): Void {
		final src: String = 'class C { static inline final USE_CACHE:Bool = false; static var _instance:C; var asset:Movie;'
			+ ' public function new() { _instance = this; asset = Loader.get("pack:item"); asset.cached = false; build(); } }';
		Assert.equals(1, violations(src).length);
	}

	/** A `switch` before the init is not straight-line — an arm may exit, and no arm need match. */
	public function testSwitchBeforeInitNotMoved(): Void {
		final src: String =
			'class C { var _a:Array<Int>; public function new(k:Int) { switch k { case 1: return; case _: } _a = new Array<Int>(); } }';
		Assert.equals(0, violations(src).length);
	}

	/** A loop before the init is not straight-line — its body may exit the constructor. */
	public function testLoopBeforeInitNotMoved(): Void {
		final src: String = 'class C { var _a:Array<Int>; public function new(xs:Array<Int>) { for (x in xs) if (x == 0) return;'
			+ ' _a = new Array<Int>(); } }';
		Assert.equals(0, violations(src).length);
	}

	/** A `throw` before the init leaves the constructor outright. */
	public function testThrowBeforeInitNotMoved(): Void {
		Assert.equals(0, violations('class C { var _a:Array<Int>; public function new() { throw "x"; _a = new Array<Int>(); } }').length);
	}

	/**
	 * The hole a kind whitelist alone leaves: a non-block `try` body projects as a plain
	 * EXPRESSION statement, so `try return catch (e:Dynamic) {}` clears the straight-line set
	 * while still exiting the constructor. Only the second term — any `controlExitKinds` node
	 * starting before the init, anywhere in the body subtree — refuses it.
	 */
	public function testNonBlockTryReturnBeforeInitNotMoved(): Void {
		final src: String =
			'class C { var _a:Array<Int>; public function new() { try return catch (e:Dynamic) {} _a = new Array<Int>(); } }';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * THE KIND-WHITELIST PIN — the one shape only that term refuses. A `while (true) { }` prefix
	 * never COMPLETES, so the constructor holds no control-exit node anywhere and the subtree
	 * scan, the gate's other term, finds nothing to object to. The loop is neither an expression
	 * statement nor a local declaration, so the kind whitelist alone is what refuses the hoist:
	 * disable that term and this is the one test that flips.
	 */
	public function testNonTerminatingLoopBeforeInitNotMoved(): Void {
		final src: String = 'class C { var _a:Array<Int>; public function new() { while (true) { } _a = new Array<Int>(); } }';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * The whitelist must not over-refuse. A plain call and a local declaration both leave the init
	 * unconditionally reached, so each one still moves. `super(…)` clears this whitelist too — it
	 * projects as a plain expression statement — but a gate of its own refuses it now, because Haxe
	 * emits declaration initializers BEFORE an explicit `super()` and the hoist would cross the
	 * base-constructor boundary. `testSuperCallInCtorNotMoved` pins that, so neither fixture here
	 * carries one.
	 */
	public function testStraightLinePrefixStillMoved(): Void {
		Assert.equals(1, violations('class C { var _a:Array<Int>; public function new() { trace(1); _a = new Array<Int>(); } }').length);
		Assert.equals(
			1, violations('class C { var _a:Array<Int>; public function new() { var t:Int = 1; _a = new Array<Int>(); } }').length
		);
	}

	/**
	 * Only the lexical PREFIX matters: a branch AFTER the init cannot stop the constructor from
	 * reaching it, so the site still moves.
	 */
	public function testBranchAfterInitStillMoved(): Void {
		final src: String = 'class C { var _a:Array<Int>; public function new(c:Bool) { _a = new Array<Int>(); if (c) return; } }';
		Assert.equals(1, violations(src).length);
	}

	/**
	 * Pins the WHITELIST term `ifStatementKinds`: an `if` holding no control exit ALWAYS
	 * COMPLETES, so the init after it is still reached and still moves. Flips back to 0 if
	 * the whitelist is narrowed to expression statements and local declarations again.
	 */
	public function testUnexitingIfBeforeInitStillMoved(): Void {
		final src: String = 'class C { var _a:Array<Int>; public function new(verbose:Bool) { if (verbose) trace("x");'
			+ ' _a = new Array<Int>(); } }';
		Assert.equals(1, violations(src).length);
	}

	/**
	 * Pins the WHITELIST terms `switchKinds` and `isConditionalKind`: an exit-free `switch`
	 * and a `#if` region complete just as the `if` above does.
	 */
	public function testUnexitingSwitchAndConditionalBeforeInitStillMoved(): Void {
		final sw: String = 'class C { var _a:Array<Int>; public function new(k:Int) { switch k { case 1: trace(1); case _: }'
			+ ' _a = new Array<Int>(); } }';
		Assert.equals(1, violations(sw).length);
		final cond: String = 'class C { var _a:Array<Int>; public function new() { #if debug trace(1); #end _a = new Array<Int>(); } }';
		Assert.equals(1, violations(cond).length);
	}

	/**
	 * Pins the LOOP half of the subtree scan (`controlExitKinds` UNION `loopStatementKinds`):
	 * a non-terminating loop NESTED inside an admitted `if` carries no control-exit node, so
	 * only the loop half can refuse it. Without that half the whitelist would bar a TOP-LEVEL
	 * loop while accepting this one.
	 */
	public function testLoopNestedInIfBeforeInitNotMoved(): Void {
		final src: String = 'class C { var _a:Array<Int>; public function new(c:Bool) { if (c) { while (true) { } }'
			+ ' _a = new Array<Int>(); } }';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * Haxe emits declaration initializers into the constructor PROLOGUE — ahead of the
	 * constructor BODY, and therefore ahead of an explicit `super()` inside it — so hoisting an
	 * init that sits AFTER one runs it before the BASE constructor. Reproduced end to end on
	 * 4.3.7 `--interp`: a subclass whose constructor reads `super(); asset = Loader.get('pack');`
	 * over a base constructor that sets the `Loader.ready` flag `get` consults printed
	 * `real:pack` as written and `TOO-EARLY:pack` once the init moved onto the declaration. ANY
	 * explicit `super(...)` anywhere in the constructor refuses the hoist, on both acceptance
	 * paths.
	 */
	public function testSuperCallInCtorNotMoved(): Void {
		final src: String = 'class C extends B { var asset:String; public function new() { super(); asset = Loader.get("pack"); } }';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * The positive control for the fixture above: the SAME class with the `super();` statement
	 * deleted still moves, so the `super()` call is the only difference between the two. The
	 * shape is REAL Haxe, not a syntactic stand-in: `super()` is required only when the BASE
	 * class DECLARES a constructor. Verified on 4.3.7 `--interp` — `class B { public var z:Int
	 * = 0; }` plus `class C extends B { public var asset:String; public function new()
	 * { asset = 'x'; } }` compiles and runs, printing `x` then `0`, and it is adding
	 * `public function new() {}` to `B` that turns it into `Missing super constructor call`.
	 * So the gate does not refuse every `extends` class — only the ones that call up.
	 */
	public function testNoSuperCallStillMoved(): Void {
		final src: String = 'class C extends B { var asset:String; public function new() { asset = Loader.get("pack"); } }';
		Assert.equals(1, violations(src).length);
	}

	/**
	 * The load-bearing premise of the "deliberately COARSER" argument, under test rather than
	 * only argued: a `super(…)` need not be a top-level statement, so "the init precedes THE
	 * super call" often has no answer at all and the gate refuses the whole constructor
	 * instead. A branch-conditional base-constructor call is legal Haxe — verified on 4.3.7
	 * `--interp`, where `if (c) super(1) else super(2);` and a one-sided `if (f) super(7);`
	 * both compile and run. Measured against the two binaries: 1 violation before the gate,
	 * 0 after.
	 */
	public function testSuperInsideBranchNotMoved(): Void {
		final src: String = 'class C extends B { var a:Int; public function new(f:Bool) { if (f) super(); a = 1; } }';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * The ACCEPTED over-refusal, as a decision under test rather than a paragraph of prose. This
	 * is the `pony/net/cs/SocketClient` shape: the init sits BEFORE the `super(…)`, so it does
	 * NOT cross the base-constructor boundary and the finer rule would keep it. The coarse gate
	 * refuses it anyway, and the class doc argues that one lost cleanup per 676 files is the
	 * right price. Measured: 1 violation before the gate, 0 after. Whoever implements the finer
	 * rule flips THIS assertion back to 1.
	 */
	public function testInitBeforeSuperStillNotMoved(): Void {
		final src: String = 'class C extends B { var _x:Int; public function new() { _x = 1; super(); } function s():Void { _x = 2; } }';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * `holdsSuperCall` matches a CALL whose callee is the bare `super` identifier, deliberately
	 * NOT any `super` reference at all: `super.foo()` is a base-MEMBER access on an already
	 * constructed base, which the prologue does not race. The branch had no coverage. Measured:
	 * 1 violation before the gate and 1 after — this fixture is the one the gate must leave
	 * alone.
	 */
	public function testSuperMemberCallStillMoved(): Void {
		final src: String = 'class C extends B { var _a:Array<Int>; public function new() { super.foo(); _a = new Array<Int>(); } }';
		Assert.equals(1, violations(src).length);
	}

	/** Assert `src` yields exactly one violation and that its declaration span names `field`. */
	private function assertSoleViolationOn(src: String, field: String): Void {
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		final span: Null<Span> = vs[0].span;
		Assert.isTrue(span != null && src.substring(span.from, span.to).indexOf(field) >= 0);
	}

	private function violations(src: String): Array<Violation> {
		return new FieldInitAtDeclaration().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixedSource(src: String): String {
		final check: FieldInitAtDeclaration = new FieldInitAtDeclaration();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final edits: Array<{ span: Span, text: String }> = check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in sorted) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
