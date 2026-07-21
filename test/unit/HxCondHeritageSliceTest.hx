package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxHeritageClause;
import anyparse.grammar.haxe.HxModule;

/**
 * Tests for `HxHeritageClause.Conditional` — a `#if <cond> ... #end`
 * region as an element of the heritage Star, so the `extends` /
 * `implements` keyword itself may live inside the guard.
 *
 * Nine of openfl's remaining unparseable modules need this:
 * `class Window #if lime extends LimeWindow #end`,
 * `class Stage extends DisplayObjectContainer #if lime implements IModule #end`,
 * and `openfl.errors.Error`, whose chain needs the `#elseif` arm.
 *
 * Distinct from a conditional in the TYPE slot of a clause
 * (`extends #if x A #else B #end`), which `HxType` already covered via
 * `HxConditionalType` — the last regression case below pins that both
 * still work and that an unguarded heritage list is untouched.
 */
class HxCondHeritageSliceTest extends HxTestHelpers {

	public function testConditionalExtendsBeforeAnyClause(): Void {
		final ast: HxModule = HaxeModuleParser.parse('class C #if lime extends L #end {}');
		final heritage: Array<HxHeritageClause> = classHeritage(ast);
		Assert.equals(1, heritage.length);
		switch heritage[0] {
			case Conditional(inner):
				Assert.equals('lime', (inner.cond: String));
				Assert.equals(1, inner.body.length);
				switch inner.body[0] {
					case ExtendsClause(_): Assert.pass();
					case _: Assert.fail('expected ExtendsClause, got ${inner.body[0]}');
				}
			case _:
				Assert.fail('expected Conditional, got ${heritage[0]}');
		}
	}

	public function testConditionalImplementsAfterPlainExtends(): Void {
		// openfl Stage / DisplayObject shape.
		final ast: HxModule = HaxeModuleParser.parse('class C extends D #if lime implements I #end {}');
		final heritage: Array<HxHeritageClause> = classHeritage(ast);
		Assert.equals(2, heritage.length);
		switch heritage[0] {
			case ExtendsClause(_):
				Assert.pass();
			case _:
				Assert.fail('expected ExtendsClause first, got ${heritage[0]}');
		}
		switch heritage[1] {
			case Conditional(_):
				Assert.pass();
			case _:
				Assert.fail('expected Conditional second, got ${heritage[1]}');
		}
	}

	public function testElseifArmCarriesItsOwnClause(): Void {
		// openfl.errors.Error shape.
		final src: String = 'class C #if (a >= "4.1.0") extends E #elseif (b && c) implements D #end {}';
		final heritage: Array<HxHeritageClause> = classHeritage(HaxeModuleParser.parse(src));
		switch heritage[0] {
			case Conditional(inner):
				Assert.equals(1, inner.elseifs.length);
				Assert.equals('(b && c)', (inner.elseifs[0].cond: String));
				switch inner.elseifs[0].body[0] {
					case ImplementsClause(_): Assert.pass();
					case _: Assert.fail('expected ImplementsClause, got ${inner.elseifs[0].body[0]}');
				}
			case _:
				Assert.fail('expected Conditional, got ${heritage[0]}');
		}
	}

	public function testConditionalHeritageOnInterface(): Void {
		final ast: HxModule = HaxeModuleParser.parse('interface I #if x extends A #end {}');
		switch ast.decls[0].decl {
			case InterfaceDecl(i):
				Assert.equals(1, i.heritage.length);
			case _:
				Assert.fail('expected InterfaceDecl, got ${ast.decls[0].decl}');
		}
	}

	public function testConditionalHeritageWritesVerbatim(): Void {
		for (src in [
			'class C #if lime extends L #end {}',
			'class C extends D #if lime implements I #end {}',
			'class C #if (a >= "4.1.0") extends E #elseif (b && c) implements D #end {}'
		]) roundTrip(src, src);
	}

	public function testTypeSlotConditionalAndPlainHeritageUnaffected(): Void {
		final typeSlot: Array<HxHeritageClause> = classHeritage(HaxeModuleParser.parse('class C extends #if x A #else B #end {}'));
		Assert.equals(1, typeSlot.length);
		switch typeSlot[0] {
			case ExtendsClause(_):
				Assert.pass();
			case _:
				Assert.fail('expected ExtendsClause, got ${typeSlot[0]}');
		}
		final plain: Array<HxHeritageClause> = classHeritage(HaxeModuleParser.parse('class C extends A implements B {}'));
		Assert.equals(2, plain.length);
		Assert.equals(0, classHeritage(HaxeModuleParser.parse('class C {}')).length);
	}

	private function classHeritage(ast: HxModule): Array<HxHeritageClause> {
		return switch ast.decls[0].decl {
			case ClassDecl(c): c.heritage;
			case _: throw 'expected ClassDecl, got ${ast.decls[0].decl}';
		};
	}

}
