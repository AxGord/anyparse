package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import haxe.Exception;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The typer's answers for an expression asked as a value of its own where the deep walk's arcs do not reach it
 * (`ValueDoors`), and the two shapes the walk carries the type of (`TypingService.typeWalk`): each as Haxe 4.3.7 types it,
 * or null where the walk cannot say exactly — a type name read as a value, a local declaration, an ascription
 * `(e : T)`, a text segment of an interpolated string.
 */
@:nullSafety(Strict)
class ValueDoorsTest extends Test {

	/** The fixture module: each case is the node of a kind starting at a marked text. */
	private static final SOURCE: String = 'package p;\n\nenum E {\n\tA;\n}\n\nenum F {\n\tItemCtor;\n}\n\n'
		+ 'interface I {}\n\nclass Item {}\n\nclass ItemCtor {}\n\nclass Shadow {}\n\nclass Box<T> {}\n\nclass C {\n'
		+ '\tvar Shadow: Int;\n\n\tfunction f(x: Int) {\n\t\tItem;\n\t\tE;\n\t\tI;\n\t\tBox;\n\t\tShadow;\n\t\tItemCtor;\n'
		+ '\t\tfinal written: Array<Int> = [];\n\t\tfinal inferred = 5;\n\t\tfinal open = null;\n'
		+ '\t\tvar first: Int = 1, second = 2;\n\t\t(x : Float);\n\t\tfinal held = (x : Float);\n\t\theld;\n'
		+ '\t\t\'a $$x b\';\n\t}\n}\n';

	@:pin('control')
	@:killer('M-DOOR-TYPE-VALUE-NULL')
	public function testATypeNameReadAsAValueIsItsClassValue(): Void {
		Assert.same({ source: 'Class<Item>', nominal: 'Class' }, typed('IdentExpr', '\t\tItem;'), 'a class');
		Assert.same({ source: 'Enum<E>', nominal: 'Enum' }, typed('IdentExpr', '\t\tE;'), 'an enum');
		Assert.same({ source: 'Class<I>', nominal: 'Class' }, typed('IdentExpr', '\t\tI;'), 'an interface');
	}

	@:pin('control')
	@:killer('M-DOOR-TYPE-VALUE-GENERIC')
	public function testAGenericTypeReadAsAValueIsUnknown(): Void {
		Assert.same({ source: null, nominal: null }, typed('IdentExpr', '\t\tBox;'), 'its value carries arguments nothing spells');
	}

	@:pin('control')
	@:killer('M-DOOR-TYPE-VALUE-SHADOWED-TRUE')
	public function testAValueOfTheTypesNameShadowsTheType(): Void {
		Assert.equals('Int', typed('IdentExpr', '\t\tShadow;').source, 'a member of the enclosing type is read before a type');
		Assert.same({ source: null, nominal: null }, typed('IdentExpr', '\t\tItemCtor;'), 'so is a constructor of the module');
	}

	@:pin('control')
	@:killer('M-DOOR-DECLARATION-NULL')
	public function testADeclarationIsTheTypeOfTheValueItBinds(): Void {
		Assert.same({ source: 'Array<Int>', nominal: 'Array' }, typed('FinalStmt', 'final written'), 'as written');
		Assert.same({ source: 'Int', nominal: 'Int' }, typed('FinalStmt', 'final inferred'), 'its initializer\'s, with none written');
		Assert.same({ source: null, nominal: null }, typed('FinalStmt', 'final open'), 'a value the compiler leaves open');
	}

	@:pin('control')
	@:killer('M-DOOR-DECLARATION-SEVERAL')
	public function testADeclarationBindingSeveralValuesIsUnknown(): Void {
		Assert.same({ source: null, nominal: null }, typed('VarStmt', 'var first'), 'no one value is the declaration\'s');
	}

	@:pin('control')
	@:killer('M-DOOR-DECLARATION-WRITTEN-FIRST')
	public function testADeclarationWrittenWithATypeIsThatTypeWhateverItsInitializer(): Void {
		Assert.equals('Array<Int>', typed('FinalStmt', 'final written').source, 'not its `[]`');
	}

	@:pin('control')
	@:killer('M-WALK-ASCRIBED-NULL')
	public function testAnAscriptionIsTheTypeItWrites(): Void {
		Assert.same({ source: 'Float', nominal: 'Float' }, typed('ECheckTypeExpr', '\t\t(x : Float);'), 'not its value\'s');
		Assert.same({ source: 'Float', nominal: 'Float' }, typed('IdentExpr', '\t\theld;'), 'a local it initializes');
	}

	@:pin('control')
	@:killer('M-WALK-SEGMENT-NULL')
	public function testAStringSegmentIsAString(): Void {
		Assert.same({ source: 'String', nominal: 'String' }, typed('Literal', 'a $$x'), 'a piece of a string literal');
	}

	/** Both currencies' answers for the node of `kind` starting at the first character of the first `at` of `SOURCE`. */
	private static function typed(kind: String, at: String): { source: Null<String>, nominal: Null<String> } {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final root: QueryNode = plugin.parseFile(SOURCE);
		final from: Int = SOURCE.indexOf(at) + at.length - at.ltrim().length;
		var found: Null<QueryNode> = null;
		function walk(node: QueryNode): Void {
			if (found == null && node.kind == kind && node.span?.from == from) found = node;
			for (c in node.children) walk(c);
		}
		walk(root);
		final node: QueryNode = found ?? throw new Exception('no $kind at $from');
		final chain: ChainTypeContext = {
			declaredTypeSources: plugin.declaredTypeSources(SOURCE),
			source: SOURCE,
			castTargetSources: () -> plugin.castTargetSources(SOURCE),
			typeSyntax: plugin.typeSyntax
		};
		final index: SymbolIndex = SymbolIndex.build([{ file: 'p/C.hx', source: SOURCE }], plugin);
		final declared: Map<Int, String> = plugin.declaredTypes(SOURCE);
		return {
			source: NominalTypes.expressionTypeSource(node, root, plugin.refShape(), declared, index, 'p/C.hx', chain),
			nominal: NominalTypes.expressionTypeNominal(node, root, plugin.refShape(), declared, index, 'p/C.hx', chain)
		};
	}

}
