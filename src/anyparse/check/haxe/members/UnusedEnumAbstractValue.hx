package anyparse.check.haxe.members;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.RiskyFix;
import anyparse.check.FactsOracle.EnumValueReads;
import anyparse.check.scan.CaseValueKey;
import anyparse.check.scan.PublicReach;
import anyparse.check.scan.RunScan;
import anyparse.query.ElementSpan;
import anyparse.query.IndexScope;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.OccurrenceScan;
import anyparse.query.OracleProviders;
import anyparse.query.ParseGate;
import anyparse.query.RefactorSupport;
import anyparse.query.SourceComments;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.util.Strings;

using StringTools;

/**
 * Flags a value of an enum abstract nothing reads — the one answer to "which enum abstract values does no code read, by
 * type". A value's name says little: a bare `GRID` in a `case` or beside `==` is the value of whatever type the place
 * expects, so a value named like a value of another type is found dead only by the compiler. The builds' facts record
 * where they read a value of each enum abstract (`FactsOracle.enumValueReads`), and every occurrence of the name is then
 * weighed: one the builds typed as no value of this type reads nothing, while one in code no build typed — a file, a
 * member or a conditional branch every configuration left out — or in a string that may look it up by name keeps the
 * value. Without the facts only a value whose name occurs nowhere outside its declaration is reported.
 *
 * No value of a type a value can arrive into implicitly is reported — one with a `from` cast or an implicit conversion
 * member, whose values come from outside as plain constants — nor one of a `@:keep` type, one carrying `@:keep` or
 * `@:expose` itself, one of a type a build macro writes, or one of a type some code names as a value rather than as a
 * type or as the qualifier of one of its members: a macro or a reflection call handed the type may enumerate its values.
 *
 * The fix removes the value with its doc comment, and is off until the rule's `fix` key enables it: it removes only a
 * value written with its own initializer (the constant is folded into every read, so nothing compiled changes) after
 * which no value is numbered implicitly (removing one would renumber those), and, as a `RiskyFix`, only where every
 * oracle configuration still compiles. A `//` line directly above a value labels its group and stays while another value
 * of the group follows; a value alone in its group takes its label along.
 */
@:nullSafety(Strict)
final class UnusedEnumAbstractValue extends HaxeRule implements DefaultOff implements RiskyFix implements ConfigAware {

	private static inline final RULE_ID: String = 'unused-enum-abstract-value';

	/** The rule's config key enabling the fix. */
	private static final FIX_KEY: String = 'fix';

	/** The span keys of the findings `fix` may remove, decided in `run` where the whole scope is in hand. */
	private var _deletable: Array<String> = [];

	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(RULE_ID, 'an enum abstract value no code of any build reads', RuleCategory.Members);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		_deletable = [];
		final shape: RefShape = plugin.refShape();
		final scope: Array<ScopeFile> = scopeOf(files, plugin);
		final index: SymbolIndex = IndexScope.report(files, plugin);
		final wide: SymbolIndex = IndexScope.resolutionIndexOf(plugin) ?? index;
		final ctx: Ctx = {
			plugin: plugin,
			shape: shape,
			scope: scope,
			declarations: wide,
			tokens: tokenCounts(scope),
			facts: OracleProviders.of(plugin).factsForFiles(plugin, scope, () -> null),
			values: CaseValueKey.seamsOf(shape),
			memberKinds: shape.memberDeclKinds ?? [],
			pins: [
				for (name in [shape.retainedDeclMetaName, shape.exportedDeclMetaName]) if (name != null) name
			]
		};
		return RunScan.collect(files, plugin, (entry, tree, out) -> {
			final info: Null<FileInfo> = index.fileInfo(entry.file);
			if (info == null) return;
			final fixing: Bool = fixEnabled(entry.file);
			for (type in info.types) if (type.isEnumAbstract && !type.hasKeep && exemption(type, ctx) == null)
				considerType(out, type, entry, tree, ctx, fixing);
		});
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		final wanted: Array<String> = [
			for (v in violations) {
				final span: Null<Span> = v.span;
				if (span != null && _deletable.contains(spanKey(v.file, span))) '${span.from}:${span.to}';
			}
		];
		if (wanted.length == 0) return [];
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		if (tree == null) return [];
		final kinds: Array<String> = plugin.refShape().memberDeclKinds ?? [];
		final regions: Array<LexRegion> = plugin.lexicalRegions(source);
		final edits: Array<FixEdit> = [];
		function walk(node: QueryNode): Void {
			for (child in node.children) {
				final span: Null<Span> = child.span;
				if (span != null && kinds.contains(child.kind) && wanted.contains('${span.from}:${span.to}'))
					edits.push(removal(source, child, node, span, regions))
				else
					walk(child);
			}
		}
		walk(tree);
		return edits;
	}

	/** Whether the rule's own config key enables the fix for `file`. */
	private function fixEnabled(file: String): Bool {
		final resolve: Null<(String) -> LintConfig> = _resolveConfig;
		return resolve != null && (resolve(file).boolOption(RULE_ID, FIX_KEY) ?? false);
	}

	/** Report every value of `type` nothing reads, and note the ones the fix may remove. */
	private function considerType(
		out: Array<Violation>, type: TypeDeclInfo, entry: ScopeFile, tree: QueryNode, ctx: Ctx, fixing: Bool
	): Void {
		final reads: Null<EnumValueReads> = ctx.facts?.enumValueReads(entry.file, type.name);
		final values: Array<MemberInfo> = [for (m in type.members) if (isValue(m, ctx)) m];
		for (i => m in values) if (!m.guarded && !ctx.pins.exists(pin -> m.metaNames.contains(pin))) {
			final node: Null<QueryNode> = memberAt(tree, m.declFrom, ctx.memberKinds);
			final span: Null<Span> = node?.span;
			if (span == null || referenced(type, m, entry.file, entry.source, span, reads, ctx)) continue;
			final blocker: Null<String> = fixing
				? removalBlocker(m, values.slice(i + 1))
				: 'its removal is off: the rule\'s `$FIX_KEY` key enables it';
			if (blocker == null) _deletable.push(spanKey(entry.file, span));
			out.push({
				file: entry.file,
				span: span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: reads == null
					? 'unused enum abstract value `${type.name}.${m.name}`: its name occurs nowhere outside its declaration'
					: 'unused enum abstract value `${type.name}.${m.name}`: no code of any build reads it',
				declineReason: blocker
			});
		}
	}

	private static inline function spanKey(file: String, span: Span): String {
		return '$file:${span.from}:${span.to}';
	}

	/** Whether `m` is a value of its enum abstract rather than a static or a method. */
	private static function isValue(m: MemberInfo, ctx: Ctx): Bool {
		return !m.isStatic && ctx.values.fieldKinds.contains(m.kind);
	}

	/**
	 * Why no value of `type` is weighed, or null: a value arrives into it implicitly, a macro writes it, or some code names
	 * it as a value — which a macro or a reflection call enumerating its values is handed.
	 */
	private static function exemption(type: TypeDeclInfo, ctx: Ctx): Null<String> {
		if (type.guarded || type.branches.length != 1) return 'it is declared under conditional compilation';
		if (type.hasBuild || type.hasAutoBuild || type.isMacroMade) return 'a build macro writes it';
		final clauses: Null<CastClauses> = type.branches[0]?.clauses;
		if (clauses == null || clauses.from.length > 0 || type.members.exists(m -> m.isImplicitConversion))
			return 'a value arrives into it implicitly';
		return namedAsValue(type, ctx) ? 'some code names it as a value' : null;
	}

	/**
	 * Whether a file of the scope names `type` other than as a type or as the qualifier of one of its own members — the
	 * positive list: anything else may hand the type itself to code that enumerates its values.
	 */
	private static function namedAsValue(type: TypeDeclInfo, ctx: Ctx): Bool {
		final own: Array<String> = type.members.map(m -> m.name);
		for (entry in ctx.scope) if (entry.source.contains(type.name)) {
			final tree: Null<QueryNode> = ParseGate.parseOrNull(ctx.plugin, entry.source);
			if (tree == null || handsOn(tree, type.name, own, entry.file, ctx)) return true;
		}
		return false;
	}

	/**
	 * Whether some code may read the value `m` of `type`, declared at
	 * `declared` in `file` (whose text is `declaredIn`): a read the builds typed
	 * (`reads`), or an occurrence of its name the facts do not place as the read of another type's value or as none.
	 */
	private static function referenced(
		type: TypeDeclInfo, m: MemberInfo, file: String, declaredIn: String, declared: Span, reads: Null<EnumValueReads>, ctx: Ctx
	): Bool {
		final key: Null<String> = CaseValueKey.ofMember(type, m, ctx.values);
		final own: Map<String, Int> = [];
		PublicReach.countTokens(declaredIn, declared.from, declared.to, own);
		if ((ctx.tokens[m.name] ?? 0) <= (own[m.name] ?? 0)) return false;
		if (reads != null && (key == null || reads.keys.contains(key))) return true;
		for (entry in ctx.scope) if (entry.source.contains(m.name)) {
			final excluded: Array<Span> = (entry.file == file ? [declared] : []).concat(declaredNames(entry, m.name, ctx));
			final found: Null<Array<ClassifiedOccurrence>> = OccurrenceScan.classifyOccurrences(
				entry.source, m.name, ctx.plugin, 0, entry.source.length, excluded
			);
			if (found == null) return true;
			for (o in found) if (mayRead(o, entry.file, file, type, reads, ctx)) return true;
		}
		return false;
	}

	/** Whether the occurrence `o` in `at` may read a value of `type`, declared in `file`. */
	private static function mayRead(
		o: ClassifiedOccurrence, at: String, file: String, type: TypeDeclInfo, reads: Null<EnumValueReads>, ctx: Ctx
	): Bool {
		switch o.kind {
			case CommentTrivia, StringWord, DirectiveComment:
				return false;
			case StringLiteral:
				return true;
			case ActiveCode, ConditionalRaw:
		}
		// the type's own body: another value's initializer reads it as no build records
		if (at == file && type.span.from <= o.span.from && o.span.to <= type.span.to) return true;
		final facts: Null<FactsOracle> = ctx.facts;
		if (facts == null || reads == null) return true;
		final typed: Null<Array<String>> = facts.enumValuesReadAt(at, o.span);
		if (typed == null || typed.contains(reads.type)) return true;
		// typed code recording no value here is a branch no build compiled or a read in a shape the walk does not record
		return typed.length == 0;
	}

	/** Why the fix may not remove `m`, followed in its type by `later`, or null when it may. */
	private static function removalBlocker(m: MemberInfo, later: Array<MemberInfo>): Null<String> {
		if (m.initializerKind == null)
			return 'it has no initializer of its own: its value is numbered or named implicitly, and removing it may change another\'s';
		return later.exists(v -> v.initializerKind == null)
			? 'a later value is numbered implicitly, and removing this one would renumber it'
			: null;
	}

	/** The files whose code may read a value: the resolution scope, with the report set over it by path. */
	private static function scopeOf(files: Array<ScopeFile>, plugin: GrammarPlugin): Array<ScopeFile> {
		final sources: Map<String, String> = [];
		for (entry in RefactorSupport.resolutionProjectSourcesOf(plugin) ?? []) sources[entry.file] = entry.source;
		for (entry in files) sources[entry.file] = entry.source;
		return [for (file => source in sources) { file: file, source: source }];
	}

	/** The member declaration of `kinds` starting at `from` in `tree`. */
	private static function memberAt(tree: QueryNode, from: Int, kinds: Array<String>): Null<QueryNode> {
		for (child in tree.children) {
			final span: Null<Span> = child.span;
			if (span == null || span.to <= from || span.from > from) continue;
			if (span.from == from && kinds.contains(child.kind)) return child;
			final inner: Null<QueryNode> = memberAt(child, from, kinds);
			if (inner != null) return inner;
		}
		return null;
	}

	/**
	 * The edit removing `node`, a child of `parent` at `span`, with its annotations, its doc comment and its lines — and the
	 * `//` label above it when no member of its group follows it.
	 */
	private static function removal(source: String, node: QueryNode, parent: QueryNode, span: Span, regions: Array<LexRegion>): FixEdit {
		final group: Span = ElementSpan.declGroupSpan(node, parent, span);
		final lines: Span = ElementSpan.lineExtendedSpan(source, ElementSpan.docExtendedSpan(source, group, regions, true));
		final tokens: Array<CommentTok> = SourceComments.collectCommentTokens(regions);
		var from: Int = lines.from;
		if (aloneInGroup(source, node, parent, lines.to)) while (true) {
			final label: Int = SourceComments.ownLineCommentAbove(source, tokens, from, false);
			if (label < 0 || !tokens.exists(t -> t.from == label && t.isLine)) break;
			from = SourceText.lineStartOf(source, label);
		}
		return { span: ElementSpan.blankExtendedSpan(source, new Span(from, lines.to)), text: '' };
	}

	/**
	 * Whether no member of the group follows `node` ending at `end`: no sibling follows it, or a blank line precedes the next one.
	 */
	private static function aloneInGroup(source: String, node: QueryNode, parent: QueryNode, end: Int): Bool {
		final siblings: Array<QueryNode> = parent.children;
		var next: Null<Span> = null;
		for (i in siblings.indexOf(node) + 1...siblings.length) {
			next = siblings[i].span;
			if (next != null) break;
		}
		if (next == null) return true;
		// the first whole line after the member: the rest of a line it ends on is no blank line
		var at: Int = Strings.lineEnd(source, end - 1) + 1;
		while (at < next.from) {
			final eol: Int = Strings.lineEnd(source, at);
			if (Strings.isBlank(source.substring(at, eol))) return true;
			at = eol + 1;
		}
		return false;
	}

	/** The name tokens of the members called `name` that `entry` declares: a declaration of another value reads none. */
	private static function declaredNames(entry: ScopeFile, name: String, ctx: Ctx): Array<Span> {
		final out: Array<Span> = [];
		for (type in ctx.declarations.fileInfo(entry.file)?.types ?? []) for (m in type.members) if (m.name == name) {
			final token: Null<Span> = OccurrenceScan.binderTokenSpan(entry.source, m.declFrom, entry.source.length, name);
			if (token != null) out.push(token);
		}
		return out;
	}

	/** Every identifier token's occurrence count over `scope`. */
	private static function tokenCounts(scope: Array<ScopeFile>): Map<String, Int> {
		final out: Map<String, Int> = [];
		for (entry in scope) PublicReach.countTokens(entry.source, 0, entry.source.length, out);
		return out;
	}

	/** Whether the type written `host` in `file` resolves to declarations, none of which a build macro writes. */
	private static function plainHost(host: Null<String>, file: String, ctx: Ctx): Bool {
		final found: Array<{ file: FileInfo, type: TypeDeclInfo }> = host == null ? [] : ctx.declarations.resolveTypeRefsFrom(host, file);
		return found.length > 0 && !found.exists(f -> f.type.hasBuild || f.type.hasAutoBuild || f.type.isMacroMade);
	}

	/** Whether `node`'s subtree in `file` names the type `name`, whose members are `own`, where it may be handed on. */
	private static function handsOn(node: QueryNode, name: String, own: Array<String>, file: String, ctx: Ctx): Bool {
		for (i => child in node.children) if (handedAt(node, i, child, name, own, file, ctx) || handsOn(child, name, own, file, ctx))
			return true;
		return false;
	}

	/**
	 * Whether `child`, the `i`th child of `node` in `file`, names the type `name` where it may be handed on: a value read of
	 * it that qualifies none of `own`, or a type argument of a host the index does not resolve to declarations no build macro
	 * writes.
	 */
	private static function handedAt(
		node: QueryNode, i: Int, child: QueryNode, name: String, own: Array<String>, file: String, ctx: Ctx
	): Bool {
		final types: Array<String> = ctx.shape.typeAnnotationKinds ?? [];
		final written: String = child.name ?? '';
		if (!types.contains(child.kind))
			return written == name
				&& (child.kind == ctx.shape.identKind || child.kind == ctx.shape.fieldAccessKind)
				&& !(i == 0 && node.kind == ctx.shape.fieldAccessKind && own.contains(node.name ?? ''));
		final argument: Bool = types.contains(node.kind) || node.kind == ctx.shape.newExprKind;
		return SourceText.lastSegment(written) == name && argument && !plainHost(node.name, file, ctx);
	}

}

/** What one run of the rule reads for every type it weighs. */
private typedef Ctx = {

	final plugin: GrammarPlugin;
	final shape: RefShape;

	/** The files whose code may read a value. */
	final scope: Array<ScopeFile>;

	/** The index declaring the scope's members. */
	final declarations: SymbolIndex;

	/** Every identifier token's occurrence count over the scope. */
	final tokens: Map<String, Int>;

	/** The builds' facts, or null when the run holds none. */
	final facts: Null<FactsOracle>;
	final values: CaseValueSeams;
	final memberKinds: Array<String>;

	/** The annotations pinning a type or a value against removal, or exporting it to code outside the program. */
	final pins: Array<String>;

}

/** A file of the scope and its text. */
private typedef ScopeFile = { file: String, source: String };
