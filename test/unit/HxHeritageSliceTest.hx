package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxHeritageClause;
import anyparse.grammar.haxe.HxInterfaceDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxType;
import anyparse.runtime.ParseError;

/**
 * Slice ω-heritage: `extends`/`implements` clauses on class and
 * interface declarations, modelled as a bare
 * `Array<HxHeritageClause>` field between `typeParams` and `members`
 * (structural twin of `HxAbstractDecl.clauses`).
 *
 * Covers single/multi clauses, heritage after type params, the
 * no-heritage case staying empty, a `#if`-wrapped class with heritage
 * (the original apq sweep failure that was masked behind module-level
 * `#if`), writer round-trip, and the keyword word boundary.
 */
class HxHeritageSliceTest extends HxTestHelpers {

	public function testClassExtends(): Void {
		final module: HxModule = HaxeModuleParser.parse('class Foo extends Bar {}');
		Assert.equals(1, module.decls.length);
		final c: HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals('Foo', (c.name: String));
		Assert.equals(1, c.heritage.length);
		Assert.isTrue(isExtends(c.heritage[0]));
		Assert.equals('Bar', (expectNamedType(clauseType(c.heritage[0])).name: String));
	}

	public function testClassImplements(): Void {
		final module: HxModule = HaxeModuleParser.parse('class Foo implements Bar {}');
		Assert.equals(1, module.decls.length);
		final c: HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals(1, c.heritage.length);
		Assert.isFalse(isExtends(c.heritage[0]));
		Assert.equals('Bar', (expectNamedType(clauseType(c.heritage[0])).name: String));
	}

	public function testClassExtendsAndMultipleImplements(): Void {
		final module: HxModule = HaxeModuleParser.parse('class Foo extends Base implements I1 implements I2 {}');
		final c: HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals(3, c.heritage.length);
		Assert.isTrue(isExtends(c.heritage[0]));
		Assert.equals('Base', (expectNamedType(clauseType(c.heritage[0])).name: String));
		Assert.isFalse(isExtends(c.heritage[1]));
		Assert.equals('I1', (expectNamedType(clauseType(c.heritage[1])).name: String));
		Assert.isFalse(isExtends(c.heritage[2]));
		Assert.equals('I2', (expectNamedType(clauseType(c.heritage[2])).name: String));
	}

	public function testHeritageAfterTypeParams(): Void {
		final module: HxModule = HaxeModuleParser.parse('class Foo<T> extends Bar<T> {}');
		final c: HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals('Foo', (c.name: String));
		Assert.notNull(c.typeParams);
		Assert.equals(1, c.heritage.length);
		Assert.isTrue(isExtends(c.heritage[0]));
		Assert.equals('Bar', (expectNamedType(clauseType(c.heritage[0])).name: String));
	}

	public function testInterfaceExtendsMultiple(): Void {
		final module: HxModule = HaxeModuleParser.parse('interface I extends A extends B {}');
		Assert.equals(1, module.decls.length);
		final iface: HxInterfaceDecl = expectInterfaceDecl(module.decls[0]);
		Assert.equals('I', (iface.name: String));
		Assert.equals(2, iface.heritage.length);
		Assert.equals('A', (expectNamedType(clauseType(iface.heritage[0])).name: String));
		Assert.equals('B', (expectNamedType(clauseType(iface.heritage[1])).name: String));
	}

	public function testNoHeritageStaysEmpty(): Void {
		final module: HxModule = HaxeModuleParser.parse('class Plain { var x:Int; }');
		final c: HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals('Plain', (c.name: String));
		Assert.equals(0, c.heritage.length);
		Assert.equals(1, c.members.length);
	}

	public function testHeritageWhitespace(): Void {
		final module: HxModule = HaxeModuleParser.parse('  class  Foo  extends  Bar  implements  I  {  }  ');
		final c: HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals(2, c.heritage.length);
		Assert.isTrue(isExtends(c.heritage[0]));
		Assert.isFalse(isExtends(c.heritage[1]));
	}

	// -- The original apq sweep failure: heritage masked behind module #if --

	public function testHeritageInsideConditional(): Void {
		final src: String = '#if macro\nclass Foo implements Bar {}\n#end';
		Assert.equals(1, HaxeModuleParser.parse(src).decls.length);
		roundTrip(src, 'class implements inside #if');
	}

	// -- Writer: extends/implements keywords must round-trip --

	public function testWriterPreservesHeritage(): Void {
		roundTrip('class Foo extends Bar {}', 'class extends idempotency');
		roundTrip('class Foo implements Bar {}', 'class implements idempotency');
		roundTrip('interface I extends A extends B {}', 'interface extends idempotency');
	}

	// -- Word boundary: `extendsX` is not the `extends` keyword --

	public function testWordBoundaryExtendslike(): Void {
		// `extendsBar` is a single identifier, not `extends Bar`; the
		// stray token where the `{` body is expected fails the parse.
		Assert.raises(HaxeModuleParser.parse.bind('class Foo extendsBar {}'), ParseError);
	}

	private function clauseType(clause: HxHeritageClause): HxType {
		return switch clause {
			case ExtendsClause(type): type;
			case ImplementsClause(type): type;
		};
	}

	private function isExtends(clause: HxHeritageClause): Bool {
		return switch clause {
			case ExtendsClause(_): true;
			case ImplementsClause(_): false;
		};
	}

}
