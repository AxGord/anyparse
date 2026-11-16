package anyparse.check.common.design;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.FileGated;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.RiskyFix;
import anyparse.check.scan.PurityScan;
import anyparse.query.ElementSpan;
import anyparse.query.IndexScope;
import anyparse.query.LexicalRegions;
import anyparse.query.Matcher;
import anyparse.query.ParseGate;
import anyparse.query.Pattern;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeRefPrinter;
import anyparse.util.Compare;
import haxe.Exception;

using anyparse.util.Strings;

/**
 * The one answer to "which statement fragments of a tree are an inlined copy of an opted-in template helper's body, and
 * may be replaced by a call to it". A helper opts in by carrying the annotation the project names in `apq.json`:
 *
 *     "prefer-helper": { "marker": "@:preferHelper" }
 *
 * Every static function of the resolution scope carrying it is a TEMPLATE: its body, with each parameter turned into a
 * hole, is a structural pattern (`Matcher`, the `apq search` engine), and a run of statements anywhere that matches it is
 * reported and fixed to a call of the helper. A new helper is found everywhere it applies with no new rule. `Info`.
 *
 * ## What a template is
 *
 * A static function whose block body reads nothing but its parameters and the locals its own top-level statements
 * declare. A local is a hole too, bound to whatever name the site declares, and its written type is not part of the
 * pattern, so `final xs = …` and `final xs: Array<String> = …` both match. A body that leaves the function early (a
 * return, a break, a continue), declares a local below its top level, reads any other name (which a site may bind to
 * something else), or never reads one of its parameters is no template, and is named once on stderr.
 *
 * ## What a site must be
 *
 * - **The statements themselves**, adjacent, in the body's order — a statement between them is no match.
 * - **No local of the copy is read after it.** The call no longer declares it, so a later read of `xs` would bind to
 *   nothing; such a site is no finding. No argument may read one of those locals either.
 * - **Every hole binds a pure expression** (`PurityScan.isPure`): the call evaluates each argument once and first, the
 *   copy at each read, so an impure value would run a different number of times or ahead of the body's own effects.
 * - **No comment in the replaced bytes**, a trailing comment on the last line included: the call would drop it.
 * - **Not the helper's own body.**
 *
 * Open: a pure hole read after a body effect it observes (`xs.push(a); xs.push(b)`, `b` = `xs.length`) still matches,
 * and the call reads `b` first; only an argument naming one of the copy's own locals is declined.
 *
 * ## The fix is risky
 *
 * Nothing here proves the call typechecks (the site's values must have the helper's parameter types, a name matched
 * literally may belong to another type), so the check is a `RiskyFix`: `--fix` applies it only under a compiler oracle,
 * reverting a file whose build breaks, else report-only. `TypeRefPrinter` spells the helper's type and adds its import.
 *
 * Grammar-agnostic: `identKind`, `paramKinds`, `blockBodyKind`, `localDeclKinds`, `controlExitKinds` and their kin over the
 * plugin's own `parsePattern`; a plugin without `paramKinds`, `blockBodyKind` or `controlExitKinds` makes it a no-op.
 */
@:nullSafety(Strict)
final class PreferHelper extends RuleBase implements ConfigAware implements FileGated implements RiskyFix {

	/** The rule id, also the `apq.json` option key. */
	private static inline final RULE_ID: String = 'prefer-helper';

	/** The option naming the annotation that marks a template helper. */
	private static final OPTION_MARKER: String = 'marker';

	/** The linter's memoised per-file config resolver; null when run outside it. */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(
			RULE_ID,
			'a run of statements repeating the body of a helper the project marks as a template, replaceable with a call of '
			+ 'that helper (final xs = m[k] ?? []; xs.push(v); m[k] = xs; -> Groups.push(m, k, v);)',
			RuleCategory.Design
		);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	/** `needs-config` while the file's config names no marker. */
	public function skipReason(file: String, config: LintConfig): Null<String> {
		return config.stringOption(RULE_ID, OPTION_MARKER) == null ? 'needs-config' : null;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final symbols: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		final memo: Map<String, Array<Template>> = [];
		final out: Array<Violation> = [];
		for (entry in files) {
			final marker: Null<String> = markerFor(entry.file);
			if (marker == null) continue;
			final index: Null<SymbolIndex> = symbols();
			if (index == null) return out;
			final templates: Array<Template> = memo[marker] ?? templatesOf(marker, index, plugin, seams);
			memo[marker] = templates;
			for (site in sitesIn(entry.file, entry.source, templates, index, seams, plugin)) out.push({
				file: entry.file,
				span: site.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'repeats the body of ${site.template.helper}(${site.template.params.join(', ')}) — call the helper'
			});
		}
		return out;
	}

	/**
	 * Re-derive every site against the plugin's resolution index — the scope `run` found the templates in — and rewrite the
	 * ones a violation names into the helper call, with the import the call needs riding on them.
	 */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		if (violations.length == 0) return [];
		final file: String = RunScan.oneFile(violations, RULE_ID);
		final seams: Null<Seams> = readSeams(plugin);
		final marker: Null<String> = markerFor(file);
		final root: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		if (seams == null || marker == null || root == null) return [];
		final resolved: SymbolIndex = IndexScope.resolutionIndexOf(plugin) ?? index ?? IndexScope.over(
			[{ file: file, source: source }], plugin
		);
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		final printer: TypeRefPrinter = TypeRefPrinter.forFile(
			file, source, root, provider == null ? [] : provider.importMap(source, file), plugin, resolved
		);
		final wanted: Array<String> = RunScan.spanKeys(violations);
		final out: Array<FixEdit> = [
			for (site in sitesIn(file, source, templatesOf(marker, resolved, plugin, seams), resolved, seams, plugin))
				if (wanted.contains('${site.span.from}:${site.span.to}'))
					{
						span: site.span,
						text: '${printer.print(site.template.typePath).text}.${site.template.member}(${site.args.join(', ')});'
					}
		];
		// The import rides on a rewrite: a file where every site declined gets no edit at all.
		if (out.length > 0) for (edit in printer.pendingImportEdits()) out.push({ span: edit.span, text: edit.text });
		return out;
	}

	/** The marker `file`'s config names, or null. */
	private function markerFor(file: String): Null<String> {
		return LintConfig.resolveWith(_resolveConfig, file).stringOption(RULE_ID, OPTION_MARKER);
	}

	/** Every static member of `index` carrying `marker`, as a template; each one that cannot be one is named once. */
	private function templatesOf(marker: String, index: SymbolIndex, plugin: GrammarPlugin, seams: Seams): Array<Template> {
		final out: Array<Template> = [];
		for (info in index.allFiles()) for (type in info.types) for (member in type.members) if (
			member.isStatic && member.metaNames.contains(marker)
		) {
			final typePath: String = SymbolIndex.typePath({ file: info, type: type });
			final problems: Array<String> = [];
			final template: Null<Template> = templateOf(info.file, typePath, member, index, plugin, seams, problems);
			if (template != null) out.push(template);
			for (p in problems) ConfiguredTypes.warn(_configNotes, RULE_ID, '$typePath.${member.name} is no template: $p');
		}
		return out;
	}

	/** `member`'s body as a template, or null with the reason in `problems`. */
	private static function templateOf(
		file: String, typePath: String, member: MemberInfo, index: SymbolIndex, plugin: GrammarPlugin, seams: Seams, problems: Array<String>
	): Null<Template> {
		final source: Null<String> = index.sourceOf(file);
		final root: Null<QueryNode> = source == null ? null : ParseGate.parseOrNull(plugin, source);
		final decl: Null<QueryNode> = root == null ? null : declAt(root, member);
		final declSpan: Null<Span> = decl?.span;
		if (source == null || decl == null || declSpan == null) {
			problems.push('its declaration cannot be read');
			return null;
		}
		final params: Array<String> = [for (c in decl.children) if (seams.paramKinds.contains(c.kind)) c.name ?? ''];
		final stmts: Array<QueryNode> = decl.children.find(c -> c.kind == seams.blockBodyKind)?.children ?? [];
		final locals: Array<String> = [for (s in stmts) if (seams.localDeclKinds.contains(s.kind)) s.name ?? ''];
		final scan: BodyScan = {
			holes: params.concat(locals),
			reads: [],
			idents: [],
			problem: null
		};
		for (s in stmts) scanBody(s, true, seams, scan);
		final unread: Null<String> = params.find(p -> !scan.reads.exists(p));
		final problem: Null<String> = stmts.length == 0
			? 'it has no block body'
			: scan.problem ?? (unread == null ? null : 'it never reads $unread');
		if (problem != null) {
			problems.push(problem);
			return null;
		}
		final pattern: Null<Pattern> = patternOf(source, stmts, scan.idents, locals, plugin, seams);
		if (pattern != null) return {
			helper: '$typePath.${member.name}',
			typePath: typePath,
			member: member.name,
			params: params,
			locals: locals,
			pattern: pattern,
			file: file,
			span: declSpan
		};
		problems.push('its body is no pattern');
		return null;
	}

	/**
	 * The pattern of `stmts`: their source with every hole read spelled as its metavariable, parsed by the plugin, and each
	 * declaration of a body local then renamed to the name-slot metavariable of its name.
	 */
	private static function patternOf(
		source: String, stmts: Array<QueryNode>, idents: Array<QueryNode>, locals: Array<String>, plugin: GrammarPlugin, seams: Seams
	): Null<Pattern> {
		final text: Null<String> = holedText(source, stmts, idents);
		if (text == null) return null;
		final parsed: Null<Pattern> = try plugin.parsePattern(text) catch (exception: Exception) null;
		return parsed == null
			? null
			: new Pattern(
				namedLocals(parsed.root, locals, seams.localDeclKinds), parsed.category, text, parsed.kindEquivalence,
				parsed.ignoredMetavars, parsed.identKind
			);
	}

	/** The declaration node `member` was indexed from. */
	private static function declAt(node: QueryNode, member: MemberInfo): Null<QueryNode> {
		if (node.kind == member.kind && node.name == member.name && node.span?.from == member.declFrom) return node;
		for (c in node.children) {
			final found: Null<QueryNode> = declAt(c, member);
			if (found != null) return found;
		}
		return null;
	}

	/** Record in `scan` every hole read under `node` and the first reason the body is no template. */
	private static function scanBody(node: QueryNode, top: Bool, seams: Seams, scan: BodyScan): Void {
		if (scan.problem != null) return;
		final name: Null<String> = node.name;
		if (seams.jumpKinds.contains(node.kind)) {
			scan.problem = 'it leaves the function early (${node.kind}), which a site would do from its own function';
			return;
		}
		if (!top && (seams.localDeclKinds.contains(node.kind) || seams.localContinuationKinds.contains(node.kind))) {
			scan.problem = 'it declares a local below its top level';
			return;
		}
		if (node.kind == seams.interpIdentKind) {
			scan.problem = 'it reads ${name ?? 'a name'} inside a string';
			return;
		}
		if (node.kind == seams.identKind) {
			if (name == null || !scan.holes.contains(name)) {
				scan.problem = 'it reads ${name ?? 'a name'}, which a site may bind to something else';
				return;
			}
			scan.reads[name] = (scan.reads[name] ?? 0) + 1;
			scan.idents.push(node);
		}
		for (c in node.children) scanBody(c, false, seams, scan);
	}

	/** The source of `stmts` with every hole read spelled as the metavariable of its name. */
	private static function holedText(source: String, stmts: Array<QueryNode>, idents: Array<QueryNode>): Null<String> {
		final first: Null<Span> = stmts[0].span;
		final last: Null<Span> = stmts[stmts.length - 1].span;
		if (first == null || last == null) return null;
		final sorted: Array<QueryNode> = idents.copy();
		sorted.sort((a, b) -> Compare.compareInt(a.span?.from ?? 0, b.span?.from ?? 0));
		final out: StringBuf = new StringBuf();
		var cursor: Int = first.from;
		for (ident in sorted) {
			final at: Null<Span> = ident.span;
			if (at == null) return null;
			out.add(source.substring(cursor, at.from));
			out.add('$$${ident.name}');
			cursor = at.to;
		}
		out.add(source.substring(cursor, last.to));
		return out.toString();
	}

	/**
	 * `node` with each declaration of a body local renamed to the name-slot metavariable of its name and its written type
	 * dropped, so the pattern binds whatever name the site declares and constrains no annotation.
	 */
	private static function namedLocals(node: QueryNode, locals: Array<String>, declKinds: Array<String>): QueryNode {
		final children: Array<QueryNode> = node.children.map(c -> namedLocals(c, locals, declKinds));
		final name: Null<String> = node.name;
		return name != null && declKinds.contains(node.kind) && locals.contains(name)
			? new QueryNode(node.kind, '$$$name', children, node.span, null, node.typeArgCount, node.target)
			: new QueryNode(node.kind, name, children, node.span, node.type, node.typeArgCount, node.target);
	}

	/** Every site of `templates` in `source`, outer-first and non-overlapping. */
	private static function sitesIn(
		file: String, source: String, templates: Array<Template>, index: SymbolIndex, seams: Seams, plugin: GrammarPlugin
	): Array<Site> {
		if (templates.length == 0) return [];
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		if (tree == null) return [];
		final root: QueryNode = tree;
		final read: Null<PurityCtx> = PurityScan.contextOf(plugin, source, root, index, file);
		if (read == null) return [];
		final purity: PurityCtx = read;
		final ctx: SiteCtx = {
			file: file,
			source: source,
			root: root,
			purity: purity,
			regions: ElementSpan.lazyRegions(source, plugin),
			seams: seams
		};
		final found: Array<Site> = [];
		for (template in templates) for (m in Matcher.search(template.pattern, root)) {
			final site: Null<Site> = siteOf(m, template, ctx);
			if (site != null) found.push(site);
		}
		found.sort((a, b) -> Compare.compareInt(a.span.from, b.span.from));
		final out: Array<Site> = [];
		var lastTo: Int = -1;
		for (site in found) if (site.span.from >= lastTo) {
			out.push(site);
			lastTo = site.span.to;
		}
		return out;
	}

	/** The site `m` is, or null when one of the gates on the type doc refuses it. */
	private static function siteOf(m: Match, template: Template, ctx: SiteCtx): Null<Site> {
		final span: Span = m.span;
		if (ctx.file == template.file && span.from >= template.span.from && span.to <= template.span.to) return null;
		if (LexicalRegions.commentIntersects(span.from, ctx.source.lineEnd(span.to), ctx.regions())) return null;
		final localNames: Array<String> = [];
		for (local in template.locals) {
			final name: Null<String> = m.bindings[local]?.name;
			if (name == null) return null;
			localNames.push(name);
		}
		final args: Array<String> = [];
		for (param in template.params) {
			final bound: Null<QueryNode> = m.bindings[param];
			final at: Null<Span> = bound?.span;
			if (bound == null || at == null || mentions(bound, localNames, ctx.seams)) return null;
			if (!PurityScan.isPure(bound, ctx.purity)) return null;
			args.push(ctx.source.substring(at.from, at.to));
		}
		if (localNames.length > 0) {
			final run: Array<QueryNode> = m.node.kind == Pattern.SEQUENCE_KIND ? m.node.children : [m.node];
			final after: Null<Array<QueryNode>> = siblingsAfter(ctx.root, run[0], run[run.length - 1]);
			if (after == null || after.exists(s -> mentions(s, localNames, ctx.seams))) return null;
		}
		return { span: span, template: template, args: args };
	}

	/** The statements after `last` in the child list holding `first`, or null when no node holds it. */
	private static function siblingsAfter(node: QueryNode, first: QueryNode, last: QueryNode): Null<Array<QueryNode>> {
		final at: Int = node.children.indexOf(first);
		if (at != -1) {
			final end: Int = node.children.indexOf(last);
			return end < at ? null : node.children.slice(end + 1);
		}
		for (c in node.children) {
			final found: Null<Array<QueryNode>> = siblingsAfter(c, first, last);
			if (found != null) return found;
		}
		return null;
	}

	/** Whether `node` reads any of `names`, as an identifier or inside a string. */
	private static function mentions(node: QueryNode, names: Array<String>, seams: Seams): Bool {
		final name: Null<String> = node.name;
		if ((node.kind == seams.identKind || node.kind == seams.interpIdentKind) && name != null && names.contains(name)) return true;
		return node.children.exists(c -> mentions(c, names, seams));
	}

	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final paramKinds: Array<String> = shape.paramKinds ?? [];
		final blockBodyKind: Null<String> = shape.blockBodyKind;
		final exits: Null<Array<String>> = shape.controlExitKinds;
		if (paramKinds.length == 0 || blockBodyKind == null || exits == null) return null;
		final throws: Array<String> = shape.throwKinds ?? [];
		final jumps: Array<String> = exits.filter(k -> !throws.contains(k));
		for (k in [
			shape.breakStatementKind,
			shape.continueStatementKind,
			shape.breakExpressionKind,
			shape.continueExpressionKind
		]) if (k != null) jumps.push(k);
		return {
			identKind: shape.identKind,
			interpIdentKind: shape.stringInterpIdentKind,
			paramKinds: paramKinds,
			blockBodyKind: blockBodyKind,
			localDeclKinds: shape.localDeclKinds ?? [],
			localContinuationKinds: shape.localDeclContinuationKinds ?? [],
			jumpKinds: jumps
		};
	}

}

/** One opted-in helper, its body as a pattern. */
private typedef Template = {

	/** `pkg.Type.member`, for the message. */
	final helper: String;

	/** The helper's type path, as the call spells it through `TypeRefPrinter`. */
	final typePath: String;
	final member: String;

	/** The parameter names in declaration order — the call's argument order. */
	final params: Array<String>;

	/** The names the body's top-level statements declare. */
	final locals: Array<String>;
	final pattern: Pattern;

	/** Where the helper is declared: its own body is never a site. */
	final file: String;
	final span: Span;

}

/** One matched copy: the replaced statements and the call's argument texts. */
private typedef Site = { final span: Span; final template: Template; final args: Array<String>; }

/** What `scanBody` learns of a helper's body. */
private typedef BodyScan = {
	final holes: Array<String>;
	final reads: Map<String, Int>;
	final idents: Array<QueryNode>;
	var problem: Null<String>;
}

/** The file one site search runs over. */
private typedef SiteCtx = {
	final file: String;
	final source: String;
	final root: QueryNode;
	final purity: PurityCtx;
	final regions: () -> Array<LexRegion>;
	final seams: Seams;
}

private typedef Seams = {

	final identKind: String;
	final interpIdentKind: Null<String>;
	final paramKinds: Array<String>;
	final blockBodyKind: String;
	final localDeclKinds: Array<String>;
	final localContinuationKinds: Array<String>;

	/** The control exits a site would take from its OWN function: every exit but a throw, plus break and continue. */
	final jumpKinds: Array<String>;

}
