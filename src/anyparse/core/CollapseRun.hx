package anyparse.core;

/**
 * One `CollapsePass` run's state: the measure render's decisions, and the
 * answers the pass would otherwise recompute at every node that shares a
 * subtree (`DocIdentityMap`). Every answer here is a function of the Doc and
 * the decisions, so one instance serves exactly one run.
 */
@:allow(anyparse.core.CollapsePass)
@:nullSafety(Strict)
final class CollapseRun {

	/** Pass-internal answers computed: rewrites, commits and subtree questions. A memo hit does not count. */
	public var evaluations(default, null): Int = 0;

	/** `IfFullLineExceeds` / probe decisions the measure render records, keyed by node identity. */
	private final _entries: Array<{ node: Doc, crosses: Bool, ?indent: Int }> = [];

	/** `rewrite` results outside a broken add-chain. */
	private final _rewroteFlat: DocIdentityMap<Doc> = new DocIdentityMap();

	/** `rewrite` results inside a broken add-chain. */
	private final _rewroteBroken: DocIdentityMap<Doc> = new DocIdentityMap();

	/** `commitOpens` results. */
	private final _committed: DocIdentityMap<Doc> = new DocIdentityMap();

	/** `subtreeOpens` answers. */
	private final _opened: DocIdentityMap<Bool> = new DocIdentityMap();

	/** `containsCollapseProbe` answers. */
	private final _probed: DocIdentityMap<Bool> = new DocIdentityMap();

	public function new() {}

}
