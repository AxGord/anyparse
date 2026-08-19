package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/** One parameter of a candidate: the name it is written under and its declared primitive type. */
typedef CandidateParam = {
	final name: String;
	final type: String;
};

/**
 * A literal lifted out of a candidate's OWN body, carried as the verbatim source spelling so a
 * generated probe can splice it back unchanged. This is what keeps the mapping search finite: the
 * constants a hand-rolled reimplementation folds into its body (`'0'` in a zero-pad loop) are the
 * only constants the stdlib call it corresponds to may need, so the argument pool never has to be
 * invented.
 */
typedef CandidateLiteral = {
	final type: String;
	final code: String;
};

/**
 * A PURE, SELF-CONTAINED function with a primitive signature -- the only shape a differential
 * harness can drive without a project around it. `source` is the declaration verbatim (modifiers
 * excluded: they are sibling nodes, outside the function node's span), so a probe program can
 * re-emit it as a static of its own.
 */
typedef StdlibCandidate = {
	final file: String;
	final owner: Null<String>;
	final name: String;
	final params: Array<CandidateParam>;
	final returnType: String;
	final literals: Array<CandidateLiteral>;
	final span: Span;
	final source: String;
};

/**
 * Per-stage survivor counts of one scan, in filter order. Reported rather than summed away: the
 * drop-off between two stages is the measurement this scan exists to produce.
 */
typedef ScanStages = {
	var functions: Int;
	var bodied: Int;
	var arityOk: Int;
	var primitiveSig: Int;
	var selfContained: Int;
};

/** The candidates a scan admitted plus the per-stage counts that explain everything it refused. */
typedef ScanResult = {
	final candidates: Array<StdlibCandidate>;
	final stages: ScanStages;
};

/**
 * The CANDIDATE FILTER behind `apq stdlib-dup`: which functions in a tree could a differential
 * harness prove equivalent to a stdlib call, without a project around them?
 *
 * ## Why a filter at all -- the two cheaper channels are measured dead
 *
 * Detecting "someone reimplemented a stdlib function by hand" by NAME fails in both directions:
 * scanning a real 800-file tree for 27 stdlib names produced five hits and every one was a false
 * positive (a domain `filter` override, a null-safe `count`, a filesystem `exists`, a `clamp` the
 * Haxe stdlib does not have, a thin `parseInt` wrapper), while the motivating real case --
 * `CrashDumper.padDigit`, a hand-rolled `StringTools.lpad` -- matched no stdlib name at all. By
 * SIGNATURE it fails on the same case: `padDigit(Int, Int):String` shares neither arity nor types
 * with `lpad(String, String, Int):String`. The correspondence exists only MODULO AN ADAPTER (the
 * `Int` reaches the `String` slot through interpolation) plus a constant lifted from the body.
 *
 * What is left is a search over adapters and constants, and it is bounded rather than infinite --
 * but only for a function whose behaviour is a function of its arguments alone. That is what this
 * scan decides.
 *
 * ## The five gates, in order
 *
 * 1. A function DECLARATION (`functionKinds`, minus `localFunctionKinds` -- a local function is
 *    reached through its host, and its host is the unit a reader would replace).
 * 2. A real BODY (`functionBodyKinds` minus `noBodyKind`): an interface method or an `extern` has
 *    no behaviour to compare.
 * 3. ARITY 1..3 with no optional, rest, or defaulted parameter. The cap is what keeps the later
 *    mapping enumeration bounded; an omitted argument would make the probe's call shape ambiguous.
 * 4. Every parameter type AND the return type PRIMITIVE (`Int` / `Float` / `String` / `Bool`) --
 *    the types a harness can enumerate inputs for. Parameter types come from
 *    `TypeInfoProvider.declaredTypes` (the `QueryNode` projection drops them); the return type is
 *    the function's own `typeAnnotationKinds` child, so an un-annotated return is refused rather
 *    than inferred.
 * 5. SELF-CONTAINMENT: every free name in the body is either bound inside the function (a
 *    parameter, a local, a loop or case binder, a catch clause, a lambda parameter, or the
 *    function's own name for recursion) or one of `STDLIB_NAMES`. `this` and `super` are free
 *    names under that rule and fail it, which is the intent. Allocation, `throw` and `untyped` are
 *    refused outright, as is any member named in `NONDETERMINISTIC_MEMBERS`.
 *
 * Gate 5 is deliberately NAME-level and index-free. It answers a question about one function's
 * text, so it needs no resolution scope, and a wrong index cannot make it silently permissive. It
 * is also only the PREFILTER: the differential's generated program contains the candidate verbatim
 * in a module with nothing else in it, so the compiler is the terminal proof of self-containment
 * and this scan only has to be cheap and conservative.
 *
 * Grammar-agnostic: every kind is read off `RefShape`, and an unset seam narrows the scan rather
 * than guessing (`typeAnnotationKinds` unset means no return type is ever accepted, so the scan
 * yields nothing instead of yielding noise).
 */
@:nullSafety(Strict)
final class StdlibDupScan {

	/** Types the differential can enumerate inputs for, so the only ones a candidate may mention. */
	public static final PRIMITIVE_TYPES: Array<String> = ['Int', 'Float', 'String', 'Bool'];

	/**
	 * Free names a self-contained candidate may reference: the deterministic, side-effect-free
	 * stdlib surface a probe module gets for free. `Sys`, `Date`, `Reflect` and the rest are
	 * absent on purpose -- a body reaching one is either non-deterministic or not a pure function.
	 */
	public static final STDLIB_NAMES: Array<String> = ['Math', 'Std', 'StringTools', 'String'];

	/** Above this arity the mapping enumeration stops being bounded in practice. */
	private static inline final MAX_ARITY: Int = 3;

	/** Body literals carried into the mapping enumeration, in document order. */
	private static inline final MAX_LITERALS: Int = 8;

	/** Members of a `STDLIB_NAMES` receiver that are NOT deterministic; a body touching one is refused. */
	private static final NONDETERMINISTIC_MEMBERS: Array<String> = ['random'];

	/**
	 * Every candidate in one file, plus the per-stage counts. A file the plugin cannot parse
	 * yields an empty result rather than throwing -- a scan over a tree must survive one bad file.
	 */
	public static function scan(file: String, source: String, plugin: GrammarPlugin): ScanResult {
		final stages: ScanStages = {
			functions: 0,
			bodied: 0,
			arityOk: 0,
			primitiveSig: 0,
			selfContained: 0
		};
		final candidates: Array<StdlibCandidate> = [];
		final root: Null<QueryNode> = try plugin.parseFile(source) catch (exception: Exception) null;
		if (root == null) return { candidates: candidates, stages: stages };
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		final declaredTypes: Map<Int, String> = provider != null ? provider.declaredTypes(source) : [];
		visit(root, null, file, source, plugin.refShape(), declaredTypes, stages, candidates);
		return { candidates: candidates, stages: stages };
	}

	/** The same scan across many files, candidates in input order and stage counts summed. */
	public static function scanAll(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): ScanResult {
		final stages: ScanStages = {
			functions: 0,
			bodied: 0,
			arityOk: 0,
			primitiveSig: 0,
			selfContained: 0
		};
		final candidates: Array<StdlibCandidate> = [];
		for (entry in files) {
			final one: ScanResult = scan(entry.file, entry.source, plugin);
			stages.functions += one.stages.functions;
			stages.bodied += one.stages.bodied;
			stages.arityOk += one.stages.arityOk;
			stages.primitiveSig += one.stages.primitiveSig;
			stages.selfContained += one.stages.selfContained;
			for (candidate in one.candidates) candidates.push(candidate);
		}
		return { candidates: candidates, stages: stages };
	}

	/** Walks the tree, tracking the enclosing type name and handing every function declaration to `consider`. */
	private static function visit(
		node: QueryNode, owner: Null<String>, file: String, source: String, shape: RefShape, declaredTypes: Map<Int, String>,
		stages: ScanStages, out: Array<StdlibCandidate>
	): Void {
		final typeDeclKinds: Array<String> = shape.typeDeclKinds ?? [];
		final nodeName: Null<String> = node.name;
		final here: Null<String> = typeDeclKinds.contains(node.kind) && nodeName != null ? nodeName : owner;
		final functionKinds: Array<String> = shape.functionKinds ?? [];
		final localFunctionKinds: Array<String> = shape.localFunctionKinds ?? [];
		if (functionKinds.contains(node.kind) && !localFunctionKinds.contains(node.kind))
			consider(node, here, file, source, shape, declaredTypes, stages, out);
		for (child in node.children) visit(child, here, file, source, shape, declaredTypes, stages, out);
	}

	/** Runs the five gates over one function declaration, pushing a candidate only when all five pass. */
	private static function consider(
		fn: QueryNode, owner: Null<String>, file: String, source: String, shape: RefShape, declaredTypes: Map<Int, String>,
		stages: ScanStages, out: Array<StdlibCandidate>
	): Void {
		stages.functions++;
		final body: Null<QueryNode> = bodyOf(fn, shape);
		final fnName: Null<String> = fn.name;
		final span: Null<Span> = fn.span;
		if (body == null || fnName == null || span == null) return;
		stages.bodied++;

		final params: Null<Array<QueryNode>> = plainParams(fn, shape);
		if (params == null) return;
		stages.arityOk++;

		final resolved: Null<Array<CandidateParam>> = primitiveParams(params, declaredTypes);
		if (resolved == null) return;
		final typed: Array<CandidateParam> = resolved;
		final written: Null<String> = returnTypeOf(fn, shape);
		if (written == null || !PRIMITIVE_TYPES.contains(written)) return;
		final returnType: String = written;
		stages.primitiveSig++;

		final declaredName: String = fnName;
		final declaredSpan: Span = span;
		final bound: Array<String> = [fnName];
		for (param in typed) bound.push(param.name);
		collectBinders(body, shape, bound);
		if (!isSelfContained(body, shape, bound)) return;
		stages.selfContained++;
		out.push({
			file: file,
			owner: owner,
			name: declaredName,
			params: typed,
			returnType: returnType,
			literals: literalsOf(body, shape),
			span: declaredSpan,
			source: source.substring(declaredSpan.from, declaredSpan.to)
		});
	}

	/**
	 * The function's parameters when every one of them is plain -- no optional, no rest, no default
	 * -- and there are between one and `MAX_ARITY` of them. Null when any of that fails: a nullary
	 * function has no input to drive a differential with, and an omitted argument would leave the
	 * probe's call shape ambiguous.
	 */
	private static function plainParams(fn: QueryNode, shape: RefShape): Null<Array<QueryNode>> {
		final paramKinds: Array<String> = shape.paramKinds ?? [];
		final params: Array<QueryNode> = fn.children.filter(c -> paramKinds.contains(c.kind));
		if (params.length < 1 || params.length > MAX_ARITY) return null;
		for (param in params) {
			if (param.kind == shape.optionalParamKind || param.kind == shape.restParamKind) return null;
			if (param.children.length > 0) return null;
			if (param.name == null || param.span == null) return null;
		}
		return params;
	}

	/**
	 * The parameters paired with their declared types, or null when any one of them lacks a
	 * `TypeInfoProvider` entry or carries a non-primitive type. The `QueryNode` projection drops
	 * parameter types, so the index is the only source -- and its absence is a refusal, never a guess.
	 */
	private static function primitiveParams(params: Array<QueryNode>, declaredTypes: Map<Int, String>): Null<Array<CandidateParam>> {
		final typed: Array<CandidateParam> = [];
		for (param in params) {
			final paramName: Null<String> = param.name;
			final paramSpan: Null<Span> = param.span;
			if (paramName == null || paramSpan == null) return null;
			final declared: Null<String> = declaredTypes[paramSpan.from];
			if (declared == null || !PRIMITIVE_TYPES.contains(declared)) return null;
			final type: String = declared;
			final bindingName: String = paramName;
			typed.push({ name: bindingName, type: type });
		}
		return typed;
	}

	/** The function's real body, or null when it declares none (an interface method, an `extern`). */
	private static function bodyOf(fn: QueryNode, shape: RefShape): Null<QueryNode> {
		final bodyKinds: Array<String> = shape.functionBodyKinds ?? [];
		final noBodyKind: Null<String> = shape.noBodyKind;
		var body: Null<QueryNode> = null;
		for (child in fn.children) if (bodyKinds.contains(child.kind) && child.kind != noBodyKind) body = child;
		return body;
	}

	/** The SIMPLE name of the function's written return type, or null when it carries no annotation. */
	private static function returnTypeOf(fn: QueryNode, shape: RefShape): Null<String> {
		final annotationKinds: Array<String> = shape.typeAnnotationKinds ?? [];
		var written: Null<String> = null;
		for (child in fn.children) if (annotationKinds.contains(child.kind)) written = child.name;
		return written;
	}

	/** Every name a declaration inside the body introduces, appended to `out` (deduped). */
	private static function collectBinders(node: QueryNode, shape: RefShape, out: Array<String>): Void {
		final name: Null<String> = node.name;
		if (name != null && binderKinds(shape).contains(node.kind) && !out.contains(name)) out.push(name);
		for (child in node.children) collectBinders(child, shape, out);
	}

	/** The kinds whose node NAME is a binding: locals, parameters, loop and case binders, catch clauses. */
	private static function binderKinds(shape: RefShape): Array<String> {
		final kinds: Array<String> = [];
		inline function add(more: Null<Array<String>>): Void if (more != null) for (kind in more) kinds.push(kind);
		add(shape.localDeclKinds);
		add(shape.localDeclContinuationKinds);
		add(shape.paramKinds);
		add(shape.iterationBindingKinds);
		add(shape.iterationValueBinderKinds);
		add(shape.casePatternBinderKinds);
		add(shape.localFunctionKinds);
		final catchKind: Null<String> = shape.catchClauseKind;
		if (catchKind != null) kinds.push(catchKind);
		return kinds;
	}

	/**
	 * Whether every free name in the subtree is bound inside the function or an allowlisted stdlib
	 * entry point, and the subtree allocates nothing, throws nothing, and reads nothing
	 * non-deterministic. Refusal is the safe answer: a missed candidate costs one report, an
	 * admitted non-pure one costs a differential run that means nothing.
	 */
	private static function isSelfContained(node: QueryNode, shape: RefShape, bound: Array<String>): Bool {
		final kind: String = node.kind;
		if (kind == shape.newExprKind) return false;
		if ((shape.throwKinds ?? []).contains(kind)) return false;
		if ((shape.untypedKinds ?? []).contains(kind)) return false;
		final name: Null<String> = node.name;
		final free: Bool = kind == shape.identKind || kind == shape.stringInterpIdentKind;
		if (free && (name == null || (!bound.contains(name) && !STDLIB_NAMES.contains(name)))) return false;
		if (kind == shape.fieldAccessKind && name != null && NONDETERMINISTIC_MEMBERS.contains(name)) return false;
		return node.children.foreach(child -> isSelfContained(child, shape, bound));
	}

	/** The first `MAX_LITERALS` distinct literals of the body, in document order. */
	private static function literalsOf(body: QueryNode, shape: RefShape): Array<CandidateLiteral> {
		final out: Array<CandidateLiteral> = [];
		gatherLiterals(body, shape, out);
		return out.length > MAX_LITERALS ? out.slice(0, MAX_LITERALS) : out;
	}

	/**
	 * Appends every numeric literal, every whole string literal, and every string-INTERPOLATION
	 * FRAGMENT of the subtree, each as the source spelling a probe can splice back. The fragment
	 * half is what makes the motivating case work at all: the `'0'` a zero-pad loop prepends is
	 * never a literal node of its own, only a fragment inside `'0$str'`.
	 */
	private static function gatherLiterals(node: QueryNode, shape: RefShape, out: Array<CandidateLiteral>): Void {
		final kind: String = node.kind;
		final name: Null<String> = node.name;
		if (name != null && (shape.numericLiteralKinds ?? []).contains(kind)) {
			final numeric: String = name;
			push(out, { type: numeric.indexOf('.') >= 0 ? 'Float' : 'Int', code: numeric });
		}
		if ((shape.stringLiteralKinds ?? []).contains(kind)) {
			if (name != null && node.children.length == 0) {
				final whole: String = name;
				push(out, { type: 'String', code: whole });
			}
			for (child in node.children) {
				final fragment: Null<String> = child.children.length == 0 ? child.name : null;
				if (fragment == null || !spliceableFragment(fragment)) continue;
				final text: String = fragment;
				push(out, { type: 'String', code: '\'$text\'' });
			}
		}
		for (child in node.children) gatherLiterals(child, shape, out);
	}

	/**
	 * Whether an interpolation fragment can be re-quoted as a single-quoted literal verbatim. A
	 * quote, a backslash or an interpolation sigil would change meaning on the way back in, and
	 * the fragment is not worth reconstructing -- refuse it.
	 */
	private static function spliceableFragment(fragment: String): Bool {
		return fragment.length > 0 && fragment.indexOf("'") < 0 && fragment.indexOf('\\') < 0 && fragment.indexOf('$') < 0;
	}

	/** Appends `literal` unless an identical spelling is already collected. */
	private static function push(out: Array<CandidateLiteral>, literal: CandidateLiteral): Void {
		for (seen in out) if (seen.code == literal.code) return;
		out.push(literal);
	}

}
