package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.MemberLookup;
import anyparse.query.MemberPathWalk;
import anyparse.query.RawSourceScan;
import anyparse.query.StructuralTypes;
import anyparse.query.SubtypeGraph;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeRefIndex;
import anyparse.query.TypeTraits;
import utest.Assert;
import utest.Test;

/**
 * The layer seam of `SymbolIndex`: each cross-file question is owned by one query layer reached
 * as a field on the index, and the index itself no longer declares any of them.
 *
 * The suite already proves the ANSWERS did not move — 13 940 tests over the same corpus. What no
 * other test can see is the STRUCTURE, which is the whole content of the change: a facade that
 * kept delegating one-liners would leave every one of these names on `SymbolIndex` and pass the
 * rest of the suite unchanged. Both halves of each assertion are needed — "absent from the index"
 * alone would also pass if dead-code elimination had removed the member outright, so every name
 * is required to be PRESENT on its layer in the same breath.
 */
class SymbolIndexLayerSeamTest extends Test {

	/** Each layer's name, the index field it is reached by, its own instance fields, and the questions it owns. */
	private static final LAYERS: Array<{
		name: String,
		field: String,
		declared: Array<String>,
		members: Array<String>
	}> = [
		{
			name: 'TypeRefIndex',
			declared: Type.getInstanceFields(TypeRefIndex),
			field: 'refs',
			members: ['declaringFiles', 'resolveTypeRef', 'resolvedDeclsNamed', 'findDeclaredType']
		},
		{
			name: 'SubtypeGraph',
			declared: Type.getInstanceFields(SubtypeGraph),
			field: 'subtypes',
			members: [
				'isSubtype',
				'hasSubtype',
				'provablyNotSubtype',
				'overrideFamilyOf',
				'supertypeNameUnion'
			]
		},
		{
			name: 'MemberLookup',
			declared: Type.getInstanceFields(MemberLookup),
			field: 'members',
			members: [
				'memberGetter',
				'returnNominalOf',
				'typeProvablyLacksMember',
				'supertypeDeclaresMember'
			]
		},
		{
			name: 'StructuralTypes',
			declared: Type.getInstanceFields(StructuralTypes),
			field: 'structural',
			members: ['satisfiesIterable', 'satisfiesIterator', 'structuralConformanceForbidsFinal']
		},
		{
			name: 'MemberPathWalk',
			declared: Type.getInstanceFields(MemberPathWalk),
			field: 'paths',
			members: ['resolvePathFinalMemberTypeSource', 'resolveGenericPathFinalMemberTypeSource']
		},
		{
			name: 'RawSourceScan',
			declared: Type.getInstanceFields(RawSourceScan),
			field: 'text',
			members: [
				'sourceCarriesAllowGrant',
				'hasAccessGrant',
				'nameOccursOutside',
				'skippedMayReference'
			]
		},
		{
			name: 'TypeTraits',
			declared: Type.getInstanceFields(TypeTraits),
			field: 'traits',
			members: [
				'transitivelyCarriesRtti',
				'transitivelyCarriesBuildMacro',
				'abstractRebindsThis'
			]
		}
	];

	/**
	 * Every layer is reachable by its own field on the index, and every question it owns is
	 * declared on the LAYER and not on `SymbolIndex`. Red at base on both halves: at base each of
	 * these names is an instance member of `SymbolIndex` and no layer class exists at all.
	 */
	public function testEachLayerOwnsItsQuestionsAndTheIndexDeclaresNone(): Void {
		final indexFields: Array<String> = Type.getInstanceFields(SymbolIndex);
		for (layer in LAYERS) {
			Assert.isTrue(indexFields.contains(layer.field), 'SymbolIndex should expose the "${layer.field}" layer');
			for (member in layer.members) {
				Assert.isTrue(layer.declared.contains(member), '${layer.name} should declare "$member"');
				Assert.isFalse(indexFields.contains(member), 'SymbolIndex should no longer declare "$member"');
			}
		}
	}

	/**
	 * The layers are WIRED, not merely present: a two-file index answers one question per layer
	 * through its field, and each answer is the one the pre-split index gave.
	 */
	public function testEveryLayerAnswersThroughItsFieldOnALiveIndex(): Void {
		final base: String = 'package p;\n\n/** Base. */\nclass Base {\n\tpublic var n: Int = 0;\n\n\tpublic function new() {}\n}';
		final derived: String =
			'package p;\n\n/** Derived. */\n@:allow(p.Base)\nclass Derived extends Base {\n\tpublic function new() {\n\t\tsuper();\n\t}\n}';
		final index: SymbolIndex = SymbolIndex.build(
			[{ file: 'p/Base.hx', source: base }, { file: 'p/Derived.hx', source: derived }], new HaxeQueryPlugin()
		);
		Assert.equals(1, index.refs.declaringFiles('Derived').length);
		Assert.isTrue(index.subtypes.isSubtype('Derived', 'Base'));
		Assert.isTrue(index.members.typeDeclaresMember('Base', 'n'));
		Assert.isFalse(index.structural.satisfiesIterable('Base'));
		Assert.isNull(index.paths.resolvePathFinalMemberTypeSource('p/Base.hx', 'Base', ['n', 'missing']));
		Assert.isTrue(index.text.sourceCarriesAllowGrant(derived));
		Assert.isFalse(index.traits.transitivelyCarriesRtti('Derived'));
	}

}
