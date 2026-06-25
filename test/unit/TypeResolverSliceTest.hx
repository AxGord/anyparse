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

}
