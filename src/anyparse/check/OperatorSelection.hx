package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;

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
 * 2. **Could an operand of THIS occurrence be one of those types?** Each operand's nominal type
 *    comes from the caller's resolver (`CheckScan.typeNominalResolver`), and the answer is
 *    `Overloaded` for a type that declares the pattern, `Builtin` for one that provably cannot,
 *    and `Unproven` for everything else — an unresolved operand included, since the whole point
 *    is that an overloading type does not look different from any other.
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
 *    abstract, so a user type carrying `@:arrayAccess` beside a `get(k)` is never a candidate
 *    (verified: 0 findings on exactly that fixture). `redundant-tostring` already refuses a
 *    `+` receiver that is not a class, and in every stringifying context a declared `toString`
 *    wins over an `@:to String` — compile-and-run on Haxe 4.3.7 `--interp` with an
 *    `abstract Tag(String)` declaring both: interpolation, concatenation, `Std.string` and the
 *    direct call all print the METHOD answer.
 *  - a verdict is per simple NAME, so a name that is AMBIGUOUS in the resolution scope answers
 *    `Unproven` — an abstract called `Path` beside `haxe.io.Path` is refused for the collision
 *    alone. Conservative and intended; worth knowing before writing a fixture.
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

	/** Per-file nominal-type resolvers, built on first demand — see `typesFor`. */
	private final _typesByFile: Map<String, Null<(QueryNode) -> Null<String>>> = [];

	/** The plugin whose resolution scope the overload table is read from. */
	private final _plugin: GrammarPlugin;

	/** The files to index when the plugin carries no resolution scope of its own. */
	private final _files: Array<{ file: String, source: String }>;

	/** Literal kinds whose value's type is built in, so such an operand can never carry an overload. */
	private final _literalKinds: Array<String>;

	/** The type names the grammar declares built in — a scalar or the string type. */
	private final _builtinTypeNames: Array<String>;

	/** The declaration kinds that may carry an operator overload at all (`RefShape.underlyingThisTypeKinds`). */
	private final _abstractKinds: Array<String>;

	/** The parenthesis kind, unwrapped before an operand is classified. */
	private final _parenKind: Null<String>;

	/** Every resolution scope a declaration may come from; null until first demand — see `indexes`. */
	private var _indexes: Null<Array<SymbolIndex>> = null;

	/** Operator node KIND -> the names of the types that overload it; null until first demand. */
	private var _declarers: Null<Map<String, Array<String>>> = null;

	private function new(plugin: GrammarPlugin, files: Array<{ file: String, source: String }>, shape: RefShape) {
		_plugin = plugin;
		_files = files;
		final literalTypeNames: Map<String, String> = shape.literalTypeNames ?? [];
		_literalKinds = [for (kind in literalTypeNames.keys()) kind];
		final builtins: Array<String> = [for (name in literalTypeNames) name];
		for (name in shape.nonNullableTypeNames ?? []) if (!builtins.contains(name)) builtins.push(name);
		_builtinTypeNames = builtins;
		_abstractKinds = shape.underlyingThisTypeKinds ?? [];
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
	 * is the wrong unit. `types` resolves an operand to its simple nominal type name (normally
	 * `CheckScan.typeNominalResolver`); passing null answers `Unproven` for every non-literal
	 * operand, which is what a grammar with no type information deserves.
	 */
	public function verdictFor(node: QueryNode, kinds: Array<String>, types: Null<(QueryNode) -> Null<String>>): OperatorVerdict {
		return verdictOfOperands(operandsOf(node), kinds, types);
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
		operands: Array<QueryNode>, kinds: Array<String>, types: Null<(QueryNode) -> Null<String>>
	): OperatorVerdict {
		if (!declared(kinds)) return Builtin;
		var verdict: OperatorVerdict = Builtin;
		for (operand in operands) {
			verdict = worse(verdict, operandVerdict(unwrapped(operand), kinds, types));
			if (verdict.match(Overloaded(_))) return verdict;
		}
		return verdict;
	}

	/**
	 * The nominal-type resolver for ONE file, built on first demand and memoised for the run.
	 *
	 * It lives here rather than in each caller because it must not be built EAGERLY: a resolver
	 * costs a declared-type map per source, and on a tree where nothing overloads the operator in
	 * question no caller ever asks for one. Demanding it only after `declared` has said yes is
	 * what keeps the whole gate free for the projects that have no overloads at all. Null when the
	 * grammar carries no type information, which answers `Unproven` for every non-literal operand.
	 */
	public function typesFor(file: String, source: String, tree: QueryNode): Null<(QueryNode) -> Null<String>> {
		if (_typesByFile.exists(file)) return _typesByFile[file];
		final resolver: Null<(QueryNode) -> Null<String>> = CheckScan.typeNominalResolver(source, _plugin, tree, file);
		_typesByFile[file] = resolver;
		return resolver;
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
				final operand: QueryNode = unwrapped(child);
				if (operand.kind == node.kind)
					collect(operand)
				else
					out.push(operand);
			}
		}
		collect(node);
		return out;
	}

	/** `node` with any parenthesis wrappers peeled off. */
	private function unwrapped(node: QueryNode): QueryNode {
		final parenKind: Null<String> = _parenKind;
		var current: QueryNode = node;
		while (parenKind != null && current.kind == parenKind && current.children.length == 1) current = current.children[0];
		return current;
	}

	/**
	 * The verdict `operand` contributes: its own type asked of the table, or `Unproven` when it
	 * has none.
	 *
	 * An operand that is ITSELF one of the operators in question is judged RECURSIVELY instead of
	 * typed. That is what walks the SPINE of a rebuilt boolean expression — `!(a == b && c)` is
	 * built-in exactly when the `!`, the `&&` and the `==` all are — and it is the only reading
	 * that can answer at all, since no type resolver names the type of an operator node. The
	 * recursion deliberately stops at everything else: an operator buried inside a CALL argument
	 * is copied verbatim by every rewrite that reaches this class, never re-selected.
	 */
	private function operandVerdict(operand: QueryNode, kinds: Array<String>, types: Null<(QueryNode) -> Null<String>>): OperatorVerdict {
		if (kinds.contains(operand.kind)) return verdictFor(operand, kinds, types);
		if (_literalKinds.contains(operand.kind)) return Builtin;
		if (types == null) return Unproven;
		final typeName: Null<String> = types(operand);
		return typeName == null ? Unproven : typeVerdict(typeName, kinds);
	}

	/**
	 * The verdict for a value of type `typeName`. Three proofs, tried in the order that reads:
	 * the name is one the grammar declares built in; some declaration of it overloads one of
	 * `kinds`; or the name resolves to a single PLAIN nominal — a class, interface or enum, none
	 * of which may carry an operator overload (`SymbolIndex.resolvesToPlainNominal`, whose own doc
	 * excludes abstracts for exactly this reason).
	 *
	 * An ABSTRACT the index carries is judged by its own record: overloading none of `kinds` means
	 * the compiler picks the built-in operator after whatever implicit conversion applies, which
	 * is the same operator the rewrite assumes. That reading needs the member set to be complete,
	 * so a `@:build` / `@:autoBuild` declaration — whose generated members no index sees — stays
	 * `Unproven`.
	 *
	 * Everything else is `Unproven`: an out-of-scope name, an alias, an ambiguous simple name.
	 */
	private function typeVerdict(typeName: String, kinds: Array<String>): OperatorVerdict {
		if (_builtinTypeNames.contains(typeName)) return Builtin;
		final decls: Array<TypeDeclInfo> = declsOf(typeName);
		if (decls.length == 0) return Unproven;
		for (decl in decls)
			for (member in decl.members)
				for (overloaded in member.operatorOverloads)
					if (kinds.contains(overloaded)) return Overloaded(typeName);
		if (indexes().exists(index -> index.resolvesToPlainNominal(typeName))) return Builtin;
		return decls.foreach(decl -> _abstractKinds.contains(decl.kind) && !decl.hasBuild && !decl.hasAutoBuild) ? Builtin : Unproven;
	}

	/** Every top-level declaration named `typeName` the resolution scope carries. */
	private function declsOf(typeName: String): Array<TypeDeclInfo> {
		return [
			for (index in indexes()) for (info in index.declaringFiles(typeName)) for (decl in info.types) if (decl.name == typeName) decl
		];
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
	 * nothing, and a verdict of `Unproven` for it silenced findings that were perfectly sound.
	 * Measured on a two-file fixture whose abstract declares NO overload: preferring the project
	 * index alone refused the finding, asking both keeps it.
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
