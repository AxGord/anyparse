package anyparse.check;

import anyparse.query.BoolExprShape;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeNameBinding.Tier;

using Lambda;

/**
 * What a check may assume about ONE operator occurrence: whether the operator it is looking at
 * is the language's own, a type's overload of it, or something the analysis cannot pin.
 *
 * The three answers are not a confidence ranking, they are three different ACTIONS. `Builtin`
 * licenses the rewrite. `Overloaded` says the rewrite would mean something else — and, for the
 * rules that read this, that the FINDING itself is wrong (`dir + 'pages'` is a path join, not a
 * string concatenation the segments of which can be merged), so the site is best left unreported.
 * `Unproven` says the finding is almost certainly right and the PROOF is missing, which is the
 * shape `fold-adjacent-string-literals` already reports without fixing for its macro gate.
 */
enum OperatorVerdict {

	/** No type reachable at this occurrence can overload the operator — it is the language's own. */
	Builtin;

	/** An operand resolves to `typeName`, which declares an overload of this operator. */
	Overloaded(typeName: String);

	/**
	 * Some type in the resolution scope overloads this operator and an operand's type could not
	 * be resolved, so nothing rules out that operand being one of them.
	 */
	Unproven;

}

/**
 * The shared "is this operator the BUILT-IN one" predicate every rule that rewrites an
 * expression containing an operator consults, so that question is answered once rather than
 * assumed once per rule.
 *
 * ## The defect class it exists for
 *
 * A rewrite that moves, drops or flips an operator silently assumes the operator is the
 * language's. In Haxe an `abstract` may overload it (`@:op(A + B)`), and such a type usually
 * carries `@:from` / `@:to` as well — so the rewritten program still COMPILES and only a
 * runtime test tells the difference. The measured instance: `pony.fs.Dir` declares
 * `@:op(A + B) addString(a: String)` that inserts a path separator, so `dir + 'pages'` is
 * `/root/pages` while the folded `'${dir}pages'` is `/rootpages` (compile-and-run verified on
 * `--interp`, Haxe 4.3.7). The same shape reaches the negation family: an abstract declaring
 * `@:op(A == B)` and NOT `@:op(A != B)` makes `!(a == b)` and `a != b` disagree — verified
 * `true` vs `true` where `!(a == b)` is `false` — because Haxe does not derive the second
 * overload from the first, it falls back to comparing the underlying values.
 *
 * ## Two questions, asked in this order
 *
 * 1. **Does anything in the resolution scope overload this operator at all?** The index records
 *    every member's operator annotations (`SymbolIndex.MemberInfo.operatorOverloads`), so this
 *    is a map lookup. In a tree where the answer is no — which is most trees, and every tree
 *    before someone writes the first `@:op` — every occurrence is `Builtin` and no operand type
 *    is ever resolved. That is what keeps the gate free.
 * 2. **Could an operand of THIS occurrence be one of those types?** Each operand's declared type
 *    is BOUND in the file that writes it, tier by tier in the compiler's order (`typingFor`), and
 *    the answer is `Overloaded` for a declaration that declares the pattern, `Builtin` for one
 *    that provably cannot, and `Unproven` for everything else — an operand no binding types
 *    included, since the whole point is that an overloading type does not look different from
 *    any other.
 *
 * ## Two subtleties, both load-bearing
 *
 * **The CHAIN, not the pair.** `x + 'a' + 'b'` parses as `(x + 'a') + 'b'`, so folding the tail
 * is only sound if `x + 'a'` is already a String — which is a question about `x`. `verdictFor`
 * therefore flattens every same-kind child before classifying, and one bad operand condemns the
 * whole chain. Skipping that is how `cfg.to + f.shortName + '_$WEBP' + ext` became
 * `'${cfg.to + f.shortName}_$WEBP$ext'`.
 *
 * **Which operator was SELECTED, not whether the type looks right.** `Dir` and `Unit` declare
 * `@:from String` / `@:to String`, so by type they read almost exactly like strings. The
 * question this answers is never "is this operand String-ish" but "does this operand's type
 * declare an overload the compiler would pick" — which is why the evidence is the declaration
 * and not the shape of the value.
 *
 * ## Where the answer is a REFUSAL and where it is silence
 *
 * That is the caller's decision, not this class's: the same `Unproven` means "report without
 * fixing" to a layout rule and "leave the site alone" to a rule whose finding IS the rewrite.
 * What this class guarantees is only that `Builtin` is a proof.
 *
 * ## Who asks, and who does not
 *
 * Asking is per rule, and a rule that does NOT ask says why here rather than by omission:
 *
 *  - `fold-adjacent-string-literals` asks in BOTH directions (merge and split) — the measured
 *    breakage, and the only rule whose finding is discarded on `Overloaded` yet kept, fix
 *    dropped, on `Unproven`: a layout finding can still be true without the proof.
 *  - `simplify-negated-compound` and `invert-negated-if-else` ask because they REBUILD or DROP
 *    an operator spine; there the finding IS the rewrite, so anything short of `Builtin` leaves
 *    the site unreported.
 *  - `join-string-append` asks too: the join turns N appends into ONE, so an overloaded `+=`
 *    runs its body once instead of N times (`r += 'a'; r += 'b'` is `root/a/b`, the joined
 *    `r += 'a' + 'b'` is `root/ab`). Its own type gate cannot catch that — a string-literal
 *    term is exactly what makes such a run look String-typed.
 *  - `double-negation` asks for the same reason one size smaller: `!!x` is redundant only while
 *    `!` is an involution.
 *  - `comparison-to-boolean` does NOT ask, and must not be handed the gate as dead code: it
 *    already demands the compared operand be a PROVEN `Bool`, which no abstract declaring
 *    `@:op(A == B)` can be (an abstract with `to Bool` resolves under its own name). Widen that
 *    proof and this becomes reachable — add the gate then, with a fixture that fires.
 *  - `prefer-index-access` and `redundant-tostring` look like the same defect under a
 *    different annotation and MEASURE clean, each for its own reason rather than by luck.
 *    `prefer-index-access` demands POSITIVE proof that the receiver is the language `Map`
 *    abstract, so a user type carrying `@:arrayAccess` beside a `get(k)` is never a candidate.
 *    `redundant-tostring` already refuses a
 *    `+` receiver that is not a class, and in every stringifying context a declared `toString`
 *    wins over an `@:to String` — compile-and-run on Haxe 4.3.7 `--interp` with an
 *    `abstract Tag(String)` declaring both: interpolation, concatenation, `Std.string` and the
 *    direct call all print the METHOD answer.
 *  - a verdict is per BINDING, never per simple name: `import far.Tag` beside an indexed class
 *    `other.Tag` names the import, so a tier that could bind the name to something the index
 *    does not hold answers `Unproven` rather than falling through to the class. Worth knowing
 *    before writing a fixture: a member reached only through a supertype, or through a receiver
 *    no binding types, has no written type here, and only the compiler's facts can vouch for it.
 *
 * ## Grammar-agnostic
 *
 * Everything language-specific arrives through `RefShape`: `operatorOverloadMetaName` (the
 * annotation a type overloads an operator with), `literalTypeNames` (the type of a literal
 * operand, and the built-in scalar names), `nonNullableTypeNames` (the rest of them),
 * `parenKind` and `underlyingThisTypeKinds`. No operator SYMBOL appears anywhere: an overload
 * is recorded and asked about by the node KIND its annotation argument projects as, so a check
 * asks with the kind it is already holding. A grammar leaving the annotation seam unset makes
 * `of` return null, and every caller then behaves exactly as it did before this class existed.
 */
@:nullSafety(Strict)
final class OperatorSelection {

	/** Per-file operand binders, built on first demand — see `typingFor`. */
	private final _typingByFile: Map<String, (QueryNode) -> Tier> = [];

	/** The plugin whose resolution scope the overload table is read from. */
	private final _plugin: GrammarPlugin;

	/** The files to index when the plugin carries no resolution scope of its own. */
	private final _files: Array<{ file: String, source: String }>;

	private final _shape: RefShape;

	/** Literal kinds whose value's type is built in, so such an operand can never carry an overload. */
	private final _literalKinds: Array<String>;

	/** The type names the grammar declares built in — a scalar or the string type. */
	private final _builtinTypeNames: Array<String>;

	/** The declaration kinds that may carry an operator overload at all (`RefShape.underlyingThisTypeKinds`). */
	private final _abstractKinds: Array<String>;

	/** The declaration kinds none of which may carry an operator overload: classes, interfaces, enums. */
	private final _plainKinds: Array<String>;

	/** The parenthesis kind, unwrapped before an operand is classified. */
	private final _parenKind: Null<String>;

	/** Every resolution scope a declaration may come from; null until first demand — see `indexes`. */
	private var _indexes: Null<Array<SymbolIndex>> = null;

	/** Operator node KIND -> the names of the types that overload it; null until first demand. */
	private var _declarers: Null<Map<String, Array<String>>> = null;

	private function new(plugin: GrammarPlugin, files: Array<{ file: String, source: String }>, shape: RefShape) {
		_plugin = plugin;
		_files = files;
		_shape = shape;
		final literalTypeNames: Map<String, String> = shape.literalTypeNames ?? [];
		_literalKinds = [for (kind in literalTypeNames.keys()) kind];
		_builtinTypeNames = OperandBinder.builtinNamesOf(shape);
		_abstractKinds = shape.underlyingThisTypeKinds ?? [];
		_plainKinds = (shape.classDeclKinds ?? []).concat(shape.interfaceDeclKinds ?? []).concat(shape.runtimeTaggedTypeKinds ?? []);
		_parenKind = shape.parenKind;
	}

	/**
	 * Whether ANY type in the resolution scope overloads an operator of one of `kinds`. False
	 * makes every occurrence of those operators built in, which is the cheap answer this class is
	 * arranged to give first: it costs one index build per run and no operand resolution at all.
	 */
	public function declared(kinds: Array<String>): Bool {
		final table: Map<String, Array<String>> = declarers();

		return kinds.exists(kind -> table.exists(kind));
	}

	/**
	 * The verdict for the operator occurrence rooted at `node`, asked about the operator `kinds`
	 * the rewrite depends on — usually the one kind `node` itself has, but a rewrite that turns
	 * one operator into another (a negation flipping `==` to `!=`) has to name both, since either
	 * overload changes what the rewritten form does.
	 *
	 * Every same-kind child is flattened first, so a `+` CHAIN is judged as a whole and one
	 * operand carrying an overload condemns all of it — see the type doc on why the pair alone
	 * is the wrong unit. `written` binds an operand's declared type in its file (`typingFor`);
	 * `proven`, when given, is a second source that may vouch for an operand `written` leaves
	 * unproven — the compiler's facts.
	 */
	public function verdictFor(
		node: QueryNode, kinds: Array<String>, written: (QueryNode) -> Tier, ?proven: (QueryNode) -> Bool
	): OperatorVerdict {
		return verdictOfOperands(operandsOf(node), kinds, written, proven);
	}

	/**
	 * The verdict for an occurrence whose operands the CALLER enumerated — the entry point for a
	 * rewrite whose operands are not simply the children of one operator node.
	 *
	 * `fold-adjacent-string-literals` needs it in both directions: the operands of a conditional
	 * splice region are its in-branch children, and the operands a SPLIT would create out of one
	 * interpolated literal are the expressions inside its interpolation blocks — neither of which
	 * is a child of a node whose kind names the operator.
	 */
	public function verdictOfOperands(
		operands: Array<QueryNode>, kinds: Array<String>, written: (QueryNode) -> Tier, ?proven: (QueryNode) -> Bool
	): OperatorVerdict {
		if (!declared(kinds)) return Builtin;
		var verdict: OperatorVerdict = Builtin;
		for (operand in operands) {
			verdict = worse(verdict, operandVerdict(BoolExprShape.unwrapParens(operand, _parenKind), kinds, written, proven));
			if (verdict.match(Overloaded(_))) return verdict;
		}
		return verdict;
	}

	/**
	 * The operand binder for ONE file, built on first demand and memoised for the run: what the
	 * type an operand is DECLARED with binds to, resolved in that file's scope in the compiler's
	 * own order (`DeclaredNullity.writtenHeadTier` over `TypeNameBinding`).
	 *
	 * A simple type name proves nothing by itself: `final t: Tag` under `import far.Tag` names the
	 * imported abstract even when the index holds only some other `Tag`, so judging the name would
	 * vouch for the wrong declaration. So every type is bound where it is WRITTEN (`OperandBinder`):
	 * a binding this file declares in this file, a member's declared type in the file that declares
	 * the member. It is built lazily for the same reason the overload table is: a tree where
	 * nothing overloads the operator never asks.
	 */
	public function typingFor(file: String, source: String, tree: QueryNode): (QueryNode) -> Tier {
		final cached: Null<(QueryNode) -> Tier> = _typingByFile[file];
		if (cached != null) return cached;
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(_plugin);
		final index: Null<SymbolIndex> = indexHolding(file);
		final typing: (QueryNode) -> Tier = provider == null || index == null
			? _ -> Unknown
			: new OperandBinder(file, source, tree, _shape, index, provider, _builtinTypeNames).tierOf;
		_typingByFile[file] = typing;
		return typing;
	}

	/**
	 * The operands of the occurrence rooted at `node`: its children, with a child of `node`'s
	 * OWN kind expanded into its own operands (the chain) and a parenthesis unwrapped. A unary
	 * operator has one child and falls out of the same walk.
	 */
	private function operandsOf(node: QueryNode): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		function collect(current: QueryNode): Void {
			for (child in current.children) {
				final operand: QueryNode = BoolExprShape.unwrapParens(child, _parenKind);
				if (operand.kind == node.kind)
					collect(operand)
				else
					out.push(operand);
			}
		}
		collect(node);
		return out;
	}

	/**
	 * The verdict `operand` contributes: what its declared type binds to, asked of the table, or
	 * `Unproven` when no binding is proven and `proven` does not vouch for it either.
	 *
	 * An operand that is ITSELF one of the operators in question is judged RECURSIVELY instead of
	 * typed. That is what walks the SPINE of a rebuilt boolean expression — `!(a == b && c)` is
	 * built-in exactly when the `!`, the `&&` and the `==` all are — and it is the only reading
	 * that can answer at all, since no binding names the type of an operator node. The recursion
	 * deliberately stops at everything else: an operator buried inside a CALL argument is copied
	 * verbatim by every rewrite that reaches this class, never re-selected.
	 */
	private function operandVerdict(
		operand: QueryNode, kinds: Array<String>, written: (QueryNode) -> Tier, proven: Null<(QueryNode) -> Bool>
	): OperatorVerdict {
		if (kinds.contains(operand.kind)) return verdictFor(operand, kinds, written, proven);
		if (_literalKinds.contains(operand.kind)) return Builtin;
		final verdict: OperatorVerdict = switch written(operand) {
			case Free: Builtin;
			case Bound(decls): declsVerdict(decls, kinds);
			case Unknown: Unproven;
		};
		return verdict.match(Unproven) && proven != null && proven(operand) ? Builtin : verdict;
	}

	/**
	 * The verdict for a value whose type is one of `decls` — every candidate the binding left, so
	 * the answer holds whichever the compiler picks. `Overloaded` when any declares an overload of
	 * `kinds`; `Builtin` when every one is a PLAIN nominal (a class, interface or enum, none of
	 * which may carry an operator overload) or an abstract overloading none of `kinds` — the
	 * compiler then picks the built-in operator after whatever implicit conversion applies. That
	 * reading of an abstract needs its member set to be complete, so a `@:build` / `@:autoBuild`
	 * declaration, whose generated members no index sees, stays `Unproven`, as does a typedef.
	 */
	private function declsVerdict(decls: Array<ResolvedType>, kinds: Array<String>): OperatorVerdict {
		for (r in decls)
			for (member in r.type.members)
				for (overloaded in member.operatorOverloads)
					if (kinds.contains(overloaded)) return Overloaded(r.type.name);
		return decls.length > 0
			&& decls.foreach(
				r -> _plainKinds.contains(r.type.kind) || (_abstractKinds.contains(r.type.kind) && !r.type.hasBuild && !r.type.hasAutoBuild)
			)
			? Builtin
			: Unproven;
	}

	/** The first scope that indexes `file` — the one its binding is resolved in — or null when none does. */
	private function indexHolding(file: String): Null<SymbolIndex> {
		return indexes().find(index -> index.fileInfo(file) != null);
	}

	/** Operator node kind -> the names of the types that overload it, built once on first demand. */
	private function declarers(): Map<String, Array<String>> {
		final built: Null<Map<String, Array<String>>> = _declarers;
		if (built != null) return built;
		final table: Map<String, Array<String>> = [];
		for (index in indexes())
			for (info in index.allFiles()) for (decl in info.types) for (member in decl.members) for (kind in member.operatorOverloads) {
				final names: Array<String> = table[kind] ?? [];
				if (!names.contains(decl.name)) names.push(decl.name);
				table[kind] = names;
			}
		_declarers = table;
		return table;
	}

	/**
	 * Every scope a declaration may come from, resolved once: the plugin's own resolution index
	 * when it has one, AND an index over the files this run was handed.
	 *
	 * BOTH, not one or the other. An overload declared in a library the report scope does not
	 * include is exactly what a narrow run would otherwise miss — but the reverse costs just as
	 * much: a type declared in the SCANNED files and absent from the resolution scope (a run over
	 * a directory outside the configured project, the common shape of a probe) resolved to
	 * nothing, and a verdict of `Unproven` for it silences findings that are perfectly sound —
	 * for an abstract declaring NO overload, the project index alone refuses the finding and
	 * asking both keeps it.
	 */
	private function indexes(): Array<SymbolIndex> {
		final built: Null<Array<SymbolIndex>> = _indexes;
		if (built != null) return built;
		final resolution: Null<SymbolIndex> = RefactorSupport.resolutionIndexOf(_plugin);
		final resolved: Array<SymbolIndex> = resolution == null
			? [SymbolIndex.build(_files, _plugin)]
			: [resolution, SymbolIndex.build(_files, _plugin)];
		_indexes = resolved;
		return resolved;
	}

	/**
	 * The selection for `plugin` over `files`, or null when the grammar declares no
	 * operator-overload annotation. A null answer is the caller's signal to assume the built-in
	 * operator, which is what every rule did before this seam existed.
	 */
	public static function of(plugin: GrammarPlugin, files: Array<{ file: String, source: String }>): Null<OperatorSelection> {
		final shape: RefShape = plugin.refShape();
		return shape.operatorOverloadMetaName == null ? null : new OperatorSelection(plugin, files, shape);
	}

	/** The more conservative of two verdicts — `Overloaded` beats `Unproven` beats `Builtin`. */
	public static function worse(a: OperatorVerdict, b: OperatorVerdict): OperatorVerdict {
		return switch [a, b] {
			case [Overloaded(_), _]: a;
			case [_, Overloaded(_)]: b;
			case [Unproven, _], [_, Unproven]: Unproven;
			case _: Builtin;
		};
	}

}
