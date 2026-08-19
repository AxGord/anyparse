package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Nominal-type resolution over written type SOURCES and the query tree: what type does
 * this expression, this receiver path or this loop binder carry, and what bare type name
 * does that written source reduce to.
 *
 * Extracted from `RefactorSupport` as one connected call cluster (`hxq clusters`): nothing
 * left behind calls in, and the only call out is `RefactorSupport.isIdentifier`. Every
 * member is a pure static — the tree, the `declaredTypes` map, the `SymbolIndex` and the
 * reading file all arrive as arguments — so there is no shared state and no thread-safety
 * question to answer.
 *
 * Three layers, outside in:
 *
 * - **Reducing a written type source.** `outerNominalOf` strips the type arguments and the
 *   package prefix off a source (`pkg.Map<String, Int>` → `Map`); `splitTypeArgumentList`
 *   and `typeArgumentSourcesOf` take the argument list apart on its top-level commas;
 *   `shadowedByNonStdType` says whether an indexed non-std file claims a name that would
 *   otherwise read as the stdlib type.
 * - **Walking a receiver path.** `pathOf` flattens a plain field chain into its segments,
 *   `pathRootTypeName` types the root off `declaredTypes`, and `pathFinalMemberTypeSource`
 *   / `pathReceiverMemberTypeSource` follow the segments through the `SymbolIndex` to the
 *   member type at the end.
 * - **Typing a value or an expression.** `valueTypeNominal` and `expressionTypeNominal` are
 *   the entry points the analysis checks call. The private deep walk below them keeps the
 *   answer at SOURCE level (type arguments intact, for substitution) and adds the arms a
 *   plain path has not got: a method call resolved through `SymbolIndex.returnNominalOf` or, when
 *   the receiver provably lacks the member, through a `using` STATIC EXTENSION
 *   (`staticExtensionNominal`); a tabled `Type.method` static call; and the loop binder whose
 *   type is the ELEMENT type of what it iterates (`iterationValueBinder` / `iterationIterable` /
 *   `forBindingElementTypeSource`).
 *
 * Every resolution entry point answers null for "unknown" rather than guessing, so a consumer that
 * needs a proof reads null as a refusal and keeps its conservative branch.
 */
@:nullSafety(Strict)
final class NominalTypes {

	/** Whether `loop` carries a key-value VALUE binder — i.e. it binds a key AND a value. */
	public static inline function hasIterationValueBinder(loop: QueryNode, valueBinderKinds: Array<String>): Bool {
		return iterationValueBinder(loop, valueBinderKinds) != null;
	}

	/**
	 * The dotted segments of a PATH expression — a root identifier (or a self reference)
	 * followed by plain field accesses, so `session.files` yields `['session', 'files']` — or
	 * null when `node` is anything else. Only `fieldKind` links over an `identKind` root are
	 * accepted: a call, an index access or a null-safe `?.` link anywhere in the chain projects
	 * as a different kind and yields null, keeping every segment a plain field read with no side
	 * effect of its own. Shared by the `map-keys-lookup` and `prefer-index-access` type gates.
	 */
	public static function pathOf(node: QueryNode, identKind: String, fieldKind: String): Null<Array<String>> {
		final name: Null<String> = node.name;
		if (name == null) return null;
		if (node.kind == identKind) return [name];
		if (node.kind != fieldKind || node.children.length != 1) return null;
		final base: Null<Array<String>> = pathOf(node.children[0], identKind, fieldKind);
		if (base == null) return null;
		base.push(name);
		return base;
	}

	/**
	 * A written type source reduced to the type a MEMBER LOOKUP on it resolves against: every
	 * leading member-TRANSPARENT wrapper application peeled off, to a fixed point, so
	 * `Null<String>` answers `String` and `Null<Null<Box<Item>>>` answers `Box<Item>`. Anything
	 * that is not such an application comes back unchanged, and an empty `wrappers` disables the
	 * peel entirely — which is what every caller that has not thought about it passes.
	 *
	 * `wrappers` is `RefShape.memberTransparentWrapperTypeNames`, whose doc carries the rule: a
	 * wrapper belongs there only when its member set IS its argument's (Haxe's `@:forward`
	 * `Null<T>`), and the answer may be used ONLY to decide which member a name resolves to. It is
	 * NOT the value's type: `Null<Int>` still is not an `Int` for an arithmetic or ordered comparison. `null` is not a
	 * value `<` orders, and what the raw comparison DOES with it is TARGET-SPECIFIC — measured on Haxe 4.3.7, `null >
	 * 0` is `false` on js and `true` on `-cpp`. That the wrap and the flip happen to agree for a null `Null<Int>` on
	 * js, `-cpp` and `--interp` alike settles nothing: the same probe has a null `String` operand DISAGREEING on js
	 * and `--interp` while AGREEING on `-cpp`.
	 *
	 * The peel is TEXTUAL over the written annotation, so a typedef that RESOLVES to `Null<T>`
	 * carries no wrapper to peel and is left alone — following the alias would mean resolving a
	 * type reference here, and the miss fails closed like every other unresolved link.
	 */
	public static function memberLookupReceiverSource(typeSource: String, wrappers: Array<String>): String {
		if (wrappers.length == 0) return typeSource;
		var t: String = typeSource.trim();
		while (true) {
			final lt: Int = t.indexOf('<');
			if (lt <= 0 || !t.endsWith('>') || !wrappers.contains(t.substring(0, lt).trim())) return t;
			final inner: String = t.substring(lt + 1, t.length - 1).trim();
			// A multi-argument application is not a wrapper of ONE type; peeling it would hand a
			// comma-joined fragment on as if it were a type name.
			if (splitTypeArgumentList(inner).length != 1) return t;
			t = inner;
		}
	}

	/** The simple outer nominal of a written type — `pkg.Map<String, Int>` → `Map` — or null when the text is not a nominal at all. */
	public static function outerNominalOf(typeSource: String): Null<String> {
		final lt: Int = typeSource.indexOf('<');
		final head: String = StringTools.trim(lt < 0 ? typeSource : typeSource.substring(0, lt));
		final dot: Int = head.lastIndexOf('.');
		final name: String = dot < 0 ? head : head.substring(dot + 1);
		return RefactorSupport.isIdentifier(name) ? name : null;
	}

	/**
	 * Split a type-argument list on its TOP-LEVEL commas, respecting EVERY delimiter a written
	 * Haxe type may nest a comma inside — `<…>` arguments, `(…)` multi-constraints, `{…}`
	 * structures, `[…]` — and the `->` arrow whose `>` is not a bracket closer. So
	 * `Map<String, (Int, Int) -> Void>` is two segments, `<T:(A, B)>` is ONE parameter, and
	 * `<T:{a:Int, b:Int}>` is one too.
	 *
	 * Each of those four groups is load-bearing for a caller, not defensive: the index-access
	 * element lookup (`FieldWriteIndex.elementTypeSource`), the declaration-header type-parameter
	 * scan (`SymbolIndexBuilder.declTypeParamNames`, whose result is a POSITIONAL substitution
	 * table — a phantom segment there shifts every parameter after it) and `typeArgumentSourcesOf`
	 * all route through this one function. Brace-blindness read `<T:{a:Int, b:Int}>` as the two
	 * parameters `T` and `b`; the structural constraint is ordinary Haxe.
	 *
	 * The scan is delimiter-only, so a comma inside a string literal in metadata still splits. No
	 * caller feeds it metadata (`SymbolIndexBuilder` strips a parameter's metadata run AFTER this
	 * split), and the failure direction there is a segment that yields no plain identifier, which
	 * refuses the whole header.
	 */
	public static function splitTypeArgumentList(text: String): Array<String> {
		final out: Array<String> = [];
		var depth: Int = 0;
		var start: Int = 0;
		var prev: Int = 0;
		for (i in 0...text.length) {
			final ch: Int = text.fastCodeAt(i);
			if (ch == '<'.code || ch == '('.code || ch == '{'.code || ch == '['.code)
				depth++;
			else if (ch == ')'.code || ch == '}'.code || ch == ']'.code)
				depth--;
			else if (ch == '>'.code && prev != '-'.code)
				depth--;
			else if (ch == ','.code && depth == 0) {
				out.push(text.substring(start, i).trim());
				start = i + 1;
			}
			prev = ch;
		}
		out.push(text.substring(start).trim());
		return out;
	}

	/**
	 * The verbatim type-ARGUMENT sources of a generic application (`Map<String, Array<Int>>` →
	 * `['String', 'Array<Int>']`), or null when `typeSource` is not `Head<…>`.
	 *
	 * Two gates keep the answer honest, both failing closed: the head before the first `<` must be
	 * a plain nominal (`outerNominalOf` answers it), and the `>` that closes that `<` must be the
	 * LAST character. Together they refuse a function type whose RESULT is generic
	 * (`(Int) -> Array<Int>`), which a naive first-`<`/last-`>` slice would mis-read as an
	 * application of `(Int) -> Array` carrying the argument `Int`.
	 */
	public static function typeArgumentSourcesOf(typeSource: String): Null<Array<String>> {
		final t: String = typeSource.trim();
		final lt: Int = t.indexOf('<');
		if (lt <= 0 || outerNominalOf(t) == null) return null;
		var depth: Int = 0;
		var prev: Int = 0;
		for (i in lt ... t.length) {
			final ch: Int = t.fastCodeAt(i);
			if (ch == '<'.code)
				depth++;
			else if (ch == '>'.code && prev != '-'.code) {
				depth--;
				if (depth == 0) return i == t.length - 1 ? splitTypeArgumentList(t.substring(lt + 1, i)) : null;
			}
			prev = ch;
		}
		return null;
	}

	/**
	 * The declared type nominal of a receiver path's ROOT — the enclosing type declaration for
	 * the self reference, else the root identifier's binding annotation from `declaredTypes` — or
	 * null when the root cannot be resolved. Shared by the map-abstract / keys()-type gates. A
	 * root that is a static TYPE name (no value binding) is resolved separately, import-aware,
	 * by `staticRootPathTypeSource`.
	 */
	public static function pathRootTypeName(
		recv: QueryNode, root: QueryNode, declaredTypes: Map<Int, String>, shape: RefShape
	): Null<String> {
		final resolved: Null<PathRoot> = pathRootBinding(recv, root, shape);
		if (resolved == null) return null;
		final bindingFrom: Null<Int> = resolved.bindingFrom;
		return bindingFrom == null ? resolved.selfTypeName : declaredTypes[bindingFrom];
	}

	/**
	 * The verbatim declared-type SOURCE of the FINAL segment of a multi-segment path receiver
	 * (`path.length >= 2`), resolved through `index`: the `rootType` nominal seeds the walk, each
	 * intermediate field segment resolves to its outer nominal via `memberTypeSourceOf`, and the
	 * last segment returns its raw type source — null when any link is unresolvable. A consumer
	 * that wants the final NOMINAL wraps this in `outerNominalOf`.
	 */
	public static function pathFinalMemberTypeSource(
		path: Array<String>, rootType: String, index: SymbolIndex, ?transparentWrappers: Array<String>
	): Null<String> {
		final wrappers: Array<String> = transparentWrappers ?? [];
		var current: String = rootType;
		for (i in 1...path.length - 1) {
			final memberType: Null<String> = index.memberTypeSourceOf(current, path[i]);
			final nominal: Null<String> = memberType == null ? null : outerNominalOf(memberLookupReceiverSource(memberType, wrappers));
			if (nominal == null) return null;
			current = nominal;
		}
		return index.memberTypeSourceOf(current, path[path.length - 1]);
	}

	/**
	 * The verbatim declared type SOURCE of a receiver path's final member, for a value / `this` /
	 * static-TYPE-name root. Resolves PACKAGE-SAFE FIRST via the import- and inheritance-aware
	 * `SymbolIndex.resolvePathFinalMemberTypeSource` (so an import-correct intermediate type's
	 * INHERITED member is read off THAT exact type, never a same-simple-named type in another
	 * package — the cross-package poisoning that made the package-blind walk emit `[]` on a
	 * non-Map). Only when the import-aware walk cannot follow the chain — an aliased conditional
	 * supertype the index does not model (openfl's `Application` inherits `meta` from lime's via
	 * `import … as LimeApplication`) — does it FALL BACK to the package-blind simple-name walk: a
	 * value / `this` root walks the whole path by simple name; a static TYPE root still resolves
	 * its FIRST member import-aware (dodging a same-named root's `#if`-typed member) before the
	 * simple-name tail. `rootType` is the value / `this` root's type name, or null for a static
	 * TYPE root (then `path[0]` is the type). Null when unresolved / ambiguous (fails closed).
	 *
	 * `substituteTypeArgs` opts the import-aware walk into TYPE-ARGUMENT SUBSTITUTION
	 * (`SymbolIndex.resolveGenericPathFinalMemberTypeSource`): `rootType` may then carry written
	 * arguments (`Box<Item>`), and a member declared as one of its type's parameters resolves to
	 * the matching argument instead of the verbatim parameter name. Default false, so every
	 * existing caller keeps today's answer byte for byte.
	 */
	public static function pathReceiverMemberTypeSource(
		path: Array<String>, rootType: Null<String>, index: SymbolIndex, fromFile: String, substituteTypeArgs: Bool = false,
		?transparentWrappers: Array<String>
	): Null<String> {
		if (path.length < 2) return null;
		final wrappers: Array<String> = transparentWrappers ?? [];
		// The path root is a RECEIVER here, never the answer, so a member-transparent wrapper on it
		// is peeled: `Null<Res>.count` IS `Res.count`. The FINAL member's own source is returned
		// untouched below, so a `Null<T>`-typed member still reads as `Null<T>`.
		final startType: String = memberLookupReceiverSource(rootType ?? path[0], wrappers);
		final resolved: Null<String> = substituteTypeArgs
			? index.resolveGenericPathFinalMemberTypeSource(fromFile, startType, path.slice(1), wrappers)
			: index.resolvePathFinalMemberTypeSource(fromFile, startType, path.slice(1));
		if (resolved != null) return resolved;
		// The package-blind fallback never substitutes; in substitute mode it is only fed the
		// root's NOMINAL, since a `Box<Item>` start source is not a name any member lookup matches.
		if (rootType != null)
			return pathFinalMemberTypeSource(
				path, substituteTypeArgs ? outerNominalOf(startType) ?? startType : startType, index, wrappers
			);
		final firstSource: Null<String> = index.resolvePathFinalMemberTypeSource(fromFile, path[0], [path[1]]);
		if (firstSource == null) return null;
		if (path.length == 2) return firstSource;
		final firstNominal: Null<String> = outerNominalOf(memberLookupReceiverSource(firstSource, wrappers));
		return firstNominal == null ? null : pathFinalMemberTypeSource(path.slice(1), firstNominal, index, wrappers);
	}

	/**
	 * The simple nominal of the type a VALUE expression carries — a bare identifier resolved
	 * through its binding annotation, a `recv.field` path walked by `pathReceiverMemberTypeSource`
	 * — or null when the expression is not a plain identifier / field path, or any link in it is
	 * unresolved. A read-only probe for an analysis gate that must know an operand's type before
	 * it may rewrite: null means "unknown", so a caller keeps its conservative branch.
	 */
	public static function valueTypeNominal(
		node: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, index: Null<SymbolIndex>, file: String
	): Null<String> {
		final identKind: Null<String> = shape.identKind;
		final fieldKind: Null<String> = shape.fieldAccessKind;
		if (identKind == null || fieldKind == null) return null;
		final path: Null<Array<String>> = pathOf(node, identKind, fieldKind);
		if (path == null) return null;
		final rootType: Null<String> = pathRootTypeName(node, root, declaredTypes, shape);
		if (path.length == 1) return rootType;
		if (index == null) return null;
		final typeSource: Null<String> = pathReceiverMemberTypeSource(path, rootType, index, file);
		return typeSource == null ? null : outerNominalOf(typeSource);
	}

	/**
	 * The simple nominal of the type ANY expression carries: `valueTypeNominal`'s identifier /
	 * field-path answer, plus the METHOD-CALL tail it stops at — `<chain>.method(…)` resolves the
	 * receiver's own nominal (recursively, so `a.b.c().d()` walks) and reads the method's return
	 * nominal off it through `SymbolIndex.returnNominalOf`. Null stays "unknown", so every caller
	 * keeps its conservative branch exactly as with `valueTypeNominal`.
	 *
	 * A STRICT superset of `valueTypeNominal`, kept SEPARATE from it on purpose: that function is
	 * also consumed by gates whose safe direction is the OTHER way round (`map-keys-lookup` acts on
	 * a resolved nominal and refuses an unresolved one), and widening a shared predicate under them
	 * is the trap this project has paid for before. The added capacity is therefore opt-in PER CALL
	 * SITE rather than a widening, and each consumer decides for itself.
	 *
	 * `chain` is the second, deeper opt-in — null gives EXACTLY the answer above, non-null adds
	 * four proof capacities the nominal-only walk structurally cannot have:
	 *
	 *  - a `for` BINDER's type, read off the iterable's element parameter. The binder carries no
	 *    `:Type`, so `declaredTypes` has no entry for it and the shallow walk answers null.
	 *  - a TABLED stdlib static call's written return (`tabledStaticCallTypeSource`), which is what
	 *    gives the binder arm an iterable to read (`for (key in Reflect.fields(o))`).
	 *  - TYPE-ARGUMENT SUBSTITUTION along the member chain: a member declared `T` on
	 *    `Box<T:Item>`, reached through a receiver written `Box<Item>`, resolves to `Item`. The
	 *    shallow walk keeps the verbatim `T`, which resolves to nothing.
	 *  - a `using`-brought STATIC EXTENSION on the call tail (`staticExtensionNominal`), reached
	 *    only after the receiver's own type is PROVEN not to declare the name. Without it a chain
	 *    dies at its first extension link — `text.trim().toLowerCase()` typed nothing at all.
	 *
	 * Two consumers take the deep opt-in: `CheckScan.typeNominalResolver`'s ordered-comparison gate,
	 * where more proof can only turn a conservative wrap into a licensed flip; and
	 * `prefer-static-extension`, which ACTS on the answer and whose own doc records why each arm
	 * clears the higher bar that demands.
	 *
	 * The four fail closed everywhere they are unsure, with ONE documented leak an acting consumer
	 * must handle itself: `SymbolIndex.resolveGenericPathFinalMemberTypeSource` refuses an effective
	 * source that still mentions a parameter name, but that refusal is the SUBSTITUTING walk's, not
	 * the whole answer's — `pathReceiverMemberTypeSource` still runs its package-blind fallback
	 * afterwards, which CAN hand back the verbatim parameter source (`payload:T` on a `Box<T>`
	 * reached through a subtype). The fallback is what keeps deep mode a superset of shallow, so it
	 * stays; a consumer that acts on the nominal must be one whose downstream gate rejects a name
	 * resolving to no unique declaration.
	 *
	 * Deliberately NOT resolved (safe misses, each a null): a bare `f()` / `this.f()` call, whose
	 * enclosing-type lookup is a different mechanism; a `Type.staticMethod()` whose receiver is a
	 * SINGLE unbound identifier and whose `Type.method` is NOT in `staticMethodReturns`, since the
	 * walk will not otherwise guess that an unbound name is a type; and an extension whose first parameter names a
	 * structural type OTHER than `Iterable` / `Iterator`, or whose ELEMENT type a receiver nominal
	 * cannot bind (`Iterable<Widget>`, `Iterable<Iterable<A>>`) — the two the layer does model, it
	 * models by MEMBERSHIP (`SymbolIndex.satisfiesIterable`), never by unification.
	 *
	 * `asReceiver` answers about the node in MEMBER-LOOKUP position rather than as a value: a
	 * member-TRANSPARENT wrapper is peeled off the top, so a `Null<Map<K, V>>` binding answers
	 * `Map`. It carries the obligation `valueNominalDeep` spells out — the answer may decide which
	 * member a name resolves to and nothing else, because `Null<Int>` is not an `Int` for anything
	 * that ORDERS or arithmetically combines the value. The intermediate seats of a path walk have
	 * always been asked this way; the flag exposes the same question about the node a caller is
	 * itself about to splice a `.member(…)` onto.
	 */
	public static function expressionTypeNominal(
		node: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, index: Null<SymbolIndex>, file: String,
		?chain: ChainTypeContext, asReceiver: Bool = false
	): Null<String> {
		return expressionNominalWalk(node, root, shape, declaredTypes, index, file, chain, [], asReceiver);
	}

	/**
	 * The `Type.method` a call node names TOGETHER with that method's written RETURN type source,
	 * when the flattened `Type.method` names a `RefShape.staticMethodReturns` entry
	 * (`Reflect.fields` → `Array<String>`, `Date.now` → `Date`, …) and the receiver is a genuine
	 * TYPE reference — its ROOT identifier binds to no value (`TypeResolver.receiverRootIsUnboundType`),
	 * so a local / parameter / field named after the module makes the access an INSTANCE call and is
	 * refused. Null for every other node. The table's values are written import-safe (fully qualified
	 * where the simple name would not resolve), so a caller may carry the source forward or copy it
	 * verbatim.
	 *
	 * What it deliberately does NOT decide is whether an indexed type SHADOWS the tabled one — the
	 * two callers need opposite answers there and each applies its own policy to `typeName`:
	 * `ExplicitLocalType` refuses a name declared AT ALL (it copies the source into the user's file,
	 * so an indexed name means the oracle can do better), while `tabledStaticCallTypeSource` refuses
	 * only a name declared by a NON-std file (it produces a nominal for internal lookups, where the
	 * normally-indexed std is not a shadow). Keeping the shape match here and the policy at the call
	 * sites is what puts those two policies side by side instead of in two near-identical copies.
	 */
	public static function tabledStaticCall(
		node: QueryNode, root: QueryNode, shape: RefShape
	): Null<{ typeName: String, returnSource: String }> {
		final table: Null<Map<String, String>> = shape.staticMethodReturns;
		final callKind: Null<String> = shape.callKind;
		final fieldKind: Null<String> = shape.fieldAccessKind;
		if (table == null || callKind == null || fieldKind == null) return null;
		if (node.kind != callKind || node.children.length == 0) return null;
		final callee: QueryNode = node.children[0];
		if (callee.kind != fieldKind || callee.children.length != 1) return null;
		final method: Null<String> = callee.name;
		final receiver: QueryNode = callee.children[0];
		final typeName: Null<String> = receiver.name;
		if (method == null || typeName == null) return null;
		final ret: Null<String> = table['$typeName.$method'];
		return ret == null || !TypeResolver.receiverRootIsUnboundType(receiver, root, shape)
			? null
			: { typeName: typeName, returnSource: ret };
	}

	/** Whether any indexed file OUTSIDE the auto-discovered Haxe std declares a top-level type named `typeName`. */
	public static function shadowedByNonStdType(index: Null<SymbolIndex>, typeName: String): Bool {
		return index != null && index.declaringFiles(typeName).exists(fi -> !StdResolver.isStdFile(fi.file));
	}

	/**
	 * The VALUE binder an iteration node carries, or null for a single-binder loop — the `v` node
	 * of `for (k => v in m)`, whose kinds the grammar publishes as
	 * `RefShape.iterationValueBinderKinds`.
	 *
	 * Public, with its three siblings below, because the binder is an EXTRA child ahead of the
	 * iterable, so every consumer reading a loop's operands positionally faces the same question.
	 * Four of them answered it with a private copy in the commit that introduced the binder — one
	 * question, four implementations, which is the drift the binder node exists to end.
	 *
	 * The kinds still arrive as a parameter, so a caller passing `[]` gets the pre-binder
	 * `children[0]` behaviour back with no compile error. Read them from
	 * `RefShape.iterationValueBinderKinds`.
	 */
	public static function iterationValueBinder(loop: QueryNode, valueBinderKinds: Array<String>): Null<QueryNode> {
		return loop.children.find(c -> valueBinderKinds.contains(c.kind));
	}

	/**
	 * The ITERABLE child of an iteration node — its first child that is not a value binder — or null
	 * for a node with no operands at all.
	 */
	public static function iterationIterable(loop: QueryNode, valueBinderKinds: Array<String>): Null<QueryNode> {
		return loop.children.find(child -> !valueBinderKinds.contains(child.kind));
	}

	/**
	 * A receiver path's ROOT reduced to whichever of the two things a root can BE: the enclosing
	 * type declaration (the self reference) or a value BINDING. Null when the path's root is not
	 * a bare identifier at all, or the one thing it is cannot be resolved.
	 *
	 * Extracted because `pathRootTypeName` and its deep-mode twin `pathRootTypeSourceDeep` differ
	 * ONLY in what they do with a resolved binding — one reads a nominal off `declaredTypes`, the
	 * other prefers the written source and falls through to the for-binding arm. Everything before
	 * that (walking down single-child wrappers to the root identifier, and the self-reference
	 * branch) is one question with one answer, and had no business being written twice.
	 */
	private static function pathRootBinding(recv: QueryNode, root: QueryNode, shape: RefShape): Null<PathRoot> {
		final identKind: Null<String> = shape.identKind;
		if (identKind == null) return null;
		var node: QueryNode = recv;
		while (node.kind != identKind && node.children.length == 1) node = node.children[0];
		if (node.kind != identKind) return null;
		if (node.name == shape.selfReferenceText) {
			final span: Null<Span> = recv.span ?? node.span;
			final enclosing: Null<String> = span == null ? null : TypeResolver.enclosingTypeName(root, span);
			return enclosing == null ? null : { selfTypeName: enclosing, bindingFrom: null };
		}
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(node, root, shape);
		return bindingFrom == null ? null : { selfTypeName: null, bindingFrom: bindingFrom };
	}

	/**
	 * `expressionTypeNominal`'s body, threading the `chain` opt-in and the for-binding recursion
	 * guard `seen` that the public signature does not expose. The method-call tail recurses through
	 * THIS function rather than the public entry so that a `a.b().c()` walk stays in deep mode
	 * instead of silently dropping to the shallow answer at the first receiver.
	 *
	 * `seen` rides along rather than being re-created per receiver only for tidiness: the call-tail
	 * recursion is structurally decreasing, and the cycle the guard actually exists for lives
	 * entirely inside `forBindingElementTypeSource`, which recurses into `valueTypeSourceDeep`
	 * directly and never comes back through here.
	 */
	private static function expressionNominalWalk(
		node: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, index: Null<SymbolIndex>, file: String,
		chain: Null<ChainTypeContext>, seen: Array<Int>, asReceiver: Bool = false
	): Null<String> {
		final direct: Null<String> = chain == null
			? valueTypeNominal(node, root, shape, declaredTypes, index, file)
			: valueNominalDeep(node, root, shape, declaredTypes, chain, index, file, seen, asReceiver);
		if (direct != null) return direct;
		final callKind: Null<String> = shape.callKind;
		final fieldKind: Null<String> = shape.fieldAccessKind;
		if (callKind == null || fieldKind == null || index == null || node.kind != callKind || node.children.length == 0) return null;
		final callee: QueryNode = node.children[0];
		final method: Null<String> = callee.name;
		if (callee.kind != fieldKind || method == null || callee.children.length != 1) return null;
		// The callee's own receiver is asked in RECEIVER mode: `tmp.trim()` on a `tmp: Null<String>`
		// looks `trim` up on `String`. A receiver that is ITSELF a call keeps today's answer — its
		// type arrives from `returnNominalOf`, already reduced to the bare nominal `Null`, with no
		// argument left to peel; recovering it needs a return-SOURCE lookup the index does not have.
		final receiver: Null<String> =
			expressionNominalWalk(callee.children[0], root, shape, declaredTypes, index, file, chain, seen, true);
		if (receiver == null) return null;
		final member: Null<String> = index.returnNominalOf(receiver, method);
		return member ?? staticExtensionNominal(receiver, method, chain, index, file);
	}

	/**
	 * The return nominal a `using`-brought STATIC EXTENSION gives at `<recv>.<method>(…)`, where
	 * `recv` carries the type `receiver` — the arm that runs only after the receiver's own type has
	 * been proven NOT to declare `method`. Null everywhere it is unsure, so a caller keeps its
	 * conservative branch exactly as it did before this arm existed.
	 *
	 * The gate is `SymbolIndex.typeProvablyLacksMember`, and nothing weaker will do. A real member
	 * BEATS an extension — verified against the compiler: under `using E`, a `d.tag()` on a `D`
	 * declaring `tag():Void` binds to the MEMBER and errors as `Void should be Dynamic`, never to
	 * `E.tag(d:D):String`. The member-side lookup that ran first (`returnNominalOf`) cannot stand in
	 * for that proof, because it answers null for a `Void` / inference-typed member exactly as it
	 * does for an absent one — reading its null as "no such member" would hand the extension's type
	 * to a call the extension never receives. Only the POSITIVE proof of absence separates the two,
	 * and it fails closed for a receiver whose type, or any type in its supertype closure, the run
	 * does not index.
	 *
	 * `usings` is walked BACKWARDS because Haxe resolves static extensions in reverse declaration
	 * order (measured: `using A; using B;` binds `B.tag`, the reverse binds `A.tag`). The first
	 * module that ANSWERS wins; one declaring the name with a first parameter the receiver does not
	 * fit answers null and the walk continues to the earlier ones — which is the compiler's own
	 * behaviour (`using A; using C;` with `C.tag(s:Int)` binds `A.tag(s:String)` for a `String`).
	 *
	 * Deliberately unreachable in SHALLOW mode: `chain` is the opt-in every deep arm sits behind,
	 * and this one carries the same obligation as its siblings — it resolves not merely MORE but
	 * type-CORRECTLY, each of the three compiler-verified rules above written as its own gate.
	 */
	private static function staticExtensionNominal(
		receiver: String, method: String, chain: Null<ChainTypeContext>, index: SymbolIndex, file: String
	): Null<String> {
		if (chain == null) return null;
		final usings: Array<String> = chain.usings;
		if (usings.length == 0 || !index.typeProvablyLacksMember(receiver, method, file)) return null;
		for (k in 0...usings.length) {
			final ret: Null<String> = index.extensionReturnNominal(usings[usings.length - 1 - k], method, receiver, file);
			if (ret != null) return ret;
		}
		return null;
	}

	/**
	 * `valueTypeNominal`'s deep-mode twin: `valueTypeSourceDeep`'s written type source, reduced to
	 * its outer nominal.
	 *
	 * `asReceiver` peels a member-TRANSPARENT wrapper off first (`Null<String>` -> `String`), and is
	 * set ONLY where the answer is about to seed a member lookup. It is deliberately NOT the default:
	 * an expression's own nominal is what a consumer reads to decide what is legal to DO with the value, and
	 * `Null<Int>` is not `Int` there. `null` is not a value `<` orders, and what the raw comparison DOES with it is
	 * TARGET-SPECIFIC — measured on Haxe 4.3.7, `null > 0` is `false` on js and `true` on `-cpp`. That the wrap and
	 * the flip happen to agree for a null `Null<Int>` on js, `-cpp` and `--interp` alike settles nothing: the same
	 * probe has a null `String` operand DISAGREEING on js and `--interp` while AGREEING on `-cpp`.
	 */
	private static function valueNominalDeep(
		node: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, chain: ChainTypeContext,
		index: Null<SymbolIndex>, file: String, seen: Array<Int>, asReceiver: Bool = false
	): Null<String> {
		final source: Null<String> = valueTypeSourceDeep(node, root, shape, declaredTypes, chain, index, file, seen);
		return if (source == null)
			null
		else if (asReceiver)
			outerNominalOf(memberLookupReceiverSource(source, shape.memberTransparentWrapperTypeNames ?? []))
		else
			outerNominalOf(source);
	}

	/**
	 * The full written type SOURCE a value expression carries — `valueTypeNominal`'s walk kept at
	 * the SOURCE level, because a nominal has already thrown away the type arguments the
	 * substitution step needs. A single-segment path answers the root's own source; a longer one
	 * walks the members with substitution enabled.
	 *
	 * A null root source is NOT a bail: `pathReceiverMemberTypeSource` reads it as the static-TYPE
	 * root case and starts from `path[0]`, exactly as `valueTypeNominal` does today.
	 *
	 * Deliberately NOT merged with `valueTypeNominal` even though the two walks are the same shape:
	 * their single-segment answers differ in KIND, this one handing back a written source with its
	 * arguments intact where that one hands back a nominal. Folding them would mean routing the
	 * shallow answer through `outerNominalOf` — harmless today, since every `declaredTypes` value is
	 * already a package-stripped simple name, but it would put a transformation on the path of the
	 * consumers this seam exists to leave untouched. The shared prefix that IS one question
	 * (resolving the path's root to a binding) is factored out as `pathRootBinding`.
	 *
	 * Ahead of the path walk sits the TABLED-STATIC arm (`tabledStaticCallTypeSource`): a call whose
	 * `Type.method` names a `RefShape.staticMethodReturns` entry answers that written return type.
	 * It is the only shape here that is not a path, and it exists because a call is what a `for`
	 * header usually iterates — `for (key in Reflect.fields(o))` has no other route to an element
	 * type, the binder carrying no annotation and the index holding no method RETURN sources.
	 */
	private static function valueTypeSourceDeep(
		node: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, chain: ChainTypeContext,
		index: Null<SymbolIndex>, file: String, seen: Array<Int>
	): Null<String> {
		final identKind: Null<String> = shape.identKind;
		final fieldKind: Null<String> = shape.fieldAccessKind;
		if (identKind == null || fieldKind == null) return null;
		final tabled: Null<String> = tabledStaticCallTypeSource(node, root, shape, index);
		if (tabled != null) return tabled;
		final path: Null<Array<String>> = pathOf(node, identKind, fieldKind);
		if (path == null) return null;
		final rootSource: Null<String> = pathRootTypeSourceDeep(node, root, shape, declaredTypes, chain, index, file, seen);
		return if (path.length == 1)
			rootSource
		else if (index == null)
			null
		else
			pathReceiverMemberTypeSource(path, rootSource, index, file, true, shape.memberTransparentWrapperTypeNames ?? []);
	}

	/**
	 * `tabledStaticCall`'s return source under the DEEP walk's shadow policy: refused when a NON-std
	 * indexed file declares the type's simple name. The stdlib itself is normally indexed
	 * (`StdResolver` joins it to the resolution scope), so "declared at all" cannot be the test here —
	 * what would make the table wrong is a PROJECT or LIBRARY type shadowing the stdlib name. With no
	 * index the question cannot be asked and the table is trusted, matching every other
	 * unindexed-run fallback.
	 */
	private static function tabledStaticCallTypeSource(
		node: QueryNode, root: QueryNode, shape: RefShape, index: Null<SymbolIndex>
	): Null<String> {
		final hit: Null<{ typeName: String, returnSource: String }> = tabledStaticCall(node, root, shape);
		return if (hit == null)
			null
		else if (shadowedByNonStdType(index, hit.typeName))
			null
		else
			hit.returnSource;
	}

	/**
	 * `pathRootTypeName`'s deep-mode twin, answering the root's written type SOURCE rather than its
	 * nominal. Three tiers, in order: the self reference resolves to the enclosing declaration's
	 * name (a bare name, carrying no arguments — the enclosing header's parameters are not in
	 * scope as concrete types); then the root identifier's own annotation, preferring the written
	 * `declaredTypeSources` form and falling back to the `declaredTypes` nominal so deep mode can
	 * never resolve LESS than the shallow walk; and finally, for a binding with no annotation at
	 * all, the for-binding element arm.
	 */
	private static function pathRootTypeSourceDeep(
		recv: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, chain: ChainTypeContext,
		index: Null<SymbolIndex>, file: String, seen: Array<Int>
	): Null<String> {
		final resolved: Null<PathRoot> = pathRootBinding(recv, root, shape);
		if (resolved == null) return null;
		final bindingFrom: Null<Int> = resolved.bindingFrom;
		if (bindingFrom == null) return resolved.selfTypeName;
		final annotated: Null<String> = chain.declaredTypeSources[bindingFrom] ?? declaredTypes[bindingFrom];
		return annotated ?? forBindingElementTypeSource(bindingFrom, root, shape, declaredTypes, chain, index, file, seen);
	}

	/**
	 * The written ELEMENT type source a `for` binder carries, for a binding `declaredTypes` has no
	 * entry for: the loop header declares no `:Type`, so the element type can only be read off the
	 * ITERABLE's own declared type through `RefShape.iterationElementTypeParams`.
	 *
	 * Every gate here fails closed (null = the caller keeps its conservative branch):
	 *
	 *  - `seen` is the recursion guard. The iterable is a CHILD of the loop node, so in
	 *    `for (x in x)` the iterable's `x` resolves right back to the binder and the walk would
	 *    never terminate. The binding offset is pushed for the duration of the recursive call only.
	 *  - The loop node is found by a kind-FILTERED walk for an exact `span.from` match, not by
	 *    "first node starting here" — the binding offset is the loop's own start, which several
	 *    co-starting nodes share. A key-value loop's VALUE binder is its own node, so the same
	 *    walk also matches a binder child's start (`loopBinderAt` reports which of the two hit).
	 *  - The KEY binder of a key-value loop is refused. `for (k => v in m)` binds `k` to the
	 *    container's KEY, not to what iteration yields: for a map that is the key type, and for
	 *    `for (i => v in arr)` it is a plain `Int` index no type parameter of `Array` names at
	 *    all. `iterationElementTypeParams` answers only the ELEMENT question, so the key binder
	 *    stays unresolved. Its VALUE binder is the element and resolves normally — the same
	 *    parameter a single-binder `for (v in m)` reads.
	 */
	private static function forBindingElementTypeSource(
		bindingFrom: Int, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, chain: ChainTypeContext,
		index: Null<SymbolIndex>, file: String, seen: Array<Int>
	): Null<String> {
		final kinds: Null<Array<String>> = shape.iterationBindingKinds;
		final elementParams: Null<Map<String, Int>> = shape.iterationElementTypeParams;
		if (kinds == null || elementParams == null || seen.contains(bindingFrom)) return null;
		final valueBinderKinds: Array<String> = shape.iterationValueBinderKinds ?? [];
		final hit: Null<LoopBinderHit> = loopBinderAt(root, bindingFrom, kinds, valueBinderKinds);
		if (hit == null) return null;
		final loop: QueryNode = hit.loop;
		if (!hit.isValueBinder && hasIterationValueBinder(loop, valueBinderKinds)) return null;
		final iterable: Null<QueryNode> = iterationIterable(loop, valueBinderKinds);
		if (iterable == null) return null;
		seen.push(bindingFrom);
		final iterableSource: Null<String> = valueTypeSourceDeep(iterable, root, shape, declaredTypes, chain, index, file, seen);
		seen.pop();
		if (iterableSource == null) return null;
		final nominal: Null<String> = outerNominalOf(iterableSource);
		final args: Null<Array<String>> = typeArgumentSourcesOf(iterableSource);
		if (nominal == null || args == null) return null;
		final at: Null<Int> = elementParams[nominal];
		return if (at == null)
			null
		else if (at < args.length)
			args[at]
		else
			null;
	}

	/**
	 * The iteration binder starting at `from` in pre-order: the `kinds` loop node itself (its own
	 * key-or-element binder, which shares the loop's start offset) or a `valueBinderKinds` child of
	 * one (a key-value loop's VALUE binder, which starts at its own identifier). Null when neither
	 * matches.
	 *
	 * A spanned subtree that does not CONTAIN `from` is pruned rather than descended: the offset is
	 * a node's own start, so every node starting there is an ancestor-chain descendant of every
	 * spanned node covering it. Without the prune this is a whole-tree walk on every call, and it
	 * is called for every unannotated root binding — a plain `var x = 5;` in a guard operand, not
	 * just a `for` binder. A node with NO span states nothing about containment and is descended
	 * into normally.
	 */
	private static function loopBinderAt(
		node: QueryNode, from: Int, kinds: Array<String>, valueBinderKinds: Array<String>
	): Null<LoopBinderHit> {
		final span: Null<Span> = node.span;
		if (span != null && (from < span.from || from >= span.to)) return null;
		if (kinds.contains(node.kind)) {
			if (span != null && span.from == from) return { loop: node, isValueBinder: false };
			for (child in node.children) if (valueBinderKinds.contains(child.kind)) {
				final binderSpan: Null<Span> = child.span;
				if (binderSpan != null && binderSpan.from == from) return { loop: node, isValueBinder: true };
			}
		}
		for (child in node.children) {
			final hit: Null<LoopBinderHit> = loopBinderAt(child, from, kinds, valueBinderKinds);
			if (hit != null) return hit;
		}
		return null;
	}

}

/**
 * A receiver path's ROOT, reduced to whichever of the two things a root can BE. EXACTLY one field
 * is set: `selfTypeName` for the self reference (already resolved to its enclosing declaration's
 * name, since nothing further can be asked of it), `bindingFrom` for a value, whose declared type
 * each consumer then reads its own way. Produced only by `NominalTypes.pathRootBinding`, which
 * answers null rather than an all-null record when the root resolves to neither.
 */
private typedef PathRoot = {
	final selfTypeName: Null<String>;
	final bindingFrom: Null<Int>;
};
/**
 * Which binder of an iteration node a binding offset landed on: the loop node itself (its own
 * key-or-element binder, sharing the loop's start offset) or the VALUE binder it carries as a
 * separate child in a key-value iteration. The two type DIFFERENTLY, so the answer cannot be a
 * bare node — see `NominalTypes.loopBinderAt`.
 */
private typedef LoopBinderHit = {
	final loop: QueryNode;
	final isValueBinder: Bool;
};

/**
 * The extra per-file context `NominalTypes.expressionTypeNominal` needs for its DEEP
 * resolution mode: the WRITTEN form of every `:Type` annotation (a nominal alone cannot carry
 * type arguments) and the file's source text (the only place a `for` loop's header form is
 * legible). Passing it is the opt-in — omit it and that function answers exactly what it
 * always did.
 *
 * That opt-in is the whole point of the seam. `NominalTypes.valueTypeNominal`'s other consumers
 * (`map-keys-lookup`, `prefer-static-extension`) read a resolved nominal as a LICENCE TO ACT,
 * so extra resolution is the unsafe direction for them; they cannot reach the deep mode BY
 * CONSTRUCTION, because it lives behind a parameter they do not pass, rather than by a
 * convention someone must remember.
 */
typedef ChainTypeContext = {
	/** Verbatim `:Type` annotation sources, keyed exactly like `declaredTypes` (`TypeInfoProvider.declaredTypeSources`). */
	final declaredTypeSources: Map<Int, String>;

	/** Source text of the file being probed — the for-binding arm reads the loop HEADER text to refuse the key-value form. */
	final source: String;

	/**
	 * The module paths of every `using` the file declares, in DECLARATION order
	 * (`UsingScan.usingModules`). The static-extension arm reads them BACKWARDS, because Haxe
	 * resolves a static extension in reverse declaration order — the later `using` wins.
	 * An empty array switches the arm off, which is what a consumer that has not thought about
	 * static extensions should pass.
	 */
	final usings: Array<String>;
}
