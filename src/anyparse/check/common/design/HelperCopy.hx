package anyparse.check.common.design;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.NoAutofix;
import anyparse.check.common.design.DuplicateCode.DupBinders;
import anyparse.check.common.design.DuplicateCode.DupCtx;
import anyparse.query.BinderScan;
import anyparse.query.MemberKinds;
import anyparse.query.ParseGate;
import anyparse.query.RefactorSupport;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.util.Compare;
import anyparse.util.Strings;

/**
 * Flags a function that re-implements a helper the project keeps in a shared home: its parameters, return type and body
 * are those of a function declared under a configured `homes` path, up to the NAMES of its parameters and locals. The
 * copy is the one a reader finds by name-guessing, and the next fix lands in only one of them — the helper is to be
 * called instead. `Info`, REPORT-ONLY: whether a call is the right replacement is a judgement (a copy may sit where
 * the home cannot be imported).
 *
 * ## What is compared
 *
 * The function's children — its parameter list, return type and body — rendered through the `duplicate-code-renamed`
 * engine (`DuplicateCode.normalizeStmt`: layout collapsed, literals exact, local binders numbered by first use). The
 * function's own name, modifiers and doc are not part of the key, so a private copy under another name matches. A
 * function whose key holds under `MIN_NON_WS_CHARS` non-blank characters is not compared: a one-liner shared by chance
 * is no copy of anything. A copy that spells a call differently (`s.fastCodeAt(i)` for `fastCodeAt(s, i)`) is a
 * different key — the check never invents a match.
 *
 * ## Growth against base
 *
 * The rule keeps no baseline of its own: its findings go through the `lint` gate row, which diffs them as a multiset
 * against the base commit, so a NEW copy in a touched file refuses a slice even when the home is untouched (the home is
 * read from the project, below). A census of today's copies is a `lint --rule helper-copy` over the project scope.
 *
 * ## Configuration
 *
 * `homes`: path fragments that name the home, each matched from a `/` boundary (`src/anyparse/util/`). Functions of a
 * file under a home are the helpers; they are never reported themselves. Without `homes` the rule does nothing, and it
 * is `DefaultOff`. The helpers are read from the project sources (`resolutionRoots` joined to the report), so a lint of
 * one file still finds the home it was not handed; a project that declares no roots answers from the report scope alone.
 */
@:nullSafety(Strict)
@:access(anyparse.check.common.design.DuplicateCode)
final class HelperCopy extends RuleBase implements NoAutofix implements DefaultOff implements ConfigAware {

	private static inline final RULE_ID: String = 'helper-copy';

	/** The least non-blank characters a function's key must hold to be compared. */
	private static inline final MIN_NON_WS_CHARS: Int = 40;

	private static final OPTION_HOMES: String = 'homes';

	/** Joins the rendered parts of one function into its key — a byte no source text contains. */
	private static final PART_SEP: String = '\x1e';

	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(
			RULE_ID, 'a function repeating, up to the names of its bindings, a helper the project keeps in a shared home',
			RuleCategory.Design
		);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function run(files: Array<SourceEntry>, plugin: GrammarPlugin): Array<Violation> {
		final own: Map<String, Array<String>> = [];
		final homes: Array<String> = [];
		for (entry in files) {
			final declared: Array<String> = LintConfig.resolveWith(_resolveConfig, entry.file)
				.stringListOption(RULE_ID, OPTION_HOMES) ?? [];
			own[entry.file] = declared;
			for (home in declared) if (!homes.contains(home)) homes.push(home);
		}
		if (homes.length == 0) return [];
		final shape: RefShape = plugin.refShape();
		final binders: DupBinders = {
			shape: shape,
			scopeKinds: BinderScan.bindingScopeKinds(shape),
			binderKinds: BinderScan.binderKinds(shape),
			identKind: shape.identKind
		};
		// The helpers come from the project, not from the report: a lint of one file still answers over the home it was not handed.
		final project: Array<SourceEntry> = RefactorSupport.resolutionProjectSourcesOf(plugin) ?? files;
		final helpers: Map<String, String> = [];
		for (entry in sortedByPath(project.filter(e -> isUnder(e.file, homes))))
			for (found in keyedFunctions(entry, plugin, shape, binders))
				if (!helpers.exists(found.key)) helpers[found.key] = found.label;
		final out: Array<Violation> = [];
		for (entry in sortedByPath(files)) if (
			!isUnder(entry.file, homes) && (own[entry.file] ?? []).length != 0
		) for (found in keyedFunctions(entry, plugin, shape, binders)) {
			final helper: Null<String> = helpers[found.key];
			final span: Null<Span> = found.fn.span;
			if (helper != null && span != null) out.push({
				file: entry.file,
				span: span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: '${found.fn.name ?? 'function'} repeats $helper up to the names of its bindings — call the helper'
			});
		}
		return out;
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [];
	}

	/** Replacing a copy with a call is a refactoring: whether the home is importable where the copy sits is a design judgement. */
	public function noAutofixReason(): String {
		return 'whether the copy may call the shared helper — and what its callers then import — is a design judgement';
	}

	/** Whether `file` lies under one of `homes`, each matched from a path-segment boundary. */
	private static function isUnder(file: String, homes: Array<String>): Bool {
		final rooted: String = '/$file';
		return homes.exists(home -> rooted.indexOf('/$home') >= 0);
	}

	/** Every function declaration in `node`'s subtree, nested local functions included, outside macro reification. */
	private static function functionsOf(node: QueryNode, opaqueKinds: Array<String>): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		function visit(n: QueryNode): Void {
			if (opaqueKinds.contains(n.kind)) return;
			if (MemberKinds.FN_DECL_KINDS.contains(n.kind)) out.push(n);
			for (child in n.children) visit(child);
		}
		visit(node);
		return out;
	}

	/**
	 * The comparison key of `fn`: its parameters, return type and body rendered with its bindings numbered by first use, or null when
	 * it is under `MIN_NON_WS_CHARS` non-blank characters or a part has no span.
	 */
	private static function keyOf(ctx: DupCtx, fn: QueryNode): Null<String> {
		final binders: Null<DupBinders> = ctx.binders;
		if (binders == null) return null;
		final paramKinds: Array<String> = binders.shape.paramKinds ?? [];
		final names: Array<String> = BinderScan.boundNames(fn, binders.shape);
		final order: Array<String> = [];
		final parts: Array<String> = [];
		var weight: Int = 0;
		for (child in fn.children) {
			final span: Null<Span> = child.span;
			if (span == null) return null;
			final part: Null<String> = paramKinds.contains(child.kind)
				? parameterPart(ctx, child, span, order)
				: DuplicateCode.renumbered(DuplicateCode.normalizeStmt(ctx, child, span, names), order);
			if (part == null) return null;
			parts.push(part);
			weight += ~/\s+/g.replace(part, '').length;
		}
		return weight < MIN_NON_WS_CHARS ? null : parts.join(PART_SEP);
	}

	/**
	 * The functions of `entry` that have a comparison key, each with the
	 * `Type.name` a finding quotes; none when the file does not parse.
	 */
	private static function keyedFunctions(
		entry: SourceEntry, plugin: GrammarPlugin, shape: RefShape, binders: DupBinders
	): Array<{ fn: QueryNode, key: String, label: String }> {
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, entry.source);
		if (tree == null) return [];
		final ctx: DupCtx = {
			source: entry.source,
			blockKinds: [],
			opaqueKinds: shape.opaqueKinds ?? [],
			binders: binders,
			bare: DuplicateCode.bareKinds(shape)
		};
		final owner: String = Strings.allBefore(Strings.allAfterLast(entry.file, '/'), '.');
		final out: Array<{ fn: QueryNode, key: String, label: String }> = [];
		for (fn in functionsOf(tree, ctx.opaqueKinds)) {
			final key: Null<String> = keyOf(ctx, fn);
			if (key != null) out.push({ fn: fn, key: key, label: '$owner.${fn.name ?? ''}' });
		}
		return out;
	}

	/**
	 * A parameter's comparison text: its kind, whatever the declaration spells before the name, and what it spells after the name
	 * (type, default) as the shared render reads it, literals exact. The
	 * name itself is numbered by position in `order`, so a copy that reads
	 * its parameters in another role than the helper declares them is not
	 * the helper. Null when the declaration does not spell its own name.
	 */
	private static function parameterPart(ctx: DupCtx, param: QueryNode, span: Span, order: Array<String>): Null<String> {
		final name: String = param.name ?? '';
		final text: String = DuplicateCode.normalizeStmt(ctx, param, span, null).text;
		final at: Int = SourceText.identTokenOffset(text, new Span(0, text.length), name);
		if (at < 0) return null;
		order.push(name);
		return param.kind + text.substring(0, at) + text.substring(at + name.length);
	}

	/**
	 * `entries` ordered by path, so which helper a key names and the order of findings do not depend on the caller's listing.
	 */
	private static function sortedByPath(entries: Array<SourceEntry>): Array<SourceEntry> {
		final ordered: Array<SourceEntry> = entries.copy();
		ordered.sort((a, b) -> Compare.compareString(a.file, b.file));
		return ordered;
	}

}
