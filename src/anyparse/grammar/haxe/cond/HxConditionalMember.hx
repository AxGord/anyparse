package anyparse.grammar.haxe.cond;

import anyparse.grammar.haxe.decl.HxMemberDecl;

/**
 * Body of a `#if <cond> <members> [#elseif ...] [#else <members>] #end` region of whole class, interface or abstract
 * members, the content between the `#if` and `#end` `HxClassMember.Conditional` consumes. Each body is laid out as a
 * `HxConditionalBlock` body, and its members are spaced exactly as the type body holding the region spaces its own:
 * every gap rule reads the `RegionGaps` that body hands down through its `regionGapKnobs`. The first member of a
 * body takes no blank, so the markers stay tight to their neighbours.
 */
@:peg
typedef HxConditionalMember = {

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

	@:trivia
	@:tryparse
	@:fmt(elemSelfTrailsNewline)
	var elseifs: Array<HxElseifMember>;

	@:optional
	@:kw('#else')
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
	var elseBody: Null<Array<HxMemberDecl>>;

};
