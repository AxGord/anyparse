package anyparse.check;

import anyparse.check.Check.FixEdit;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberLookup.SupertypeProof;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * The ASCRIPTION arm of `avoid-dynamic`: a `Dynamic` PARAMETER whose every read states the type
 * it really holds is not a typing hole to report and leave alone — the ascription is the
 * signature written one level too deep, and moving it up is the same program with the type in
 * the place that checks the callers.
 *
 * The whole arm lives here: proving the finding is a parameter's WHOLE written type, proving
 * every read of it is an ascription to ONE type or a null comparison, proving no supertype declares
 * the method and no subtype redeclares it, proving the method is neither generic nor dispatched by
 * the compiler on its operands' types, and proving the ascribed type converts nothing — an abstract
 * with a `@:from` member would start running that member on each call site's static argument type,
 * where the raw `Dynamic` ran nothing.
 *
 * Two limits are accepted deliberately. Only `T`'s side of a conversion is examined: an argument
 * whose own static type declares `@:to T` begins converting at a call site that used to pass the
 * value untouched — but such a value was never a `T` at runtime, so the ascription this arm hoists
 * was already a type confusion and the signature only makes it visible. And whether every call site
 * still compiles is the compiler oracle's contract, blind as it is to the `#if` branches its defines
 * exclude, exactly as for every other risky signature rewrite here.
 *
 * Split out of `AvoidDynamic`, which keeps the primary rule and the local-narrowing autofix, the same
 * way the bag arm lives in `DynamicBag`.
 */
@:access(anyparse.check.AvoidDynamic)
@:nullSafety(Strict)
final class ParamAscription {

	/**
	 * The arm's verdict for one `Dynamic` finding — see `ParamVerdict` for what its two answers separate.
	 */
	public static function rewrite(
		tree: QueryNode, source: String, span: Span, shape: RefShape, dynName: String, castTargets: Map<Int, String>, symbols: SymbolIndex
	): ParamVerdict {
		final subject: Null<ParamSubject> = wholeDynamicParam(tree, span, shape, dynName);
		return subject == null ? { subject: false, edits: null } : {
			subject: true,
			edits: editsFor(subject, tree, source, shape, dynName, castTargets, symbols)
		};
	}

	/**
	 * The parameter whose WHOLE written type is the raw `Dynamic` at `span`, plus what the arm
	 * needs to reach its owner and its reads. Null for every other position and for every
	 * parameter a signature rewrite must not reach: a REST parameter (whose written type is the
	 * element's, not the binding's), an anonymous-structure field, and a lambda's or local
	 * function's parameter — only a type MEMBER function has a signature the index can reason
	 * about.
	 */
	private static function wholeDynamicParam(tree: QueryNode, span: Span, shape: RefShape, dynName: String): Null<ParamSubject> {
		final param: Null<QueryNode> = AvoidDynamic.innermostContaining(tree, span, shape.paramKinds ?? []);
		if (param == null || param.kind == shape.restParamKind) return null;
		final wrapped: Null<Bool> = dynamicIsWholeParamType(param, span, shape, dynName);
		final name: Null<String> = param.name;
		final paramSpan: Null<Span> = param.span;
		final written: Null<QueryNode> = param.type;
		final writtenSpan: Null<Span> = written?.span;
		if (wrapped == null || name == null || paramSpan == null || writtenSpan == null) return null;
		final chain: Null<Array<QueryNode>> = ancestryOf(tree, param);
		if (chain == null || chain.length < 3) return null;
		final path: Array<QueryNode> = chain;
		// `ancestryOf` ends at the parameter, so its parent is the declaring function.
		final owner: QueryNode = path[path.length - 2];
		final members: Array<String> = shape.memberDeclKinds ?? [];
		return (shape.functionKinds ?? []).filter(k -> members.contains(k)).contains(owner.kind) ? {
			owner: owner,
			chain: path.slice(0, path.length - 1),
			name: name,
			bindFrom: paramSpan.from,
			typeSpan: writtenSpan,
			wrapped: wrapped
		} : null;
	}

	/**
	 * Whether the raw `Dynamic` at `span` is the WHOLE written type of `param`: false when it IS
	 * the type, true when it is the sole argument of an explicit nullable wrapper that is the
	 * type, and null when it is neither — a container's type argument, an arrow's operand, a
	 * partial match.
	 */
	private static function dynamicIsWholeParamType(param: QueryNode, span: Span, shape: RefShape, dynName: String): Null<Bool> {
		final written: Null<QueryNode> = param.type;
		final writtenSpan: Null<Span> = written?.span;
		if (written == null || writtenSpan == null) return null;
		final head: Null<String> = written.name;
		if (head == dynName && writtenSpan.from == span.from && writtenSpan.to == span.to) return false;
		// A raw-dynamic HEAD is refused rather than treated as a wrapper: `Dynamic<T>` is the very
		// thing this rule exists to remove, so preserving it around the ascribed type proves nothing.
		if (head == null || head == dynName || written.children.length != 1 || !(shape.nullableWrapperTypeNames ?? []).contains(head))
			return null;
		final argument: QueryNode = written.children[0];
		final argumentSpan: Null<Span> = argument.span;
		return argument.name == dynName && argumentSpan != null && argumentSpan.from == span.from && argumentSpan.to == span.to
			? true
			: null;
	}

	/**
	 * The edits retyping `subject` to the type its reads ascribe and unwrapping every one of
	 * those ascriptions, or null at the first gate that fails. The ascribed type must be ONE type
	 * across every read, and must resolve to a conversion-free declaration.
	 */
	private static function editsFor(
		subject: ParamSubject, tree: QueryNode, source: String, shape: RefShape, dynName: String, castTargets: Map<Int, String>,
		symbols: SymbolIndex
	): Null<Array<FixEdit>> {
		final host: Null<TypeDeclMatch> = ownerAllowsSignatureRewrite(subject, shape, source, symbols);
		// The signature edit replaces the WHOLE written type, so a comment anywhere inside it is text
		// the replacement would delete.
		if (host == null || CheckScan.hasCommentMarker(source, subject.typeSpan.from, subject.typeSpan.to)) return null;
		final pinned: Null<ParamReads> = paramReads(subject, tree, shape, castTargets);
		if (pinned == null || pinned.ascriptions.length == 0) return null;
		final written: String = pinned.types[0];
		final canonical: String = TypeResolver.stripWs(written);
		for (target in pinned.types) if (TypeResolver.stripWs(target) != canonical) return null;
		// The conversion question is about the type INSIDE an explicit nullable wrapper: the wrapper is
		// transparent, so it is the inner type whose `@:from` a call site would start running. The
		// WRITTEN path is kept — a dotted one resolves as a path, not by its last segment. A name the
		// enclosing type declares as a type PARAMETER is not a type at all (the method's own are
		// handled by refusing a generic method outright).
		final path: String = headOfTypeSource(withoutNullableWrapper(written, shape));
		if (
			!AvoidDynamic.isNominalName(path) || !AvoidDynamic.acceptableType(path, dynName) || typeParameterOf(host, path, symbols)
			|| !symbols.resolvesToConversionFreeType(path)
		)
			return null;
		final edits: Null<Array<FixEdit>> = unwrapEdits(pinned, source);
		if (edits == null) return null;
		// A parameter the source declared nullable, or one a read compares with null, must keep
		// admitting it; every other one takes the ascribed type verbatim.
		final declared: Null<String> = subject.wrapped || pinned.nullCompared ? wrappedNullable(written, shape) : written;
		if (declared == null) return null;
		// Re-bind to a non-null local — Strict null-safety takes a struct literal's field type from
		// the declared type, not the narrowed one.
		final text: String = declared;
		final unwraps: Array<FixEdit> = edits;
		// The WHOLE written type is replaced, not just the `Dynamic` token: a `Null<Dynamic>` whose
		// ascription is itself `Null<…>` would otherwise nest one wrapper inside the other.
		unwraps.push({ span: subject.typeSpan, text: text });
		return unwraps;
	}

	/**
	 * One edit per ascription, replacing it with its operand's text — or null when a comment sits
	 * in a region the replacement deletes (the `(` head or the ` : T)` tail), which is content no
	 * replacement text carries.
	 */
	private static function unwrapEdits(reads: ParamReads, source: String): Null<Array<FixEdit>> {
		final edits: Array<FixEdit> = [];
		for (node in reads.ascriptions) {
			final nodeSpan: Null<Span> = node.span;
			final operandSpan: Null<Span> = node.children[0].span;
			if (nodeSpan == null || operandSpan == null) return null;
			// Re-bind to non-null locals — Strict null-safety takes a struct literal's field type from
			// the declared type, not the narrowed one.
			final ascription: Span = nodeSpan;
			final operand: Span = operandSpan;
			if (
				CheckScan.hasCommentMarker(source, ascription.from, operand.from)
				|| CheckScan.hasCommentMarker(source, operand.to, ascription.to)
			)
				return null;
			edits.push({ span: ascription, text: source.substring(operand.from, operand.to) });
		}
		return edits;
	}

	/**
	 * Whether `subject`'s owning method may have a parameter type rewritten: it is not an
	 * `override`, a `dynamic` or a macro member, it has a real body, and its enclosing type is
	 * neither an interface nor extern. An INSTANCE method must additionally have an EMPTY
	 * override family — a subtype redeclaring it makes the signature a contract across files —
	 * and a family the index cannot prove (`null`) is refused with it.
	 */
	private static function ownerAllowsSignatureRewrite(
		subject: ParamSubject, shape: RefShape, source: String, symbols: SymbolIndex
	): Null<TypeDeclMatch> {
		final chain: Array<QueryNode> = subject.chain;
		final owner: QueryNode = subject.owner;
		final method: Null<String> = owner.name;
		final run: LeadingRun = leadingRunOf(chain[chain.length - 2], owner, shape);
		final mods: Array<String> = run.kinds;
		final dispatched: Array<String> = shape.dispatchedMemberMetaNames ?? [];
		// A compiler-DISPATCHED member is selected by the static type of its operands, at sites that
		// name neither it nor its type, so its parameter type is the dispatch key and cannot move.
		final pinnedByItsDeclaration: Bool = carries(mods, shape.overrideModifierKind) || carries(mods, shape.dynamicModifierKind)
			|| carries(mods, shape.macroModifierKind) || run.metas.exists(meta -> dispatched.contains(meta));
		if (method == null || pinnedByItsDeclaration || declaresTypeParameters(owner, shape, source)) return null;
		// A bodyless member is an interface method or an `abstract` one: the signature is a contract
		// the implementors already match. Haxe admits no other bodiless member, so this gate alone
		// carries what an owner-kind test would have said.
		final bodyKinds: Array<String> = shape.functionBodyKinds ?? [];
		final body: Null<QueryNode> = owner.children.find(c -> bodyKinds.contains(c.kind));
		if (body == null || body.kind == shape.noBodyKind) return null;
		final owning: Null<TypeDeclMatch> = enclosingTypeOf(chain);
		if (owning == null) return null;
		final host: TypeDeclMatch = owning;
		if (carries(mods, shape.staticModifierKind)) return host;
		// Downward: a subtype redeclaring the method makes the signature a family contract. Upward: a
		// supertype or implemented interface declaring the name pins it from above, and there a family
		// scan looks in the wrong direction entirely. An ancestor the closure cannot reach proves neither.
		final family: Null<Array<OverrideFamilyMember>> = symbols.subtypes.overrideFamilyOf(host.name, method);
		return family != null && family.length == 0 && symbols.members.supertypeMemberProof(host.name, method) == SupertypeProof.Absent
			? host
			: null;
	}

	/** The innermost type declaration of the root-to-owner `chain`, with its index in it, or null when the chain holds none. */
	private static function enclosingTypeOf(chain: Array<QueryNode>): Null<TypeDeclMatch> {
		var at: Int = chain.length - 2;
		while (at >= 0) {
			final found: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(chain[at]);
			if (found != null) return found;
			at--;
		}
		return null;
	}

	/**
	 * Whether `written` names a type PARAMETER of the enclosing type rather than a type. Answered only
	 * when the owner resolves to ONE indexed declaration — an unresolved owner makes this no proof
	 * either way, and the refusal it would otherwise cause belongs to no gate: a type name that merely
	 * collides with some other file's is still a type here.
	 */
	private static function typeParameterOf(host: TypeDeclMatch, written: String, symbols: SymbolIndex): Bool {
		final decls: Array<TypeDeclInfo> = symbols.refs.declsNamed(host.name);
		return decls.length == 1 && decls[0].typeParamNames.contains(written);
	}

	/**
	 * Whether the owner method declares type parameters of its own. The projection carries a type
	 * parameter's CONSTRAINT as a child and its NAME not at all, so an ascription to a bare `T` cannot
	 * be told from one to a type called `T`; the whole generic method is refused rather than resolved
	 * against the wrong declaration. Read from the header text — `function <name><…>` up to the
	 * parameter list — and an unreadable header counts as generic.
	 */
	private static function declaresTypeParameters(owner: QueryNode, shape: RefShape, source: String): Bool {
		final span: Null<Span> = owner.span;
		final first: Null<QueryNode> = owner.children.find(c -> (shape.paramKinds ?? []).contains(c.kind));
		final firstSpan: Null<Span> = first?.span;
		final header: Null<String> = span != null && firstSpan != null ? source.substring(span.from, firstSpan.from) : null;
		// An unreadable header counts as generic.
		return header == null || header.indexOf('<') >= 0;
	}

	/**
	 * Every read of `subject`'s parameter, classified — or null the moment one is neither an
	 * ascription `(p : T)` nor a null comparison. A write, a member access, a call argument, a
	 * `return`: each either leaves the value's real type unproven or hands it to a typed seam the
	 * retype would change, so the whole parameter is refused rather than that occurrence skipped.
	 */
	private static function paramReads(
		subject: ParamSubject, tree: QueryNode, shape: RefShape, castTargets: Map<Int, String>
	): Null<ParamReads> {
		final targetKeys: Map<String, Bool> = AvoidDynamic.occurrenceKeysOf(subject.name, subject.bindFrom, tree, shape);
		final reads: ParamReads = { ascriptions: [], types: [], nullCompared: false };
		return collectParamReads(tree, null, subject.name, shape, castTargets, targetKeys, reads) ? reads : null;
	}

	/** Walk `node` recording every resolved occurrence of `name` into `reads`; false the moment one disqualifies. */
	private static function collectParamReads(
		node: QueryNode, parent: Null<QueryNode>, name: String, shape: RefShape, castTargets: Map<Int, String>,
		targetKeys: Map<String, Bool>, reads: ParamReads
	): Bool {
		final s: Null<Span> = node.span;
		if (
			node.kind == shape.identKind && node.name == name && s != null && targetKeys.exists('${s.from}:${s.to}')
			&& !recordParamRead(node, parent, shape, castTargets, reads)
		)
			return false;
		return node.children.foreach(child -> collectParamReads(child, node, name, shape, castTargets, targetKeys, reads));
	}

	/** Record ONE occurrence — an ascription or a null comparison — into `reads`; false for every other shape. */
	private static function recordParamRead(
		occurrence: QueryNode, parent: Null<QueryNode>, shape: RefShape, castTargets: Map<Int, String>, reads: ParamReads
	): Bool {
		if (parent == null) return false;
		final host: QueryNode = parent;
		final hostSpan: Null<Span> = host.span;
		if (host.kind == shape.checkTypeKind && host.children.length == 1 && hostSpan != null) {
			final target: Null<String> = TypeResolver.castTargetWithin(hostSpan, castTargets);
			if (target == null) return false;
			reads.ascriptions.push(host);
			reads.types.push(target);
			return true;
		}
		if (!isNullComparison(host, occurrence, shape)) return false;
		reads.nullCompared = true;
		return true;
	}

	/** Whether `host` compares `occurrence` with the null literal — the one read that says nothing about the value's type. */
	private static function isNullComparison(host: QueryNode, occurrence: QueryNode, shape: RefShape): Bool {
		final nullKind: Null<String> = shape.nullLiteralKind;
		return nullKind != null && host.children.length == 2 && (host.kind == shape.eqKind || host.kind == shape.notEqKind)
			&& (host.children[0] == occurrence ? host.children[1] : host.children[0]).kind == nullKind;
	}

	/**
	 * `typeSource` inside the explicit nullable wrapper `nullableWrapperName` names, or unchanged when
	 * its head already IS that wrapper; null when the grammar names none. A parameter a read compares
	 * with null must keep admitting it, and must not gain a second wrapper doing so.
	 */
	private static function wrappedNullable(typeSource: String, shape: RefShape): Null<String> {
		final wrapper: Null<String> = nullableWrapperName(shape);
		if (wrapper == null) return null;
		final name: String = wrapper;
		return TypeResolver.stripWs(headOfTypeSource(typeSource)) == name ? typeSource : '$name<$typeSource>';
	}

	/**
	 * The language's explicit nullable wrapper, or null when the grammar names none unambiguously: the
	 * ONE name that both keeps a value nullable under a null-safety meta and is transparent to a member
	 * lookup — Haxe's `Null`, whose `from T to T` is exactly that pair of facts.
	 */
	private static function nullableWrapperName(shape: RefShape): Null<String> {
		final nullable: Array<String> = shape.nullableWrapperTypeNames ?? [];
		final names: Array<String> = (shape.memberTransparentWrapperTypeNames ?? []).filter(n -> nullable.contains(n));
		return names.length == 1 ? names[0] : null;
	}

	/** `typeSource` with a leading explicit nullable wrapper peeled off, or unchanged when it carries none. */
	private static function withoutNullableWrapper(typeSource: String, shape: RefShape): String {
		final wrapper: Null<String> = nullableWrapperName(shape);
		return wrapper == null ? typeSource : NominalTypes.unwrapNullable(TypeResolver.stripWs(typeSource), [wrapper]);
	}

	/** The nominal head of a written type source — its text before any type-argument list. */
	private static function headOfTypeSource(typeSource: String): String {
		final lt: Int = typeSource.indexOf('<');
		return lt < 0 ? typeSource : typeSource.substring(0, lt);
	}

	/** The root-to-`target` node chain, or null when `target` is not in `root`'s tree. */
	private static function ancestryOf(root: QueryNode, target: QueryNode): Null<Array<QueryNode>> {
		final path: Array<QueryNode> = [];
		function walk(node: QueryNode): Bool {
			path.push(node);
			if (node == target) return true;
			for (child in node.children) if (walk(child)) return true;
			path.pop();
			return false;
		}
		return walk(root) ? path : null;
	}

	/**
	 * The kinds of the modifier run immediately before `node` among `parent`'s children. A
	 * modifier projects as a childless, nameless sibling, so anything carrying a child or a name
	 * ends the run — the same reading `SymbolIndexBuilder`'s member walk makes forward.
	 */
	private static function leadingRunOf(parent: QueryNode, node: QueryNode, shape: RefShape): LeadingRun {
		final kids: Array<QueryNode> = parent.children;
		final prefixes: Array<String> = shape.metadataNamePrefixes ?? [];
		final kinds: Array<String> = [];
		final metas: Array<String> = [];
		var i: Int = kids.indexOf(node) - 1;
		while (i >= 0) {
			final sibling: QueryNode = kids[i];
			final named: Null<String> = sibling.name;
			// Re-bind to a non-null local — Strict null-safety does not carry a narrowing into a closure.
			final name: String = named ?? '';
			if (named != null && prefixes.exists(prefix -> name.startsWith(prefix)))
				metas.push(name);
			else if (sibling.children.length == 0 && named == null)
				kinds.push(sibling.kind);
			else
				break;
			i--;
		}
		return { kinds: kinds, metas: metas };
	}

	/** Whether the modifier run `mods` carries `kind` — false for a grammar that names no such modifier. */
	private static function carries(mods: Array<String>, kind: Null<String>): Bool {
		return kind != null && mods.contains(kind);
	}

}

/**
 * The arm's verdict for one `Dynamic` finding: whether the finding is this arm's SUBJECT at all,
 * and the edits when it is and every gate passed.
 *
 * The two answers are separate because the ledger's are: a finding that is not a parameter belongs
 * to no arm, while one that is and was refused has a reason of its own. Folded into a bare
 * `Null<Array<…>>` a reader chasing the second would look for a gate that never ran.
 */
typedef ParamVerdict = {
	final subject: Bool;
	final edits: Null<Array<FixEdit>>;
};

/** The modifier kinds and metadata names of the annotation run written immediately before a declaration. */
private typedef LeadingRun = {
	final kinds: Array<String>;
	final metas: Array<String>;
};

/** The parameter a `Dynamic` finding sits on, plus what the arm needs to reach its owner and its reads. */
private typedef ParamSubject = {
	/** The type-member function declaring the parameter. */
	final owner: QueryNode;

	/** The root-to-`owner` node chain — the modifier runs and the enclosing type declaration are read off it. */
	final chain: Array<QueryNode>;
	final name: String;

	/** The parameter's binding offset: the `from` its resolved reads carry. */
	final bindFrom: Int;

	/** The span of the WHOLE written type — what the signature edit replaces. */
	final typeSpan: Span;

	/** Whether the `Dynamic` sits INSIDE an explicit nullable wrapper that is the rest of the written type. */
	final wrapped: Bool;
};

/** The classified reads of a `Dynamic` parameter — built only when every one of them is an ascription or a null comparison. */
private typedef ParamReads = {
	/** The ascription nodes the fix unwraps to their operand. */
	final ascriptions: Array<QueryNode>;

	/** The written ascribed type source of each, parallel to `ascriptions`. */
	final types: Array<String>;

	/** Whether some read compares the parameter with null — the retyped signature must still admit it. */
	var nullCompared: Bool;
};
