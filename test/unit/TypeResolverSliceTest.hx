package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.UnusedLocal;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import anyparse.query.TypeResolver;

/**
 * Type-resolver MVP (getter-purity): `unused-local`'s autofix now deletes a
 * dead `final x = recv.field;` when `recv` is an anonymous-struct value (whose
 * fields can never be property getters), and keeps every receiver it cannot
 * resolve to an anon struct. Also covers the decl-type side-table
 * (`HaxeQueryPlugin.declaredTypes`) span-alignment with `Refs` bindings.
 */
class TypeResolverSliceTest extends Test {

	public function testAnonStructFieldAccessDeleted(): Void {
		final src: String = wrap('c: Ctx', 'final dead = c.f;');
		Assert.equals(1, fixEdits(src).length, 'a dead anon-struct field read should be deletable');
	}

	public function testClassPlainFieldDeleted(): Void {
		final src: String = 'class T { public var f:Int; } class C { static function m(t:T):Int { final dead = t.f; return 1; } }';
		Assert.equals(1, fixEdits(src).length, 'a plain class field read is side-effect-free — deletable');
	}

	public function testUnannotatedReceiverKept(): Void {
		final src: String = 'typedef Ctx = { var f:Int; }; class C { static function mk():Ctx { return null; } static function m():Void {'
			+ ' final c = mk(); final dead = c.f; } }';
		Assert.equals(0, fixEdits(src).length, 'no annotation on the receiver → unresolved → kept');
	}

	public function testNoIndexKept(): Void {
		final src: String = wrap('c: Ctx', 'final dead = c.f;');
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: UnusedLocal = new UnusedLocal();
		final violations: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		Assert.equals(0, check.fix(src, violations, plugin).length, 'no symbol index → conservative status quo');
	}

	public function testDeclaredTypeSpanAlignment(): Void {
		final src: String = wrap('c: Ctx', 'final dead = c.f;');
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final declTypes: Map<Int, String> = plugin.declaredTypes(src);
		final tree: QueryNode = plugin.parseFile(src);
		final shape: RefShape = plugin.refShape();
		var bindingFrom: Int = -1;
		for (hit in Refs.find('c', tree, shape)) {
			final b: Null<Span> = hit.bindingSpan;
			if (b == null) continue;
			bindingFrom = b.from;
			break;
		}
		Assert.notEquals(-1, bindingFrom, 'the receiver `c` binding should resolve');
		Assert.equals('Ctx', declTypes[bindingFrom], 'declaredTypes should map the binding span to Ctx');
	}

	public function testClassGetterFieldKept(): Void {
		final src: String =
			'class T { public var f(get, never):Int; } class C { static function m(t:T):Int { final dead = t.f; return 1; } }';
		Assert.equals(0, fixEdits(src).length, 'a getter property read may run code — kept');
	}

	public function testThisPlainFieldDeleted(): Void {
		final src: String = 'class C { var f:Int; function m():Int { final dead = this.f; return 1; } }';
		Assert.equals(1, fixEdits(src).length, 'this.f on a plain field is side-effect-free — deletable');
	}

	public function testThisGetterFieldKept(): Void {
		final src: String = 'class C { var f(get, never):Int; function m():Int { final dead = this.f; return 1; } }';
		Assert.equals(0, fixEdits(src).length, 'this.f on a getter property may run code — kept');
	}

	public function testCustomMethodAccessorKept(): Void {
		// A custom-named read accessor (`getF`) runs code on read — not a plain field.
		final src: String = 'class C { var f(getF, never):Int; function m():Int { final dead = this.f; return 1; } }';
		Assert.equals(0, fixEdits(src).length, 'a custom-method read accessor may run code — kept');
	}

	/**
	 * Two TRANSPARENT single-child wrapper shapes reuse the underlying operand's
	 * purity: the unchecked cast `cast expr` and a parenthesized expression. Both
	 * are exercised alone, nested together, and with an impure operand (kept) —
	 * plus the runtime-CHECKED `cast(expr, T)`, which stays refused because it can
	 * THROW on a type mismatch (a negative fixture pinning that invariant).
	 */
	public function testUncheckedCastOfPlainFieldDeleted(): Void {
		final src: String = 'class T { public var f:Int; } class C { static function m(t:T):Int { final dead = cast t.f; return 1; } }';
		Assert.equals(1, fixEdits(src).length, 'an unchecked cast of a plain field read is transparent — deletable');
	}

	public function testParenWrappedFieldDeleted(): Void {
		final src: String = 'class T { public var f:Int; } class C { static function m(t:T):Int { final dead = (t.f); return 1; } }';
		Assert.equals(1, fixEdits(src).length, 'a parenthesized plain field read is transparent — deletable');
	}

	public function testNestedCastParenDeleted(): Void {
		final src: String = 'class T { public var f:Int; } class C { static function m(t:T):Int { final dead = cast (t.f); return 1; } }';
		Assert.equals(1, fixEdits(src).length, 'a cast wrapping a parenthesized plain field read is deletable through both wrappers');
	}

	public function testUncheckedCastOfImpureCallKept(): Void {
		final src: String = 'class C { static function m(o:T):Int { final dead = cast o.foo(); return 1; } }';
		Assert.equals(0, fixEdits(src).length, 'an unchecked cast of an unresolved instance call stays impure through the wrapper — kept');
	}

	public function testParenWrappedImpureCallKept(): Void {
		final src: String = 'class C { static function m(o:T):Int { final dead = (o.foo()); return 1; } }';
		Assert.equals(0, fixEdits(src).length, 'a parenthesized unresolved instance call stays impure through the wrapper — kept');
	}

	public function testTypedCastKept(): Void {
		final src: String =
			'class T { public var f:Int; } class C { static function m(t:T):Int { final dead = cast(t.f, Int); return 1; } }';
		Assert.equals(0, fixEdits(src).length, 'the runtime-CHECKED cast can throw on a mismatch — not a transparent wrapper, kept');
	}

	public function testNonNullValueType(): Void {
		Assert.isTrue(
			nonNull('class C { static function m(x:Int):Void { if (x != null) {} } }'),
			'an Int operand is non-null regardless of null-safety'
		);
	}

	/**
	 * The two entry points DIVERGE on exactly one arm. `isProvablyNonNull` grants the value
	 * type; `isProvablyNonNullAtNullComparison` does not, because the comparison the caller is
	 * asking about does not compile on a static target ("On static platforms, null can't be
	 * used as basic type Int") — so its presence proves the target is one where `Int` is
	 * nullable.
	 */
	public function testValueTypeSplitBetweenEntryPoints(): Void {
		final src: String = 'class C { static function m(x:Int):Void { if (x != null) {} } }';
		Assert.isTrue(nonNull(src), 'the general predicate still grants the value type');
		Assert.isFalse(nonNullAtNullComparison(src), 'the null-comparison predicate declines it');
	}

	/** Under null safety the same operand is proven by the NOMINAL arm, so both agree again. */
	public function testValueTypeUnderNullSafetyAgreesAcrossEntryPoints(): Void {
		final src: String = '@:nullSafety(Strict) class C { static function m(x:Int):Void { if (x != null) {} } }';
		Assert.isTrue(nonNull(src), 'null safety normalises Int to non-nullable on every target');
		Assert.isTrue(nonNullAtNullComparison(src), 'the null-comparison predicate keeps the null-safety proof');
	}

	/**
	 * A declaration initialised by the literal `null` is nullable by its own syntax, ahead of
	 * both the value-type and the null-safety arm — the `pony` `esVersion: Int = null` shape,
	 * and its nominal twin. BOTH entry points must decline.
	 */
	public function testNullInitialisedDeclRejectedByBoth(): Void {
		final valueField: String = 'class C { var esVersion:Int = null; function m():Void { if (esVersion != null) {} } }';
		Assert.isFalse(nonNull(valueField), 'a `= null` value-typed field is nullable');
		Assert.isFalse(nonNullAtNullComparison(valueField), 'and stays so at a null comparison');
		final nominalLocal: String = '@:nullSafety(Strict) class C { static function m():Void { var s:Foo = null; if (s != null) {} } }';
		Assert.isFalse(nonNull(nominalLocal), 'a `= null` local outranks the null-safety proof');
	}

	public function testNonNullNominalUnderNullSafety(): Void {
		Assert.isTrue(
			nonNull('@:nullSafety class C { static function m(x:Foo):Void { if (x != null) {} } }'),
			'a nominal operand under @:nullSafety is provably non-null'
		);
	}

	public function testNonNullNullWrapperRejected(): Void {
		Assert.isFalse(
			nonNull('@:nullSafety class C { static function m(x:Null<Foo>):Void { if (x != null) {} } }'),
			'Null<Foo> stays nullable even under null-safety'
		);
	}

	public function testNonNullOptionalParamRejected(): Void {
		Assert.isFalse(
			nonNull('@:nullSafety class C { static function m(?x:Foo):Void { if (x != null) {} } }'),
			'an optional parameter is nullable despite a nominal annotation'
		);
	}

	public function testNonNullWithoutNullSafetyRejected(): Void {
		Assert.isFalse(
			nonNull('class C { static function m(x:Foo):Void { if (x != null) {} } }'),
			'a nominal operand without null-safety is not provably non-null'
		);
	}

	public function testNonNullMemberOffFieldRejected(): Void {
		Assert.isFalse(
			nonNull('@:nullSafety(Strict) class C { @:nullSafety(Off) var f:Foo; function m():Void { if (f != null) {} } }'),
			'a member-level @:nullSafety(Off) field escapes null-safety even inside a Strict class'
		);
	}

	public function testNonNullMemberOffMethodRejected(): Void {
		Assert.isFalse(
			nonNull('@:nullSafety(Strict) class C { var f:Foo; @:nullSafety(Off) function m():Void { if (f != null) {} } }'),
			'a read inside a @:nullSafety(Off) method is not provably non-null'
		);
	}

	public function testNonNullMemberStrictWithoutClassNotAffirmed(): Void {
		Assert.isFalse(
			nonNull('class C { @:nullSafety(Strict) static function m(x:Foo):Void { if (x != null) {} } }'),
			'a member-level @:nullSafety without a class/module annotation does not affirm — kept strictly no-more-affirming than the '
			+ 'class-level predicate'
		);
	}

	public function testNonNullClassOffMemberStrictRejected(): Void {
		Assert.isFalse(
			nonNull('@:nullSafety(Off) class C { @:nullSafety(Strict) static function m(x:Foo):Void { if (x != null) {} } }'),
			'an inner @:nullSafety(Strict) does not re-enable a disabled outer class (Haxe 4.3.7 semantics)'
		);
	}

	public function testNonNullExplicitStrictAffirmed(): Void {
		Assert.isTrue(
			nonNull('@:nullSafety(Strict) class C { static function m(x:Foo):Void { if (x != null) {} } }'),
			'a nominal operand under explicit @:nullSafety(Strict) is provably non-null'
		);
	}

	public function testNonNullExplicitLooseAffirmed(): Void {
		Assert.isTrue(
			nonNull('@:nullSafety(Loose) class C { static function m(x:Foo):Void { if (x != null) {} } }'),
			'Loose rejects null into a non-nullable binding just as Strict does — trusted for this proof'
		);
	}

	public function testReshadowedNullableParamNotAffirmed(): Void {
		// A later same-name non-null local (`final n:String = n;`) must NOT poison the
		// proof for the EARLIER `n == null` guard on the nullable param: the first-wins
		// scope resolver binds the guard's `n` to the later, non-null shadow, so the
		// proof must bail when the name is re-shadowed in a scope visible at the use
		// (mirrors `identDeclaredTypeSource`). This is the root of the 8-consumer family.
		Assert.isFalse(
			nonNull(
				'@:nullSafety(Strict) class C { static function m(n:Null<String>):Void { if (n == null) '
				+ 'return; final n:String = n; trace(n); } }'
			),
			'a nullable param re-shadowed by a later same-name non-null local is NOT provably non-null at the earlier guard'
		);
	}

	/**
	 * The autofix now deletes a dead local whose initializer is a provably-pure
	 * stdlib static call: `Date.now()` (no args) and a fully-qualified
	 * `haxe.io.Path.join([...])` whose `ArrayExpr` elements are side-effect-free.
	 */
	public function testPureStdlibCallDeleted(): Void {
		final now: String = 'class C { static function m():Int { final dead = Date.now(); return 1; } }';
		Assert.equals(1, fixEdits(now).length, 'Date.now() is a pure stdlib static call — deletable');
		final path: String = 'class C { static function m():Int { final dead = haxe.io.Path.join(["a", "b"]); return 1; } }';
		Assert.equals(1, fixEdits(path).length, 'haxe.io.Path.join of pure args — deletable');
	}

	/**
	 * A call the pure-stdlib whitelist does not cover is kept: an impure stdlib
	 * member (`Math.random`, `Sys.getEnv`), an unknown instance call, and a
	 * whitelisted call whose argument is itself impure (`Std.string(o.foo())`).
	 */
	public function testImpureOrUnknownCallKept(): Void {
		Assert.equals(
			0, fixEdits('class C { static function m():Int { final dead = Math.random(); return 1; } }').length,
			'Math.random advances PRNG state — kept'
		);
		Assert.equals(
			0, fixEdits('class C { static function m():Int { final dead = Sys.getEnv("X"); return 1; } }').length,
			'Sys is not whitelisted — kept'
		);
		Assert.equals(
			0, fixEdits('class C { static function m(o:T):Int { final dead = o.foo(); return 1; } }').length,
			'an unknown instance call — kept'
		);
		Assert.equals(
			0, fixEdits('class C { static function m(o:T):Int { final dead = Std.string(o.foo()); return 1; } }').length,
			'a whitelisted call with an impure argument — kept'
		);
	}

	/**
	 * A stdlib name shadowed by a project type or a local binding is kept: a
	 * project `Path` class (`declaringFiles` non-empty) and a local `Date`
	 * variable (the receiver resolves to a binding, not a type reference).
	 */
	public function testStdlibShadowKept(): Void {
		final project: String = 'class Path { public static function join(a:Array<String>):String { return ""; } } class C {'
			+ ' static function m():Int { final dead = Path.join(["a"]); return 1; } }';
		Assert.equals(0, fixEdits(project).length, 'a project-declared Path shadows stdlib — kept');
		final local: String = 'class C { static function m():Int { final Date = 0; final dead = Date.now(); return 1; } }';
		Assert.equals(0, fixEdits(local).length, 'a local Date binding is not the stdlib type — kept');
	}

	/**
	 * End-to-end canary: the dead local's initializer reads a plain field declared on a
	 * GENERIC supertype, so `isPlainFieldRead` must prove it accessor-less and the fix
	 * must delete the local.
	 */
	public function testInheritedPlainFieldDeleted(): Void {
		final src: String = 'class Base<T> { public final d:T; } class Sub extends Base<Int> {} class C { static function m(s:Sub):Int {'
			+ ' final dead = cast s.d; return 1; } }';
		Assert.equals(1, fixEdits(src).length, 'an inherited plain field read is side-effect-free — deletable');
	}

	/** The same shape with a GETTER on the base: reading it may run code, so the local stays. */
	public function testInheritedGetterFieldKept(): Void {
		final src: String = 'class Base<T> { public var f(get, never):Int; } class Sub extends Base<Int> {} class C {'
			+ ' static function m(s:Sub):Int { final dead = cast s.f; return 1; } }';
		Assert.equals(0, fixEdits(src).length, 'an inherited getter property read may run code — kept');
	}

	/** The `this`-receiver branch resolves through the enclosing type's supertype chain too. */
	public function testThisInheritedPlainFieldDeleted(): Void {
		final src: String = 'class Base { public var f:Int; } class C extends Base { function m():Int { final dead = this.f; return 1; } }';
		Assert.equals(1, fixEdits(src).length, 'this.f on an inherited plain field is side-effect-free — deletable');
	}

	private function wrap(param: String, body: String): String {
		return 'typedef Ctx = { var f:Int; }; class C { static function m($param):Void { $body } }';
	}

	private function fixEdits(src: String): Array<{ span: Span, text: String }> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		final check: UnusedLocal = new UnusedLocal();
		final violations: Array<Violation> = check.run(files, plugin);
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		return check.fix(src, violations, plugin, index);
	}

	private function nonNull(src: String): Bool {
		return proveNonNull(src, false);
	}

	/** `nonNull`'s twin over the null-COMPARISON entry point — the same fixture, the other predicate. */
	private function nonNullAtNullComparison(src: String): Bool {
		return proveNonNull(src, true);
	}

	/** The `… != null` operand of `src`, put to whichever `TypeResolver` entry point is asked for. */
	private function proveNonNull(src: String, atNullComparison: Bool): Bool {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(src);
		final shape: RefShape = plugin.refShape();
		final declaredTypes: Map<Int, String> = plugin.declaredTypes(src);
		final operand: Null<QueryNode> = nullCheckOperand(tree, shape);
		Assert.notNull(operand, 'fixture must contain a `… != null` comparison');
		if (operand == null) return false;
		final found: QueryNode = operand;
		return atNullComparison
			? TypeResolver.isProvablyNonNullAtNullComparison(found, tree, shape, declaredTypes)
			: TypeResolver.isProvablyNonNull(found, tree, shape, declaredTypes);
	}

	private function nullCheckOperand(tree: QueryNode, shape: RefShape): Null<QueryNode> {
		final equalityKinds: Array<String> = shape.equalityKinds ?? [];
		final nullLit: Null<String> = shape.nullLiteralKind;
		if (nullLit == null) return null;
		var found: Null<QueryNode> = null;
		function walk(n: QueryNode): Void {
			if (found != null) return;
			if (n.children.length == 2 && equalityKinds.contains(n.kind)) {
				final leftIsNull: Bool = n.children[0].kind == nullLit;
				final rightIsNull: Bool = n.children[1].kind == nullLit;
				if (leftIsNull != rightIsNull) {
					found = leftIsNull ? n.children[1] : n.children[0];
					return;
				}
			}
			for (c in n.children) walk(c);
		}
		walk(tree);
		return found;
	}

}
