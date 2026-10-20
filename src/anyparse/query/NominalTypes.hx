package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.MemberLookup.HostedMembers;
import anyparse.query.MemberLookup.MemberDeclaration;
import anyparse.query.NodeShape;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.query.TypeSyntax;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.query.TypingService.TypingHost;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Nominal-type resolution over written type SOURCES and the query tree: what type does
 * this expression, this receiver path or this loop binder carry, and what bare type name
 * does that written source reduce to.
 *
 * Extracted from `RefactorSupport` as one connected call cluster (`hxq clusters`): nothing left
 * behind calls in, and the only calls out are to `RefactorSupport` character / identifier
 * predicates. Every member is a pure static — the tree, the `declaredTypes` map, the `SymbolIndex`
 * and the reading file all arrive as arguments — so there is no shared state and no thread-safety
 * question to answer.
 *
 * Three layers, outside in:
 *
 * - **Reducing a written type source.** `outerNominalOf` strips the type arguments and the
 *   package prefix off a source (`pkg.Map<String, Int>` → `Map`); `typeArgumentSourcesOf`,
 *   `unwrapNullable` and `memberLookupReceiverSource` read its arguments and peel its wrappers —
 *   every one of them through the grammar's `GrammarPlugin.typeSyntax`; `shadowedByNonStdType`
 *   says whether an indexed non-std file claims a name that would otherwise read as the stdlib
 *   type.
 * - **Walking a receiver path.** `pathOf` flattens a plain field chain into its segments,
 *   `pathRootTypeName` types the root off `declaredTypes`, and `pathFinalMemberTypeSource`
 *   / `pathReceiverMemberTypeSource` follow the segments through the `SymbolIndex` to the
 *   member type at the end.
 * - **Typing a value or an expression.** `valueTypeNominal` and `expressionTypeNominal` are
 *   the entry points the analysis checks call; `expressionTypeSource` is the SOURCE mode, the
 *   same deep walk answering the written type. The private deep walk below them keeps the
 *   answer at SOURCE level (type arguments intact, for substitution) and adds the arms a
 *   plain path has not got: a method call resolved through `MemberLookup.returnNominalOf` or, when
 *   the receiver provably lacks the member, through a `using` STATIC EXTENSION
 *   (`staticExtensionNominal`); a tabled `Type.method` static call; a literal, a construction, and
 *   `this` inside an abstract (its underlying type); and the loop binder whose
 *   type is the ELEMENT type of what it iterates (`iterationValueBinder` / `iterationIterable` /
 *   `forBindingElementTypeSource`).
 *
 * Every resolution entry point answers null for "unknown" rather than guessing, so a consumer that
 * needs a proof reads null as a refusal and keeps its conservative branch.
 */
@:nullSafety(Strict)
final class NominalTypes {

	/**
	 * The index's resolution for `typeWalk` (`TypingHost`): a written type source, resolved in the file that wrote it — the
	 * deep walk's arcs, each answering what it always did. An identifier's annotation (`declaredTypeSources`, then the
	 * `declaredTypes` nominal, so the deep walk never resolves less than the shallow one), a `for` binder's element
	 * (`forBindingElementTypeSource`), a field PATH walked from its root as one (`indexAccess`), a tabled static call, the self reference
	 * (`indexSelf`), and a local written with no type by its initializer (`localInitializer`). It types no element or construction.
	 */
	private static final INDEX_HOST: TypingHost<String, IndexTyping> = {
		peel: (node, _) -> node,
		isAccess: (kind, c) -> kind == c.shape.fieldAccessKind,
		literal: (typeName, _) -> typeName,
		self: indexSelf,
		binding: (ident, c) -> TypeResolver.identBindingFrom(ident, c.root, c.shape),
		bound: (from, c) -> {
			final written: Null<String> = c.chain.declaredTypeSources[from];
			// the nominal alone has lost the arguments written with it: it is no text to complete
			written == null ? boundType(from, c.declaredTypes[from], c, false) : boundType(from, written, c, true);
		},
		initializer: (_, use, c) -> localInitializer(use, c.root, c.shape, c.chain.declaredTypeSources),
		loopElement: forBindingElementTypeSource,
		// the index resolves no call to a declaration (its call arc is the tabled statics), so it reads no callee's parameter
		// a lambda could take its type from, and its currency spells a type parameter as a bare name its own later lookups
		// would resolve package-blind: an untyped lambda parameter stays unknown here (`ExpectedTypes`)
		parameter: null,
		unbound: (_, _) -> null,
		access: indexAccess,
		element: null,
		call: (node, c) -> tabledStaticCallTypeSource(node, c.root, c.shape, c.index),
		construction: null,
		arithmetic: null,
		reading: c -> c.seen
	};

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
	 * `wrappers` is `RefShape.memberTransparentWrapperTypeNames`, whose doc carries the rule: a wrapper
	 * belongs there only when its member set IS its argument's (Haxe's `@:forward` `Null<T>`), and the
	 * answer may be used ONLY to decide which member a name resolves to. It is NOT the value's type:
	 * `Null<Int>` still is not an `Int` for an arithmetic or ordered comparison. `null` is not a value `<`
	 * orders, and what the raw comparison DOES with it is TARGET-SPECIFIC: `null > 0` is `false` on js and
	 * `true` on `-cpp`. That the wrap and the flip agree for a null `Null<Int>` on js, `-cpp` and
	 * `--interp` alike settles nothing — a null `String` operand DISAGREES on js and `--interp` while
	 * agreeing on `-cpp`.
	 *
	 * The peel reads the WRITTEN annotation (`typeSyntax`), so a typedef that RESOLVES to `Null<T>`
	 * carries no wrapper to peel and is left alone — following the alias would mean resolving a
	 * type reference here, and the miss fails closed like every other unresolved link.
	 */
	public static function memberLookupReceiverSource(typeSource: String, wrappers: Array<String>, typeSyntax: TypeSyntaxReader): String {
		if (wrappers.length == 0) return typeSource;
		var t: String = typeSource.trim();
		while (true) {
			final inner: String = unwrapNullable(t, wrappers, typeSyntax);
			if (inner == t) return t;
			t = inner;
		}
	}

	/**
	 * The simple outer nominal of a written type — `pkg.Map<String, Int>` → `Map` — or null when the
	 * text is not a named type.
	 */
	public static function outerNominalOf(typeSource: String, typeSyntax: TypeSyntaxReader): Null<String> {
		return switch typeSyntax(typeSource)?.shape {
			case Nominal(path, _): SourceText.lastSegment(path);
			case _: null;
		};
	}

	/**
	 * The dotted path of a written type's outer nominal — `pkg.Map<String, Int>` → `pkg.Map`, as written — once each
	 * of the `wrappers` around it is peeled (`memberLookupReceiverSource`); null when the text is not a named type.
	 */
	public static function outerPathOf(typeSource: String, wrappers: Array<String>, typeSyntax: TypeSyntaxReader): Null<String> {
		return switch typeSyntax(memberLookupReceiverSource(typeSource, wrappers, typeSyntax))?.shape {
			case Nominal(path, _): path;
			case _: null;
		};
	}

	/**
	 * The ELEMENT type a written container type gives what iterates it, as written: the argument at the position
	 * `elementParams` names for the container's simple name (`RefShape.iterationElementTypeParams`: `Array<Item>` → `Item`,
	 * `Map<K, V>` → `V`), the `wrappers` around it peeled first. Null for a container `elementParams` does not list, or one
	 * written without that argument. Which container it IS — the std's or a namesake — is the caller's question.
	 */
	public static function elementTypeSourceOf(
		typeSource: String, elementParams: Map<String, Int>, wrappers: Array<String>, typeSyntax: TypeSyntaxReader
	): Null<String> {
		return switch typeSyntax(memberLookupReceiverSource(typeSource, wrappers, typeSyntax))?.shape {
			case Nominal(path, args):
				final at: Null<Int> = elementParams[SourceText.lastSegment(path)];
				at != null && at < args.length ? args[at].text : null;
			case _: null;
		};
	}

	/**
	 * `typeSource` with a leading nullable WRAPPER peeled off — `Null<Foo>` -> `Foo` — or unchanged
	 * when it is not one of `wrappers` applied to one type. The caller names the wrappers because the
	 * question differs per consumer: a nullability reader passes every name that stays nullable under
	 * a null-safety meta, a rewriter passes only the one syntactic wrapper it may re-emit. The one
	 * `Null<>` unwrap every consumer shares — `memberLookupReceiverSource` repeats it to a fixed point.
	 */
	public static function unwrapNullable(typeSource: String, wrappers: Array<String>, typeSyntax: TypeSyntaxReader): String {
		return typeSyntax(typeSource)?.wrapped(wrappers)?.text ?? typeSource;
	}

	/**
	 * `typeSource` as a read of an OPTIONAL declaration carries it — a parameter `?x: T`, a structure field `?a: T` or
	 * `@:optional var b: T` — wrapped in `wrapper` (`RefShape.optionalValueTypeName`, Haxe `Null`: 4.3.7 types such a read as
	 * `Null<T>`), unless it is one already (`?x: Null<T>` reads as `Null<T>`); unchanged with no wrapper.
	 */
	public static function optionalValueType(typeSource: String, wrapper: Null<String>, typeSyntax: TypeSyntaxReader): String {
		return wrapper == null || outerNominalOf(typeSource, typeSyntax) == wrapper ? typeSource : '$wrapper<$typeSource>';
	}

	/**
	 * Whether `typeSource` reads as ONE type a typing currency may answer with: one the grammar reads, holding no
	 * conditional-compilation region (`#if lime Image #else Dynamic #end` is a different type per configuration) and no form
	 * the model does not break down (a macro splice).
	 */
	public static function answerableType(typeSource: String, typeSyntax: TypeSyntaxReader): Bool {
		final t: Null<TypeSyntax> = typeSyntax(typeSource);
		return t != null && !t.descendants().exists(d -> d.shape.match(Conditional(_) | Other));
	}

	/**
	 * The verbatim type-ARGUMENT sources of a generic application (`Map<String, Array<Int>>` →
	 * `['String', 'Array<Int>']`), or null when `typeSource` is not a named type written with
	 * arguments — a function type whose RESULT is generic (`(Int) -> Array<Int>`) included, and any
	 * text the grammar does not read as one type.
	 */
	public static function typeArgumentSourcesOf(typeSource: String, typeSyntax: TypeSyntaxReader): Null<Array<String>> {
		final args: Null<Array<String>> = typeSyntax(typeSource)?.argumentTexts();
		return args == null || args.length == 0 ? null : args;
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
		final host: Null<String> = pathFinalHost(path, rootType, index, transparentWrappers ?? []);
		return host == null ? null : index.typing.members.memberTypeSourceOf(host, path[path.length - 1]);
	}

	/**
	 * The simple name of the type whose member the last segment of `path` reads on the package-blind walk of
	 * `pathFinalMemberTypeSource` — the type each intermediate member's written type reduces to, from `rootType` on — or
	 * null when a link does not resolve.
	 */
	private static function pathFinalHost(
		path: Array<String>, rootType: String, index: SymbolIndex, wrappers: Array<String>
	): Null<String> {
		var current: String = rootType;
		for (i in 1...path.length - 1) {
			final memberType: Null<String> = index.typing.members.memberTypeSourceOf(current, path[i]);
			final nominal: Null<String> = memberType == null
				? null
				: outerNominalOf(memberLookupReceiverSource(memberType, wrappers, index.typeSyntax), index.typeSyntax);
			if (nominal == null) return null;
			current = nominal;
		}
		return current;
	}

	/**
	 * The verbatim declared type SOURCE of a receiver path's final member, for a value / `this` /
	 * static-TYPE-name root. Resolves PACKAGE-SAFE FIRST via the import- and inheritance-aware
	 * `MemberPathWalk.resolvePathFinalMemberTypeSource` (so an import-correct intermediate type's
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
	 * (`MemberPathWalk.resolveGenericPathFinalMemberTypeSource`): `rootType` may then carry written
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
		final startType: String = memberLookupReceiverSource(rootType ?? path[0], wrappers, index.typeSyntax);
		final resolved: Null<String> = substituteTypeArgs
			? index.paths.resolveGenericPathFinalMemberTypeSource(fromFile, startType, path.slice(1), wrappers)
			: index.paths.resolvePathFinalMemberTypeSource(fromFile, startType, path.slice(1));
		if (resolved != null) return resolved;
		// The package-blind fallback never substitutes; in substitute mode it is only fed the
		// root's NOMINAL, since a `Box<Item>` start source is not a name any member lookup matches.
		if (rootType != null) {
			final start: String = substituteTypeArgs ? outerNominalOf(startType, index.typeSyntax) ?? startType : startType;
			final blind: Null<String> = pathFinalMemberTypeSource(path, start, index, wrappers);
			if (!substituteTypeArgs || blind == null) return blind;
			// the substituting caller types a value: a written type that is no one type (`#if` inside it) is no answer there, nor
			// is one naming a parameter of the member's declaring type or of the member, which this walk never substitutes
			final host: Null<String> = pathFinalHost(path, start, index, wrappers);
			final params: Array<String> = host == null ? [] : [
				for (d in index.typing.members.memberDeclarationsOf(host, path[path.length - 1]))
					for (p in d.type.typeParamNames.concat(d.member.typeParamNames)) p
			];
			return !answerableType(blind, index.typeSyntax) || CallGraphNames.mentionsTypeName(blind, params, index.typeSyntax)
				? null
				: blind;
		}
		final firstSource: Null<String> = index.paths.resolvePathFinalMemberTypeSource(fromFile, path[0], [path[1]]);
		if (firstSource == null) return null;
		if (path.length == 2) return firstSource;
		final firstNominal: Null<String> = outerNominalOf(
			memberLookupReceiverSource(firstSource, wrappers, index.typeSyntax), index.typeSyntax
		);
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
		// A `$name` interpolation FRAGMENT is an identifier read that the grammar keeps as a leaf inside
		// the string literal rather than as an `identKind` node, so `pathOf` cannot see it. It binds
		// exactly like a bare ident, and resolving it is what lets a caller ask about the operands a SPLIT
		// of the literal would create — `'${dir}pages'` becoming `dir + 'pages'` re-selects the `+` on
		// `dir`'s type, so a `$name` answering null leaves every such question unprovable, which is most of
		// the report-only `fold-adjacent-string-literals` findings on a real tree.
		final interpIdentKind: Null<String> = shape.stringInterpIdentKind;
		if (interpIdentKind != null && node.kind == interpIdentKind) {
			final interpName: Null<String> = node.name;
			final interpSpan: Null<Span> = node.span;
			if (interpName == null || interpSpan == null) return null;
			final bindingFrom: Null<Int> = TypeResolver.resolveBindingFrom(interpName, interpSpan, root, shape);
			return bindingFrom == null ? null : declaredTypes[bindingFrom];
		}
		final path: Null<Array<String>> = pathOf(node, identKind, fieldKind);
		if (path == null) return null;
		final rootType: Null<String> = pathRootTypeName(node, root, declaredTypes, shape);
		if (path.length == 1) return rootType;
		if (index == null) return null;
		final typeSource: Null<String> = pathReceiverMemberTypeSource(path, rootType, index, file);
		return typeSource == null ? null : outerNominalOf(typeSource, index.typeSyntax);
	}

	/**
	 * The simple nominal of the type ANY expression carries: `valueTypeNominal`'s identifier /
	 * field-path answer, plus the METHOD-CALL tail it stops at — `<chain>.method(…)` resolves the
	 * receiver's own nominal (recursively, so `a.b.c().d()` walks) and reads the method's return
	 * nominal off it through `MemberLookup.returnNominalOf`. Null stays "unknown", so every caller
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
	 * must handle itself: `MemberPathWalk.resolveGenericPathFinalMemberTypeSource` refuses an effective
	 * source that still mentions a parameter name, but that refusal is the SUBSTITUTING walk's, not
	 * the whole answer's — `pathReceiverMemberTypeSource` still runs its package-blind fallback
	 * afterwards, which CAN hand back the verbatim parameter source (`payload:T` on a `Box<T>`
	 * reached through a subtype). The fallback is what keeps deep mode a superset of shallow, so it
	 * stays; a consumer that acts on the nominal must be one whose downstream gate rejects a name
	 * resolving to no unique declaration.
	 *
	 * Deliberately NOT resolved (safe misses, each a null): a bare `f()` / `this.f()` call, whose
	 * enclosing-type lookup is a different mechanism; a `Type.staticMethod()` whose receiver is a SINGLE
	 * unbound identifier and whose `Type.method` is NOT in `staticMethodReturns`, since the walk will not
	 * otherwise guess that an unbound name is a type; and an extension whose first parameter names a
	 * structural type OTHER than `Iterable` / `Iterator`, or whose ELEMENT type a receiver nominal cannot
	 * bind (`Iterable<Widget>`, `Iterable<Iterable<A>>`) — the two the layer does model, it models by
	 * MEMBERSHIP (`StructuralTypes.satisfiesIterable`), never by unification.
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
	 * The SOURCE mode of the deep walk: the written type SOURCE an expression carries, type arguments kept
	 * (`Map<String, Array<Int>>`, not `Map`) — what a consumer substituting or reading arguments needs, where
	 * `expressionTypeNominal` has already thrown them away. Every arc the deep walk reads at source level answers: a literal,
	 * an identifier's annotation (`declaredTypeSources`), a `for` binder's element, a field path with substitution, a tabled
	 * static call, `this` (an abstract's underlying type); and a METHOD CALL `<recv>.m(…)` when every declaration of `m` on
	 * the receiver's type writes one return type that names no type parameter of the method or its type
	 * (`returnSourceOf`). A construction has none (`new Box(item)` is a `Box<Item>` nothing spells), nor has an inherited
	 * method or one returning a type parameter: null, as for anything else the walk cannot spell exactly.
	 */
	public static function expressionTypeSource(
		node: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, index: Null<SymbolIndex>, file: String,
		chain: ChainTypeContext
	): Null<String> {
		final direct: Null<String> = valueTypeSourceDeep(node, root, shape, declaredTypes, chain, index, file, []);
		if (direct != null || index == null || node.kind != shape.callKind || node.children.length == 0) return direct;
		final callee: QueryNode = node.children[0];
		final method: Null<String> = callee.name;
		if (method == null || callee.kind != shape.fieldAccessKind || callee.children.length != 1) return null;
		final receiver: Null<String> = expressionNominalWalk(callee.children[0], root, shape, declaredTypes, index, file, chain, [], true);
		return receiver == null ? null : returnSourceOf(index, receiver, method);
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
		if (table == null || callKind == null || node.kind != callKind) return null;
		final call: Null<MethodCall> = NodeShape.methodCall(node, fieldKind);
		if (call == null) return null;
		final receiver: QueryNode = call.receiver;
		final typeName: Null<String> = receiver.name;
		if (typeName == null) return null;
		final ret: Null<String> = table['$typeName.${call.method}'];
		return ret == null || !TypeResolver.receiverRootIsUnboundType(receiver, root, shape)
			? null
			: { typeName: typeName, returnSource: ret };
	}

	/** Whether any indexed file OUTSIDE the auto-discovered Haxe std declares a top-level type named `typeName`. */
	public static function shadowedByNonStdType(index: Null<SymbolIndex>, typeName: String): Bool {
		return index != null && index.refs.declaringFiles(typeName).exists(fi -> !StdResolver.isStdFile(fi.file));
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
	 * Whether a key-value loop over `iterable` may drop its key and iterate the values alone: the
	 * iterable's type resolves to a `RefShape.valueIterationTypes` container that the file does not
	 * rebind (no import alias spelling the name, no import of another type under it, no indexed
	 * project type of that name), and the iterable is not a local or parameter written anywhere in
	 * its scope. That last gate is the language, not the container: a value loop over a bare local
	 * re-reads the LOCAL each step, while the key-value iterator captured the value once, so a
	 * reassignment in the body — or in a closure the body calls — changes what the value loop sees.
	 * A field is read once into a hidden temporary by both forms. `importMap` is the file's
	 * `TypeInfoProvider.importMap`.
	 */
	public static function valueIterationProvable(
		iterable: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, index: Null<SymbolIndex>, file: String,
		importMap: Map<String, String>
	): Bool {
		return standardContainer(shape.valueIterationTypes, iterable, root, shape, declaredTypes, index, file, importMap) != null;
	}

	/**
	 * Whether `iterable` is one of the standard KEYED containers (`RefShape.keyedIterationTypes`, a map) under the gates
	 * `valueIterationProvable` applies, and no type outside the standard library extends a class a value of that type
	 * may be at run time (`RefShape.keyedIterationHolders`; the type itself when it has no entry): a subclass may
	 * override the iterators. Dropping the key of a loop over one is sound only when nothing the loop body runs changes
	 * the container — the question `ValueIterationProof` asks `MemberReach`.
	 */
	public static function keyedIterationContainer(
		iterable: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, index: Null<SymbolIndex>, file: String,
		importMap: Map<String, String>
	): Bool {
		final nominal: Null<String> = standardContainer(
			shape.keyedIterationTypes, iterable, root, shape, declaredTypes, index, file, importMap
		);
		if (nominal == null || index == null) return false;
		final holders: Array<String> = shape.keyedIterationHolders?.get(nominal) ?? [nominal];
		return !holders.exists(holder -> index.subtypes.subtypeFiles(holder).exists(f -> !StdResolver.isStdFile(f)));
	}

	/**
	 * The type a construction `new T<…>(…)` writes, read off the grammar's nodes: `path` the type as written, `args` the
	 * verbatim type arguments it writes (none for `new Box(item)`, whose arguments the language infers), `text` the two
	 * spelled as one type. The type arguments are the node's leading `typeArgCount` children — the grammar's own split,
	 * where this used to re-derive it from the separators between the children. A node of another kind, or a type
	 * argument without a span, answers null.
	 */
	public static function writtenConstruction(node: QueryNode, shape: RefShape, source: String): Null<WrittenConstruction> {
		final path: Null<String> = node.name;
		if (node.kind != shape.newExprKind || path == null || node.span == null) return null;
		final args: Array<Span> = [];
		for (k in 0...node.typeArgCount) {
			final cs: Null<Span> = node.children[k].span;
			if (cs == null) return null;
			args.push(cs);
		}
		return args.length == 0 ? { path: path, args: [], text: path } : {
			path: path,
			args: [for (a in args) source.substring(a.from, a.to)],
			text: '$path<${source.substring(args[0].from, args[args.length - 1].to)}>'
		};
	}

	/**
	 * The expression initialising the local the identifier `use` reads, when that local is written with no type
	 * (`annotations` keyed by binding offset, `TypeInfoProvider.declaredTypeSources`): the local holds its type, the one
	 * Haxe infers for it. Null for a binding of another kind (a parameter, a field, a loop binder), one written with a
	 * type, one with no initializer, and a use the initializer does not end before.
	 */
	public static function localInitializer(
		use: QueryNode, root: QueryNode, shape: RefShape, annotations: Map<Int, String>
	): Null<QueryNode> {
		final name: Null<String> = use.name;
		final at: Null<Span> = use.span;
		if (name == null || at == null) return null;
		final decl: Null<QueryNode> = TypeResolver.bindingNodeFrom(name, at, root, shape);
		if (decl == null || !(shape.localDeclKinds ?? []).contains(decl.kind)) return null;
		final declAt: Null<Span> = decl.span;
		if (declAt == null || annotations.exists(declAt.from)) return null;
		final init: Null<QueryNode> = CtorFieldFold.declInitializer(decl, shape);
		final initAt: Null<Span> = init?.span;
		return initAt == null || initAt.to > at.from ? null : init;
	}

	/**
	 * The simple name of the one of `types` (simple name to standard path) `iterable`'s type resolves to, when the file
	 * does not rebind it and the iterable is not a local written in its scope — the gates `valueIterationProvable`'s doc
	 * gives — or null.
	 */
	private static function standardContainer(
		types: Null<Map<String, String>>, iterable: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>,
		index: Null<SymbolIndex>, file: String, importMap: Map<String, String>
	): Null<String> {
		final nominal: Null<String> = expressionTypeNominal(iterable, root, shape, declaredTypes, index, file);
		if (types == null || nominal == null || index == null) return null;
		final stdPath: Null<String> = types[nominal];
		if (stdPath == null || shadowedByNonStdType(index, nominal)) return null;
		final imported: Null<String> = importMap[nominal];
		if (imported != null && imported != stdPath) return null;
		final aliasKinds: Array<String> = shape.importAliasKinds ?? [];
		final rebound: Bool = root.children.exists(c -> aliasKinds.contains(c.kind) && c.name == nominal);
		return rebound || reassignedLocal(iterable, root, shape) ? null : nominal;
	}

	/**
	 * A receiver path's ROOT reduced to whichever of the two things a root can BE: the enclosing
	 * type declaration (the self reference) or a value BINDING. Null when the path's root is not
	 * a bare identifier at all, or the one thing it is cannot be resolved.
	 *
	 * The shallow walk's root (`pathRootTypeName`); the deep walk types its root through `typeWalk`'s identifier arm instead.
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
	 * recursion is structurally decreasing, and the cycle the guard actually exists for lives entirely
	 * inside `typeWalk` (a `for` binder whose iterable reads it), which never comes back through here.
	 * The type of an IDENT that names no value binding: a member of the ENCLOSING type, read
	 * through an implicit `this` (`MS`, `l_usedLibs`). Null for anything else, including a name
	 * that IS a binding — that one the path walk already answered.
	 */
	private static function implicitMemberNominal(
		node: QueryNode, root: QueryNode, shape: RefShape, index: SymbolIndex, file: String
	): Null<String> {
		final identKind: Null<String> = shape.identKind;
		if (identKind == null || node.kind != identKind) return null;
		final source: Null<String> = RefactorSupport.implicitThisMemberTypeSource(node, root, shape, index, file, []);
		return source == null ? null : outerNominalOf(source, index.typeSyntax);
	}

	/**
	 * The return type of an UNQUALIFIED call — a method of the enclosing type called without a
	 * receiver (`l_benchTime(time)`). A callee name that binds to any declaration but a member — a
	 * local or a parameter holding a closure, a local function (`function walk(…)` shadowing a
	 * member `walk`), a module-level function — is another callee, whose return type the member
	 * lookup does not name, so it stays null.
	 */
	private static function unqualifiedCallNominal(
		callee: QueryNode, root: QueryNode, shape: RefShape, index: SymbolIndex, method: String
	): Null<String> {
		final identKind: Null<String> = shape.identKind;
		final span: Null<Span> = callee.span;
		if (identKind == null || callee.kind != identKind || span == null) return null;
		// Only a MEMBER binding is the sibling method: the scope walk resolves a bare `f(x)` to the
		// `FnMember f` that declares it, and binds nothing for one a supertype declares
		final binding: Null<QueryNode> = TypeResolver.bindingNodeFrom(method, span, root, shape);
		if (binding != null && !(shape.memberDeclKinds ?? []).contains(binding.kind)) return null;
		final enclosing: Null<String> = TypeResolver.enclosingTypeName(root, span);
		return enclosing == null ? null : index.typing.members.returnNominalOf(enclosing, method);
	}

	/**
	 * The return type of a TYPE-qualified static call (`Tools.getBuildDate()`) — the one shape
	 * where the receiver is not a VALUE at all, so asking it for a type answers null and the
	 * member lookup never runs.
	 *
	 * Three conditions, all of them needed: the receiver is a bare identifier, it is upper-initial
	 * (the language's own convention for a type reference — a lower-case receiver is a value whose
	 * type simply did not resolve, and guessing there would name a package segment), and it names
	 * no value binding in scope. Only then is the NAME itself the receiver type.
	 */
	private static function staticCallNominal(
		receiver: QueryNode, root: QueryNode, shape: RefShape, index: SymbolIndex, method: String
	): Null<String> {
		final identKind: Null<String> = shape.identKind;
		final name: Null<String> = receiver.name;
		final span: Null<Span> = receiver.span;
		return if (identKind == null || receiver.kind != identKind || name == null || span == null)
			null
		else if (!SourceText.isUpperInitial(name) || TypeResolver.resolveBindingFrom(name, span, root, shape) != null)
			null
		else if (index.refs.declaringFiles(name).length == 0)
			null
		else
			index.typing.members.returnNominalOf(name, method);
	}

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
		if (callKind == null || fieldKind == null || index == null) return null;
		final resolved: SymbolIndex = index;
		// Three shapes the path walk cannot reach, each turning a NULL into an answer rather than
		// one answer into another — so a caller that read the null as "unknown" gains a type where
		// it had none, and no existing answer moves. All three were measured as the reason
		// `fold-adjacent-string-literals` could not prove its `+` on `pony/src`: an enclosing-type
		// member read with no `this` (`MS`), an unqualified call to a sibling method
		// (`l_benchTime(time)`), and a type-qualified static call (`Tools.getBuildDate()`).
		if (node.kind != callKind) return implicitMemberNominal(node, root, shape, resolved, file);
		if (node.children.length == 0) return null;
		final callee: QueryNode = node.children[0];
		final method: Null<String> = callee.name;
		if (method == null) return null;
		if (callee.kind == shape.identKind) return unqualifiedCallNominal(callee, root, shape, resolved, method);
		if (callee.kind != fieldKind || callee.children.length != 1) return null;
		// The callee's own receiver is asked in RECEIVER mode: `tmp.trim()` on a `tmp: Null<String>`
		// looks `trim` up on `String`. A receiver that is ITSELF a call keeps today's answer — its
		// type arrives from `returnNominalOf`, already reduced to the bare nominal `Null`, with no
		// argument left to peel; recovering it needs a return-SOURCE lookup the index does not have.
		final receiver: Null<String> =
			expressionNominalWalk(callee.children[0], root, shape, declaredTypes, index, file, chain, seen, true);
		if (receiver == null) return staticCallNominal(callee.children[0], root, shape, resolved, method);
		final member: Null<String> = resolved.typing.members.returnNominalOf(receiver, method);
		return member ?? staticExtensionNominal(receiver, method, chain, resolved, file);
	}

	/**
	 * The return nominal a STATIC EXTENSION gives at `<recv>.<method>(…)`, where `recv` carries the type `receiver` — what
	 * the typing service binds there (`StaticExtensions.binding`) on the declaration `receiver` names in `file`: a member of
	 * the receiver's type binds first (verified against the compiler: under `using E`, a `d.tag()` on a `D` declaring
	 * `tag():Void` binds the MEMBER and errors as `Void should be Dynamic`, never `E.tag(d:D):String`), then the type's own
	 * and inherited `@:using`, then the file's `using`s in the compiler's order, each candidate's first parameter unified
	 * with the receiver and one that rejects it passed over. The bound member's written return, or null where the service
	 * proves no binding or the member writes none.
	 *
	 * Deliberately unreachable in SHALLOW mode: `chain` is the opt-in every deep arm sits behind, and this one carries the
	 * same obligation as its siblings — it resolves not merely MORE but type-CORRECTLY.
	 */
	private static function staticExtensionNominal(
		receiver: String, method: String, chain: Null<ChainTypeContext>, index: SymbolIndex, file: String
	): Null<String> {
		final fi: Null<FileInfo> = chain == null ? null : index.fileInfo(file);
		final start: Null<ResolvedType> = fi == null ? null : index.refs.resolveStartType(receiver, file);
		final declared: Null<HostedMembers> = fi == null || start == null ? null : index.typing.extensions.binding(fi, start, method);
		return declared?.members[0].returnNominal;
	}

	/**
	 * `valueTypeNominal`'s deep-mode twin: `valueTypeSourceDeep`'s written type source, reduced to
	 * its outer nominal; with no source, the type a construction makes — the node itself, or the one
	 * initialising the local it reads (`initializingConstruction`).
	 *
	 * `asReceiver` peels a member-TRANSPARENT wrapper off first (`Null<String>` -> `String`), and is
	 * set ONLY where the answer is about to seed a member lookup. It is deliberately NOT the default:
	 * an expression's own nominal is what a consumer reads to decide what is legal to DO with the
	 * value, and `Null<Int>` is not `Int` there. `null` is not a value `<` orders, and what the raw
	 * comparison DOES with it is TARGET-SPECIFIC: `null > 0` is `false` on js and `true` on `-cpp`.
	 */
	private static function valueNominalDeep(
		node: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Map<Int, String>, chain: ChainTypeContext,
		index: Null<SymbolIndex>, file: String, seen: Array<Int>, asReceiver: Bool = false
	): Null<String> {
		final source: Null<String> = valueTypeSourceDeep(node, root, shape, declaredTypes, chain, index, file, seen);
		return if (source == null)
			constructedNominal(initializingConstruction(node, root, shape, chain.declaredTypeSources), shape)
		else if (asReceiver)
			outerNominalOf(
				memberLookupReceiverSource(source, shape.memberTransparentWrapperTypeNames ?? [], chain.typeSyntax), chain.typeSyntax
			)
		else
			outerNominalOf(source, chain.typeSyntax);
	}

	/**
	 * The nominal a construction `new T(…)` makes: the type it writes, by its simple name — whatever type arguments it passes
	 * or infers, so it has no SOURCE answer (`new Box(item)` is a `Box<Item>` nothing here spells). Null for any other node.
	 */
	private static function constructedNominal(node: QueryNode, shape: RefShape): Null<String> {
		final written: Null<String> = node.kind == shape.newExprKind ? node.name : null;
		return written == null ? null : SourceText.lastSegment(written);
	}

	/**
	 * The construction a local written with no type holds, for an identifier reading one — followed through the locals
	 * initialised by one another (`final b = a`): Haxe infers the local's type from its initializer
	 * (`localInitializer`), and the source walk types no construction. Any other node is itself; one whose initializer
	 * chain ends in no construction answers that last node, which `constructedNominal` then types as nothing.
	 */
	private static function initializingConstruction(
		node: QueryNode, root: QueryNode, shape: RefShape, annotations: Map<Int, String>
	): QueryNode {
		var held: QueryNode = node;
		while (held.kind == shape.identKind) {
			final init: Null<QueryNode> = localInitializer(held, root, shape, annotations);
			if (init == null) return held;
			held = init;
		}
		return held;
	}

	/**
	 * The return type every declaration of the method `method` on `typeName` writes, as written — null when they disagree,
	 * when one writes none, when it names a type parameter of the method or of its declaring type (which the call binds), or
	 * when `typeName` declares no such method directly (an inherited one returns through its supertype's arguments).
	 */
	private static function returnSourceOf(index: SymbolIndex, typeName: String, method: String): Null<String> {
		var found: Null<String> = null;
		final declared: Array<MemberDeclaration> = index.typing.members.memberDeclarationsOf(typeName, method);
		for (d in declared) {
			final params: Array<String> = d.type.typeParamNames.concat(d.member.typeParamNames);
			// as the compiler reads it where it is written: a reference leaving arguments out names their defaults
			final returned: Null<String> = d.member.returnSource;
			final written: Null<String> = returned == null
				? null
				: index.typing.ancestors.completed(returned, d.file, d.member.declFrom, params);
			if (written == null || found != null && written != found || CallGraphNames.mentionsTypeName(written, params, index.typeSyntax))
				return null;
			found = written;
		}
		return found;
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
		if (shape.identKind == null || shape.fieldAccessKind == null) return null;
		final c: IndexTyping = {
			root: root,
			shape: shape,
			declaredTypes: declaredTypes,
			chain: chain,
			index: index,
			file: file,
			seen: seen
		};
		return TypingService.typeWalk(node, shape, INDEX_HOST, c);
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
	 * The written ELEMENT type source a `for` binder carries, for a binding `declaredTypes` has no
	 * entry for: the loop header declares no `:Type`, so the element type can only be read off the
	 * ITERABLE's own declared type through `RefShape.iterationElementTypeParams`.
	 *
	 * Every gate here fails closed (null = the caller keeps its conservative branch):
	 *
	 *  - The walk's cycle guard (`TypingHost.reading`, `c.seen` here) stops the recursion. The iterable is
	 *    a CHILD of the loop node, so in `for (x in x)` the iterable's `x` resolves right back to the
	 *    binder and the walk would never terminate.
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
	private static function forBindingElementTypeSource(bindingFrom: Int, c: IndexTyping): Null<String> {
		final shape: RefShape = c.shape;
		final kinds: Null<Array<String>> = shape.iterationBindingKinds;
		final elementParams: Null<Map<String, Int>> = shape.iterationElementTypeParams;
		if (kinds == null || elementParams == null) return null;
		final valueBinderKinds: Array<String> = shape.iterationValueBinderKinds ?? [];
		final hit: Null<LoopBinderHit> = loopBinderAt(c.root, bindingFrom, kinds, valueBinderKinds);
		if (hit == null) return null;
		final loop: QueryNode = hit.loop;
		if (!hit.isValueBinder && hasIterationValueBinder(loop, valueBinderKinds)) return null;
		final iterable: Null<QueryNode> = iterationIterable(loop, valueBinderKinds);
		if (iterable == null) return null;
		final iterableSource: Null<String> = TypingService.typeWalk(iterable, shape, INDEX_HOST, c);
		return iterableSource == null ? null : elementTypeSourceOf(iterableSource, elementParams, [], c.chain.typeSyntax);
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

	/**
	 * Whether `node` is a bare identifier whose binding some `Write` in the file reaches — the
	 * reassignment `valueIterationProvable` refuses. An identifier the resolver cannot bind is a
	 * field reached through `this`, which neither loop form re-reads.
	 */
	private static function reassignedLocal(node: QueryNode, root: QueryNode, shape: RefShape): Bool {
		final name: Null<String> = node.name;
		final span: Null<Span> = node.span;
		if (node.kind != shape.identKind || name == null || span == null) return false;
		final hits: Array<RefHit> = Refs.find(name, root, shape);
		final own: Null<RefHit> = hits.find(h -> h.span.from == span.from && h.span.to == span.to);
		final bound: Null<Span> = own?.bindingSpan;
		return bound != null
			&& hits.exists(h -> h.kind == RefKind.Write && h.bindingSpan?.from == bound.from && h.bindingSpan?.to == bound.to);
	}

	/**
	 * The self reference `node` for the index host: the enclosing type by its name, or — inside a type whose `this` is its
	 * underlying value (`RefShape.underlyingThisTypeKinds`: `abstract A(T)`, where 4.3.7 types `this` as `T`) — the
	 * underlying type as its declaration writes it. Null outside a type, and for such a type whose underlying type is not
	 * written readably.
	 */
	private static function indexSelf(node: QueryNode, c: IndexTyping): Null<String> {
		final span: Null<Span> = node.span;
		final decl: Null<TypeDeclMatch> = span == null ? null : TypeResolver.enclosingTypeDecl(c.root, span);
		if (decl == null) return null;
		if (!(c.shape.underlyingThisTypeKinds ?? []).contains(decl.kind)) {
			// a generic type's `this` is the type applied to its own parameters (4.3.7: `Box<T>` inside `Box<T>`)
			final params: Array<String> = c.index?.refs.findDeclaredType(c.file, decl.name)?.type.typeParamNames ?? [];
			return params.length == 0 ? decl.name : '${decl.name}<${params.join(', ')}>';
		}
		final underlying: Null<Span> = decl.declNode.type?.span;
		return underlying == null ? null : c.chain.source.substring(underlying.from, underlying.to);
	}

	/**
	 * The type a read of the binding at `from` carries for the index host, its written type `written`: an optional
	 * parameter's (`?x: T`, a node of `RefShape.optionalParamKind` starting at `from`) wrapped as an optional value
	 * (`optionalValueType`), since 4.3.7 types a read of it as `Null<T>` with or without a default. Any other binding's as
	 * written — with the type arguments a reference in it leaves out written in (`AncestorTable.completed`: `b: Box` reads as
	 * `Box<Int>` for `class Box<T = Int>`), null when they cannot be. With no index, or for a written type that is not the
	 * whole text (`complete` false), nothing is completed.
	 */
	private static function boundType(from: Int, written: Null<String>, c: IndexTyping, complete: Bool): Null<String> {
		final kind: Null<String> = c.shape.optionalParamKind;
		// a written type the grammar does not read as one type (`#if lime Image #else Dynamic #end`) is no answer
		if (written == null || !answerableType(written, c.chain.typeSyntax)) return null;
		final index: Null<SymbolIndex> = c.index;
		final fi: Null<FileInfo> = index?.fileInfo(c.file);
		final full: Null<String> = !complete || index == null || fi == null
			? written
			: index.typing.ancestors.completed(written, fi, from, writtenTypeParams(fi));
		return if (full == null)
			null
		else if (kind != null && startsKindAt(c.root, from, kind))
			optionalValueType(full, c.shape.optionalValueTypeName, c.chain.typeSyntax)
		else
			full;
	}

	/**
	 * Every type parameter `fi` declares on a type or a member: a name the file may write for one rather than for a type
	 * (`AncestorTable.completed`'s scope).
	 */
	private static function writtenTypeParams(fi: FileInfo): Array<String> {
		return [
			for (t in fi.types) for (p in t.typeParamNames.concat([for (m in t.members) for (q in m.typeParamNames) q])) p
		];
	}

	/** Whether a node of `kind` starts at `from` under `node`, descending only into the nodes whose range holds `from`. */
	private static function startsKindAt(node: QueryNode, from: Int, kind: String): Bool {
		final span: Null<Span> = node.span;
		if (span != null && (from < span.from || from >= span.to)) return false;
		if (span != null && span.from == from && node.kind == kind) return true;
		return node.children.exists(child -> startsKindAt(child, from, kind));
	}

	/**
	 * A field access for the index host: a PATH (`pathOf`) walked from its root as one — the root typed by the walk, the
	 * members through `pathReceiverMemberTypeSource` with substitution, each link resolved where its member is declared
	 * and only then package-blind. Null for any other receiver, and with no index.
	 */
	private static function indexAccess(node: QueryNode, c: IndexTyping): Null<String> {
		final shape: RefShape = c.shape;
		final identKind: Null<String> = shape.identKind;
		final fieldKind: Null<String> = shape.fieldAccessKind;
		final index: Null<SymbolIndex> = c.index;
		final path: Null<Array<String>> = identKind == null || fieldKind == null ? null : pathOf(node, identKind, fieldKind);
		if (path == null || index == null) return null;
		var root: QueryNode = node;
		while (root.kind != identKind && root.children.length == 1) root = root.children[0];
		final rootSource: Null<String> = TypingService.typeWalk(root, shape, INDEX_HOST, c);
		return pathReceiverMemberTypeSource(path, rootSource, index, c.file, true, shape.memberTransparentWrapperTypeNames ?? []);
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


	/** `GrammarPlugin.typeSyntax` — how the deep mode reads a written type's wrapper and arguments. */
	final typeSyntax: TypeSyntaxReader;
}

/** The type a construction writes (`NominalTypes.writtenConstruction`). */
typedef WrittenConstruction = {
	/** The type's path as written (`pkg.Box`). */
	final path: String;

	/** The type arguments it writes, each verbatim; empty when the language infers them. */
	final args: Array<String>;

	/** `path` with its written arguments (`pkg.Box<Int, String>`), the arguments' source kept as written between them. */
	final text: String;
}

/** What the index host of `TypingService.typeWalk` reads with: the deep walk's arguments, `seen` its cycle guard. */
private typedef IndexTyping = {
	final root: QueryNode;
	final shape: RefShape;
	final declaredTypes: Map<Int, String>;
	final chain: ChainTypeContext;
	final index: Null<SymbolIndex>;
	final file: String;
	final seen: Array<Int>;
}
