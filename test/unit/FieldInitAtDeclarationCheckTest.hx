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
 * whole container (its interior is trivia here). A static field, a property, a
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

	/** A leading `super(...)` is not a candidate init, so the chain breaks — left alone. */
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
		// (type refs like `Colors.WHITE`) stay movable.
		final sub: String = 'class C extends B { private var _a:X; public function new() { super(); _a = new X(_w / 2); } }';
		Assert.equals(0, violations(sub).length);
		final upper: String = 'class C extends B { private var _a:X; public function new() { super(); _a = new X(Colors.WHITE); } }';
		Assert.equals(1, violations(upper).length);
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
