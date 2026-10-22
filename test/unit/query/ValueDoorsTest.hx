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
		+ '\t\t\'a $$x b\';\n\t\tfinal big = 3000000000;\n\t}\n}\n';

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

	public function testAConstructorOfATypeAUsingBringsShadowsTheType(): Void {
		final tools: String = 'package p;\n\nenum UMode {\n\tUsg;\n}\n\nclass Tools {}\n';
		final text: String = 'package p;\n\nusing p.Tools;\n\nclass D {\n\tfunction f() {\n\t\tUsg;\n\t}\n}\n';
		final others: Array<{ file: String, source: String }> = [
			{ file: 'p/Tools.hx', source: tools },
			{ file: 'p/Usg.hx', source: 'package p;\n\nclass Usg {}\n' }
		];
		Assert.same({ source: null, nominal: null }, typedIn(text, 'p/D.hx', others, 'IdentExpr', '\t\tUsg;'), 'the enum the using brings');
		final unlisted: String = 'package p;\n\nusing ext.Tools;\n\nclass D {\n\tfunction f() {\n\t\tUsg;\n\t}\n}\n';
		Assert.same(
			{ source: null, nominal: null },
			typedIn(unlisted, 'p/D.hx', others.slice(1), 'IdentExpr', '\t\tUsg;'), 'a module the index does not hold may bring one'
		);
	}

	@:pin('control')
	@:killer('M-DOOR-ANY-CONSTRUCTOR-BLIND')
	public function testAConstructorOfAnEnumNothingImportsShadowsTheType(): Void {
		final text: String = 'package p;\n\nclass D {\n\tfunction f(x: other.E2) {}\n\n\tfunction g() {\n\t\tf(EnPat);\n\t}\n}\n';
		final others: Array<{ file: String, source: String }> = [
			{ file: 'other/E2.hx', source: 'package other;\n\nenum E2 {\n\tEnPat;\n\tOther;\n}\n' },
			{ file: 'p/EnPat.hx', source: 'package p;\n\nclass EnPat {}\n' }
		];
		Assert.same(
			{ source: null, nominal: null }, typedIn(text, 'p/D.hx', others, 'IdentExpr', 'EnPat)'), 'the expected type may name it'
		);
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
	@:killer('M-WALK-INTEGER-RANGE-FALSE')
	public function testADecimalLiteralPastTheIntegerRangeIsUnknown(): Void {
		Assert.same({ source: null, nominal: null }, typed('IntLit', '3000000000'), 'the compiler types it as a Float');
		Assert.same({ source: null, nominal: null }, typed('FinalStmt', 'final big'), 'and the local it initializes');
		Assert.same({ source: 'Int', nominal: 'Int' }, typed('FinalStmt', 'final inferred'), 'one within the range is an Int');
	}

	@:pin('control')
	@:killer('M-WALK-SEGMENT-NULL')
	public function testAStringSegmentIsAString(): Void {
		Assert.same({ source: 'String', nominal: 'String' }, typed('Literal', 'a $$x'), 'a piece of a string literal');
	}

	/** Both currencies' answers for the node of `kind` starting at the first character of the first `at` of `SOURCE`. */
	private static function typed(kind: String, at: String): { source: Null<String>, nominal: Null<String> } {
		return typedIn(SOURCE, 'p/C.hx', [], kind, at);
	}

	/** `typed` over the file `file` holding `text`, the files `others` indexed beside it. */
	private static function typedIn(
		text: String, file: String, others: Array<{ file: String, source: String }>, kind: String, at: String
	): { source: Null<String>, nominal: Null<String> } {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final root: QueryNode = plugin.parseFile(text);
		final from: Int = text.indexOf(at) + at.length - at.ltrim().length;
		var found: Null<QueryNode> = null;
		function walk(node: QueryNode): Void {
			if (found == null && node.kind == kind && node.span?.from == from) found = node;
			for (c in node.children) walk(c);
		}
		walk(root);
		final node: QueryNode = found ?? throw new Exception('no $kind at $from');
		final chain: ChainTypeContext = {
			declaredTypeSources: plugin.declaredTypeSources(text),
			source: text,
			castTargetSources: plugin.castTargetSources.bind(text),
			typeSyntax: plugin.typeSyntax
		};
		final index: SymbolIndex = SymbolIndex.build([{ file: file, source: text }].concat(others), plugin);
		final declared: Map<Int, String> = plugin.declaredTypes(text);
		return {
			source: NominalTypes.expressionTypeSource(node, root, plugin.refShape(), declared, index, file, chain),
			nominal: NominalTypes.expressionTypeNominal(node, root, plugin.refShape(), declared, index, file, chain)
		};
	}

}
