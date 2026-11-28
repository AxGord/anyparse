package anyparse.check.common.expressions;

import anyparse.check.scan.ArrowTail;
import anyparse.check.scan.OperandBinder;
import anyparse.query.Constructs;
import anyparse.query.ElementSpan;
import anyparse.query.IndexScope;
import anyparse.query.LexicalRegions;
import anyparse.query.NodeShape;
import anyparse.query.Refs;
import anyparse.query.ShapeVocab;
import anyparse.query.SourceComments;
import anyparse.query.SymbolIndex;
import anyparse.query.TreePath;

using anyparse.util.Groups;

/** The kinds and the construct builder `single-use-local-function` reads. */
private typedef Seams = {
	final shape: RefShape;
	final localFunctionKinds: Array<String>;
	final paramKinds: Array<String>;
	final bodyKinds: Array<String>;
	final typeAnnotationKinds: Array<String>;
	final valueReturnKinds: Array<String>;
	final localDeclKinds: Array<String>;
	final barrierKinds: Array<String>;
	final opaqueKinds: Array<String>;
	final voidTypeName: String;
	final constructs: Constructs;
};

/**
 * One rewritable local function: its declaration (the finding key), the bytes the fix deletes, its one reference and the
 * lambda that replaces it.
 */
private typedef Match = {
	var span: Span;
	final cut: Span;
	final read: Span;
	final lambda: Built;
};

/** What one file's scan reads lazily: the lexical regions, the type parameters each declaration declares, the operand binder. */
private typedef FileScan = {
	final file: String;
	final source: String;
	final tree: QueryNode;
	final plugin: GrammarPlugin;
	final regions: () -> Array<LexRegion>;
	final typeParams: () -> Map<Int, Array<String>>;
	final binder: () -> Null<OperandBinder>;
};

/** A local function's parts: its parameter spans, its return-type hint and its body. */
private typedef FnParts = { final params: Array<Span>; final hint: Null<QueryNode>; final body: QueryNode; };

/**
 * Flags a local named function that is referenced exactly once, and there as a VALUE, and rewrites it into a lambda at that
 * reference, deleting the declaration:
 *
 * ```haxe
 * function fix(): Int { return run(files); }
 * return dryRun(o.dryRun, fix);
 * // ->
 * return dryRun(o.dryRun, () -> run(files));
 * ```
 *
 * A body of one `return e;` becomes the lambda's expression `e`; any other body is carried whole as `() -> { … }`. The
 * lambda is built by the grammar (`Constructs.lambda`), the parameters and the body copied from the source by span.
 *
 * ## Gates
 *
 * - The one reference is a call or construction ARGUMENT, a returned value, a declaration's initializer or an assignment's
 *   right-hand side. A function called by name, read twice or more, or reading its own name (recursion) stays.
 * - The reference is evaluated at most once per run of the declaration: no loop or function boundary (`barrierKinds`)
 *   lies between the declaration's statement list and it, since a lambda there would be a fresh closure on every pass.
 * - Every name the body reads from outside binds the same declaration at the reference as at the declaration, so moving
 *   the body under a later shadowing declaration cannot rebind it.
 * - The function declares no type parameter, carries no metadata (a metadata-headed local function is another node
 *   kind) and no comment above it or in a part the rewrite drops; no parameter is optional, defaulted or a rest.
 * - Its RESULT survives. An arrow answers its body's last expression where a `function` with no `return` answers `Void`
 *   (`ArrowTail`), and an arrow has no return-type hint. So the fix needs no proof only where the body is `ArrowTail`
 *   preserving or `Void`-tailed and the hint is absent or `Void`; anywhere else the reference's position must expect a
 *   function whose result is the hint (`Void` for none) — read through the resolution index (`OperandBinder.expectsResult`).
 *
 * Nothing that fails a gate is reported: every finding is fixable.
 */
@:nullSafety(Strict)
final class SingleUseLocalFunction extends RuleBase {

	private static inline final RULE_ID: String = 'single-use-local-function';
	private static final MSG: String = 'this local function is used once, as a value — write it as a lambda there';

	public function new() {
		super(
			RULE_ID, 'a local function referenced once, as a value, replaceable with a lambda at that reference', RuleCategory.Expressions
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final getIndex: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		return RunScan.collectWith(files, plugin, readSeams(plugin), (entry, tree, s, violations) -> {
			for (m in collect(scanOf(entry.file, entry.source, tree, plugin, getIndex), s)) violations.push({
				file: entry.file,
				span: m.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: MSG
			});
		});
	}

	/**
	 * Each flagged function's two edits: the declaration deleted, the reference replaced by the lambda. A function declared
	 * inside another flagged one rides in the outer lambda as written, its own edits dropped as contained, and waits a pass.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return RunScan.matchedEdits(
			plugin, source, readSeams(plugin), violations, index,
			(tree, s, symbols, file) -> collect(scanOf(file, source, tree, plugin, symbols), s),
			m -> [{ span: m.cut, text: '' }, { span: m.read, text: m.lambda.text }]
		);
	}

	/** Bundle the kinds the check reads, or null when the grammar names no local function or builds no construct. */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final localFunctionKinds: Null<Array<String>> = shape.localFunctionKinds;
		if (localFunctionKinds == null || localFunctionKinds.length == 0) return null;
		final voidTypeName: Null<String> = shape.voidTypeName;
		final constructs: Null<Constructs> = plugin.constructs();
		if (voidTypeName == null || constructs == null) return null;
		final barriers: Array<String> = ShapeVocab.functionLikeKinds(shape);
		barriers.pushAllUnique(ShapeVocab.loopKinds(shape));
		return {
			shape: shape,
			localFunctionKinds: localFunctionKinds,
			paramKinds: shape.paramKinds ?? [],
			bodyKinds: shape.functionBodyKinds ?? [],
			typeAnnotationKinds: shape.typeAnnotationKinds ?? [],
			valueReturnKinds: shape.valueReturnKinds ?? [],
			localDeclKinds: shape.localDeclKinds ?? [],
			barrierKinds: barriers,
			opaqueKinds: shape.opaqueKinds ?? [],
			voidTypeName: voidTypeName,
			constructs: constructs
		};
	}

	private static function scanOf(
		file: String, source: String, tree: QueryNode, plugin: GrammarPlugin, getIndex: () -> Null<SymbolIndex>
	): FileScan {
		var typeParams: Null<Map<Int, Array<String>>> = null;
		var binder: Null<OperandBinder> = null;
		var bound: Bool = false;
		return {
			file: file,
			source: source,
			tree: tree,
			plugin: plugin,
			regions: ElementSpan.lazyRegions(source, plugin),
			typeParams: () -> {
				final known: Map<Int, Array<String>> = typeParams ?? RunScan.typeParamNamesOf(plugin, source);
				typeParams = known;
				return known;
			},
			binder: () -> {
				if (!bound) {
					bound = true;
					final index: Null<SymbolIndex> = getIndex();
					binder = index == null ? null : OperandBinder.forFile(plugin, file, source, tree, index);
				}
				return binder;
			}
		};
	}

	/** Every rewritable local function of the file, opaque subtrees (macro reification) skipped whole. */
	private static function collect(f: FileScan, s: Seams): Array<Match> {
		final out: Array<Match> = [];
		function walk(node: QueryNode): Void {
			if (s.opaqueKinds.contains(node.kind)) return;
			for (c in node.children) {
				if (s.localFunctionKinds.contains(c.kind)) {
					final m: Null<Match> = matchOf(c, node, f, s);
					if (m != null) out.push(m);
				}
				walk(c);
			}
		}
		walk(f.tree);
		return out;
	}

	private static function matchOf(fn: QueryNode, list: QueryNode, f: FileScan, s: Seams): Null<Match> {
		final name: Null<String> = fn.name;
		final span: Null<Span> = fn.span;
		if (name == null || span == null) return null;
		if ((f.typeParams()[span.from] ?? []).length > 0) return null;
		final parts: Null<FnParts> = partsOf(fn, s);
		if (parts == null) return null;
		final ref: Null<QueryNode> = soleValueRead(name, span, list, f, s);
		final refSpan: Null<Span> = ref?.span;
		if (ref == null || refSpan == null) return null;
		if (!capturesSurvive(parts.body, span, refSpan.from, f, s)) return null;
		if (!resultSurvives(parts, ref, f, s)) return null;
		final cut: Span = ElementSpan.elementCut(f.source, fn, list, span, false, f.regions, s.shape, [fn]).span;
		final kept: Null<Span> = keptBodySpan(parts.body, f, s);
		if (kept == null || commentDropped(cut, kept, span.from, f)) return null;
		final body: Null<Built> = s.constructs.copied(f.source, kept, Expression);
		final lambda: Null<Built> =
			body == null ? null : s.constructs.lambda(parts.params.map(p -> f.source.substring(p.from, p.to)), body);
		return lambda == null ? null : {
			span: span,
			cut: cut,
			read: refSpan,
			lambda: lambda
		};
	}

	/** The function's parameters, hint and body; null for an optional, defaulted or rest parameter, or a child of no known role. */
	private static function partsOf(fn: QueryNode, s: Seams): Null<FnParts> {
		final params: Array<Span> = [];
		var hint: Null<QueryNode> = null;
		var body: Null<QueryNode> = null;
		for (c in fn.children) {
			final cs: Null<Span> = c.span;
			if (cs == null) return null;
			if (s.paramKinds.contains(c.kind)) {
				if (c.kind == s.shape.restParamKind || c.kind == s.shape.optionalParamKind || c.children.length > 0) return null;
				params.push(cs);
			} else if (s.bodyKinds.contains(c.kind)) {
				body = c;
			} else if (s.typeAnnotationKinds.contains(c.kind)) {
				hint = c;
			} else {
				return null;
			}
		}
		final b: Null<QueryNode> = body;
		return b == null || b.kind == s.shape.noBodyKind ? null : { params: params, hint: hint, body: b };
	}

	/**
	 * The one reference of `name` bound to the declaration `declSpan`, when it is a read outside the declaration, in a
	 * value position, reached from the declaration's statement list `list` through no barrier.
	 */
	private static function soleValueRead(name: String, declSpan: Span, list: QueryNode, f: FileScan, s: Seams): Null<QueryNode> {
		final bound: Array<RefHit> = Refs.find(name, f.tree, s.shape).filter(h -> {
			final bs: Null<Span> = h.bindingSpan;
			return h.kind != RefKind.Decl && bs != null && bs.from >= declSpan.from && bs.to <= declSpan.to;
		});
		if (bound.length != 1) return null;
		final hit: RefHit = bound[0];
		if (hit.kind != RefKind.Read || hit.interpolated) return null;
		final ref: Null<QueryNode> = TreePath.withSpan(f.tree, hit.span, s.shape.identKind);
		if (ref == null) return null;
		final path: Null<Array<QueryNode>> = TreePath.pathTo(f.tree, ref);
		if (path == null || path.length < 2) return null;
		final from: Int = path.indexOf(list);
		return from >= 0
			&& !path.slice(from + 1, path.length - 1).exists(n -> s.barrierKinds.contains(n.kind))
			&& isValuePosition(ref, path[path.length - 2], s)
			? ref
			: null;
	}

	/** Whether `ref` is passed as a value by its parent: an argument, a returned value, an initializer, an assigned value. */
	private static function isValuePosition(ref: QueryNode, parent: QueryNode, s: Seams): Bool {
		final at: Int = parent.children.indexOf(ref);
		final kind: String = parent.kind;
		return (kind == s.shape.callKind && at >= 1)
			|| (kind == s.shape.newExprKind && at >= parent.typeArgCount)
			|| s.valueReturnKinds.contains(kind)
			|| (s.localDeclKinds.contains(kind) && NodeShape.initOf(parent) == ref)
			|| (kind == s.shape.assignKind && at == 1);
	}

	/**
	 * Whether no name the body reads is declared again between the declaration and the reference at `refFrom`: such a
	 * declaration could shadow the binding the body captured, and the moved body would read it instead.
	 */
	private static function capturesSurvive(body: QueryNode, declSpan: Span, refFrom: Int, f: FileScan, s: Seams): Bool {
		final names: Array<String> = [];
		function gather(n: QueryNode): Void {
			final nm: Null<String> = n.name;
			if ((n.kind == s.shape.identKind || n.kind == s.shape.stringInterpIdentKind) && nm != null && !names.contains(nm))
				names.push(nm);
			for (c in n.children) gather(c);
		}
		gather(body);
		for (hits in Refs.findMulti(names, f.tree, s.shape))
			for (h in hits)
				if (h.kind == RefKind.Decl && h.span.from >= declSpan.to && h.span.from < refFrom) return false;
		return true;
	}

	/**
	 * Whether the function's result type survives the rewrite: proved by the body's shape for no hint or a `Void` one,
	 * otherwise by the reference's position expecting a function whose result is the hint (`Void` for none).
	 */
	private static function resultSurvives(parts: FnParts, ref: QueryNode, f: FileScan, s: Seams): Bool {
		final hint: Null<QueryNode> = parts.hint;
		final hintSpan: Null<Span> = hint?.span;
		final hintText: Null<String> = hintSpan == null ? null : f.source.substring(hintSpan.from, hintSpan.to);
		final voidHint: Bool = hintText == null || isVoid(hintText, f, s);
		if (voidHint && ArrowTail.of(parts.body, s.shape) != Open) return true;
		final binder: Null<OperandBinder> = f.binder();
		final at: Int = hintSpan?.from ?? parts.body.span?.from ?? 0;
		return binder != null && binder.expectsResult(ref, { text: hintText ?? s.voidTypeName, at: at });
	}

	/** Whether the written type `text` is the grammar's `Void`. */
	private static function isVoid(text: String, f: FileScan, s: Seams): Bool {
		return switch f.plugin.typeSyntax(text)?.shape {
			case Nominal(path, []) if (path == s.voidTypeName): true;
			case _: false;
		};
	}

	/**
	 * The span the lambda carries as its body: the value of a lone `return e`, whether written as an expression body or as
	 * the one statement of a block, else the whole block. Null for a comment between the `return` and its value.
	 */
	private static function keptBodySpan(body: QueryNode, f: FileScan, s: Seams): Null<Span> {
		final bodySpan: Null<Span> = body.span;
		if (bodySpan == null) return null;
		final lone: Null<QueryNode> = body.children.length == 1 ? body.children[0] : null;
		final value: Null<QueryNode> = lone != null && s.valueReturnKinds.contains(lone.kind) && lone.children.length == 1
			? lone.children[0]
			: null;
		final valueSpan: Null<Span> = value?.span;
		if (valueSpan == null) return body.kind == s.shape.blockBodyKind ? bodySpan : lone?.span;
		final commented: Bool = LexicalRegions.commentIntersects(bodySpan.from, valueSpan.from, f.regions())
			|| LexicalRegions.commentIntersects(valueSpan.to, bodySpan.to, f.regions());
		return if (!commented)
			valueSpan
		else if (body.kind == s.shape.blockBodyKind)
			bodySpan
		else
			null;
	}

	/**
	 * Whether a comment sits in the deleted bytes outside the body the lambda carries, or on its own line right above the
	 * declaration starting at `declFrom` — a doc or a note that documents the function the rewrite takes away.
	 */
	private static function commentDropped(cut: Span, kept: Span, declFrom: Int, f: FileScan): Bool {
		return LexicalRegions.commentIntersects(cut.from, kept.from, f.regions())
			|| LexicalRegions.commentIntersects(kept.to, cut.to, f.regions())
			|| SourceComments.ownLineCommentAbove(f.source, SourceComments.collectCommentTokens(f.regions()), declFrom, false) >= 0;
	}

}
