package anyparse.query;

import anyparse.check.NativeCodeScan;
import anyparse.query.FactsView.TruthSites;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.runtime.Span;

using Lambda;

/**
 * The POSITIVE check a reachability walk runs over every body it enters: each node kind must be one the
 * grammar declares modelled (`ExecutionShape.modelledKinds`), and the sites a call graph does not carry are listed
 * — reflective member accesses (with the literal name when there is one), target-language carriers, untyped
 * code, raw conditional regions, and every site that changes SOME array (an element write, an
 * array-changing method on any receiver). A kind outside the whitelist is a blind spot of its own, so a
 * construct nobody classified fails closed. Where the compiler facts are the truth
 * (`FactsView.truth`), `underTruth` trades the hazards they record in full for their own sites.
 */
@:nullSafety(Strict)
final class ReachHazards {

	/** File -> the hazards its tree carries, computed on first demand. */
	private final _byFile: Map<String, Array<ReachHazard>> = [];

	private final _plugin: GrammarPlugin;
	private final _shape: RefShape;

	public function new(plugin: GrammarPlugin) {
		_plugin = plugin;
		_shape = plugin.refShape();
	}

	public inline function isAccess(kind: String): Bool {
		return kind == _shape.fieldAccessKind || kind == _shape.nullSafeAccessKind || kind == _shape.forceFieldAccessKind;
	}

	/** Every call node in `tree` inside `span`. */
	public function callsIn(tree: QueryNode, span: Span): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		function walk(node: QueryNode): Void {
			final s: Null<Span> = node.span;
			if (s != null && (s.to <= span.from || s.from >= span.to)) return;
			if (node.kind == _shape.callKind && s != null && s.from >= span.from && s.to <= span.to) out.push(node);
			for (c in node.children) walk(c);
		}
		walk(tree);
		return out;
	}

	/** Drop what was computed for `file`, whose text changed. */
	public function forget(file: String): Void {
		_byFile.remove(file);
	}

	/** The hazards of `tree` (the text of `file` is `source`) inside `span`, in document order. */
	public function hazardsIn(file: String, tree: QueryNode, source: String, span: Span): Array<ReachHazard> {
		return [
			for (h in hazardsOfFile(file, tree, source)) if (h.span.from >= span.from && h.span.to <= span.to) h
		];
	}

	/**
	 * The hazards of code whose compiler facts are the truth (`FactsView.truthSites`): `syntactic`, its hazards as the syntax
	 * reads them, less those the facts record in full, plus a native site for each the facts name and a computed name for
	 * each reflective access by name the syntax does not see (`typed`). The facts record a native call however it is
	 * spelled — an alias, an import — and not one a class merely named `Syntax` makes, so the syntax's native calls go; an
	 * `untyped` expression goes when it is built only of what the facts record (`untypedRecorded`). Every other hazard stays:
	 * the facts do not say what they would stand for. A reflective call's recorded literal is the first of ANY argument,
	 * not the name's, so one the syntax does not see names nothing. `root` is the tree the added hazards hang off.
	 */
	public function underTruth(syntactic: Array<ReachHazard>, typed: TruthSites, root: QueryNode): Array<ReachHazard> {
		final out: Array<ReachHazard> = [for (h in syntactic) if (!recordedWhole(h)) h];
		for (n in typed.natives) out.push({ kind: Native, span: n.at.span, node: root });
		final named: Map<String, Int> = _shape.execution?.reflectiveNameCalls ?? [];
		inline function seen(at: Span): Bool {
			return syntactic.exists(h -> h.kind.match(ReflectiveName(_)) && same(h.span, at));
		}
		for (r in typed.reflection) if (named.exists(r.target) && !seen(r.at.span))
			out.push({ kind: ReflectiveName(null), span: r.at.span, node: root });
		out.sort((a, b) -> a.span.from - b.span.from);
		return out;
	}

	/**
	 * The spans of the field initializers of the type named `typeName` in `tree` — the instance ones, or with
	 * `isStatic` the static ones: the code the `<init>` / `<static>` pseudo-node of the call graph runs. Null
	 * when no single declaration of that name is found, which a caller reads as a blind spot.
	 */
	public function initializerSpans(tree: QueryNode, typeName: String, isStatic: Bool): Null<Array<Span>> {
		final decls: Array<QueryNode> = [];
		function find(node: QueryNode): Void {
			if (CallGraphNames.typeNameOf(node) == typeName) decls.push(node);
			for (c in node.children) find(c);
		}
		find(tree);
		if (decls.length != 1) return null;
		final fieldKinds: Array<String> = _shape.fieldDeclKinds ?? [];
		final staticKind: Null<String> = _shape.staticModifierKind;
		final boundary: QueryNode -> Bool = c -> c.children.length > 0 || c.name != null;
		final kids: Array<QueryNode> = decls[0].children;
		final out: Array<Span> = [];
		for (i in 0...kids.length) {
			final c: QueryNode = kids[i];
			if (!fieldKinds.contains(c.kind) || MemberKinds.macroModifierPrecedes(kids, i, staticKind, boundary) != isStatic) continue;
			final init: Null<QueryNode> = CtorFieldFold.declInitializer(c, _shape);
			final span: Null<Span> = init?.span;
			if (span != null) out.push(span);
		}
		return out;
	}

	/** The literal member name a reflective accessor call passes, or null when `node` is not one or the name is computed. */
	public function reflectiveNameWith(node: QueryNode, source: String, stringFold: Null<StringFoldSupport>): Null<String> {
		final arg: Null<QueryNode> = nameArgumentOf(node);
		final literal: Null<StringLiteral> = arg == null || stringFold == null ? null : stringFold.literalOf(arg, source);
		return literal?.content;
	}

	/**
	 * The object a reflective access by name (`RefShape.reflectiveNameCalls`) acts on — the argument just before the name
	 * (`Reflect.field(o, "x")` -> `o`) — or null when `node` is no such call or names nothing before the name.
	 */
	public function reflectiveReceiverOf(node: QueryNode): Null<QueryNode> {
		final at: Null<Int> = reflectiveNameIndex(node);
		return at == null || at < 1 || at >= node.children.length ? null : node.children[at];
	}

	/** Every hazard of `file`'s tree, computed once. */
	private function hazardsOfFile(file: String, tree: QueryNode, source: String): Array<ReachHazard> {
		final cached: Null<Array<ReachHazard>> = _byFile[file];
		if (cached != null) return cached;
		final out: Array<ReachHazard> = [];
		_byFile[file] = out;
		final stringFold: Null<StringFoldSupport> = _plugin.stringFoldSupport();
		final untypedKinds: Array<String> = _shape.untypedKinds ?? [];
		final opaqueKinds: Array<String> = _shape.opaqueKinds ?? [];
		final opaqueRegionKinds: Array<String> = _shape.opaqueCondRegionKinds ?? [];
		final modelled: Array<String> = _shape.execution?.modelledKinds ?? [];
		function walk(node: QueryNode): Void {
			// a reification subtree is compile-time emission; it runs nothing when the program does
			if (opaqueKinds.contains(node.kind)) return;
			final at: Null<Span> = node.span;
			if (at != null) {
				final span: Span = at;
				if (untypedKinds.contains(node.kind))
					out.push({ kind: Untyped, span: span, node: node });
				else if (opaqueRegionKinds.contains(node.kind))
					out.push({ kind: Opaque, span: span, node: node });
				else if (!modelled.contains(node.kind))
					out.push({ kind: Unmodelled(node.kind), span: span, node: node });
				else if (NativeCodeScan.isCarrier(node, _shape, stringFold))
					out.push({ kind: Native, span: span, node: node });
				else if (nameArgumentOf(node) != null)
					out.push({ kind: ReflectiveName(reflectiveNameWith(node, source, stringFold)), span: span, node: node });
				else if (changesAnArray(node))
					out.push({ kind: ArrayChange, span: span, node: node });
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		for (region in CondRegionScan.opaqueCondRegions(tree, source, _shape)) out.push({ kind: Opaque, span: region.region, node: tree });
		return out;
	}

	/** Whether the compiler facts of the code holding the syntactic hazard `h` record all it stands for (`underTruth`). */
	private function recordedWhole(h: ReachHazard): Bool {
		return switch h.kind {
			case Native: h.node.kind == _shape.callKind;
			case Untyped: untypedRecorded(h.node);
			case ReflectiveName(_), Opaque, Unmodelled(_), ArrayChange: false;
		};
	}

	/**
	 * Whether the `untyped` expression `node` is built only of identifiers, field accesses, calls, parentheses and
	 * constants: the compiler types each as a fact — a field read or write (a `Dynamic` one where untyped code names a field
	 * the type lacks), a call, a native identifier (`TypedFactsWalk`). An index access there reads or writes a field by a
	 * name no fact holds (`untyped this["items"]`), and any other construct is one nobody checked.
	 */
	private function untypedRecorded(node: QueryNode): Bool {
		final kinds: Array<Null<String>> = [
			_shape.identKind,
			_shape.fieldAccessKind,
			_shape.nullSafeAccessKind,
			_shape.forceFieldAccessKind,
			_shape.callKind,
			_shape.parenKind
		];
		for (k in (_shape.inertTextLiteralKinds ?? []).concat(_shape.caseLiteralKinds ?? [])) kinds.push(k);
		function recorded(n: QueryNode): Bool {
			return kinds.contains(n.kind) && n.children.foreach(recorded);
		}
		return node.children.foreach(recorded);
	}

	/**
	 * Whether `node` changes an array whatever its receiver is typed: a write through an index, or a call of a
	 * method the built-in array type changes itself with (`ExecutionShape.mutatingArrayMethods`).
	 */
	private function changesAnArray(node: QueryNode): Bool {
		if (_shape.writeParentKinds.contains(node.kind) && node.children.length > 0) return node.children[0].kind == _shape.indexAccessKind;
		if (node.kind != _shape.callKind || node.children.length == 0) return false;
		final callee: QueryNode = node.children[0];
		return isAccess(callee.kind) && (_shape.execution?.mutatingArrayMethods ?? []).contains(callee.name ?? '');
	}

	/**
	 * The argument naming the member in a reflective accessor call (`ExecutionShape.reflectiveNameCalls`), or null when
	 * `node` is not one.
	 */
	private function nameArgumentOf(node: QueryNode): Null<QueryNode> {
		final at: Null<Int> = reflectiveNameIndex(node);
		return at == null || at + 1 >= node.children.length ? null : node.children[at + 1];
	}

	/** The argument index naming the member when `node` calls a reflective accessor (`ExecutionShape.reflectiveNameCalls`). */
	private function reflectiveNameIndex(node: QueryNode): Null<Int> {
		final calls: Null<Map<String, Int>> = _shape.execution?.reflectiveNameCalls;
		if (calls == null || node.kind != _shape.callKind || node.children.length == 0) return null;
		final path: String = pathOf(node.children[0]);
		return path == '' ? null : calls[lastSegments(path, 2)];
	}

	/** `a.b.c` for a plain identifier / field-access chain, '' for any other shape. */
	private function pathOf(node: QueryNode): String {
		final name: Null<String> = node.name;
		if (name == null) return '';
		if (node.kind == _shape.identKind) return name;
		if (!isAccess(node.kind) || node.children.length == 0) return '';
		final head: String = pathOf(node.children[0]);
		return head == '' ? '' : '$head.$name';
	}

	public static function lastSegments(path: String, count: Int): String {
		final parts: Array<String> = path.split('.');
		return parts.length <= count ? path : parts.slice(parts.length - count).join('.');
	}

	/** Whether `a` and `b` are the same range. */
	private static inline function same(a: Span, b: Span): Bool {
		return a.from == b.from && a.to == b.to;
	}

}

/** What kind of blind spot a hazard is; a reflective access carries its literal member name, null when computed. */
enum ReachHazardKind {

	ReflectiveName(literal: Null<String>);
	Native;
	Untyped;
	Opaque;

	/** A node kind the grammar does not declare modelled (`ExecutionShape.modelledKinds`). */
	Unmodelled(kind: String);

	/** Not a blind spot by itself: a site that changes SOME array — an element write, or an array-changing method on any receiver. */
	ArrayChange;

}

/** One hazard: what it is, the node span it covers and the node itself. */
typedef ReachHazard = {
	var kind: ReachHazardKind;
	var span: Span;
	var node: QueryNode;
}
