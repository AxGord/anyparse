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
		final src: String = 'typedef Ctx = { var f:Int; }; class C { static function mk():Ctx { return null; } static function m():Void { final c = mk(); final dead = c.f; } }';
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
			if (b != null) {
				bindingFrom = b.from;
				break;
			}
		}
		Assert.notEquals(-1, bindingFrom, 'the receiver `c` binding should resolve');
		Assert.equals('Ctx', declTypes[bindingFrom], 'declaredTypes should map the binding span to Ctx');
	}

	public function testClassGetterFieldKept(): Void {
		final src: String = 'class T { public var f(get, never):Int; } class C { static function m(t:T):Int { final dead = t.f; return 1; } }';
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

	public function testNonNullValueType(): Void {
		Assert.isTrue(
			nonNull('class C { static function m(x:Int):Void { if (x != null) {} } }'),
			'an Int operand is non-null regardless of null-safety'
		);
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
			'a member-level @:nullSafety without a class/module annotation does not affirm — kept strictly no-more-affirming than the class-level predicate'
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
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(src);
		final shape: RefShape = plugin.refShape();
		final declaredTypes: Map<Int, String> = plugin.declaredTypes(src);
		final operand: Null<QueryNode> = nullCheckOperand(tree, shape);
		Assert.notNull(operand, 'fixture must contain a `… != null` comparison');
		return operand != null && TypeResolver.isProvablyNonNull(operand, tree, shape, declaredTypes);
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
		final project: String = 'class Path { public static function join(a:Array<String>):String { return ""; } } class C { static function m():Int { final dead = Path.join(["a"]); return 1; } }';
		Assert.equals(0, fixEdits(project).length, 'a project-declared Path shadows stdlib — kept');
		final local: String = 'class C { static function m():Int { final Date = 0; final dead = Date.now(); return 1; } }';
		Assert.equals(0, fixEdits(local).length, 'a local Date binding is not the stdlib type — kept');
	}

}
