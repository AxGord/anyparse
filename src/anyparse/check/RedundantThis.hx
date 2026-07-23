package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import anyparse.query.RefactorSupport;

/**
 * Flags a redundant `this.` qualifier — a `this.field` access where no local,
 * parameter, loop / catch variable or local function in the enclosing member
 * shadows `field`, so `this.` adds nothing and the access reduces to bare
 * `field`. `Info` severity (a cosmetic cleanup); `fix` drops the `this.`.
 *
 * A `this.field` is kept (not flagged) when a same-named binding is in scope —
 * the canonical `this.x = x` constructor pattern, where the parameter `x`
 * shadows the field and `this.` is load-bearing.
 *
 * A `this.name` is also kept unless `name` is provably a member (field / method /
 * property) of the enclosing type or an in-scope ancestor. A name that is not a
 * local member may be a `using` static-extension call (`this.getClass()` under
 * `using Type` resolves via static extension — the bare name is not a member,
 * and dropping `this.` yields an `Unknown identifier`) or a member inherited
 * from a base OUTSIDE the linted file set. Either way `this.` may be
 * required, so the check stays silent — the membership check is the primary gate
 * against stripping a load-bearing qualifier.
 *
 * ## Grammar-agnostic
 *
 * The self-qualifier text comes from `RefShape.selfReferenceText` (`this` /
 * `self`; unset → no-op), the access node from `fieldAccessKind`, the receiver
 * ident from `identKind`. Shadowing names are collected from `paramKinds`,
 * `localDeclKinds`, `selfScopeDeclKinds` (loop iterator / catch var) and
 * `localFunctionKinds`, scoped to each enclosing member function. Member names
 * come from `memberDeclKinds` hosts inside a `visibilityContainerKinds` type; a
 * grammar supplying neither leaves the membership gate inert (shadow-only test).
 * A compile-time abstract's `this.field` (where `this` is the underlying value
 * and `this.` is mandatory) carries no `identKind` receiver child, so it is
 * never matched.
 */
@:nullSafety(Strict)
final class RedundantThis implements Check {

	public function new() {}

	public function id(): String {
		return 'redundant-this';
	}

	public function description(): String {
		return 'a this.field access whose this. qualifier is redundant';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final ctx: Null<Ctx> = context(plugin);
		if (ctx == null) return [];
		final violations: Array<Violation> = [];
		// The inheritance index is consulted only by a `this.name` that misses the same-file
		// member scan (an inherited base member or a `using` extension) — rare — so it is built
		// at most once per run, on first demand, via the shared lazy builder. When the plugin
		// carries a resolution scope, that builder resolves supertypes against library roots too.
		final resolveSymbols: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin);
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walkMembers(violations, entry.file, tree, ctx, null, [], resolveSymbols);
		}
		return violations;
	}

	/** Drop the `this.` qualifier of each flagged access, leaving the bare field name. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final ctx: Null<Ctx> = context(plugin);
		return ctx == null
			? []
			: CheckScan.applyBySpan(plugin, source, violations, [ctx.fieldAccessKind], (node, span) -> {
				if (!isThisAccess(node, ctx)) return null;
				final fieldName: Null<String> = node.name;
				return fieldName == null ? null : { span: span, text: fieldName };
			});
	}

	/** Bundle the seams the check needs, or null when the grammar lacks any. */
	private static function context(plugin: GrammarPlugin): Null<Ctx> {
		final shape: RefShape = plugin.refShape();
		final self: Null<String> = shape.selfReferenceText;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final identKind: Null<String> = shape.identKind;
		final functionKinds: Array<String> = shape.functionKinds ?? [];
		if (self == null || fieldAccessKind == null || identKind == null || functionKinds.length == 0) return null;
		final bindingKinds: Array<String> = (shape.paramKinds ?? []).concat(shape.localDeclKinds ?? [])
			.concat(shape.selfScopeDeclKinds ?? [])
			.concat(shape.localFunctionKinds ?? []);
		return {
			self: self,
			fieldAccessKind: fieldAccessKind,
			identKind: identKind,
			functionKinds: functionKinds,
			bindingKinds: bindingKinds,
			underlyingThisKinds: shape.underlyingThisTypeKinds ?? [],
			containerKinds: shape.visibilityContainerKinds ?? [],
			memberDeclKinds: shape.memberDeclKinds ?? [],
			// Membership gate active only when the grammar names both the type
			// containers and their member hosts — else the check falls back to
			// the legacy shadow-only test (no member set to enforce against).
			membershipGate: (shape.visibilityContainerKinds ?? []).length > 0 && (shape.memberDeclKinds ?? []).length > 0
		};
	}

	/**
	 * Descend to each OUTERMOST member function, then flag its redundant `this.`
	 * accesses against the names bound anywhere in its subtree — a name bound in
	 * any branch or nested function is treated as a possible shadow (conservative,
	 * never removes a load-bearing `this.`). On reaching a function the whole
	 * subtree is handled here, so nested functions are not visited again. A
	 * compile-time abstract (where `this` is the underlying value and `this.` is
	 * mandatory) is skipped entirely.
	 *
	 * `members` is the set of field / method / property names declared by the
	 * enclosing type, `typeName` its name (for the inheritance lookup). Entering a
	 * type-declaration container collects a fresh set from THAT container and
	 * threads it, with the container's own name, down. A `this.name` is flagged
	 * when `name` is one of those same-file members, or — when it is not — when an
	 * ancestor reachable through the `extends` / `implements` chain declares it
	 * (resolved through the run's lazily-built `SymbolIndex`, `symbols`). A name
	 * neither declared here nor by any in-scope ancestor is ambiguous — a `using`
	 * static-extension call (`this.getClass()` via `using Type`, where `this.` is
	 * load-bearing) or a member inherited from a base OUTSIDE the file set — so the
	 * check stays silent rather than remove a possibly-required `this.`.
	 */
	private static function walkMembers(
		out: Array<Violation>, file: String, node: QueryNode, c: Ctx, typeName: Null<String>, members: Array<String>,
		symbols: () -> Null<SymbolIndex>
	): Void {
		if (c.underlyingThisKinds.contains(node.kind)) return;
		if (c.containerKinds.contains(node.kind)) {
			final ownMembers: Array<String> = [];
			collectMemberNames(node, c, ownMembers);
			for (child in node.children) walkMembers(out, file, child, c, node.name, ownMembers, symbols);
			return;
		}
		if (c.functionKinds.contains(node.kind)) {
			final names: Array<String> = [];
			collectBindingNames(node, c, names);
			flagThisAccess(out, file, node, c, names, typeName, members, symbols);
			return;
		}
		for (child in node.children) walkMembers(out, file, child, c, typeName, members, symbols);
	}

	/**
	 * Collect the enclosing type's own member names — direct member-host children
	 * plus those wrapped in `#if … #end` conditional or modifier nodes. A member
	 * host is a leaf for this walk (its subtree is the member's body, holding
	 * locals, not more members); a nested type container is not descended into, so
	 * its members do not leak into the outer type's set.
	 */
	private static function collectMemberNames(node: QueryNode, c: Ctx, out: Array<String>): Void {
		for (child in node.children) if (!c.containerKinds.contains(child.kind)) {
			if (c.memberDeclKinds.contains(child.kind)) {
				final name: Null<String> = child.name;
				if (name != null) out.push(name);
			} else
				collectMemberNames(child, c, out);
		}
	}

	/** Collect every shadowing binding name in `node`'s subtree. */
	private static function collectBindingNames(node: QueryNode, c: Ctx, names: Array<String>): Void {
		if (c.bindingKinds.contains(node.kind)) {
			final name: Null<String> = node.name;
			if (name != null) names.push(name);
		}
		for (child in node.children) collectBindingNames(child, c, names);
	}

	/**
	 * Flag each `this.field` in `node`'s subtree whose field name is not shadowed
	 * by a local AND is a declared member of the enclosing type. When the grammar
	 * supplies no type-container / member seams the membership gate is inert
	 * (`members` is empty and unenforceable), so the check falls back to the
	 * shadow-only test.
	 */
	private static function flagThisAccess(
		out: Array<Violation>, file: String, node: QueryNode, c: Ctx, names: Array<String>, typeName: Null<String>, members: Array<String>,
		symbols: () -> Null<SymbolIndex>
	): Void {
		if (isThisAccess(node, c)) {
			final fieldName: Null<String> = node.name;
			final span: Null<Span> = node.span;
			if (
				fieldName != null && span != null && !names.contains(fieldName) && isMember(c, file, fieldName, typeName, members, symbols)
			) out.push({
				file: file,
				span: span,
				rule: 'redundant-this',
				severity: Severity.Info,
				message: 'redundant this. qualifier — reduces to $fieldName'
			});
		}
		for (child in node.children) flagThisAccess(out, file, child, c, names, typeName, members, symbols);
	}

	/**
	 * Whether `name` is provably a member of the enclosing type. When the grammar
	 * supplies no type-container / member seams the membership gate is inert, so
	 * the check falls back to the shadow-only test (`true`). Otherwise `name` must
	 * be a member declared by the enclosing type in THIS file (the same-file fast
	 * path) or — when that misses — proven inherited by `SymbolIndex.inheritsMemberUnambiguously`
	 * (built lazily, at most once), which pins the enclosing type to its `(file, name)`
	 * declaration and resolves each supertype link import / qualified-path aware. The
	 * proof is POSITIVE and UNAMBIGUOUS: it holds only when a UNIQUELY-resolved ancestor
	 * declares `name`. Every case that is not that proof yields `false` — an ancestor
	 * outside the file set (e.g. `openfl.display.Sprite` when only the project is linted),
	 * a supertype whose simple name merely collides with an unrelated in-set type, an
	 * ambiguous enclosing / supertype resolution, or a `using` static-extension name — so
	 * the check stays silent rather than strip a possibly load-bearing `this.`.
	 */
	private static function isMember(
		c: Ctx, file: String, name: String, typeName: Null<String>, members: Array<String>, symbols: () -> Null<SymbolIndex>
	): Bool {
		if (!c.membershipGate) return true;
		if (members.contains(name)) return true;
		if (typeName == null) return false;
		final index: Null<SymbolIndex> = symbols();
		return index != null && index.inheritsMemberUnambiguously(file, typeName, name);
	}


	/** `this.field`: a field-access node whose sole child is the self-reference ident. */
	private static function isThisAccess(node: QueryNode, c: Ctx): Bool {
		if (node.kind != c.fieldAccessKind || node.children.length != 1) return false;
		final receiver: QueryNode = node.children[0];
		return receiver.kind == c.identKind && receiver.name == c.self;
	}

}

private typedef Ctx = {
	self: String,
	fieldAccessKind: String,
	identKind: String,
	functionKinds: Array<String>,
	bindingKinds: Array<String>,
	underlyingThisKinds: Array<String>,
	containerKinds: Array<String>,
	memberDeclKinds: Array<String>,
	membershipGate: Bool
};
