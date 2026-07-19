package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags a `@:bypassAccessor` metadata on a plain-`=` assignment whose lvalue -
 * a bare `x` or `this.x` - resolves to an own-class member that has NO
 * set-accessor: a plain `var` / `final` field, or a property whose WRITE slot is
 * `default` / `null` / `never`. Such a member is written by direct field access,
 * so the meta bypasses a setter that does not exist - a stale leftover. `Info`
 * severity; `fix` removes the `@:bypassAccessor ` token.
 *
 * ## Scope
 *
 * Only a plain `=` assignment (`assignKind`) is considered. A compound assign
 * (`x += 1`, `x++`) is a distinct node kind and also READS the member, so its
 * accessor semantics differ - those are out of scope. A `@:bypassAccessor` on a
 * property READ is meaningful (it bypasses a getter) and is never matched, since
 * the meta here must wrap an assignment. An lvalue that does not resolve to a
 * directly-declared member of the enclosing type (a local, a parameter, an
 * inherited base member, a cross-class field) is left alone - the write slot is
 * not visible single-file, so removing the meta cannot be proven safe.
 *
 * ## Why the removal is safe
 *
 * When the member has no set-accessor, `this.x = x` already compiles to a direct
 * field write; `@:bypassAccessor` is a no-op there (there is no setter to bypass).
 * Dropping it leaves the identical direct write, so the fix is not a `RiskyFix`.
 *
 * ## Grammar-agnostic
 *
 * The assignment kind comes from `RefShape.assignKind` (unset makes the check a
 * no-op), the bare lvalue from `identKind`, the `this.x` form from
 * `fieldAccessKind` + `selfReferenceText`. The metadata node is any
 * `RefactorSupport.META_KINDS` node named `@:bypassAccessor`. Member resolution and
 * the write-accessor flag come from `SymbolIndex` (`MemberInfo.hasSetter`), which
 * needs a `TypeInfoProvider` to populate the write slot: the Haxe plugin supplies
 * one and is the only shipped consumer. A grammar without a provider leaves every
 * `hasSetter = false`, which would treat a real setter as absent - so the rule is
 * meaningful only where write accessors are reported.
 */
@:nullSafety(Strict)
final class RedundantBypassAccessor implements Check {

	private static final BYPASS_META: String = '@:bypassAccessor';

	public function new() {}

	public function id(): String {
		return 'redundant-bypass-accessor';
	}

	public function description(): String {
		return 'a @:bypassAccessor on an assignment to a member that has no set-accessor';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final ctx: Null<Ctx> = context(plugin);
		if (ctx == null) return [];
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			final info: Null<FileInfo> = index.fileInfo(entry.file);
			if (tree != null && info != null) collect(tree, entry.file, ctx, info, violations);
		}
		return violations;
	}

	/**
	 * Remove the `@:bypassAccessor ` token of each flagged assignment - the meta
	 * node plus the whitespace up to the wrapped expression, so a stacked
	 * `@:other @:bypassAccessor ...` keeps its other metadata.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final ctx: Null<Ctx> = context(plugin);
		if (ctx == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final flagged: Array<String> = [for (v in violations) if (v.span != null) '${v.span.from}:${v.span.to}'];
		final edits: Array<{ span: Span, text: String }> = [];
		collectEdits(tree, flagged, edits);
		return edits;
	}

	/** Bundle the seams the check needs, or null when the grammar has no assignment kind. */
	private static function context(plugin: GrammarPlugin): Null<Ctx> {
		final shape: RefShape = plugin.refShape();
		final assignKind: Null<String> = shape.assignKind;
		return assignKind == null ? null : {
			assignKind: assignKind,
			identKind: shape.identKind,
			fieldAccessKind: shape.fieldAccessKind,
			self: shape.selfReferenceText
		};
	}

	/**
	 * Walk `node`; at each `@:bypassAccessor` wrapper (a node with a META child named
	 * `@:bypassAccessor` whose wrapped expression unwraps to a plain assignment) flag
	 * the meta token when the lvalue resolves to an own-class member with no
	 * set-accessor.
	 */
	private static function collect(node: QueryNode, file: String, ctx: Ctx, info: FileInfo, out: Array<Violation>): Void {
		final meta: Null<QueryNode> = bypassMeta(node);
		if (meta != null) {
			final wrapped: Null<QueryNode> = node.children.find(c -> !RefactorSupport.META_KINDS.contains(c.kind));
			final assign: Null<QueryNode> = wrapped == null ? null : unwrapToAssign(wrapped, ctx.assignKind);
			final metaSpan: Null<Span> = meta.span;
			if (assign != null && metaSpan != null) {
				final name: Null<String> = lvalueName(assign, ctx);
				if (name != null && hasNoSetter(name, assign, info)) out.push({
					file: file,
					span: metaSpan,
					rule: 'redundant-bypass-accessor',
					severity: Severity.Info,
					message: 'this @:bypassAccessor bypasses a set-accessor that $name does not have'
				});
			}
		}
		for (child in node.children) collect(child, file, ctx, info, out);
	}

	/** Re-walk to emit the token deletion for each flagged wrapper. */
	private static function collectEdits(node: QueryNode, flagged: Array<String>, edits: Array<{ span: Span, text: String }>): Void {
		final meta: Null<QueryNode> = bypassMeta(node);
		if (meta != null) {
			final metaSpan: Null<Span> = meta.span;
			final wrapped: Null<QueryNode> = node.children.find(c -> !RefactorSupport.META_KINDS.contains(c.kind));
			final wrapSpan: Null<Span> = wrapped == null ? null : wrapped.span;
			if (metaSpan != null && wrapSpan != null && flagged.contains('${metaSpan.from}:${metaSpan.to}'))
				edits.push({ span: new Span(metaSpan.from, wrapSpan.from), text: '' });
		}
		for (child in node.children) collectEdits(child, flagged, edits);
	}

	/** The `@:bypassAccessor` META child of `node`, or null. */
	private static function bypassMeta(node: QueryNode): Null<QueryNode> {
		return node.children.find(c -> RefactorSupport.META_KINDS.contains(c.kind) && c.name == BYPASS_META);
	}

	/** Descend `node` through nested metadata wrappers to the plain assignment it wraps, or null. */
	private static function unwrapToAssign(node: QueryNode, assignKind: String): Null<QueryNode> {
		if (node.kind == assignKind) return node;
		if (!node.children.exists(c -> RefactorSupport.META_KINDS.contains(c.kind))) return null;
		final inner: Null<QueryNode> = node.children.find(c -> !RefactorSupport.META_KINDS.contains(c.kind));
		return inner == null ? null : unwrapToAssign(inner, assignKind);
	}

	/**
	 * The member name written by `assign` - its first child is either a bare
	 * identifier (`identKind`) or a `this.field` (`fieldAccessKind` whose sole child
	 * is the self identifier). Any other lvalue (index access, other receiver) is null.
	 */
	private static function lvalueName(assign: QueryNode, ctx: Ctx): Null<String> {
		if (assign.children.length < 1) return null;
		final lhs: QueryNode = assign.children[0];
		return lhs.kind == ctx.identKind
			? lhs.name
			: ctx.fieldAccessKind != null && ctx.self != null && lhs.kind == ctx.fieldAccessKind && lhs.children.length == 1
				&& lhs.children[0].kind == ctx.identKind && lhs.children[0].name == ctx.self
				? lhs.name
				: null;
	}

	/**
	 * Whether `name` is a directly-declared member of the innermost enclosing type
	 * (the smallest `TypeDeclInfo` whose span contains `assign`) that has no
	 * set-accessor. A name not found as an own member is false (unresolved, a local,
	 * inherited, or cross-class - left alone).
	 */
	private static function hasNoSetter(name: String, assign: QueryNode, info: FileInfo): Bool {
		final span: Null<Span> = assign.span;
		if (span == null) return false;
		var best: Null<TypeDeclInfo> = null;
		for (type in info.types) if (
			type.span.from <= span.from && span.to <= type.span.to
			&& (best == null || type.span.to - type.span.from < best.span.to - best.span.from)
		)
			best = type;
		if (best == null) return false;
		final member: Null<MemberInfo> = best.members.find(m -> m.name == name);
		return member != null && !member.hasSetter;
	}

}

private typedef Ctx = {
	assignKind: String,
	identKind: String,
	fieldAccessKind: Null<String>,
	self: Null<String>
};
