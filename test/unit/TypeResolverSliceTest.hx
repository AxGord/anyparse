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

	public function testClassFieldAccessKept(): Void {
		final src: String = 'class T { public var f:Int; } class C { static function m(t:T):Void { final dead = t.f; } }';
		Assert.equals(0, fixEdits(src).length, 'a class receiver is not an anon struct — kept');
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

}
