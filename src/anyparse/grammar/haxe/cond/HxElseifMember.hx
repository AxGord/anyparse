package anyparse.grammar.haxe.cond;

import anyparse.grammar.haxe.decl.HxMemberDecl;

/** One `#elseif <cond> <members>` clause of a `HxConditionalMember` chain; its body is spaced as that region's are. */
@:peg
typedef HxElseifMember = {

	@:kw('#elseif')
	var cond: HxPpCondLit;

	@:trivia
	@:tryparse
	@:fmt(padLeading, padTrailing, conditionalBodyIndent, elementPerLine,
		siblingPad('anyparse.format.SiblingShare.padSlot', 'conditionalSiblings'),
		afterFieldsWithDocComments('_regionGaps.afterFieldsWithDocComments'), existingBetweenFields('_regionGaps.existingBetweenFields'),
		beforeDocCommentEmptyLines('_regionGaps.beforeDocCommentEmptyLines'),
		metadataCountsAsDoc('meta', '_regionGaps.metadataCountsAsDoc'),
		interMemberBlankLines(
			'member', '_regionGaps.varKinds', '_regionGaps.fnKinds', '_regionGaps.betweenVars', '_regionGaps.betweenFunctions',
			'_regionGaps.afterVars'
		))
	var body: Array<HxMemberDecl>;

};
