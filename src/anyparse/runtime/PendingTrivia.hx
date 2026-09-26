package anyparse.runtime;

/**
 * The trivia a Trivia-mode parser has consumed but not yet attached to a node
 * (`Parser.pendingTrivia`): the next `collectTrivia` drains it as a prefix.
 */
typedef PendingTrivia = {
	blankBefore: Bool,
	blankAfterLeadingComments: Bool,
	newlineBefore: Bool,
	leadingComments: Array<String>
};
