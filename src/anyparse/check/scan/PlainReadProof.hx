package anyparse.check.scan;

import anyparse.query.MemberKinds;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;

/** The `RefShape` kinds the plain-read proof reads. */
typedef PlainReadSeams = {

	final fieldAccessKind: String;
	final selfText: Null<String>;
	final opaqueKinds: Array<String>;
	final localDeclKinds: Array<String>;
	final paramKinds: Array<String>;
	final scopeKinds: Array<String>;

	/**
	 * The member kinds that project a PHYSICAL field: the field-root
	 * proof's whitelist, empty when the grammar names no extern modifier.
	 */
	final fieldDeclKinds: Array<String>;

	/** The extern-modifier node kind, a preceding sibling of the type it marks: an extern host refuses the field-root proof. */
	final externKind: Null<String>;

};

/** One type declaration's lexical extent: the span it covers, the node hosting its members, and whether `extern` marks it. */
typedef TypeScope = { var span: Span; var host: QueryNode; var isExtern: Bool; }

/**
 * The one answer to "is a second read of this value unobservable": a rewrite that turns one read of a value into
 * two (or two into one) asks it, so a property getter is never run a different number of times. Proven only for
 * the self reference, a bound local or parameter, an own physical field of a non-extern type, and a `.field`
 * chain over one of those whose every step the resolution index proves a plain member. Everything else refuses.
 */
@:nullSafety(Strict)
final class PlainReadProof {

	/** The proof's seams, or null for a grammar with no field-access kind. */
	public static function seamsOf(shape: RefShape): Null<PlainReadSeams> {
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		return fieldAccessKind == null ? null : {
			fieldAccessKind: fieldAccessKind,
			selfText: shape.selfReferenceText,
			opaqueKinds: shape.opaqueKinds ?? [],
			localDeclKinds: shape.localDeclKinds ?? [],
			paramKinds: shape.paramKinds ?? [],
			scopeKinds: shape.scopeKinds,
			// The extern gate is what keeps a foreign slot's read out of the field proof, so a
			// grammar that cannot name its extern modifier gets no field roots at all.
			fieldDeclKinds: shape.externModifierKind == null ? [] : shape.fieldDeclKinds ?? [],
			externKind: shape.externModifierKind
		};
	}

	/**
	 * The proof over one parsed file: whether a second read of the node it is given is unobservable. `index` is asked
	 * only for a `.field` step; a grammar without the seams proves nothing.
	 */
	public static function prover(
		tree: QueryNode, source: String, plugin: GrammarPlugin, index: () -> Null<SymbolIndex>
	): QueryNode -> Bool {
		final shape: RefShape = plugin.refShape();
		final seams: Null<PlainReadSeams> = seamsOf(shape);
		if (seams == null) return _ -> false;
		final s: PlainReadSeams = seams;
		final bindings: Array<{ name: String, scope: Span, declEnd: Int }> = [];
		collectBindings(tree, null, s, bindings);
		final declaredTypes: () -> Map<Int, String> = TypeResolver.memoizedDeclaredTypeSources(plugin, source);
		final plainRead: QueryNode -> Bool = subject -> {
			final resolved: Null<SymbolIndex> = index();
			return resolved != null && TypeResolver.isPlainFieldRead(subject, tree, shape, declaredTypes(), resolved);
		};
		final fieldOk: (String, Span) -> Bool = fieldProver(tree, source, plugin, s);
		return subject -> acceptedReceiver(subject, bindings, fieldOk, plainRead, s);
	}

	/**
	 * Whether `subject` is a receiver whose double read is provably free: the self reference
	 * (a keyword, never an accessor), a local / param binding whose scope encloses it and
	 * that lexically precedes it, or a field `fieldOk` proves physical.
	 *
	 * A one-step `<root>.<field>` path reads BOTH parts twice, so it needs both proofs: `root`
	 * accepted on its own terms, and `plainRead` — the resolution index proving the step itself
	 * resolves to a physical member rather than a property whose read runs a getter.
	 */
	private static function acceptedReceiver(
		subject: QueryNode, bindings: Array<{ name: String, scope: Span, declEnd: Int }>, fieldOk: (String, Span) -> Bool,
		plainRead: QueryNode -> Bool, s: PlainReadSeams
	): Bool {
		if (subject.kind == s.fieldAccessKind)
			return acceptedReceiver(subject.children[0], bindings, fieldOk, plainRead, s) && plainRead(subject);
		final name: Null<String> = subject.name;
		final span: Null<Span> = subject.span;
		if (name == null || span == null) return false;
		if (name == s.selfText) return true;
		final useName: String = name;
		final useSpan: Span = span;
		final bound: Bool = bindings.exists(
			b -> b.name == useName && b.scope.from <= useSpan.from && useSpan.to <= b.scope.to && b.declEnd <= useSpan.from
		);
		return bound || fieldOk(useName, useSpan);
	}

	/**
	 * The per-file predicate deciding whether a NON-local receiver named `name` at `span` is a
	 * field whose double read is a provable no-op: it must be a PHYSICAL `var` / `final`
	 * (`fieldDeclKinds`) with no read accessor, declared directly by the type declaration that
	 * lexically encloses the use.
	 *
	 * A Haxe field cannot be redeclared by a subtype, and property accessors resolve from the
	 * STATIC type — so a plain field stays plain at every use of the declaring type. That, and only
	 * that, is what makes `if (f != null) f.m()` (two reads) and `f?.m()` (one) the same
	 * observation. Everything unproven refuses: a get-accessor property (`(get, …)` / `dynamic`,
	 * whose read RUNS code), a member of any other kind (a method value), a name the enclosing type
	 * does not itself declare (an inherited member, a static import, an out-of-scope local — none of
	 * which this proof can see), an EXTERN host (a foreign slot whose read may run host code), and a
	 * grammar with no accessor information at all (`TypeInfoProvider` absent — every property would
	 * then read as plain) or no extern modifier to name (`readSeams` empties `fieldDeclKinds`).
	 *
	 * Coverage is deliberately the enclosing type's OWN members. A resolution index that can prove
	 * the same facts about an INHERITED member widens this predicate without changing any caller —
	 * but the extern gate MUST move with it: `collectTypeScopes` reads only this file, so an
	 * inherited field whose declaring type is an `extern` class in another module would pass a gate
	 * that never saw it.
	 */
	private static function fieldProver(tree: QueryNode, source: String, plugin: GrammarPlugin, s: PlainReadSeams): (String, Span) -> Bool {
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		if (provider == null || s.fieldDeclKinds.length == 0) return (_, _) -> false;
		final accessors: Map<Int, Bool> = provider.propertyAccessors(source);
		final scopes: Array<TypeScope> = [];
		collectTypeScopes(tree, false, s, scopes);
		return (name, span) -> {
			final host: Null<TypeScope> = innermostScope(scopes, span);
			return host != null && !host.isExtern && declaresPlainField(host.host, name, accessors, s);
		};
	}

	/** The innermost type declaration whose span contains `span`, or null when `span` sits outside every type. */
	private static function innermostScope(scopes: Array<TypeScope>, span: Span): Null<TypeScope> {
		var best: Null<TypeScope> = null;
		for (t in scopes) if (t.span.from <= span.from && span.to <= t.span.to && (best == null || t.span.from >= best.span.from)) best = t;
		return best;
	}

	/**
	 * Every type declaration under `node`, with the span it occupies and whether an extern
	 * modifier precedes it. `pendingExtern` carries an `extern` keyword forward across the
	 * modifier / metadata siblings that may sit between it and the declaration it marks — and
	 * into nested regions, since over-attaching it only ever REFUSES more.
	 */
	private static function collectTypeScopes(node: QueryNode, pendingExtern: Bool, s: PlainReadSeams, out: Array<TypeScope>): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		var marked: Bool = pendingExtern;
		for (child in node.children) {
			if (child.kind == s.externKind) {
				marked = true;
				continue;
			}
			final decl: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(child);
			if (decl != null) {
				out.push({ span: decl.fullSpan, host: decl.nameNode, isExtern: marked });
				marked = false;
			}
			collectTypeScopes(child, marked, s, out);
		}
	}

	/**
	 * Whether `host` declares `name` as a physical field with no read accessor. A member of that
	 * name whose kind is not a field kind, or that carries a getter, REFUSES outright rather than
	 * being ignored — two same-named members cannot both be the receiver, so a single unproven
	 * declaration is enough to lose the proof.
	 */
	private static function declaresPlainField(host: QueryNode, name: String, accessors: Map<Int, Bool>, s: PlainReadSeams): Bool {
		var proven: Bool = false;
		var refused: Bool = false;
		MemberKinds.eachMemberHost(host, memberHost -> {
			for (child in memberHost.children) if (child.name == name && MemberKinds.isMemberDeclNode(child)) {
				final span: Null<Span> = child.span;
				if (span == null || !s.fieldDeclKinds.contains(child.kind) || accessors[span.from] == true)
					refused = true;
				else
					proven = true;
			}
		});
		return proven && !refused;
	}

	/**
	 * Walk `node`, tracking the innermost enclosing scope, recording every local
	 * declaration (`localDeclKinds`) and parameter (`paramKinds`) with the span of
	 * its enclosing scope. A reification subtree (`opaqueKinds`) is skipped wholesale.
	 */
	private static function collectBindings(
		node: QueryNode, enclosingScope: Null<QueryNode>, s: PlainReadSeams, out: Array<{ name: String, scope: Span, declEnd: Int }>
	): Void {
		if (s.opaqueKinds.contains(node.kind)) return;
		if (s.localDeclKinds.contains(node.kind) || s.paramKinds.contains(node.kind)) {
			final name: Null<String> = node.name;
			final declSpan: Null<Span> = node.span;
			final scope: Null<Span> = enclosingScope?.span;
			if (name != null && declSpan != null && scope != null) out.push({ name: name, scope: scope, declEnd: declSpan.to });
		}
		final childScope: Null<QueryNode> = s.scopeKinds.contains(node.kind) ? node : enclosingScope;
		for (c in node.children) collectBindings(c, childScope, s, out);
	}

}
