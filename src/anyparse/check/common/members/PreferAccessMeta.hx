package anyparse.check.common.members;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.RiskyFix;
import anyparse.check.scan.OperandBinder;
import anyparse.query.AddMeta;
import anyparse.query.MemberKinds;
import anyparse.query.MemberLookup.HostedMembers;
import anyparse.query.RefactorSupport;
import anyparse.query.SourceComments;
import anyparse.query.StaticExtensions;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeNameBinding.Tier;

/** The grammar seams the rule reads (`PreferAccessMeta.seamsOf`). */
private typedef Seams = {
	final annotatedKinds: Array<String>;
	final waiver: String;
	final grant: String;
	final memberKinds: Array<String>;
	final fieldAccessKind: String;
	final newExprKind: Null<String>;
};

/** One waiver: the annotated expression, its annotation, the expression it waives privacy in, and where it sits. */
private typedef Waiver = {
	final meta: QueryNode;
	final expr: QueryNode;
	final member: Null<QueryNode>;
	final owner: Null<TypeDeclMatch>;
};

/** The grants the fix adds, member by member, in the order the waivers were met. */
private final class MemberGrants {

	public final members: Array<QueryNode> = [];
	public final paths: Array<Array<String>> = [];

	public function new() {}

	/** Record that `member` needs every grant in `needed`. */
	public function add(member: QueryNode, needed: Array<String>): Void {
		var slot: Int = members.indexOf(member);
		if (slot < 0) {
			members.push(member);
			paths.push([]);
			slot = members.length - 1;
		}
		for (path in needed) if (!paths[slot].contains(path)) paths[slot].push(path);
	}

}

/**
 * Flags an expression that waives every privacy check inside it (Haxe `@:privateAccess`): the user's rule is to name the
 * type whose private members the code reads, with `@:access(T)` on the member that reads them. `Severity.Info`, DEFAULT OFF.
 *
 * The fix drops the waiver and grants, on the enclosing member, every type declaring a private member the expression reads
 * — each receiver's declarations through `OperandBinder.receiverDecls`, the member where the type declares or inherits it
 * (`MemberLookup.declaringMember`), privacy as `StaticExtensions.accessible` reads it. A grant the member or its type
 * already carries is not repeated, and the enclosing type's own members need none. An expression with a receiver the
 * binder cannot type, or a member it cannot find, keeps its waiver: the grant would be a guess. `RiskyFix`: a grant the
 * index computed stands only where the compiler oracle accepts the edit.
 */
@:nullSafety(Strict)
final class PreferAccessMeta extends RuleBase implements DefaultOff implements RiskyFix {

	private static inline final RULE_ID: String = 'prefer-access-meta';

	/** A prefix annotation has the annotation, then the expression it annotates. */
	private static inline final ANNOTATED_CHILDREN: Int = 2;

	/** The constructor's member name, which a construction reads. */
	private static inline final CONSTRUCTOR: String = 'new';

	/** The finding's text after the waiver's own spelling. */
	private static inline final MESSAGE_TAIL: String =
		' waives every privacy check in its expression — grant the type it reads on the member instead';

	private static inline final DECLINE_UNTYPED: String =
		'a receiver or member in the waived expression could not be resolved, so the types to grant are not known';
	private static inline final DECLINE_PLACE: String = 'the waiver sits outside any member, so there is no member to grant';
	private static inline final DECLINE_COMMENT: String = 'a comment sits between the waiver and its expression';

	public function new() {
		super(RULE_ID, 'an expression waiving every privacy check — grant the type it reads on the member instead', RuleCategory.Members);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return RunScan.collectWith(files, plugin, seamsOf(plugin.refShape()), (entry, tree, s, out) -> {
			for (w in waivers(tree, s)) {
				final span: Null<Span> = w.meta.span;
				if (span != null) out.push({
					file: entry.file,
					span: span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: s.waiver + MESSAGE_TAIL
				});
			}
		});
	}

	/** Drop each flagged waiver whose grants are all known, and add the grants its member lacks. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		final file: String = violations.length > 0 ? violations[0].file : '';
		final scope: Null<SymbolIndex> = IndexScope.resolutionIndexOf(plugin) ?? index;
		return RunScan.editsWith(plugin, source, seamsOf(plugin.refShape()), (tree, s) -> {
			final binder: Null<OperandBinder> = scope == null ? null : OperandBinder.forFile(plugin, file, source, tree, scope);
			final byFrom: Map<Int, Violation> = [];
			for (v in violations) {
				final span: Null<Span> = v.span;
				if (span != null) byFrom[span.from] = v;
			}
			final edits: Array<FixEdit> = [];
			final grants: MemberGrants = new MemberGrants();
			for (w in waivers(tree, s)) {
				final v: Null<Violation> = byFrom[w.meta.span?.from ?? -1];
				if (v == null) continue;
				final needed: Null<Array<String>> = binder == null || scope == null
					? null
					: grantsOf(w.expr, w.owner, file, binder, scope, s);
				final reason: Null<String> = decline(w, source) ?? (needed == null ? DECLINE_UNTYPED : null);
				final member: Null<QueryNode> = w.member;
				if (reason != null || member == null || needed == null) {
					v.declineReason = reason ?? DECLINE_PLACE;
					continue;
				}
				edits.push({ span: new Span(w.meta.span?.from ?? 0, w.expr.span?.from ?? 0), text: '' });
				grants.add(member, needed);
			}
			return edits.concat(grantEdits(tree, source, s, grants));
		});
	}

	/** The seams, or null when the grammar names no waiver, no grant or no prefix annotation. */
	private static function seamsOf(shape: RefShape): Null<Seams> {
		final waiver: Null<String> = shape.waivesPrivacyMetaName;
		final grant: Null<String> = shape.takesPrivateAccessMetaName;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final annotatedKinds: Array<String> = shape.prefixAnnotationKinds ?? [];
		return waiver == null || grant == null || fieldAccessKind == null || annotatedKinds.length == 0 ? null : {
			annotatedKinds: annotatedKinds,
			waiver: waiver,
			grant: grant,
			memberKinds: shape.memberDeclKinds ?? [],
			fieldAccessKind: fieldAccessKind,
			newExprKind: shape.newExprKind
		};
	}

	/** Every waiver in `tree`, with the member and the type declaration it sits in. */
	private static function waivers(tree: QueryNode, s: Seams): Array<Waiver> {
		final out: Array<Waiver> = [];
		function walk(node: QueryNode, member: Null<QueryNode>, owner: Null<TypeDeclMatch>): Void {
			final decl: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			final inType: Null<TypeDeclMatch> = decl ?? owner;
			final inMember: Null<QueryNode> = if (decl != null)
				null
			else if (s.memberKinds.contains(node.kind))
				node
			else
				member;
			if (s.annotatedKinds.contains(node.kind) && node.children.length == ANNOTATED_CHILDREN) {
				final meta: QueryNode = node.children[0];
				if (MemberKinds.META_KINDS.contains(meta.kind) && meta.name == s.waiver) out.push({
					meta: meta,
					expr: node.children[1],
					member: inMember,
					owner: inType
				});
			}
			for (c in node.children) walk(c, inMember, inType);
		}
		walk(tree, null, null);
		return out;
	}

	/** Why the waiver `w` cannot be rewritten whatever its grants, or null. */
	private static function decline(w: Waiver, source: String): Null<String> {
		final metaSpan: Null<Span> = w.meta.span;
		final exprSpan: Null<Span> = w.expr.span;
		return if (w.member == null || metaSpan == null || exprSpan == null)
			DECLINE_PLACE
		else if (SourceComments.textHasCommentMarker(source.substring(metaSpan.to, exprSpan.from)))
			DECLINE_COMMENT
		else
			null;
	}

	/**
	 * The paths of the types declaring a private member `expr` reads — a member access through a typed receiver, a
	 * construction through its constructor — or null when a receiver or a member does not resolve. `owner`'s own members
	 * need no grant.
	 */
	private static function grantsOf(
		expr: QueryNode, owner: Null<TypeDeclMatch>, file: String, binder: OperandBinder, scope: SymbolIndex, s: Seams
	): Null<Array<String>> {
		final paths: Array<String> = [];
		function walk(node: QueryNode): Bool {
			final name: Null<String> = node.name;
			final resolved: Bool = if (name == null)
				true
			else if (node.kind == s.fieldAccessKind && node.children.length == 1)
				addGrants(binder.receiverDecls(node.children[0]), name, owner, file, scope, paths)
			else if (node.kind == s.newExprKind)
				addGrants(boundDecls(binder.typeNameTier(name, node.span?.from)), CONSTRUCTOR, owner, file, scope, paths)
			else
				true;
			return resolved && node.children.foreach(walk);
		}
		return walk(expr) ? paths : null;
	}

	/**
	 * Add to `paths` the path of each declaration of `decls` whose `member` is private to it, false when `decls` is unknown
	 * or one of them does not declare or inherit `member`. `owner`'s own members need no grant.
	 */
	private static function addGrants(
		decls: Null<Array<ResolvedType>>, member: String, owner: Null<TypeDeclMatch>, file: String, scope: SymbolIndex,
		paths: Array<String>
	): Bool {
		if (decls == null || decls.length == 0) return false;
		for (rt in decls) {
			final hosted: Null<HostedMembers> = scope.typing.members.declaringMember(rt, member);
			if (hosted == null || hosted.members.length == 0) return false;
			final host: ResolvedType = hosted.host;
			final own: Bool = owner != null && host.file.file == file && host.type.name == owner.name;
			final path: String = SymbolIndex.typePath(host);
			if (!own && !hosted.members.exists(m -> StaticExtensions.accessible(m, host)) && !paths.contains(path)) paths.push(path);
		}
		return true;
	}

	/** The declarations a bound tier names, null for any other tier. */
	private static function boundDecls(tier: Tier): Null<Array<ResolvedType>> {
		return switch tier {
			case Bound(found): found;
			case _: null;
		};
	}

	/** One edit per member of `grants` adding the grants it and its type do not already carry. */
	private static function grantEdits(tree: QueryNode, source: String, s: Seams, grants: MemberGrants): Array<FixEdit> {
		final edits: Array<FixEdit> = [];
		for (i => member in grants.members) {
			final owner: Null<QueryNode> = ownerDeclOf(tree, member);
			final held: Array<String> = RefactorSupport.accessGrantsOn(tree, member, s.grant)
				.concat(owner == null ? [] : RefactorSupport.accessGrantsOn(tree, owner, s.grant));
			final missing: Array<String> = [for (path in grants.paths[i]) if (!held.contains(path)) '${s.grant}($path)'];
			final edit: Null<FixEdit> = missing.length == 0 ? null : AddMeta.entriesEdit(source, tree, member, missing);
			if (edit != null) edits.push(edit);
		}
		return edits;
	}

	/** The type declaration node holding `member`, whose own grants cover it too. */
	private static function ownerDeclOf(tree: QueryNode, member: QueryNode): Null<QueryNode> {
		var found: Null<QueryNode> = null;
		function walk(node: QueryNode, owner: Null<QueryNode>): Void {
			if (found != null) return;
			final decl: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			final inType: Null<QueryNode> = decl == null ? owner : decl.declNode;
			if (node == member) {
				found = inType;
				return;
			}
			for (c in node.children) walk(c, inType);
		}
		walk(tree, null);
		return found;
	}

}
