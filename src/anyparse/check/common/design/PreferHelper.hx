package anyparse.check.common.design;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.FileGated;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.GroupedEdit;
import anyparse.check.Check.GroupedFix;
import anyparse.check.Check.OptionKeyed;
import anyparse.check.Check.RiskyFix;
import anyparse.check.Check.VolatileMessage;
import anyparse.check.scan.LoopScan;
import anyparse.check.scan.PurityScan;
import anyparse.check.scan.ReceiverShadow;
import anyparse.check.scan.UsingScan;
import anyparse.query.ElementSpan;
import anyparse.query.IndexScope;
import anyparse.query.LexicalRegions;
import anyparse.query.Matcher;
import anyparse.query.ParseGate;
import anyparse.query.Pattern;
import anyparse.query.ShapeVocab;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeRefPrinter;
import anyparse.util.Compare;
import haxe.Exception;

using anyparse.util.Arrays;
using anyparse.util.Groups;
using anyparse.util.Strings;

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

	/** The names the body declares below its top level, loop binders included: scoped to the copy, never read after it. */
	final nested: Array<String>;

	/** Each function parameter, the body's one call of it the hole: the locals that call passes, the lambda's parameters. */
	final calls: Map<String, Array<String>>;

	/** The value parameters a read of which may follow a body effect: a site binds each to a plain value only. */
	final late: Array<String>;

	/** The spelling around the closing return's value, when the body ends in one: the call then ends the site's function. */
	final exit: Null<Exit>;
	final pattern: Pattern;

	/** Where the helper is declared: its own body is never a site. */
	final file: String;
	final span: Span;

	/** False when the helper cannot be an extension: `@:noUsing`, or no parameter to be the receiver. */
	final extensible: Bool;

}

/** The text before and after the value of a template's closing return. */
private typedef Exit = { final head: String; final tail: String; }

/** One matched copy: the replaced statements, the call's argument texts and how the call is spelled. */
private typedef Site = {
	final span: Span;
	final template: Template;
	final args: Array<String>;
	final spelling: Spelling;
}

/** What `scanBody` learns of a helper's body. */
private typedef BodyScan = {

	final params: Array<String>;
	final holes: Array<String>;
	final nested: Array<String>;
	final reads: Map<String, Int>;

	/** Each value parameter's reads, a read a loop repeats placed at that loop's end. */
	final readsAt: Map<String, Array<Int>>;
	final calls: Map<String, Array<String>>;
	final idents: Array<QueryNode>;

	/** The control exits that refuse the body: a body ending in a value return keeps its value returns. */
	final jumps: Array<String>;
	final exits: Bool;
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
	final plugin: GrammarPlugin;

	/** Null unless a helper of the file's scope sits in a module the project spells as extension calls. */
	final extension: Null<ExtensionCtx>;

}

/** The project's choice of the extension spelling: the modules (`prefer-static-extension` `types`) and whether a `using` may be added. */
private typedef ExtOptions = { final modules: Array<String>; final addUsing: Bool; }

/** What a call's extension spelling is judged on in one file. */
private typedef ExtensionCtx = {
	final modules: Array<String>;
	final addUsing: Bool;
	final header: UsingHeader;
	final usings: Array<String>;
	final typing: Null<ReceiverTyping>;
	final index: SymbolIndex;
}

/** How a site's call is spelled. */
private typedef Spelling = {

	/** `recv.member(rest)` instead of `Type.member(args)`. */
	final extension: Bool;

	/** The extension call needs a `using` the file does not have yet. */
	final needsUsing: Bool;

	/** Why a helper of a listed module stayed qualified; null when the module is not listed or the call is an extension. */
	final note: Null<String>;

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
	final iterationBinderKinds: Array<String>;
	final valueBinderKinds: Array<String>;
	final loopKinds: Array<String>;
	final callKind: Null<String>;
	final returnKind: Null<String>;
	final valueReturnKinds: Array<String>;
	final functionKinds: Array<String>;
	final lambdaKinds: Array<String>;

	/**
	 * The jumps a lambda hole's binding may not hold: in the lambda a `return` leaves the
	 * lambda, a `break` or `continue` no loop of the binding encloses has none to bind to.
	 */
	final escapes: LoopJumpSeams;

}

/**
 * The one answer to "which statement fragments of a tree are an inlined copy of an opted-in template helper's body, and
 * may be replaced by a call to it". A helper opts in by carrying the annotation `apq.json` names
 * (`"prefer-helper": { "marker": "@:preferHelper" }`); every static function of the resolution scope carrying it is a
 * TEMPLATE, its body a structural pattern (`Matcher`) whose parameters and locals are holes, and a run of statements
 * matching it is reported and fixed to a call of the helper. A new helper needs no new rule. `Info`. The user contract
 * with examples: docs/guide/lint/design.md § prefer-helper.
 *
 * ## What a template is
 *
 * A static function whose block body reads nothing but its parameters and the locals it declares; a local binds whatever
 * name the site declares, its written type aside, and one below the top level or a loop binder is scoped to the copy. A
 * body that leaves its function early, reads any other name, shadows a hole or never reads a parameter is no template,
 * named once on stderr. A body ENDING in a value return keeps its other value returns: the site runs through its closing
 * return, and the fix is that return spelled around the call. A FUNCTION PARAMETER is one the body only calls, once, with
 * locals of its own as the arguments: that call is the hole, and the site's expression there becomes a lambda of the names
 * the site binds those locals to (`resolve(c.name)` → `c -> resolve(c.name)`), spelled as the plugin parses one.
 *
 * ## What a site must be
 *
 * - **The statements themselves**, adjacent, in the body's order, with no comment in the replaced bytes or trailing them.
 * - **No local of the copy is read after it**, nor by an argument: the call no longer declares it.
 * - **Every value hole binds a pure expression** (`PurityScan.isPure`): the call evaluates each argument once and first.
 * - **A late hole binds a plain value** (`PurityScan.isPlainValue`): one the body reads after an effect, or in a loop
 *   repeating one, the copy reads after that effect and the call before the body (`xs.push(a); xs.push(b)`, `b` =
 *   `xs.length`). A lambda runs where the copy's expression ran, so it need not be pure, and reads no copy local but its own.
 * - **A lambda holds no jump that leaves it**: the copy's `return` leaves the site's function, the lambda's only the
 *   lambda, and a `break` or `continue` needs its loop inside the binding. Running where the copy ran covers effects only.
 * - **Not the helper's own body.**
 *
 * ## The fix is risky
 *
 * Nothing proves the call typechecks (the site's values must have the helper's parameter types, a name matched literally
 * may belong to another type, a lambda loses the null narrowing its body had in the copy), so the check is a `RiskyFix`:
 * `--fix` applies it only under a compiler oracle, reverting an edit whose build breaks, else report-only.
 * `TypeRefPrinter` spells the helper's type and its import; a module `prefer-static-extension` lists gets `recv.member(rest)` + `using`.
 *
 * Grammar-agnostic: the ident, parameter, body, local, binder, loop, call, return and lambda kinds of `RefShape` over the
 * plugin's own `parsePattern`; a plugin without `paramKinds`, `blockBodyKind` or `controlExitKinds` makes it a no-op.
 */
@:nullSafety(Strict)
final class PreferHelper extends RuleBase implements ConfigAware implements FileGated implements RiskyFix implements OptionKeyed
		implements GroupedFix implements VolatileMessage {

	/** The rule id, also the `apq.json` option key. */
	private static inline final RULE_ID: String = 'prefer-helper';

	/** What every finding's message says before the call it quotes; `messageIdentity` cuts the quoted call and the spelling note off. */
	private static final MESSAGE_LEAD: String = ' — call the helper';

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
			for (site in sitesIn(entry.file, entry.source, templates, index, seams, plugin, extensionOptionsOf(entry.file))) out.push({
				file: entry.file,
				span: site.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: messageOf(site)
			});
		}
		return out;
	}

	/**
	 * Re-derive every site against the plugin's resolution index — the scope `run` found the templates in — and rewrite the
	 * ones a violation names into the helper call, with the import the call needs riding on them.
	 */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return fixGrouped(source, violations, plugin, index).map(edit -> { span: edit.span, text: edit.text });
	}

	/**
	 * Each rewrite shares a group with the import its helper's type needs, so the verifier's bisect never keeps an import
	 * whose every rewrite it reverted.
	 */
	public function fixGrouped(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<GroupedEdit> {
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
		final sites: Array<Site> = [
			for (site in sitesIn(
				file, source, templatesOf(marker, resolved, plugin, seams), resolved, seams, plugin, extensionOptionsOf(file)
			)) if (wanted.contains('${site.span.from}:${site.span.to}')) site
		];
		// The import and the `using` ride on a rewrite: a file where every site declined gets no edit at all.
		if (sites.length == 0) return [];
		final texts: Array<String> = sites.map(site -> callText(site, printer));
		final imports: ImportGroups = printer.importGroups();
		// The sites that need a `using` share one group with its insert, as a qualified site shares one with its import.
		final usingGroup: Int = imports.edits.length;
		final edits: Array<GroupedEdit> = [
			for (i => site in sites) {
				span: site.span,
				text: texts[i],
				group: site.spelling.extension ? (site.spelling.needsUsing ? usingGroup : null) : imports.groupOf(site.template.typePath)
			}
		];
		final header: UsingHeader = UsingScan.headerOf(root, source, plugin, resolved.fileInfo(file));
		final usingInsert: Null<Array<GroupedEdit>> = usingInsertOf(sites, header, usingGroup);
		return usingInsert == null ? [] : edits.concat(imports.edits).concat(usingInsert);
	}

	public function messageIdentity(message: String): String {
		return MessageMask.cutAfter(message, MESSAGE_LEAD);
	}

	public function acceptedOptions(): Array<String> {
		return [OPTION_MARKER];
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

	private function extensionOptionsOf(file: String): ExtOptions {
		final config: LintConfig = LintConfig.resolveWith(_resolveConfig, file);
		return { modules: UsingScan.extensionTypes(config) ?? [], addUsing: UsingScan.extensionAddUsing(config) };
	}

	/** The helper call replacing `site`: a statement, or the helper's own closing return spelled around it. */
	private static function callText(site: Site, printer: TypeRefPrinter): String {
		final call: String = site.spelling.extension
			? extensionCall(site)
			: '${printer.print(site.template.typePath).text}.${site.template.member}(${site.args.join(', ')})';
		final exit: Null<Exit> = site.template.exit;
		return exit == null ? '$call;' : exit.head + call + exit.tail;
	}

	/** `member`'s body as a template, or null with the reason in `problems`. */
	private static function templateOf(
		file: String, typePath: String, member: MemberInfo, index: SymbolIndex, plugin: GrammarPlugin, seams: Seams, problems: Array<String>
	): Null<Template> {
		final source: Null<String> = index.sourceOf(file);
		final root: Null<QueryNode> = source == null ? null : ParseGate.parseOrNull(plugin, source);
		final decl: Null<QueryNode> = root == null ? null : declAt(root, member);
		final declSpan: Null<Span> = decl?.span;
		if (source == null || root == null || decl == null || declSpan == null) {
			problems.push('its declaration cannot be read');
			return null;
		}
		final params: Array<String> = [ for (c in decl.children) if (seams.paramKinds.contains(c.kind)) c.name ?? '' ];
		final stmts: Array<QueryNode> = decl.children.find(c -> c.kind == seams.blockBodyKind)?.children ?? [];
		final locals: Array<String> = [ for (s in stmts) if (seams.localDeclKinds.contains(s.kind)) s.name ?? '' ];
		final exit: Null<Exit> = stmts.length == 0 ? null : exitOf(source, stmts[stmts.length - 1], seams);
		final scan: BodyScan = scanOf(stmts, params, locals, exit != null, seams);
		final problem: Null<String> = stmts.length == 0 ? 'it has no block body' : scan.problem ?? usageProblem(params, scan, seams);
		if (problem != null) {
			problems.push(problem);
			return null;
		}
		final pattern: Null<Pattern> = patternOf(source, stmts, scan.idents, locals.concat(scan.nested), plugin, seams);
		if (pattern != null) return {
			helper: '$typePath.${member.name}',
			typePath: typePath,
			member: member.name,
			params: params,
			locals: locals,
			nested: scan.nested,
			calls: scan.calls,
			late: lateParams(stmts, scan, PurityScan.contextOf(plugin, source, root, index, file), seams),
			exit: exit,
			pattern: pattern,
			file: file,
			span: declSpan,
			extensible: isExtensible(member, params, scan.calls)
		};
		problems.push('its body is no pattern');
		return null;
	}

	/** What the body `stmts` reads and declares; `exits` when it ends in a value return, which keeps its value returns. */
	private static function scanOf(
		stmts: Array<QueryNode>, params: Array<String>, locals: Array<String>, exits: Bool, seams: Seams
	): BodyScan {
		final scan: BodyScan = {
			params: params,
			holes: params.concat(locals),
			nested: [],
			reads: [],
			readsAt: [],
			calls: [],
			idents: [],
			jumps: exits ? seams.jumpKinds.filter(k -> !seams.valueReturnKinds.contains(k)) : seams.jumpKinds,
			exits: exits,
			problem: null
		};
		for (s in stmts) scanBody(s, true, null, seams, scan);
		return scan;
	}

	/** Why the parameters `scan` saw read make the body no template, or null. */
	private static function usageProblem(params: Array<String>, scan: BodyScan, seams: Seams): Null<String> {
		final unread: Null<String> = params.find(p -> !scan.reads.exists(p) && !scan.calls.exists(p));
		if (unread != null) return 'it never reads $unread';
		final mixed: Null<String> = params.find(p -> scan.reads.exists(p) && scan.calls.exists(p));
		if (mixed != null) return 'it reads $mixed other than by calling it';
		return scan.calls.keys().hasNext() && seams.lambdaKinds.length == 0 ? 'its grammar has no lambda to pass a function' : null;
	}

	/**
	 * The value parameters a read of which may come after a body effect: the copy reads such a hole after that effect, the
	 * call before the body, so only a value no effect can change may bind it. With no purity context every one is late.
	 */
	private static function lateParams(stmts: Array<QueryNode>, scan: BodyScan, purity: Null<PurityCtx>, seams: Seams): Array<String> {
		var effect: Null<Int> = null;
		if (purity != null) for (s in stmts) if (effect == null) effect = firstEffect(s, purity, seams);
		final out: Array<String> = [];
		for (p in scan.params) if (!scan.calls.exists(p)) {
			final reads: Array<Int> = scan.readsAt[p] ?? [];
			if (purity == null || (effect != null && reads.exists(at -> at >= effect))) out.push(p);
		}
		return out;
	}

	/**
	 * Where the first effect under `node` has run: the end of the first impure node no impure child explains, or null. A call
	 * runs its effect after its callee's receiver and its arguments, so a method read in callee position is no effect.
	 */
	private static function firstEffect(node: QueryNode, purity: PurityCtx, seams: Seams): Null<Int> {
		if (PurityScan.isPure(node, purity)) return null;
		final call: Bool = node.kind == seams.callKind && node.children.length > 0;
		final parts: Array<QueryNode> = call ? node.children[0].children.concat(node.children.slice(1)) : node.children;
		for (c in parts) {
			final at: Null<Int> = firstEffect(c, purity, seams);
			if (at != null) return at;
		}
		return node.span?.to ?? 0;
	}

	/** The spelling around the value of `last` when it is a value return: a site's copy then ends its own function. */
	private static function exitOf(source: String, last: QueryNode, seams: Seams): Null<Exit> {
		final at: Null<Span> = last.span;
		final value: Null<Span> = last.children.length == 1 ? last.children[0].span : null;
		return last.kind != seams.returnKind || at == null || value == null
			? null
			: { head: source.substring(at.from, value.from), tail: source.substring(value.to, at.to) };
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
				namedLocals(parsed.root, locals, seams.localDeclKinds.concat(seams.iterationBinderKinds).concat(seams.valueBinderKinds)),
				parsed.category, text, parsed.kindEquivalence, parsed.ignoredMetavars, parsed.identKind
			);
	}

	/** The declaration node `member` was indexed from. */
	private static function declAt(node: QueryNode, member: MemberInfo): Null<QueryNode> {
		return node.kind == member.kind && node.name == member.name && node.span?.from == member.declFrom
			? node
			: node.children.findMap(c -> declAt(c, member));
	}

	/**
	 * Record in `scan` every hole read under `node` and the first reason the body is no template. `loopEnd` is the end of
	 * the outermost loop that repeats `node`, where its reads count as made: a later iteration reads after every effect in
	 * the loop. A loop's iterable runs once, so it is read where it stands.
	 */
	private static function scanBody(node: QueryNode, top: Bool, loopEnd: Null<Int>, seams: Seams, scan: BodyScan): Void {
		if (scan.problem != null) return;
		scan.problem = refusalOf(node, top, seams, scan);
		if (scan.problem != null) return;
		final name: Null<String> = node.name;
		final binder: Bool = seams.iterationBinderKinds.contains(node.kind);
		final declares: Bool = binder || seams.valueBinderKinds.contains(node.kind) || (!top && seams.localDeclKinds.contains(node.kind));
		if (declares && !declare(name, scan)) return;
		if (node.kind == seams.callKind && callHole(node, seams, scan)) return;
		if (node.kind == seams.identKind && !readHole(node, loopEnd, scan)) return;
		final repeated: Null<Int> = seams.loopKinds.contains(node.kind) ? loopEnd ?? node.span?.to : loopEnd;
		final iterable: Null<QueryNode> = binder ? node.children.find(c -> !seams.valueBinderKinds.contains(c.kind)) : null;
		for (c in node.children) scanBody(c, false, c == iterable ? loopEnd : repeated, seams, scan);
	}

	/** Record the read `ident` of a hole made at `loopEnd` or where it stands; false with the problem when it names none. */
	private static function readHole(ident: QueryNode, loopEnd: Null<Int>, scan: BodyScan): Bool {
		final name: Null<String> = ident.name;
		if (name == null || !scan.holes.contains(name)) {
			scan.problem = 'it reads ${name ?? 'a name'}, which a site may bind to something else';
			return false;
		}
		scan.reads[name] = (scan.reads[name] ?? 0) + 1;
		scan.readsAt.push(name, loopEnd ?? ident.span?.from ?? 0);
		scan.idents.push(ident);
		return true;
	}

	/** Why `node` alone makes the body no template, or null. */
	private static function refusalOf(node: QueryNode, top: Bool, seams: Seams, scan: BodyScan): Null<String> {
		if (scan.jumps.contains(node.kind))
			return 'it leaves the function early (${node.kind}), which a site would do from its own function';
		if (scan.exits && seams.functionKinds.contains(node.kind))
			return 'it holds a function, whose return would leave that function and not the body';
		if (!top && seams.localContinuationKinds.contains(node.kind)) return 'it declares a local below its top level';
		return node.kind == seams.interpIdentKind ? 'it reads ${node.name ?? 'a name'} inside a string' : null;
	}

	/** Make `name` a hole of a local below the body's top level; false with the problem when it shadows a hole. */
	private static function declare(name: Null<String>, scan: BodyScan): Bool {
		if (name == null || (scan.holes.contains(name) && !scan.nested.contains(name))) {
			scan.problem = 'it declares ${name ?? 'a local'} over a parameter or a local of its own';
			return false;
		}
		if (!scan.nested.contains(name)) {
			scan.holes.push(name);
			scan.nested.push(name);
		}
		return true;
	}

	/**
	 * Whether `call` calls a parameter with locals of the body's own as its arguments: the whole call is then the hole of that
	 * parameter, and a site's expression in its place becomes a lambda of those locals. One such call per parameter.
	 */
	private static function callHole(call: QueryNode, seams: Seams, scan: BodyScan): Bool {
		final callee: Null<QueryNode> = call.children[0];
		final param: Null<String> = callee?.name;
		if (callee == null || callee.kind != seams.identKind || param == null) return false;
		if (!scan.params.contains(param)) return false;
		final args: Array<String> = [];
		for (a in call.children.slice(1)) {
			final arg: Null<String> = a.name;
			if (a.kind != seams.identKind || arg == null) return false;
			if (!scan.nested.contains(arg) || args.contains(arg)) return false;
			args.push(arg);
		}
		if (scan.calls.exists(param)) {
			scan.problem = 'it calls $param more than once';
			return true;
		}
		scan.calls[param] = args;
		scan.idents.push(new QueryNode(seams.identKind, param, [], call.span));
		return true;
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
		file: String, source: String, templates: Array<Template>, index: SymbolIndex, seams: Seams, plugin: GrammarPlugin,
		options: ExtOptions
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
			seams: seams,
			plugin: plugin,
			extension: extensionOf(templates, options, root, source, file, index, plugin)
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
		final localNames: Array<String> = boundNames(m, template.locals);
		final nestedNames: Array<String> = boundNames(m, template.nested);
		if (localNames.length < template.locals.length || nestedNames.length < template.nested.length) return null;
		final copyNames: Array<String> = localNames.concat(nestedNames);
		final args: Array<String> = [];
		for (param in template.params) {
			final arg: Null<String> = argOf(m, template, param, copyNames, ctx);
			if (arg == null) return null;
			args.push(arg);
		}
		if (localNames.length > 0) {
			final run: Array<QueryNode> = m.node.kind == Pattern.SEQUENCE_KIND ? m.node.children : [m.node];
			final after: Null<Array<QueryNode>> = siblingsAfter(ctx.root, run[0], run[run.length - 1]);
			if (after == null || after.exists(s -> mentions(s, localNames, ctx.seams))) return null;
		}
		return {
			span: span,
			template: template,
			args: args,
			spelling: spellingOf(template, template.params.length == 0 ? null : m.bindings[template.params[0]], span, ctx)
		};
	}

	/** The call's argument for `param`, or null when its binding is no value the call may take in place of the copy's. */
	private static function argOf(m: Match, template: Template, param: String, copyNames: Array<String>, ctx: SiteCtx): Null<String> {
		final bound: Null<QueryNode> = m.bindings[param];
		final at: Null<Span> = bound?.span;
		if (bound == null || at == null) return null;
		final text: String = ctx.source.substring(at.from, at.to);
		final lambda: Null<Array<String>> = template.calls[param];
		if (lambda != null) {
			if (LoopScan.escapesIteration(bound, ctx.seams.escapes, false)) return null;
			final lambdaNames: Array<String> = boundNames(m, lambda);
			return mentions(bound, copyNames.filter(n -> !lambdaNames.contains(n)), ctx.seams) ? null : lambdaText(lambdaNames, text, ctx);
		}
		if (mentions(bound, copyNames, ctx.seams)) return null;
		if (!PurityScan.isPure(bound, ctx.purity)) return null;
		return template.late.contains(param) && !PurityScan.isPlainValue(bound, ctx.purity) ? null : text;
	}

	/** The names `m` binds the name holes `holes` to, skipping one it leaves unbound. */
	private static function boundNames(m: Match, holes: Array<String>): Array<String> {
		return [ for (h in holes) {
			final name: Null<String> = m.bindings[h]?.name;
			if (name != null) name;
		} ];
	}

	/**
	 * `body` as a lambda of `params`, spelled as the plugin parses one, or null when it does not. The copy evaluates the body
	 * at each call of the parameter, and so does the helper through the lambda, so an impure body is no reason to decline.
	 * That holds for effects, not for jumps: `argOf` declines a body holding one that leaves it (`LoopScan.escapesIteration`).
	 */
	private static function lambdaText(params: Array<String>, body: String, ctx: SiteCtx): Null<String> {
		final text: String = '${params.length == 1 ? params[0] : '(${params.join(', ')})'} -> $body';
		final parsed: Null<Pattern> = try ctx.plugin.parsePattern(text) catch (exception: Exception) null;
		return parsed != null && ctx.seams.lambdaKinds.contains(parsed.root.kind) ? text : null;
	}

	/** The statements after `last` in the child list holding `first`, or null when no node holds it. */
	private static function siblingsAfter(node: QueryNode, first: QueryNode, last: QueryNode): Null<Array<QueryNode>> {
		final at: Int = node.children.indexOf(first);
		if (at == -1) return node.children.findMap(c -> siblingsAfter(c, first, last));
		final end: Int = node.children.indexOf(last);
		return end < at ? null : node.children.slice(end + 1);
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
		final loopJumps: Array<String> = [
			for (k in [
				shape.breakStatementKind,
				shape.continueStatementKind,
				shape.breakExpressionKind,
				shape.continueExpressionKind
			]) if (k != null) k
		];
		final hardExits: Array<String> = exits.filter(k -> !throws.contains(k) && !loopJumps.contains(k));
		final jumps: Array<String> = hardExits.concat(loopJumps);
		return {
			identKind: shape.identKind,
			interpIdentKind: shape.stringInterpIdentKind,
			paramKinds: paramKinds,
			blockBodyKind: blockBodyKind,
			localDeclKinds: shape.localDeclKinds ?? [],
			localContinuationKinds: shape.localDeclContinuationKinds ?? [],
			jumpKinds: jumps,
			iterationBinderKinds: shape.iterationBindingKinds ?? [],
			valueBinderKinds: shape.iterationValueBinderKinds ?? [],
			loopKinds: ShapeVocab.loopKinds(shape),
			callKind: shape.callKind,
			returnKind: shape.returnStatementKind,
			valueReturnKinds: shape.valueReturnKinds ?? [],
			functionKinds: ShapeVocab.nestedFunctionKinds(shape),
			lambdaKinds: shape.lambdaKinds ?? [],
			escapes: {
				loopKinds: shape.loopStatementKinds ?? [],
				doWhileKinds: shape.doWhileLoopKinds ?? [],
				opaqueKinds: shape.opaqueKinds ?? [],
				nestedScopeKinds: LoopScan.nestedScopeKinds(shape),
				hardExitKinds: hardExits,
				loopJumpKinds: loopJumps
			}
		};
	}

	/** Whether a call of the helper may be spelled on its first argument: a first parameter that takes a value, `@:noUsing` not set. */
	private static function isExtensible(member: MemberInfo, params: Array<String>, calls: Map<String, Array<String>>): Bool {
		return params.length > 0 && !member.excludedFromExtensions && !calls.exists(params[0]);
	}

	/** The extension judging context of a file, null when no template of its scope sits in a module the project spells as extensions. */
	private static function extensionOf(
		templates: Array<Template>, options: ExtOptions, root: QueryNode, source: String, file: String, index: SymbolIndex,
		plugin: GrammarPlugin
	): Null<ExtensionCtx> {
		if (!templates.exists(t -> options.modules.contains(t.typePath))) return null;
		final info: Null<FileInfo> = index.fileInfo(file);
		final header: UsingHeader = UsingScan.headerOf(root, source, plugin, info);
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		return {
			modules: options.modules,
			addUsing: options.addUsing,
			header: header,
			usings: UsingScan.reachingUsings(header, info),
			typing: provider == null ? null : ReceiverShadow.typingOf(provider, plugin, root, source, file, () -> index),
			index: index
		};
	}

	/** `recv.member(rest)` when the project spells the helper's module as an extension and nothing says it would bind elsewhere. */
	private static function spellingOf(template: Template, recv: Null<QueryNode>, span: Span, ctx: SiteCtx): Spelling {
		final ext: Null<ExtensionCtx> = ctx.extension;
		if (ext == null || !ext.modules.contains(template.typePath)) return { extension: false, needsUsing: false, note: null };
		final reason: Null<String> = qualifiedReason(template, recv, span, ext, ctx);
		return {
			extension: reason == null,
			needsUsing: reason == null && UsingScan.usingScopeAt(ext.header, template.typePath, [span.from]) == UsingScope.Absent,
			note: reason
		};
	}

	/** Why the call of a helper of a listed module stays qualified, null when the extension spelling binds that helper. */
	private static function qualifiedReason(
		template: Template, recv: Null<QueryNode>, span: Span, ext: ExtensionCtx, ctx: SiteCtx
	): Null<String> {
		final typing: Null<ReceiverTyping> = ext.typing;
		final path: String = template.typePath;
		final member: String = template.member;
		if (recv == null || typing == null || !template.extensible) return 'the helper cannot be called on its first argument';
		final shadow: Null<String> = switch ReceiverShadow.judge(recv, member, typing, span.from).verdict {
			case Free: null;
			case Shadowed: 'the receiver\'s type declares a member `$member`, which a static extension never overrides';
			case DynamicReceiver: 'a `Dynamic` receiver dispatches no extension';
			case UnresolvedReceiver: 'the receiver\'s type is not resolved';
			case UnresolvedClosure: 'the receiver\'s type may declare `$member` or bring its own extensions';
		};
		if (shadow != null) return shadow;
		if (UsingScan.usingConflict(ext.usings, path, member, ctx.plugin, () -> ext.index, ctx.file) != UsingConflict.Clear)
			return 'another `using` in the file could also supply `$member`';
		final scope: UsingScope = UsingScan.usingScopeAt(ext.header, path, [span.from]);
		if (scope == UsingScope.Guarded) return UsingScan.guardedUsingDecline(path, 'this call');
		return scope == UsingScope.Absent && !ext.addUsing ? 'the file has no `using $path` and addUsing is off' : null;
	}

	/** `recv.member(rest)` for a site whose first argument is the receiver. */
	private static function extensionCall(site: Site): String {
		return '${site.args[0]}.${site.template.member}(${site.args.slice(1).join(', ')})';
	}

	private static function messageOf(site: Site): String {
		final base: String = 'repeats the body of ${site.template.helper}(${site.template.params.join(', ')})$MESSAGE_LEAD';
		final note: Null<String> = site.spelling.note;
		return if (site.spelling.extension)
			'$base as `${extensionCall(site)}`'
		else if (note == null)
			base
		else
			'$base, qualified: $note';
	}

	/** The one `using` insert the sites that need it share, grouped with them; none when every site's module is in scope. */
	private static function usingInsertOf(sites: Array<Site>, header: UsingHeader, group: Int): Null<Array<GroupedEdit>> {
		final modules: Array<String> = [];
		for (site in sites) if (site.spelling.needsUsing) modules.pushUnique(site.template.typePath);
		if (modules.length == 0) return [];
		final insert: Null<FixEdit> = UsingScan.usingInsertsEdit(header, modules);
		return insert == null ? null : [{ span: insert.span, text: insert.text, group: group }];
	}

}
