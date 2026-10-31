package anyparse.check.common.design;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FileGated;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.NoAutofix;
import anyparse.check.scan.CasePatternScan;
import anyparse.query.NodeShape;
import anyparse.query.SymbolIndex;

/**
 * Flags a `case` arm that matches a REFUSAL constructor (`Err(_)`) without reading what the refusal carries and then
 * passes (`Assert.pass()`) — an assertion any refusal satisfies, so a call refused for another reason stays green.
 * Inert until the project names both halves in `apqlint.json`:
 *
 *     "refusal-assert-ignores-message": { "refusalConstructors": ["Err"], "passCalls": ["Assert.pass"] }
 *
 * An arm qualifies when every pattern of its run is a constructor call whose last callee segment is a
 * `refusalConstructors` name, it has no guard, no binder of its patterns is read again inside the arm, and its body
 * calls a `passCalls` name (the dotted callee spelling). `Info`, default-off, report-only: which refusal the test
 * expects is the author's to name. Grammar-agnostic over `CasePatternScan`'s seams.
 */
@:nullSafety(Strict)
final class RefusalAssertIgnoresMessage extends RuleBase implements ConfigAware implements FileGated implements DefaultOff
		implements NoAutofix {

	/** The rule id, also the `apqlint.json` option key. */
	private static inline final RULE_ID: String = 'refusal-assert-ignores-message';

	private static inline final REFUSALS_KEY: String = 'refusalConstructors';
	private static inline final PASSES_KEY: String = 'passCalls';

	/** The linter's memoised per-file config resolver; null when run outside it. */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(
			RULE_ID, 'a case arm that passes on a refusal constructor without reading the refusal — any refusal satisfies it',
			RuleCategory.Design
		);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	/** `needs-config` while the file's config does not name both the refusal constructors and the pass calls. */
	public function skipReason(file: String, config: LintConfig): Null<String> {
		return declared(config) == null ? 'needs-config' : null;
	}

	public function noAutofixReason(): String {
		return 'which refusal the test expects is the author\'s to name';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return RunScan.collectWith(files, plugin, CasePatternScan.seamsOf(plugin), (entry, tree, seams, out) -> {
			final options: Null<RefusalOptions> = declared(LintConfig.resolveWith(_resolveConfig, entry.file));
			if (options == null) return;
			final declaredOptions: RefusalOptions = options;
			CasePatternScan.eachCaseArm(seams, tree, (switchNode, at) -> {
				final arm: QueryNode = switchNode.children[at];
				final ctor: Null<String> = silentRefusal(seams, arm, declaredOptions);
				final span: Null<Span> = arm.span;
				if (ctor != null && span != null) out.push({
					file: entry.file,
					span: span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: 'this arm passes on any $ctor without reading it — check that the refusal names the expected reason'
				});
			});
		});
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [];
	}

	/** Both option lists of `config`, or null while either is absent or empty. */
	private static function declared(config: LintConfig): Null<RefusalOptions> {
		final refusals: Array<String> = config.stringListOption(RULE_ID, REFUSALS_KEY) ?? [];
		final passes: Array<String> = config.stringListOption(RULE_ID, PASSES_KEY) ?? [];
		return refusals.length == 0 || passes.length == 0 ? null : { refusals: refusals, passes: passes };
	}

	/** The refusal constructor `arm` passes on without reading, or null when the arm is not that shape. */
	private static function silentRefusal(seams: CaseSeams, arm: QueryNode, options: RefusalOptions): Null<String> {
		if (arm.kind != seams.caseBranchKind) return null;
		final run: Array<QueryNode> = CasePatternScan.patternRun(seams, arm);
		if (run.length == 0 || CasePatternScan.guardOf(seams, arm, run.length) != null) return null;
		var ctor: Null<String> = null;
		for (pattern in run) {
			final named: Null<String> = refusalOf(seams, pattern, options.refusals);
			if (named == null) return null;
			ctor = named;
		}
		final groups: Null<Array<Array<PatternBinder>>> = CasePatternScan.binderGroups(seams, arm);
		if (groups == null) return null;
		for (group in groups) if (CasePatternScan.mentionCount(seams, arm, group[0].name) > group.length) return null;
		final body: Array<QueryNode> = arm.children.slice(run.length);
		return body.exists(node -> callsAny(seams, node, options.passes)) ? ctor : null;
	}

	/** The refusal constructor `pattern` extracts, or null when it is no call of one. */
	private static function refusalOf(seams: CaseSeams, pattern: QueryNode, refusals: Array<String>): Null<String> {
		final inner: QueryNode = pattern.kind == seams.plainCasePatternKind && pattern.children.length == 1 ? pattern.children[0] : pattern;
		if (inner.kind != seams.callKind || inner.children.length == 0) return null;
		final path: Array<String> = NodeShape.calleePath(inner.children[0], seams.fieldAccessKind, seams.identKind);
		final last: Null<String> = path.length == 0 ? null : path[path.length - 1];
		return last != null && refusals.contains(last) ? last : null;
	}

	/** Whether `node`'s subtree calls one of `names`, compared by the dotted callee spelling. */
	private static function callsAny(seams: CaseSeams, node: QueryNode, names: Array<String>): Bool {
		return node.kind == seams.callKind
			&& node.children.length > 0
			&& names.contains(NodeShape.calleePath(node.children[0], seams.fieldAccessKind, seams.identKind).join('.'))
			|| node.children.exists(child -> callsAny(seams, child, names));
	}

}

/** The two option lists the rule reads. */
typedef RefusalOptions = {
	final refusals: Array<String>;
	final passes: Array<String>;
}
