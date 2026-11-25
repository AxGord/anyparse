package anyparse.format;

/**
 * The one answer to "by which rules does a `#if` region body inside a type body space its members": the member-gap
 * decisions that type body resolved for its own members, handed to the region through the write options. The defaults
 * keep a region's source blanks and apply no doc gap, the layout of a region whose holder hands nothing down.
 */
final class RegionGaps {

	/** The holder's `existingBetweenFields` policy. */
	public final existingBetweenFields: KeepEmptyLinesPolicy;

	/** The holder's blank count between two vars. */
	public final betweenVars: Int;

	/** The holder's blank count between two functions. */
	public final betweenFunctions: Int;

	/** The holder's blank count between a var and the member after it. */
	public final afterVars: Int;

	/** The holder's policy after a doc-led member; `Ignore` when the holder applies none. */
	public final afterFieldsWithDocComments: CommentEmptyLinesPolicy;

	/** The holder's policy before a doc-led member; `Ignore` when the holder applies none. */
	public final beforeDocCommentEmptyLines: CommentEmptyLinesPolicy;

	/** Whether the holder counts a member led by metadata as doc-led. */
	public final metadataCountsAsDoc: Bool;

	/** The holder's var family: bit `i` set when the `i`-th ctor of the member classifier enum counts as a var. */
	public final varKinds: Int;

	/** The holder's function family, bit per classifier ctor as `varKinds`. */
	public final fnKinds: Int;

	public function new(
		existingBetweenFields: KeepEmptyLinesPolicy = KeepEmptyLinesPolicy.Keep, betweenVars: Int = 0, betweenFunctions: Int = 0,
		afterVars: Int = 0, afterFieldsWithDocComments: CommentEmptyLinesPolicy = CommentEmptyLinesPolicy.Ignore,
		beforeDocCommentEmptyLines: CommentEmptyLinesPolicy = CommentEmptyLinesPolicy.Ignore, metadataCountsAsDoc: Bool = false,
		varKinds: Int = 0, fnKinds: Int = 0
	) {
		this.existingBetweenFields = existingBetweenFields;
		this.betweenVars = betweenVars;
		this.betweenFunctions = betweenFunctions;
		this.afterVars = afterVars;
		this.afterFieldsWithDocComments = afterFieldsWithDocComments;
		this.beforeDocCommentEmptyLines = beforeDocCommentEmptyLines;
		this.metadataCountsAsDoc = metadataCountsAsDoc;
		this.varKinds = varKinds;
		this.fnKinds = fnKinds;
	}

	/** Whether bit `index` of a ctor-family mask is set. */
	public static inline function inFamily(mask: Int, index: Int): Bool {
		return (mask >> index & 1) != 0;
	}

}
