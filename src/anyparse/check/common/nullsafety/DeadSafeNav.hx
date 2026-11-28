package anyparse.check.common.nullsafety;

import anyparse.check.Check.ConfigAware;
import anyparse.check.common.nullsafety.NullFlowScan.IdentOperand;
import anyparse.query.DeclaredNullity;
import anyparse.query.OracleProviders;
import anyparse.query.SymbolIndex;

/**
 * Flags a null-safe access (`a?.b`) whose receiver is already non-null **by flow**
 * on every path reaching it — the `?.` can never short-circuit, so a plain `.` is
 * equivalent. The flow-only counterpart of `unnecessary-safe-nav`.
 *
 * ## Flow-only — complements `unnecessary-safe-nav`, never duplicates it
 *
 * Non-null-ness comes purely from `NullFlow`: an earlier `!= null` guard narrowing
 * this path (then-arm), an `== null` guard's else-arm, or a syntactically non-null
 * assignment. It skips any receiver the declared prover
 * `TypeResolver.isProvablyNonNull` already proves non-null — those belong to
 * `unnecessary-safe-nav`. So a redundant `?.` is reported exactly once.
 *
 * Conservative throughout (see `NullFlow`): every uncertainty collapses to
 * `Unknown`, so only a genuinely redundant `?.` is reported. `Severity.Info`;
 * `fix` rewrites `?.`→`.`, the same rewrite `unnecessary-safe-nav` applies. Under null-safety (`@:nullSafety`
 * in scope, or an oracle build that may enable it) the compiler must see the proof too, so a receiver whose
 * proof it does not follow — only `NullFacts.nonNullVisible` ones count — is not reported at all.
 */
@:nullSafety(Strict)
final class DeadSafeNav extends RuleBase implements ConfigAware {

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(
			'dead-safe-nav', 'a null-safe access (?.) whose receiver is already non-null on every path reaching it', RuleCategory.NullSafety
		);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final safeNavKind: Null<String> = shape.nullSafeAccessKind;
		final identKind: Null<String> = shape.identKind;
		if (safeNavKind == null || identKind == null) return [];
		final navKind: String = safeNavKind;
		final ident: String = identKind;
		final gate: NullSafetyGate = new NullSafetyGate(_resolveConfig, OracleProviders.of(plugin), _configNotes);
		final index: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		return RunScan.collectWith(files, plugin, RunScan.typeInfoOf(plugin), (entry, root, typed, violations) -> {
			final types: DeclaredNullity = DeclaredNullity.of(entry.file, root, entry.source, shape, typed, plugin.typeSyntax, index);
			NullFlow.analyze(root, shape, entry.source, (node, facts) -> {
				if (node.kind != navKind || node.children.length != 1) return;
				final receiver: Null<IdentOperand> = NullFlowScan.identOperand(node, node.children[0], ident);
				if (receiver == null) return;
				// Owned by `unnecessary-safe-nav` when the declared type proves it.
				if (TypeResolver.isProvablyNonNull(receiver.operand, root, shape, types)) return;
				if (!facts.nonNull(receiver.name)) return;
				// Under null-safety a proof the compiler does not follow (a `?.` comparison, a Bool local, an alias) leaves the
				// `?.` required to it, so the access is not redundant there.
				if (gate.unseenProofReason(entry.file, root, receiver.span, shape, facts, receiver.name, '') != null) return;
				violations.push({
					file: entry.file,
					span: receiver.span,
					rule: 'dead-safe-nav',
					severity: Severity.Info,
					message: 'null-safe access is redundant — receiver is already non-null on this path'
				});
			});
		});
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final marker: String = '?.';
		return RunScan.spanEdits(violations, (violation, span) -> {
			final rel: Int = source.substring(span.from, span.to).indexOf(marker);
			if (rel < 0) return null;
			final at: Int = span.from + rel;
			return { span: new Span(at, at + marker.length), text: '.' };
		});
	}

}
