package unit.grammar.haxe;

import anyparse.format.MetadataLineEndPolicy;
import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapMode;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * Under `fit` a lone simple metadata glues to its declaration only when the declaration keeps the layout it
 * takes without the metadata: a head the glue alone would break keeps the metadata on its own line, and a head
 * that breaks anyway keeps it glued.
 */
@:nullSafety(Strict)
final class MetadataFitSameLayoutTest extends Test {

	private static final FIT: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
		edited.lineWidth = 140;
		edited.metadataFunctionLineEnd = MetadataLineEndPolicy.Fit;
		edited.metadataTypeLineEnd = MetadataLineEndPolicy.Fit;
		edited.metadataVarLineEnd = MetadataLineEndPolicy.Fit;
		edited.metadataOtherLineEnd = MetadataLineEndPolicy.Fit;
	});
	private static final FIT_SIGNATURE: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
		edited.lineWidth = 140;
		edited.metadataFunctionLineEnd = MetadataLineEndPolicy.Fit;
		edited.metadataTypeLineEnd = MetadataLineEndPolicy.Fit;
		edited.metadataVarLineEnd = MetadataLineEndPolicy.Fit;
		edited.metadataOtherLineEnd = MetadataLineEndPolicy.Fit;
		edited.functionSignatureWrap = {
			defaultAdditionalIndent: 0,
			defaultMode: WrapMode.FillLineWithLeadingBreak,
			rules: [
				{
					conditions: [
						{ cond: WrapConditionType.TotalItemLengthLessThan, value: 100 },
						{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }
					],
					mode: WrapMode.NoWrap
				},
				{ conditions: [{ cond: WrapConditionType.ItemCountLessThan, value: 1 }], mode: WrapMode.NoWrap }
			]
		};
	});

	public function new(): Void {
		super();
	}

	/** Three parameters that fit alone but not after the metadata stay unwrapped, the metadata above them. */
	@:pin('control')
	@:killer('M-META-FIT-GLUED-COLUMN')
	public function testThreeParametersOnlyTheGlueWouldWrapStayWhole(): Void {
		final src: String = 'class C {\n\t@:allow(pkg.sub)\n\tprivate function carryObjectIntoTheSavedAnimationSlotOfTheHolder('
			+ 'object:Box<Data>, saved:SavedAnimData, info:FieldSwitch):Void {}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, FIT_SIGNATURE));
	}

	/** Two parameters under a dotted `@:allow` path keep the same layout as without the metadata. */
	@:pin('control')
	@:killer('M-META-FIT-GLUED-COLUMN')
	public function testTwoParametersOnlyTheGlueWouldWrapStayWhole(): Void {
		final src: String = 'class C {\n\t@:allow(pkg.Type.member)\n\tprivate function '
			+ 'holdTheSavedAnimationDataOfTheCurrentlySelectedObjectNow(object:Box<Data>, saved:SavedAnimData):Void {}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, FIT_SIGNATURE));
	}

	/** A head with type parameters that fits alone keeps the metadata above it rather than wrapping. */
	@:pin('control')
	@:killer('M-META-FIT-GLUED-COLUMN')
	public function testTypeParametersOnlyTheGlueWouldWrapStayWhole(): Void {
		final src: String = 'class C {\n\t@:allow(pkg.sub)\n\tprivate function carryObj<TKeyType:SomeConstraint, '
			+ 'TValueType:AnotherConstraint>(object:Box<TKeyType>, saved:TValueType):Void {}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, FIT_SIGNATURE));
	}

	/** Parameters that wrap even without the metadata keep it glued to the head's first line. */
	@:pin('control')
	@:killer('M-META-FIT-REST-GROUP-UNGLUED-ONLY')
	public function testParametersThatWrapAnywayKeepTheMetadata(): Void {
		final name: String = 'carryObjectIntoTheSavedAnimationSlotOfTheCurrentHolderNow';
		Assert.equals(
			'class C {\n\t@:allow(pkg.sub) private function $name(\n\t\tobject:Box<Data>, saved:SavedAnimData, info:FieldSwitch\n'
			+ '\t):Void {}\n}',
			HxWriteFixture.triviaWrite(
				'class C {\n\t@:allow(pkg.sub)\n\tprivate function $name'
				+ '(object:Box<Data>, saved:SavedAnimData, info:FieldSwitch):Void {}\n}\n',
				FIT_SIGNATURE
			)
		);
	}

	/** A fill whose first line would lose an item after the metadata keeps that line, the metadata above it. */
	@:pin('control')
	@:killer('M-META-FIT-FILL-FIRST-ITEM-ONLY')
	public function testAFillKeepsItsFirstLineWithoutTheMetadata(): Void {
		final head: String = 'public function f(aaaaaaaaaaaaaaaaaaaaaaaaaaaaa:String, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:String, '
			+ 'cccccccccccccccccccccccc:String,';
		Assert.equals(
			'class C {\n\t@:keep\n\t$head\n\t\tdddddddddddddddddddddddddddddddd:String):Void {}\n}',
			HxWriteFixture.triviaWrite('class C {\n\t@:keep $head dddddddddddddddddddddddddddddddd:String):Void {}\n}\n', FIT)
		);
	}

	/** A fill that packs the same items after the metadata as without it, its tail reserved, keeps the metadata glued. */
	@:pin('control')
	@:killer('M-META-FIT-FILL-TAIL-UNRESERVED')
	public function testAFillWithTheSameFirstLineKeepsTheMetadata(): Void {
		final src: String = 'class C {\n\t@:allow(pkg.sub.Type) public function g(aaaaaaaaaaaaaaaaaaaaaaaaa:String, '
			+ 'bbbbbbbbbbbbbbbbbbbbbbbbbb:String, cccccccccccccc:String,\n\t\tddddddddddddddd:String):Void {}\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, FIT));
	}

	/** A variable whose initializer fits alone but not after the metadata keeps the metadata above it. */
	@:pin('control')
	@:killer('M-META-FIT-NATURAL-BREAK-ASSUMED')
	public function testAnInitializerOnlyTheGlueWouldBreakStaysWhole(): Void {
		final src: String = 'class C {\n\t@:allow(pkg.sub)\n\tvar holderOfTheSavedAnimationData:Map<SomeVeryLongKeyTypeName, '
			+ 'Array<AnotherVeryLongValueTypeName>> = new Map<Int, Int>();\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, FIT));
	}

	/** A variable that breaks after `=` even without the metadata keeps it glued. */
	@:pin('control')
	@:killer('M-META-FIT-NATURAL-BREAK-IGNORED')
	public function testAnInitializerThatBreaksAnywayKeepsTheMetadata(): Void {
		final decl: String = 'var holderOfTheSavedAnimationData:Map<SomeVeryLongKeyTypeName, Array<AnotherVeryLongValueTypeName>> =';
		Assert.equals(
			'class C {\n\t@:allow(pkg.sub) $decl\n\t\tnew Map<SomeVeryLongKeyName, Int>();\n}',
			HxWriteFixture.triviaWrite('class C {\n\t@:allow(pkg.sub)\n\t$decl new Map<SomeVeryLongKeyName, Int>();\n}\n', FIT)
		);
	}

	/** A fill that packs an item fewer at the glued column than without the metadata keeps its first line, the metadata above it. */
	@:pin('control')
	@:killer('M-META-FIT-FILL-GLUED-PACKING')
	public function testAFillThePackingOfWhichTheGlueChangesKeepsItsFirstLine(): Void {
		final name: String = ''.lpad('f', 61);
		final params: String = 'aaaaaaaaaaaa:String, bbbbbbbbbbbbbb:Int,';
		Assert.equals(
			'class C {\n\t@:allow(pkg.sub)\n\tpublic function $name($params\n\t\tcccccccc:Array<String>):Void {}\n}',
			HxWriteFixture.triviaWrite(
				'class C {\n\t@:allow(pkg.sub) public function $name($params cccccccc:Array<String>):Void {}\n}\n', FIT
			)
		);
	}

	/** Call arguments that pack an item fewer at the glued column keep their first line, the metadata above it. */
	@:pin('control')
	@:killer('M-META-FIT-FILL-GLUED-PACKING')
	public function testCallArgumentsThePackingOfWhichTheGlueChangesKeepTheirFirstLine(): Void {
		final decl: String = 'var ${''.lpad('x', 64)}:Int = callSomething(aaaaaaaa, function(q:Int) return q + 1,';
		Assert.equals(
			'class C {\n\t@:keep\n\t$decl\n\t\tccccccc);\n}',
			HxWriteFixture.triviaWrite('class C {\n\t@:keep $decl ccccccc);\n}\n', FIT_SIGNATURE)
		);
	}

}
