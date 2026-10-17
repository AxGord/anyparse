package anyparse.check;

import anyparse.check.PublicReach.MemberRun;
import anyparse.check.PublicReach.ReachRegion;
import anyparse.query.ElementSpan;
import anyparse.query.GrammarPlugin;
import anyparse.query.IndexScope;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.MemberBranchScan;
import anyparse.query.MemberKinds;
import anyparse.query.NamingPolicy.NamedDecl;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.NamingPolicy.NamingPolicy;
import anyparse.query.NamingPolicy.NamingRule;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * `naming`'s PRIVATIZE arm: a PUBLIC member spelled `_x` that nothing outside its own type (and
 * its subtypes - Haxe `private` is visible to them) reads is made `private`, keeping its name, where
 * the ordinary fix would rename it to `x`. The `_` prefix is the private-member marker of the
 * convention the policy encodes, so such a member was meant private, and the rename would cement a
 * public API nothing uses.
 *
 * ## Which findings are candidates (`isCandidate`, cheap, per file)
 *
 * A POSITIVE list: a FIELD (a method's visibility answers to overrides and interfaces a field's
 * does not), carrying `public`, named `_…`, with an enclosing type, no implicit reach (no metadata,
 * no type-registry shape) and no rename hazard the grammar marks (an accessor-backed property, an
 * `@:rtti` member, a structure field) - and, the gate that keeps the arm inside whatever policy
 * governs the file, the rule that would govern it once PRIVATE accepts its name. Under the built-in
 * Haxe convention that admits exactly a `_camel` instance field.
 *
 * ## The whole-project verdict (`verdicts`, once per run)
 *
 * Every gate is `unused-public-member`'s reachability set, asked through `PublicReach`: the token
 * count over report UNION resolution scope against the member's type plus its subtypes, then the
 * raw-text confirm; an interpolation fragment that could spell the name; `@:keep` / `@:build` /
 * `extern` / RTTI / an `@:autoBuild` ancestor / an unresolved supertype; any metadata on the
 * member; any `@:access` grant naming the type; a modifier run only some builds see. There is no
 * separate supertype / interface / structure gate, for `unused-public-member`'s reason: an
 * interface or supertype declaring the name, and a structure the class could unify with, all SPELL
 * it, so the token count already refuses.
 *
 * WHOLE-PROJECT evidence is the arm's precondition (`RefactorSupport.projectIsComplete`: declared
 * `resolutionRoots`, every one of them matched). Without it the token map is the report set, a
 * narrowed lint scope would read a reference in an unlinted file as absent - the lint-fix-scope
 * incident - and the arm stays off, leaving the rename it always was. With it the evidence spans
 * the project however narrow the run, so a subdirectory run answers what the whole-project one does.
 *
 * The edit replaces the `public` keyword with `private`. It is a `RiskyArm`: the gate list is a
 * NEGATIVE one, so the edit reaches the tree only through the compiler oracle's typecheck-and-revert
 * pipeline, and without an oracle the finding is report-only.
 */
@:nullSafety(Strict)
@:access(anyparse.check.Naming)
final class NamingPrivatize {

	/** The neutral modifier name of `public`. */
	private static inline final PUBLIC_MOD: String = 'public';

	/** The neutral modifier name of `private` - also the keyword the edit writes. */
	private static inline final PRIVATE_MOD: String = 'private';

	/** The private-member marker the arm reads as "meant private". */
	private static inline final UNDERSCORE: String = '_';

	/** The keyword the edit writes over `public`. */
	public static inline function keyword(): String {
		return PRIVATE_MOD;
	}

	/** Whether `decl`, reported by `naming` under `policy`, is a privatize candidate - see the type doc. */
	public static function isCandidate(decl: NamedDecl, policy: NamingPolicy): Bool {
		if (decl.category != NamingCategory.Field || !decl.name.startsWith(UNDERSCORE) || !decl.mods.contains(PUBLIC_MOD)) return false;
		if (decl.enclosingType == null || decl.implicitReach != null || decl.renameUnsafe == true) return false;
		final privatized: NamedDecl = {
			span: decl.span,
			name: decl.name,
			category: decl.category,
			mods: [for (m in decl.mods) m == PUBLIC_MOD ? PRIVATE_MOD : m],
			enclosingType: decl.enclosingType
		};
		final rule: Null<NamingRule> = Naming.applicableRule(privatized, policy);
		return rule != null && rule.format.match(decl.name);
	}

	/**
	 * Every candidate the whole-project gates prove safe to privatize, keyed by
	 * `CheckScan.spanKey(file, declarationSpan)`. Empty unless the run indexes the whole project.
	 */
	public static function verdicts(
		candidates: Array<PrivatizeCandidate>, files: Array<{ file: String, source: String }>, plugin: GrammarPlugin
	): Map<String, Privatized> {
		final out: Map<String, Privatized> = [];
		if (candidates.length == 0 || !RefactorSupport.projectIsComplete(plugin)) return out;
		final index: SymbolIndex = IndexScope.report(files, plugin);
		final wide: SymbolIndex = IndexScope.resolutionIndexOf(plugin) ?? index;
		final ctx: Evidence = {
			tokens: PublicReach.tokenCounts(files, wide, plugin),
			fragments: ReflectionScan.reflectionSurface(files, plugin).fragments,
			index: index,
			wide: wide
		};
		for (c in candidates) {
			final declSpan: Null<Span> = c.decl.span;
			final owner: Null<String> = c.decl.enclosingType;
			if (declSpan == null || owner == null) continue;
			final keywordSpan: Null<Span> = publicKeywordIfConfined(c, declSpan, owner, plugin, ctx);
			if (keywordSpan == null) continue;
			// Re-bound: strict null-safety does not narrow inside a struct literal.
			final keywordAt: Span = keywordSpan;
			final ownerName: String = owner;
			final proven: Privatized = { keywordSpan: keywordAt, owner: ownerName };
			out[CheckScan.spanKey(c.file, declSpan)] = proven;
		}
		return out;
	}

	/** Whether `outer` is known and wholly contains `inner`. */
	private static inline function contains(outer: Null<Span>, inner: Span): Bool {
		return outer != null && outer.from <= inner.from && inner.to <= outer.to;
	}

	/** The `public` keyword's span of `c` when every gate proves nothing outside its type and subtypes reads it, else null. */
	private static function publicKeywordIfConfined(
		c: PrivatizeCandidate, declSpan: Span, owner: String, plugin: GrammarPlugin, ctx: Evidence
	): Null<Span> {
		final cls: Null<QueryNode> = CheckScan.classBodies(c.tree).find(n -> n.name == owner && contains(n.span, declSpan));
		if (cls == null) return null;
		final lex: Array<LexRegion> = plugin.lexicalRegions(c.source);
		final found: Null<FoundMember> = memberAt(cls, declSpan, c.source, plugin);
		if (found == null || !found.certain) return null;
		final mods: MemberRun = PublicReach.readRun(found.run);
		final keyword: Null<QueryNode> = mods.publicModifier;
		// Metadata anywhere in the run, a guarded one included, is already the grammar's `implicitReach`, which `isCandidate` refuses.
		if (keyword == null) return null;
		final scope: SymbolIndex = ctx.wide.fileInfo(c.file) == null ? ctx.index : ctx.wide;
		final host: Null<FileInfo> = scope.fileInfo(c.file);
		final declared: Null<TypeDeclInfo> = host?.types.find(t -> t.name == owner);
		if (host == null || declared == null) return null;
		final type: TypeDeclInfo = declared;
		// An `@:autoBuild` ANCESTOR does not refuse: its generated code lands inside this type, where the
		// member stays visible once private. The type's OWN `@:build` still does (`typeOutOfReach`).
		if (PublicReach.typeOutOfReach(type) || PublicReach.chainOutOfReach(scope, host, type, false)) return null;
		if (ctx.wide.allFiles().exists(fi -> fi.accessGrants.contains(owner))) return null;
		if (ReflectionScan.runtimeNameFragment(ctx.fragments, c.decl.name)) return null;
		final regions: Null<Array<ReachRegion>> = allowedRegions(c, cls, owner, lex, scope);
		return regions != null && PublicReach.occursOnlyWithin(c.decl.name, ctx.tokens, regions, ctx.wide) ? keyword.span : null;
	}

	/**
	 * The member node of `cls` declared at `declSpan` with its modifier run, read the way
	 * `unused-public-member` reads one - every member-position `#if` branch visited, the run
	 * resetting at each member - or null when none starts there.
	 */
	private static function memberAt(cls: QueryNode, declSpan: Span, source: String, plugin: GrammarPlugin): Null<FoundMember> {
		final seams: MemberBranchSeams = MemberBranchScan.seamsOf(plugin.refShape(), source, plugin.lexicalRegions.bind(source));
		var found: Null<FoundMember> = null;
		MemberBranchScan.eachMember(seams, cls, child -> MemberKinds.isMemberDeclKind(child.kind), (child, run, certain) -> {
			final span: Null<Span> = child.span;
			if (span != null && span.from == declSpan.from) found = { run: run, certain: certain };
		});
		return found;
	}

	/**
	 * The regions allowed to name the member: its type's declaration with its doc comment, and every
	 * subtype's declaration. Null when a subtype's source cannot be read - the proof then cannot be made.
	 */
	private static function allowedRegions(
		c: PrivatizeCandidate, cls: QueryNode, owner: String, lex: Array<LexRegion>, scope: SymbolIndex
	): Null<Array<ReachRegion>> {
		final clsSpan: Null<Span> = cls.span;
		if (clsSpan == null) return null;
		final out: Array<ReachRegion> = [
			{ file: c.file, source: c.source, span: ElementSpan.docExtendedSpan(c.source, clsSpan, lex) }
		];
		for (sub in scope.subtypes.subtypeDecls(owner, c.file)) {
			final src: Null<String> = scope.sourceOf(sub.file.file);
			if (src == null) return null;
			// Re-bound: strict null-safety does not narrow inside a struct literal.
			final text: String = src;
			out.push({ file: sub.file.file, source: text, span: sub.type.span });
		}
		return out;
	}

}

/** One `naming` finding the cheap candidate test admitted, with what the whole-project verdict reads of its file. */
typedef PrivatizeCandidate = {
	final file: String;
	final source: String;
	final tree: QueryNode;
	final decl: NamedDecl;
};

/** One proven privatization: the `public` keyword the edit replaces, and the type nothing outside of reads the member. */
typedef Privatized = {
	final keywordSpan: Span;
	final owner: String;
};

/** The whole-run reference evidence, gathered once where the entire file set is in hand. */
private typedef Evidence = {

	/** Identifier-token occurrence counts over every source in report UNION resolution scope. */
	final tokens: Map<String, Int>;

	/** The static text FRAGMENTS of every interpolated string in report scope. */
	final fragments: Array<String>;

	/** The report index. */
	final index: SymbolIndex;

	/** The resolution index (report UNION libraries), or the report index without a scope. */
	final wide: SymbolIndex;

};

/** A member found by `memberAt`: its modifier run and whether every build sees that run. */
private typedef FoundMember = {
	final run: Array<QueryNode>;
	final certain: Bool;
};
