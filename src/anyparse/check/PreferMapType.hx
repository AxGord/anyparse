package anyparse.check;

import anyparse.check.Check.GroupedEdit;
import anyparse.check.Check.GroupedFix;
import anyparse.check.Check.RiskyFix;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;

/**
 * One concrete-map reference the rule found: the span to report, the message that carries the
 * verdict, and the edits that rewrite it. An empty `edits` array is a REPORT-ONLY finding — the
 * site is a `haxe.ds` map, but something at it (a shadowed `Map`, a missing type parameter, an
 * unpinned bare construction) makes the rewrite unavailable.
 */
private typedef Candidate = {
	var span: Span;
	var message: String;
	var edits: Array<{ span: Span, text: String }>;
}

/**
 * What one file's header binds, for the two name-resolution questions this rule asks: does a
 * short `IntMap` here MEAN `haxe.ds.IntMap`, and is `Map` free to be written? `imports` maps a
 * plain `import a.b.X;` / `using a.b.X;`'s simple name to its full path, `aliases` holds every
 * simple name an `import … as/in Y;` binds (the grammar does not expose the aliased path, so such
 * a name is never provable), `wildcards` holds each wildcard's package, `declared` holds every type
 * this MODULE declares, and `aliasTargets` maps each module-declared typedef / abstract to the type
 * it stands for — ONE hop, the chain being the reader's to follow. `mapFree` is the precomputed
 * `Map` answer — it is a property of the file, not of a site, so every candidate in the file shares
 * it.
 */
private typedef Scope = {
	var imports: Map<String, String>;
	var aliases: Array<String>;
	var wildcards: Array<String>;
	var declared: Array<String>;
	var aliasTargets: Map<String, String>;
	var mapFree: Bool;
}

/** The resolved per-file seams the candidate walk threads through, so no node visit re-derives them. */
private typedef Seams = {
	var source: String;
	var scope: Scope;
	var typeRefKinds: Array<String>;
	var newExprKind: Null<String>;
	var declHostKinds: Array<String>;
	var functionBodyKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var conditionalIf: Null<String>;
}

/**
 * A candidate site resolved down to what both arms need: the span to report, the name as
 * WRITTEN, the concrete map that name provably denotes, and the site's source text. `siteOf`
 * returning null means the node is not a provable `haxe.ds` map reference, and neither arm
 * proceeds.
 */
private typedef Site = {
	var span: Span;
	var name: String;
	var concrete: String;
	var text: String;
}

/**
 * Flags a CONCRETE `haxe.ds` map type — `IntMap<V>` / `StringMap<V>` / `ObjectMap<K, V>` /
 * `EnumValueMap<K, V>` — written where the unified `Map<K, V>` syntax says the same thing, and
 * rewrites it. `Severity.Info` (a modernization cleanup). `haxe.ds.WeakMap` is NOT one of them:
 * its entries are weakly held, so `Map<K, V>` is a different data structure, not a different
 * spelling.
 *
 * ```haxe
 * var byId:IntMap<Row> = new IntMap();      // ->  var byId:Map<Int, Row> = new Map();
 * function f(m:StringMap<Int>):Void         // ->  function f(m:Map<String, Int>):Void
 * var nested:IntMap<IntMap<Int>>;           // ->  var nested:Map<Int, Map<Int, Int>>;
 * ```
 *
 * ## Why the rewrite preserves meaning
 *
 * `haxe.ds.Map` is a `@:multiType` abstract that RESOLVES to exactly these implementations:
 * `Map<Int, V>` IS an `IntMap<V>` at runtime, `Map<String, V>` a `StringMap<V>`, and a
 * `Map<K, V>` over an object / enum-value key an `ObjectMap` / `EnumValueMap`. So the rewrite
 * renames the spelling, never the structure. It also keeps value flows compiling ACROSS the edit
 * boundary: `Map` declares a `@:from` for `StringMap` / `IntMap` / `ObjectMap` and a `@:to` for
 * all four, so a rewritten annotation still accepts a concrete-typed value from an unedited file,
 * and still satisfies a concrete-typed slot in one.
 *
 * `EnumValueMap` is the exception: `Map` carries a `@:to` for it but NO `@:from`, so an
 * explicitly `EnumValueMap`-typed value flowing INTO a rewritten `Map<K, V>` slot can stop
 * compiling. Exactly ONE producer of such a value is handled structurally — a declaration's own
 * bare construction, `var x:EnumValueMap<K, V> = new EnumValueMap();`, whose two halves are judged
 * as a pair and therefore move together or not at all. Every OTHER producer (an initializer call,
 * a return-position value, a cross-file assignment) is outside what this rule can see and rides on
 * the `RiskyFix` verification below.
 *
 * ## What is rewritten, and how the edits compose
 *
 * Each site emits up to two edits against the SOURCE NAME rather than one replacement of the
 * whole type region: the name token becomes `Map`, and — for the two implementations whose key
 * type is implied by the class rather than written (`IntMap` -> `Int`, `StringMap` -> `String`)
 * — the following `<` is REPLACED by `<Int, ` / `<String, `. `ObjectMap` / `EnumValueMap`
 * already write their key as the first type parameter, so they need the name edit alone.
 *
 * That shape is what makes NESTED maps work. `IntMap<IntMap<Int>>` projects as two sibling
 * heads, and their edit spans interleave without touching: the outer head's `<` sits exactly
 * where the inner head's name begins. Replacing the `<` (rather than inserting after it) keeps
 * every edit a non-empty, non-overlapping range, so the batch applies in any order and yields
 * `Map<Int, Map<Int, Int>>`.
 *
 * A `new` expression is the same rewrite over the constructed name, located by TOKENISING past
 * comments so that a comment naming the type between the `new` keyword and the constructor cannot
 * absorb the edit. A bare `new IntMap()` has no type parameters to carry the key, so it becomes a
 * bare `new Map()`, which resolves only from the declaration it initializes: that declaration must
 * itself be annotated with `Map` or a concrete map — resolved through the same name proof, never
 * matched by bare name — and must write the arguments that determine both parameters.
 * `NewLiteral.pinnedByTypeHint` — the predicate `prefer-map-literal` gates its `[]` on — answers
 * the head-SHAPE half and is reused verbatim; the stricter "determines K and V" half lives here,
 * because `prefer-map-literal` needs that predicate exactly as loose as it is.
 *
 * ## Gates — fail closed
 *
 *  - **The name must PROVABLY mean the `haxe.ds` type.** Either the reference is written
 *    fully qualified (`haxe.ds.IntMap<V>` — self-proving), or the file carries the exact
 *    `import haxe.ds.IntMap;` / `using haxe.ds.IntMap;`, or a `haxe.ds` wildcard. A name the
 *    MODULE itself declares, a name an `import … as/in` binds (the grammar does not expose what it
 *    was aliased FROM), and a name bound from any other package are all refused — and refused
 *    SILENTLY, with no finding: the reference does not denote a `haxe.ds` map, so reporting it
 *    would be a false positive, not a conservative one.
 *  - **`Map` must be free.** A file that declares its own `Map`, aliases a `Map`, or binds one
 *    from another package — by `import` OR by `using`, which shadows the simple name just as hard
 *    — cannot spell the unified type here. That finding IS reported (the site really is a
 *    `haxe.ds` map) but carries no edit.
 *  - **The key must PROVE which implementation `Map` resolves to.** `Map`'s `@:multiType` selector
 *    chain is `K:String` -> `K:Int` -> `K:EnumValue` -> `K:{}` (`haxe/ds/Map.hx`). `IntMap` /
 *    `StringMap` become `Map<Int, …>` / `Map<String, …>`, which the first two selectors claim by
 *    construction — but the two implementations that WRITE their own key get no such guarantee, so
 *    their key must be a plain nominal THIS FILE CAN POINT AT: written qualified, imported, or
 *    declared by this module, not naming one of the earlier selectors' constraint types, and — for
 *    a module-declared name — not ALIASING one either, since `@:followWithAbstracts` reads through
 *    a local `abstract LocalKey(String)` to the same claimed selector. The test is positive because
 *    the dangerous shape is a type PARAMETER: `ObjectMap<K, Int>` in a `class C<K>` satisfies
 *    `K:{}` at the declaration site exactly as a class does, so `Map<K, Int>` typechecks there and
 *    only a monomorphised `C<String>` picks the StringMap — no oracle sees it. A deny list would
 *    have to enumerate every name that is not a type parameter; requiring the file to resolve the
 *    key excludes them all at once, together with `ObjectMap<Dynamic, V>` and
 *    `ObjectMap<String, V>` (both reach `K:String`, both then throw at runtime on the first object
 *    key — found by running this rule over a real tree, not by any fixture).
 *  - **Conditional compilation.** A `#if … #end` region is skipped wholesale — what a name means
 *    inside one depends on the build, which the import map does not model. The test is the
 *    DIRECTIVE, not a node kind (`CheckScan.opensConditionalRegion`), because the grammar
 *    projects a conditional region through a dozen position-specific kinds. A type region whose
 *    own text carries a `#` is skipped too.
 *  - **Non-empty constructor arguments.** `new IntMap(x)` is never touched — the `NewLiteral`
 *    precedent: a parseable-but-unexpected argument list is never silently dropped or reasoned
 *    about.
 *  - **Imports are never rewritten** (the `ShortenTypeRef` precedent). An `import haxe.ds.IntMap;`
 *    left dangling by this rule's edits is `unused-import`'s to remove, on its own evidence.
 *
 * ## Positions — an annotation, never a class role
 *
 * `Map` is an ABSTRACT: it cannot be extended, cannot be a runtime `is` / `cast` target, and
 * cannot be a `catch` type. Every such position is therefore skipped — and, like a name that
 * does not resolve, skipped without a finding: a concrete map class used AS a class is correct
 * code, not a modernization miss. Heritage (`extends` / `implements`), `is`, `cast(x, T)`,
 * `catch (e:T)`, `(x : T)` and a type-parameter CONSTRAINT (`<K:IntMap<Int>>`) are all out.
 *
 * The discrimination is positional, driven by `RefShape`. A type reference is rewritable when it
 * is a direct child of a declaration host (`declHostKinds` — a field, a local, a parameter, a
 * typedef's aliased type, and the name/type pair of an anonymous-structure field), the RETURN
 * type of a function (the child immediately before a `functionBodyKinds` child — the same
 * child-before-the-body rule `explicit-type` uses), a type ARGUMENT of a `new` expression, or a
 * type argument of an already-rewritable reference. Everything else — the clause and expression
 * positions above — fails the test by construction rather than by an enumerated deny list.
 *
 * ## Verified, not trusted — `RiskyFix`
 *
 * `apq lint --fix` applies this check's edits speculatively, typechecks, and REVERTS any file the
 * edit breaks (that file's findings degrade to report-only); with no `compilerOracle` configured
 * the rule is report-only wholesale. Three things lean on that, and one thing is beyond it:
 *
 *  - **The name proof is per FILE.** It reads the file's own header, not a cross-module index, so
 *    a same-package type named `IntMap` in a SIBLING file (which would shadow the wildcard arm) is
 *    invisible to it, as is a `Map` brought in by a non-`haxe.ds` wildcard.
 *  - **`EnumValueMap` has no `@:from`** (above), so a rewritten annotation can reject an
 *    `EnumValueMap`-typed value from any producer other than the paired bare construction.
 *  - **A rewritten `typedef TD = IntMap<Int>;` is a CROSS-FILE change.** The alias itself is
 *    legal either way, but another module's `extends TD` / `x is TD` binds to a concrete class
 *    through it and stops compiling once `TD` aliases the abstract. The rewrite is kept — the
 *    alias is a genuine annotation position and the whole-project oracle catches the fallout,
 *    which costs a revert, never corruption.
 *  - **NOT covered, because it typechecks:** an `ObjectMap` keyed by an IMPORTED or QUALIFIED
 *    abstract / typedef over `String` / `Int`. `@:multiType(@:followWithAbstracts K)` follows the
 *    alias and picks the earlier selector, giving a StringMap that throws at runtime. The
 *    MODULE-DECLARED form of that shape IS closed (the chain is in this file's own tree); the
 *    cross-file forms would need cross-file type resolution.
 *
 * ## Composition with the neighbouring rules
 *
 * This rule stops at the type spelling. `prefer-map-literal` then collapses an
 * annotation-pinned `new Map()` to `[]`, and `unused-import` removes the now-dead
 * `import haxe.ds.IntMap;` — each on its own evidence, at its own fixed-point pass.
 */
@:nullSafety(Strict)
final class PreferMapType implements Check implements RiskyFix implements GroupedFix {

	/** The rule's stable identifier — the `apqlint.json` key and the `--rule` selector. */
	private static inline final RULE_ID: String = 'prefer-map-type';

	/** The package the four rewritable map implementations live in — the target of every name proof. */
	private static inline final MAP_MODULE_PACKAGE: String = 'haxe.ds';

	/** The unified map abstract's simple name — what every rewrite writes. */
	private static inline final UNIFIED_MAP: String = 'Map';

	/** An empty constructor argument list — the only one this rule rewrites (the `NewLiteral` precedent). */
	private static inline final EMPTY_ARGUMENT_LIST: String = '()';

	/** The wildcard import's trailing segment, stripped to recover the imported package. */
	private static inline final WILDCARD_SUFFIX: String = '.*';

	/**
	 * The ANNOTATION type-reference kind, spelled literally: `RefShape` carries no field naming
	 * it, and it needs a different position rule from the clause kind below. Both are declared in
	 * `TypeRefShape.typeRefKinds`, so a grammar missing either makes the check a no-op.
	 */
	private static inline final ANNOTATION_TYPE_KIND: String = 'TypeRef';

	/**
	 * The CLAUSE type-reference kind — a return type, a heritage entry, a type-parameter
	 * constraint, an abstract's underlying / `from` / `to` type, an `is` operand. Only the return
	 * type of these is an annotation, which is why it needs its own position rule.
	 */
	private static inline final CLAUSE_TYPE_KIND: String = 'Named';

	/** The grammar's name/type pair inside an anonymous-structure field — transparent to the position walk. */
	private static inline final FIELD_PAIR_KIND: String = 'Plain';

	/** The plain `import a.b.X;` declaration kind (spelled literally, as `CheckScan`'s import anchors are). */
	private static inline final IMPORT_DECL_KIND: String = 'ImportDecl';

	/** The `import a.b.*;` declaration kind. */
	private static inline final WILDCARD_IMPORT_KIND: String = 'ImportWildDecl';

	/** The `using a.b.*;` declaration kind — the `using` twin of `WILDCARD_IMPORT_KIND` (`CheckScan.USING_DECL_KIND` names the plain one). */
	private static inline final WILDCARD_USING_KIND: String = 'UsingWildDecl';

	/** The aliasing import kinds (`import a.b.X as Y;` / `… in Y;`) — each binds a simple name to an unexposed path. */
	private static final ALIAS_IMPORT_KINDS: Array<String> = ['ImportAliasDecl', 'ImportAliasInDecl'];

	/** The fully-qualified prefix a self-proving reference carries. */
	private static inline final QUALIFIED_PREFIX: String = '$MAP_MODULE_PACKAGE.';

	/**
	 * The concrete map implementations this rule rewrites, each mapped to the key type the unified
	 * syntax must SPELL OUT — empty when the implementation already writes its key as the first
	 * type parameter. `WeakMap` is deliberately absent: weakly-held entries are different
	 * semantics, not a different spelling.
	 */
	private static final CONCRETE_MAP_KEY_TYPES: Map<String, String> = [
		'IntMap' => 'Int',
		'StringMap' => 'String',
		'ObjectMap' => '',
		'EnumValueMap' => ''
	];

	/** The finding message when the rewrite is available — the only message `fix` acts on. */
	private static inline final MSG_FIXABLE: String = 'this concrete map type can be the unified Map<K, V> syntax';

	/** The finding message when the file binds `Map` to something else, so the unified name cannot be written here. */
	private static inline final MSG_MAP_SHADOWED: String =
		'a concrete map type replaceable with Map<K, V> (report-only: this file binds Map to another type)';

	/** The finding message for a reference written with no type parameters, which `Map<K, V>` requires. */
	private static inline final MSG_NO_TYPE_PARAMS: String =
		'a concrete map type replaceable with Map<K, V> (report-only: written without the type parameters Map requires)';

	/** The finding message for a bare construction whose declaration does not determine the resulting map type. */
	private static inline final MSG_UNPINNED_NEW: String =
		'a concrete map construction replaceable with new Map() (report-only: no annotation determines the resulting key and value types)';

	/** The finding message when the written key does not prove `Map` resolves back to the implementation named here. */
	private static inline final MSG_KEY_UNPROVEN: String =
		'a concrete map type replaceable with Map<K, V> (report-only: the key type does not prove Map resolves to this implementation)';

	/**
	 * Key type names `Map`'s `@:multiType` selector chain claims BEFORE it can reach `ObjectMap` /
	 * `EnumValueMap`, plus the two top types that unify with every one of them. The chain is
	 * `K:String` -> `K:Int` -> `K:EnumValue` -> `K:{}` (`haxe/ds/Map.hx`), so this list is CLOSED by
	 * that declaration rather than grown one discovered leak at a time: any other nominal key
	 * reaches the same implementation the source already names.
	 */
	private static final KEY_TYPES_ROUTED_ELSEWHERE: Array<String> = ['String', 'Int', 'UInt', 'EnumValue', 'Dynamic', 'Any'];

	/** Hop budget for following a module-declared alias chain — a cycle is illegal Haxe, but a scan must still terminate. */
	private static inline final ALIAS_CHAIN_LIMIT: Int = 16;

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a concrete map type (IntMap / StringMap / ObjectMap / EnumValueMap) replaceable with the unified Map<K, V> syntax';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return [
			for (entry in files) for (candidate in candidatesOf(entry.source, plugin))
				{
					file: entry.file,
					span: candidate.span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: candidate.message
				}
		];
	}

	/**
	 * The flat projection of `fixGrouped` — the `Check.fix` contract, for the callers that never
	 * split an edit set. Grouping is the ONLY thing dropped here, which is the obligation
	 * `GroupedFix` states: the two views can never disagree about WHICH edits a fix produces.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [
			for (edit in fixGrouped(source, violations, plugin, index)) { span: edit.span, text: edit.text }
		];
	}

	/**
	 * The edits for the fixable subset of `violations`, one GROUP per candidate. The verdict is
	 * RE-DERIVED here rather than carried on the violation — a finding the report left report-only
	 * yields no edit, whatever the caller hands back.
	 *
	 * The group exists because one candidate is ONE rewrite that happens to need two edits: the name
	 * token becomes `Map`, and an implied key type is spelled out by replacing the following `<`. Half
	 * of that is `Map<V>` or `IntMap<Int, V>` — neither compiles, so a bisect splitting the pair would
	 * name one half a failer, keep the other, and then see its own complement confirm fail: a spurious
	 * WHOLE-FILE revert of every candidate in the file. A candidate whose key type is already written
	 * needs one edit and becomes a group of one, which is indistinguishable from ungrouped.
	 */
	public function fixGrouped(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<GroupedEdit> {
		final wanted: Array<String> = [];
		for (violation in violations) {
			final span: Null<Span> = violation.span;
			if (span != null && violation.message == MSG_FIXABLE) wanted.push('${span.from}:${span.to}');
		}
		if (wanted.length == 0) return [];
		final edits: Array<GroupedEdit> = [];
		var group: Int = 0;
		for (candidate in candidatesOf(source, plugin)) if (
			candidate.message == MSG_FIXABLE && wanted.contains('${candidate.span.from}:${candidate.span.to}')
		) {
			for (edit in candidate.edits) edits.push({ span: edit.span, text: edit.text, group: group });
			group++;
		}
		return edits;
	}

	/**
	 * Every concrete-map reference in `source` this rule has something to say about. The type-ref
	 * projection is a SECOND parse (`parseFileTypeRefs`) — the default tree drops annotation
	 * positions into trivia — so it is taken once per file and shared by the whole walk.
	 */
	private static function candidatesOf(source: String, plugin: GrammarPlugin): Array<Candidate> {
		final typeRefKinds: Array<String> = plugin.typeRefShape().typeRefKinds;
		if (!typeRefKinds.contains(ANNOTATION_TYPE_KIND) || !typeRefKinds.contains(CLAUSE_TYPE_KIND)) return [];
		final tree: Null<QueryNode> = CheckScan.parseTypeRefsOrNull(plugin, source);
		if (tree == null) return [];
		final shape: RefShape = plugin.refShape();
		final out: Array<Candidate> = [];
		walk(tree, null, false, {
			source: source,
			scope: scopeOf(tree, shape),
			typeRefKinds: typeRefKinds,
			newExprKind: shape.newExprKind,
			declHostKinds: shape.declHostKinds,
			functionBodyKinds: shape.functionBodyKinds ?? [],
			opaqueKinds: shape.opaqueKinds ?? [],
			conditionalIf: shape.conditionalIfKeyword
		}, out);
		return out;
	}


	/**
	 * Visit `node`'s subtree, collecting candidates. `accepted` says whether THIS node, were it a
	 * type reference, sits in a rewritable position — the parent decides it, so the flag is the
	 * only thing the walk carries. A reification subtree and a conditional-compilation region are
	 * skipped wholesale.
	 */
	private static function walk(node: QueryNode, parent: Null<QueryNode>, accepted: Bool, seams: Seams, out: Array<Candidate>): Void {
		if (seams.opaqueKinds.contains(node.kind) || CheckScan.opensConditionalRegion(node, seams.source, seams.conditionalIf)) return;
		if (node.kind == seams.newExprKind)
			newExprCandidate(node, parent, seams, out);
		else if (accepted && seams.typeRefKinds.contains(node.kind))
			annotationCandidate(node, seams, out);
		final returnSlot: Int = returnTypeSlot(node, seams);
		for (i in 0...node.children.length) {
			final child: QueryNode = node.children[i];
			walk(child, node, typePositionAccepted(child, node, i == returnSlot, accepted, seams), seams, out);
		}
	}

	/**
	 * Whether `child` of `parent` is a type reference this rule may rewrite. The four accepting
	 * shapes are the whole positive criterion (see the class doc): a `new` expression's leading
	 * type-ARGUMENT run, a type argument of an already-accepted reference (which is how a rejected
	 * clause position denies its own arguments too), a function's RETURN type — the child immediately
	 * before its body — and a direct child of a declaration host. The anonymous-structure field pair
	 * is transparent: it holds a declaration host's annotation one level down.
	 *
	 * A `new` expression's children are its type arguments AND its constructor arguments; only the
	 * former are matched, by kind. A constructor argument is an EXPRESSION, and the grammar never
	 * projects an expression as the clause type kind — so the type-argument run is exactly the set
	 * this returns true for, whatever order the two runs appear in.
	 */
	private static function typePositionAccepted(
		child: QueryNode, parent: QueryNode, isReturnSlot: Bool, parentAccepted: Bool, seams: Seams
	): Bool {
		return if (parent.kind == seams.newExprKind)
			child.kind == CLAUSE_TYPE_KIND
		else if (parent.kind == FIELD_PAIR_KIND || seams.typeRefKinds.contains(parent.kind))
			parentAccepted
		else if (child.kind == CLAUSE_TYPE_KIND)
			isReturnSlot
		else
			seams.declHostKinds.contains(parent.kind);
	}

	/**
	 * The index of `node`'s return-type child — the one immediately before its function body — or -1
	 * when it has none.
	 *
	 * The child-before-the-body rule alone is not enough here. A function that OMITS its return type
	 * puts a type-parameter CONSTRAINT in exactly that slot — `function f<T:IntMap<Int>>() {}`
	 * projects the constraint and the body as its only two children — and the two share a node kind.
	 * A return type is the last thing before the body, so the source between them holds no `(`; a
	 * constraint always has the parameter list between it and the body.
	 */
	private static function returnTypeSlot(node: QueryNode, seams: Seams): Int {
		for (i in 0...node.children.length) if (seams.functionBodyKinds.contains(node.children[i].kind)) {
			if (i == 0) return -1;
			final candidate: Null<Span> = node.children[i - 1].span;
			final body: Null<Span> = node.children[i].span;
			return if (candidate == null || body == null)
				-1
			else if (seams.source.substring(candidate.to, body.from).indexOf('(') == -1)
				i - 1
			else
				-1;
		}
		return -1;
	}

	/**
	 * The candidate for a type reference in an annotation position, or nothing when the name is not
	 * provably a `haxe.ds` map.
	 */
	private static function annotationCandidate(node: QueryNode, seams: Seams, out: Array<Candidate>): Void {
		final site: Null<Site> = siteOf(node, seams);
		if (site == null) return;
		// The head node's span covers the WHOLE generic region, opening with the name itself; a
		// region that does not, or that carries a conditional splice, is not one this rule slices.
		if (site.text.indexOf(site.name) != 0 || site.text.indexOf('#') != -1) return;
		if (!seams.scope.mapFree) {
			out.push({ span: site.span, message: MSG_MAP_SHADOWED, edits: [] });
			return;
		}
		final open: Int = typeParameterOpen(site.text, site.name.length);
		if (open == -1) {
			out.push({ span: site.span, message: MSG_NO_TYPE_PARAMS, edits: [] });
			return;
		}
		if (writesItsOwnKey(site.concrete) && !keyResolvesBack(site.text, open, seams.scope)) {
			out.push({ span: site.span, message: MSG_KEY_UNPROVEN, edits: [] });
			return;
		}
		out.push({ span: site.span, message: MSG_FIXABLE, edits: rewriteEdits(site, 0, open) });
	}

	/**
	 * The candidate for a `new <ConcreteMap>(…)` construction. A non-empty argument list is never
	 * touched; a construction that spells its type parameters rewrites like an annotation; a bare one
	 * rewrites only where an annotation DETERMINES the resulting key and value types, and stays
	 * report-only otherwise.
	 */
	private static function newExprCandidate(node: QueryNode, parent: Null<QueryNode>, seams: Seams, out: Array<Candidate>): Void {
		final site: Null<Site> = siteOf(node, seams);
		if (site == null) return;
		if (!StringTools.endsWith(StringTools.rtrim(site.text), EMPTY_ARGUMENT_LIST) || site.text.indexOf('#') != -1) return;
		final nameAt: Int = constructedNameOffset(site.text, site.name);
		if (nameAt == -1) return;
		if (!seams.scope.mapFree) {
			out.push({ span: site.span, message: MSG_MAP_SHADOWED, edits: [] });
			return;
		}
		final open: Int = typeParameterOpen(site.text, nameAt + site.name.length);
		if (open != -1) {
			if (writesItsOwnKey(site.concrete) && !keyResolvesBack(site.text, open, seams.scope)) {
				out.push({ span: site.span, message: MSG_KEY_UNPROVEN, edits: [] });
				return;
			}
			out.push({ span: site.span, message: MSG_FIXABLE, edits: rewriteEdits(site, nameAt, open) });
			return;
		}
		// A bare construction carries no type arguments of its own, so everything `new Map()` needs to
		// resolve has to come off the declaration it initializes.
		final host: Null<Span> = parent?.span;
		final pin: Null<String> = host == null ? null : pinningAnnotation(seams.source, host.from, site.span.from);
		if (pin == null || !pinDeterminesMapType(pin, site.concrete, seams.scope)) {
			out.push({ span: site.span, message: MSG_UNPINNED_NEW, edits: [] });
			return;
		}
		out.push({ span: site.span, message: MSG_FIXABLE, edits: [nameEdit(site.span.from + nameAt, site.name)] });
	}

	/**
	 * The offset of the constructed type's NAME TOKEN inside a `new …` expression's source, or -1.
	 *
	 * The scan TOKENISES, skipping comment regions outright. Neither a substring search nor a
	 * neighbour check on one is enough: a comment between the `new` keyword and the constructor can
	 * supply whatever characters a neighbour check looks for. A comment reading "see IntMap() below"
	 * puts whitespace before the match and a `(` after it; one reading "IntMap<Int>" supplies a `<`
	 * and would draw BOTH edits inside the comment. Editing the comment leaves the construction
	 * untouched, and the result still compiles through `Map`'s `@:from` — so no oracle would ever
	 * report it. Only the first name-token match is taken; the `new` keyword always precedes it, so a
	 * match at offset 0 cannot be the constructed type.
	 */
	private static function constructedNameOffset(text: String, name: String): Int {
		var i: Int = 0;
		var tokenStart: Int = -1;
		while (i < text.length) {
			final commentEnd: Int = commentRegionEnd(text, i);
			if (commentEnd != -1) {
				tokenStart = -1;
				i = commentEnd;
				continue;
			}
			if (isNominalChar(text.fastCodeAt(i))) {
				if (tokenStart == -1) tokenStart = i;
			} else {
				if (tokenStart > 0 && text.substring(tokenStart, i) == name) return tokenStart;
				tokenStart = -1;
			}
			i++;
		}
		return -1;
	}

	/** The offset just past the comment starting at `at`, or -1 when no comment starts there. */
	private static function commentRegionEnd(text: String, at: Int): Int {
		if (text.fastCodeAt(at) != '/'.code || at + 1 >= text.length) return -1;
		final next: Int = text.fastCodeAt(at + 1);
		if (next == '*'.code) {
			final close: Int = text.indexOf('*/', at + 2);
			return close == -1 ? text.length : close + 2;
		}
		if (next != '/'.code) return -1;
		final line: Int = text.indexOf('\n', at + 2);
		return line == -1 ? text.length : line + 1;
	}

	/**
	 * The type annotation that pins the construction at `newStart`, or null when the declaration head
	 * carries none. `NewLiteral.pinnedByTypeHint` owns the head-SHAPE question — it is the same
	 * predicate `prefer-map-literal` gates on, and it stays exactly as loose as that caller needs;
	 * this reads the annotation OUT of the head so the stricter question below can be asked here.
	 */
	private static function pinningAnnotation(source: String, declStart: Int, newStart: Int): Null<String> {
		if (!NewLiteral.pinnedByTypeHint(source, declStart, newStart)) return null;
		final head: String = source.substring(declStart, newStart).rtrim();
		var depth: Int = 0;
		for (i in 0...head.length - 1) {
			final c: Int = head.fastCodeAt(i);
			if (c == '<'.code || c == '('.code || c == '['.code || c == '{'.code)
				depth++;
			else if (c == '>'.code || c == ')'.code || c == ']'.code || c == '}'.code) {
				if (depth > 0) depth--;
			} else if (c == ':'.code && depth == 0 && (i == 0 || head.fastCodeAt(i - 1) != '@'.code))
				// The head ends in the initializer's `=`, which `pinnedByTypeHint` proved is its last char.
				return head.substring(i + 1, head.length - 1).trim();
		}
		return null;
	}

	/**
	 * Whether `annotation` determines the `Map` a bare `new Map()` would build — and determines it to
	 * the SAME implementation `concrete` names.
	 *
	 * "There is an annotation" — all `pinnedByTypeHint` answers, and all `prefer-map-literal`'s `[]`
	 * needs — is not enough here: `var d:Dynamic = new Map()` fails with "Type parameters of multi
	 * type abstracts must be known", and `var a:IMap<Int, String> = new Map()` fails to unify. So the
	 * annotation must name `Map` or a concrete map AND write the arguments that pin it.
	 *
	 * The annotation's nominal is RESOLVED through the same name proof every other site uses, never
	 * matched by bare name: a module declaring its own `IntMap` means `var m:IntMap<Int>` is not a
	 * `haxe.ds` map, so it determines nothing for a `new haxe.ds.IntMap()` standing beside it, even
	 * though that construction proves its own name.
	 *
	 * A pin already spelling the unified type needs no key PROOF — `Map<K, V>` writes both parameters
	 * itself, and the caller has already established that `Map` is free here — but it must still name
	 * the implementation being replaced, or the rewrite would quietly swap one for another
	 * (`var m:Map<Dynamic, Int> = new IntMap()` is an IntMap today and a StringMap after).
	 */
	private static function pinDeterminesMapType(annotation: String, concrete: String, scope: Scope): Bool {
		final open: Int = annotation.indexOf('<');
		if (open == -1 || !annotation.endsWith('>')) return false;
		final split: { first: String, more: Bool } = typeArgumentSplit(annotation, open);
		if (split.first == '') return false;
		final impliedKey: Null<String> = CONCRETE_MAP_KEY_TYPES[concrete];
		final writesOwnKey: Bool = impliedKey == null || impliedKey == '';
		final nominal: String = annotation.substring(0, open).trim();
		return if (nominal == UNIFIED_MAP || nominal == QUALIFIED_PREFIX + UNIFIED_MAP)
			split.more && (writesOwnKey ? keyProven(split.first, scope) : split.first == impliedKey)
		else if (resolveConcreteMap(nominal, scope) != concrete)
			false
		else
			!writesOwnKey || split.more && keyProven(split.first, scope);
	}

	/** Whether `concrete` writes its key as the first type parameter (`ObjectMap` / `EnumValueMap`) rather than implying it. */
	private static function writesItsOwnKey(concrete: String): Bool {
		return CONCRETE_MAP_KEY_TYPES[concrete] == '';
	}

	/**
	 * Whether the WRITTEN first type argument at `open` sends `Map`'s `@:multiType` selector chain
	 * back to the implementation the source names. Only the implementations that write their own key
	 * ask this: `IntMap` / `StringMap` become `Map<Int, …>` / `Map<String, …>`, which the chain's
	 * first two selectors claim by construction.
	 */
	private static function keyResolvesBack(text: String, open: Int, scope: Scope): Bool {
		return keyProven(typeArgumentSplit(text, open).first, scope);
	}

	/**
	 * Whether `key` — a written first type argument — PROVES which implementation `Map` resolves to.
	 * The test is POSITIVE by design: the key must be a plain nominal that this file can point at —
	 * written qualified, imported, or declared by this module — and must not name, or locally alias,
	 * one of the constraint types an earlier selector claims.
	 *
	 * The positive half is what rejects a type PARAMETER, and it is the reason the test cannot be a
	 * deny list. `class C<K> { var m:ObjectMap<K, Int>; }` satisfies `K:{}` at the declaration site
	 * exactly as a class does, so `Map<K, Int>` TYPECHECKS there; the wrong implementation is only
	 * chosen when a call site monomorphises `C<String>`, at which point a StringMap stands where the
	 * source named an object map. No compiler oracle sees that, and a type parameter is never
	 * qualified, imported or module-declared — so requiring one of those excludes it by construction,
	 * along with every other name this file cannot resolve.
	 *
	 * `Map<Dynamic, V>` / `Map<String, V>` are the deny half: both reach the `K:String` selector, so
	 * the rewrite becomes a StringMap and throws at runtime on the first object key.
	 *
	 * The ALIAS half closes the same runtime break one indirection out. `@:multiType` resolves K with
	 * `@:followWithAbstracts`, so an `abstract LocalKey(String)` key routes exactly as `String` does —
	 * it compiles, and throws. Where the alias is declared by this module the chain is right here in
	 * the tree `scopeOf` already walks, so it is followed; an IMPORTED or QUALIFIED alias needs
	 * cross-file resolution and stays the documented residual.
	 */
	private static function keyProven(key: String, scope: Scope): Bool {
		if (key == '') return false;
		for (i in 0...key.length) if (!isNominalChar(key.fastCodeAt(i))) return false;
		return !KEY_TYPES_ROUTED_ELSEWHERE.contains(CheckScan.simpleModuleName(key))
			&& (key.indexOf('.') != -1 || (scope.imports.exists(key) || scope.declared.contains(key)) && !aliasesToAClaimedKey(key, scope));
	}

	/** Whether `name`'s module-declared alias chain reaches a type name an earlier `Map` selector claims. */
	private static function aliasesToAClaimedKey(name: String, scope: Scope): Bool {
		var target: Null<String> = scope.aliasTargets[name];
		var hops: Int = 0;
		while (target != null && hops < ALIAS_CHAIN_LIMIT) {
			if (KEY_TYPES_ROUTED_ELSEWHERE.contains(target)) return true;
			target = scope.aliasTargets[target];
			hops++;
		}
		return false;
	}

	/** Whether `code` may appear in a plain nominal type reference — an identifier character or the path `.`. */
	private static function isNominalChar(code: Int): Bool {
		return code == '.'.code || code == '_'.code || (code >= 'a'.code && code <= 'z'.code) || (code >= 'A'.code && code <= 'Z'.code)
			|| (code >= '0'.code && code <= '9'.code);
	}

	/**
	 * The type-argument list opening at `open`, split into its FIRST argument's source text and
	 * whether a second one follows. `first` is empty when the list never closes. The `more` half is
	 * what tells `Map<K, V>` (both parameters written, so the multi-type is determined) from a
	 * one-argument list.
	 */
	private static function typeArgumentSplit(text: String, open: Int): { first: String, more: Bool } {
		var depth: Int = 0;
		for (i in open ... text.length) {
			final c: Int = text.fastCodeAt(i);
			if (c == '<'.code || c == '('.code || c == '{'.code || c == '['.code)
				depth++;
			else if (c == ')'.code || c == '}'.code || c == ']'.code)
				depth--;
			else if (c == '>'.code && text.fastCodeAt(i - 1) != '-'.code) {
				depth--;
				if (depth == 0) return { first: text.substring(open + 1, i).trim(), more: false };
			} else if (c == ','.code && depth == 1)
				return { first: text.substring(open + 1, i).trim(), more: true };
		}
		return { first: '', more: false };
	}

	/**
	 * `node` resolved to a `Site`, or null when it carries no span / name, or when its name is not
	 * PROVABLY one of the concrete `haxe.ds` maps (see `resolveConcreteMap`) — the shared head of
	 * both candidate arms.
	 */
	private static function siteOf(node: QueryNode, seams: Seams): Null<Site> {
		final nodeSpan: Null<Span> = node.span;
		final name: Null<String> = node.name;
		if (nodeSpan == null || name == null) return null;
		final concrete: Null<String> = resolveConcreteMap(name, seams.scope);
		if (concrete == null) return null;
		// Re-bound out of the nullable field: a narrowing fact does not reach an anonymous structure
		// literal, and the result is one.
		final span: Span = nodeSpan;
		return {
			span: span,
			name: name,
			concrete: concrete,
			text: seams.source.substring(span.from, span.to)
		};
	}

	/**
	 * The edits rewriting one reference: the name token becomes `Map`, and an implied key type is
	 * spelled out by REPLACING the following `<` with `<Key, `. Replacing rather than inserting is
	 * what keeps a map of maps composable — a zero-length insert would start at the same byte as
	 * the nested head's own name edit, which no offset-ordered applier can sequence.
	 */
	private static function rewriteEdits(site: Site, nameAt: Int, open: Int): Array<{ span: Span, text: String }> {
		final base: Int = site.span.from;
		final edits: Array<{ span: Span, text: String }> = [nameEdit(base + nameAt, site.name)];
		final key: Null<String> = CONCRETE_MAP_KEY_TYPES[site.concrete];
		if (key != null && key != '') edits.push({ span: new Span(base + open, base + open + 1), text: '<$key, ' });
		return edits;
	}

	/** The edit replacing the concrete map's name token at `at` with the unified name. */
	private static inline function nameEdit(at: Int, name: String): { span: Span, text: String } {
		return { span: new Span(at, at + name.length), text: UNIFIED_MAP };
	}

	/** The offset of the type-parameter list's `<` at or after `from` in `text`, or -1 when the reference carries none. */
	private static function typeParameterOpen(text: String, from: Int): Int {
		var i: Int = from;
		while (i < text.length && text.isSpace(i)) i++;
		return i < text.length && text.fastCodeAt(i) == '<'.code ? i : -1;
	}

	/**
	 * The concrete map `name` PROVABLY denotes, or null. A fully-qualified reference proves
	 * itself; a short one needs the exact single import or a `haxe.ds` wildcard, and is refused
	 * outright when the module declares that name or an alias binds it (see the class doc).
	 */
	private static function resolveConcreteMap(name: String, scope: Scope): Null<String> {
		if (name.startsWith(QUALIFIED_PREFIX)) {
			final simple: String = name.substr(QUALIFIED_PREFIX.length);
			return CONCRETE_MAP_KEY_TYPES.exists(simple) ? simple : null;
		}
		if (!CONCRETE_MAP_KEY_TYPES.exists(name) || scope.declared.contains(name) || scope.aliases.contains(name)) return null;
		final imported: Null<String> = scope.imports[name];
		return if (imported != null)
			imported == QUALIFIED_PREFIX + name ? name : null
		else if (scope.wildcards.contains(MAP_MODULE_PACKAGE))
			name
		else
			null;
	}

	/** What `tree`'s file binds — the header imports plus every type the module declares — with the `Map` answer precomputed. */
	private static function scopeOf(tree: QueryNode, shape: RefShape): Scope {
		final typeDecls: Array<String> = (shape.typeDeclKinds ?? []).copy();
		final enumAbstract: Null<String> = shape.enumAbstractDeclKind;
		if (enumAbstract != null && !typeDecls.contains(enumAbstract)) typeDecls.push(enumAbstract);
		// A `final class` projects as a nameless wrapper around the named form, so the name is read
		// through the same host list `misplaced-type-doc` reads it through.
		final nameHosts: Array<String> = (shape.visibilityContainerKinds ?? []).concat(shape.interfaceDeclKinds ?? []);
		final scope: Scope = {
			imports: [],
			aliases: [],
			wildcards: [],
			declared: [],
			aliasTargets: [],
			mapFree: false
		};
		collectScope(tree, typeDecls, shape.aliasingDeclKinds ?? [], nameHosts, scope);
		final boundMap: Null<String> = scope.imports[UNIFIED_MAP];
		scope.mapFree = !scope.declared.contains(UNIFIED_MAP) && !scope.aliases.contains(UNIFIED_MAP)
			&& (boundMap == null || boundMap == QUALIFIED_PREFIX + UNIFIED_MAP);
		return scope;
	}

	/**
	 * Collect `node`'s subtree into `scope`. The walk is the WHOLE tree rather than the module's
	 * direct children so a declaration wrapped in a conditional region still registers as declared —
	 * the conservative direction for a shadowing question.
	 *
	 * A `using` binds a simple name exactly as an `import` does (it only ADDS extension resolution),
	 * so the two forms feed the same two slots: a foreign `using foo.Map;` shadows the unified name
	 * just as hard as `import foo.Map;`.
	 */
	private static function collectScope(
		node: QueryNode, typeDecls: Array<String>, aliasingDecls: Array<String>, nameHosts: Array<String>, scope: Scope
	): Void {
		final name: Null<String> = node.name;
		if (name != null) switch node.kind {
			case IMPORT_DECL_KIND | CheckScan.USING_DECL_KIND:
				scope.imports[CheckScan.simpleModuleName(name)] = name;
			case WILDCARD_IMPORT_KIND | WILDCARD_USING_KIND:
				if (StringTools.endsWith(name, WILDCARD_SUFFIX)) scope.wildcards.push(name.substr(0, name.length - WILDCARD_SUFFIX.length));
			case _:
				if (ALIAS_IMPORT_KINDS.contains(node.kind)) scope.aliases.push(name);
		}
		if (typeDecls.contains(node.kind)) {
			final declared: String = CheckScan.typeDeclName(node, nameHosts);
			scope.declared.push(declared);
			final target: Null<String> = aliasingDecls.contains(node.kind) ? aliasTargetOf(node) : null;
			if (target != null) scope.aliasTargets[declared] = target;
		}
		for (child in node.children) collectScope(child, typeDecls, aliasingDecls, nameHosts, scope);
	}

	/**
	 * The type a module-declared typedef / abstract stands for — a typedef's aliased type or an
	 * abstract's underlying type — or null when it is not a plain nominal.
	 *
	 * Both project as a LEADING run of type-reference children, and both may be preceded in that run
	 * by their own type-parameter constraints (`typedef T<K:Foo> = String` → `Foo`, then `String`;
	 * `abstract A<K:Foo>(MyClass)` → `Foo`, then `MyClass`). The head is therefore the LAST child of
	 * the run that is not NESTED inside an earlier one — the nesting test being what keeps
	 * `typedef T = Array<String>` answering `Array` rather than its type argument.
	 */
	private static function aliasTargetOf(node: QueryNode): Null<String> {
		var head: Null<QueryNode> = null;
		for (child in node.children) {
			if (child.kind != ANNOTATION_TYPE_KIND && child.kind != CLAUSE_TYPE_KIND) break;
			final span: Null<Span> = child.span;
			if (span == null) break;
			final current: Null<Span> = head?.span;
			if (current == null || span.from >= current.to || span.to <= current.from) head = child;
		}
		final name: Null<String> = head?.name;
		return name == null ? null : CheckScan.simpleModuleName(name);
	}

}
