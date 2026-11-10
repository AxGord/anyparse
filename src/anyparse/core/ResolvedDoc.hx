package anyparse.core;

/**
 * A Doc with every `BreakCommit` resolved (`BreakCommits.resolveMeasured`), and the decisions its last measure render
 * recorded when that render laid out exactly this Doc — what `CollapsePass` would measure it for. `decisions` is null
 * when no measure render laid out the returned Doc.
 */
typedef ResolvedDoc = {
	final doc: Doc;
	final decisions: Null<Array<{ node: Doc, crosses: Bool, ?indent: Int }>>;
}
