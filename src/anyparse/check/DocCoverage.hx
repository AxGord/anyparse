package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags a public API declaration — a top-level type or a public member of one —
 * that carries no leading doc comment. The public surface is what other modules
 * compile against, so an undocumented public declaration is a coverage gap the
 * intra-body checks (complexity, naming) never see. Report-only, `Severity.Info`:
 * writing the doc is an authoring decision, so `fix` produces no edits.
 *
 * ## What counts as documented
 *
 * A `/**`-opened block comment immediately preceding the declaration (only
 * whitespace between the comment close and the declaration, or the modifier /
 * metadata run that precedes it). A line comment is NOT a doc; neither is a plain
 * `/*` block nor the empty `/**` `/` form. The doc anchor is the START of the
 * leading modifier / `@:meta` run, because that is where the doc sits in source —
 * `@:nullSafety` and `public` project as siblings BEFORE the declaration node.
 *
 * ## Scope — the public API surface only
 *
 * - A top-level type is public unless a preceding `private` modifier makes it
 *   module-private; a module-private type and every member inside it are skipped.
 * - A class / abstract member is public only with an explicit `public` modifier
 *   (Haxe defaults an unmodified member to private); an interface member is
 *   implicitly public, and an extern / `@:publicFields` container's members are too.
 * - The constructor (`new`) is exempt by default — the type-level doc covers
 *   construction (`includeConstructor` opts in).
 * - Enum constructors and typedef fields are NOT flagged as members; the type-level
 *   doc documents the shape. Only the enum / typedef itself is required to carry one.
 *
 * ## Config
 *
 * `requireTypeDoc` / `requireMemberDoc` (requireTypeDoc default true; requireMemberDoc default FALSE, opt-in) toggle the type-level and
 * member-level requirements independently; `includeConstructor` (default false)
 * extends the member requirement to the constructor. A project scopes the rule to
 * its API packages, or turns off the member half, through an `apqlint.json`.
 *
 * ## Grammar-agnostic
 *
 * `RefShape.typeDeclKinds` lists the documentable top-level type kinds,
 * `interfaceDeclKinds` the containers whose members are implicitly public,
 * `visibilityContainerKinds` + `memberDeclKinds` + `publicModifierKind` the
 * explicit-visibility member model, and `constructorName` the exempt member. Any
 * unset required seam (`typeDeclKinds`) makes the check a no-op. `#if`-guarded
 * members are not descended into — their raw-trivia projection is skipped
 * conservatively.
 */
@:nullSafety(Strict)
final class DocCoverage implements Check implements ConfigAware {

	/** Whether an undocumented public top-level type is flagged, unless an `apqlint.json` sets `requireTypeDoc`. */
	private static inline final RULE_ID: String = 'doc-coverage';

	private static inline final DEFAULT_REQUIRE_TYPE_DOC: Bool = true;

	/**
	 * Whether an undocumented public MEMBER is flagged, unless an `apqlint.json` sets
	 * `requireMemberDoc`. Default false: the public-member surface is large (the
	 * type-level requirement is the bounded default signal), so a project opts into
	 * member coverage deliberately rather than being flooded by it.
	 */
	private static inline final DEFAULT_REQUIRE_MEMBER_DOC: Bool = false;

	/** Whether the constructor is subject to the member requirement, unless an `apqlint.json` sets `includeConstructor`. */
	private static inline final DEFAULT_INCLUDE_CONSTRUCTOR: Bool = false;

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a public API type or member without a doc comment';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final config: LintConfig = LintConfig.resolveWith(_resolveConfig, entry.file);
			final cfg: DocCfg = {
				requireTypeDoc: config.boolOption(RULE_ID, 'requireTypeDoc') ?? DEFAULT_REQUIRE_TYPE_DOC,
				requireMemberDoc: config.boolOption(RULE_ID, 'requireMemberDoc') ?? DEFAULT_REQUIRE_MEMBER_DOC,
				includeConstructor: config.boolOption(RULE_ID, 'includeConstructor') ?? DEFAULT_INCLUDE_CONSTRUCTOR
			};
			scanModule(violations, entry.file, entry.source, tree, seams, cfg, CheckScan.docBlockEnds(entry.source));
		}
		return violations;
	}

	/** Documenting a public declaration is an authoring decision, not a mechanical autofix — report-only. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** The declared name of a type node — its own, or its container child's for a `final class` (whose name sits on the inner `ClassForm`). */
	private static inline function typeName(node: QueryNode, seams: Seams): String {
		return CheckScan.typeDeclName(node, seams.containers.concat(seams.interfaceDecls));
	}

	/** Whether `node` is a leading modifier / `@:meta` annotation (part of a decl's preceding run), not a member or clause. */
	private static inline function isLeadingAnnotation(node: QueryNode, seams: Seams): Bool {
		return CheckScan.isLeadingAnnotation(node, seams.modifiers);
	}

	/**
	 * Scan a module's direct children. A running modifier / `@:meta` sibling run
	 * precedes each top-level type decl; `runStart` tracks its start (the doc anchor),
	 * `sawPrivate` whether the run makes the type module-private, and `publicByDefault`
	 * whether an extern / `@:publicFields` marker makes its members implicitly public.
	 * A non-annotation, non-type child (package / import / clause) resets the run.
	 */
	private static function scanModule(
		out: Array<Violation>, file: String, source: String, root: QueryNode, seams: Seams, cfg: DocCfg, docEnds: Map<Int, Bool>
	): Void {
		var runStart: Int = -1;
		var sawPrivate: Bool = false;
		var publicByDefault: Bool = false;
		for (child in root.children) {
			if (seams.typeDecls.contains(child.kind)) {
				final span: Null<Span> = child.span;
				if (span != null && !sawPrivate) {
					final anchor: Int = runStart >= 0 ? runStart : span.from;
					if (cfg.requireTypeDoc && !CheckScan.hasDocBefore(source, docEnds, anchor))
						out.push(finding(file, source, span, 'public type \'${typeName(child, seams)}\' has no doc comment'));
					if (cfg.requireMemberDoc) {
						final container: Null<QueryNode> = memberContainerOf(child, seams);
						if (container != null)
							scanMembers(
								out, file, source, container, seams, seams.interfaceDecls.contains(child.kind) || publicByDefault,
								cfg.includeConstructor, docEnds
							);
					}
				}
			} else if (isLeadingAnnotation(child, seams)) {
				final span: Null<Span> = child.span;
				if (runStart < 0 && span != null) runStart = span.from;
				if (seams.privateKind != null && child.kind == seams.privateKind) sawPrivate = true;
				if (seams.externKind != null && child.kind == seams.externKind) publicByDefault = true;
				final nm: Null<String> = child.name;
				if (nm != null && seams.publicMetaNames.contains(nm)) publicByDefault = true;
				continue;
			}
			runStart = -1;
			sawPrivate = false;
			publicByDefault = false;
		}
	}

	/**
	 * Scan a container's members. A member is public when `implicitPublic` (an interface
	 * / public-default container) or its preceding modifier run carries the public
	 * modifier (`sawPublic`). `runStart` tracks the doc anchor (the run start). The
	 * constructor is skipped unless `includeConstructor`.
	 */
	private static function scanMembers(
		out: Array<Violation>, file: String, source: String, container: QueryNode, seams: Seams, implicitPublic: Bool,
		includeConstructor: Bool, docEnds: Map<Int, Bool>
	): Void {
		var runStart: Int = -1;
		var sawPublic: Bool = false;
		for (child in container.children) {
			if (seams.members.contains(child.kind)) {
				final span: Null<Span> = child.span;
				if (span != null) {
					final isPublic: Bool = implicitPublic || sawPublic;
					final name: String = child.name ?? '';
					final isCtor: Bool = seams.constructorName != null && name == seams.constructorName;
					final anchor: Int = runStart >= 0 ? runStart : span.from;
					if (isPublic && (includeConstructor || !isCtor) && !CheckScan.hasDocBefore(source, docEnds, anchor))
						out.push(finding(file, source, span, 'public member \'$name\' has no doc comment'));
				}
			} else if (isLeadingAnnotation(child, seams)) {
				final span: Null<Span> = child.span;
				if (runStart < 0 && span != null) runStart = span.from;
				if (seams.publicKind != null && child.kind == seams.publicKind) sawPublic = true;
				continue;
			}
			runStart = -1;
			sawPublic = false;
		}
	}

	/**
	 * The member-hosting node for a type decl: the decl itself for a class / abstract /
	 * interface, its container child for a `final class` (whose members nest in a
	 * `ClassForm`), and null for an enum / typedef (no doc-checked members).
	 */
	private static function memberContainerOf(typeNode: QueryNode, seams: Seams): Null<QueryNode> {
		return seams.containers.contains(typeNode.kind) || seams.interfaceDecls.contains(typeNode.kind)
			? typeNode
			: typeNode.children.find(c -> seams.containers.contains(c.kind) || seams.interfaceDecls.contains(c.kind));
	}

	/** Build one `Info` finding on the declaration's HEADER line (so an inline `// noqa` on that line suppresses it). */
	private static function finding(file: String, source: String, span: Span, message: String): Violation {
		final headerEnd: Int = source.indexOf('\n', span.from);
		return {
			file: file,
			span: new Span(span.from, headerEnd == -1 ? span.to : headerEnd),
			rule: RULE_ID,
			severity: Severity.Info,
			message: message
		};
	}

	/** Resolve the type / member / visibility seam kinds, or null when the required `typeDeclKinds` is unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final typeDecls: Array<String> = shape.typeDeclKinds ?? [];
		if (typeDecls.length == 0) return null;
		final visibility: Array<String> = shape.visibilityModifierKinds ?? [];
		final publicKind: Null<String> = shape.publicModifierKind;
		var privateKind: Null<String> = null;
		for (v in visibility) if (v != publicKind) privateKind = v;
		final modifiers: Array<String> = CheckScan.modifierKinds(shape);
		return {
			typeDecls: typeDecls,
			members: shape.memberDeclKinds ?? [],
			containers: shape.visibilityContainerKinds ?? [],
			interfaceDecls: shape.interfaceDeclKinds ?? [],
			modifiers: modifiers,
			publicKind: publicKind,
			privateKind: privateKind,
			externKind: shape.externModifierKind,
			publicMetaNames: shape.publicDefaultMetaNames ?? [],
			constructorName: shape.constructorName
		};
	}

}

/** Resolved kind-sets the doc-coverage walk threads through its recursion. */
private typedef Seams = {
	final typeDecls: Array<String>;
	final members: Array<String>;
	final containers: Array<String>;
	final interfaceDecls: Array<String>;
	final modifiers: Array<String>;
	final publicKind: Null<String>;
	final privateKind: Null<String>;
	final externKind: Null<String>;
	final publicMetaNames: Array<String>;
	final constructorName: Null<String>;
};

/** Per-file resolved config for the doc-coverage walk. */
private typedef DocCfg = {
	final requireTypeDoc: Bool;
	final requireMemberDoc: Bool;
	final includeConstructor: Bool;
};
