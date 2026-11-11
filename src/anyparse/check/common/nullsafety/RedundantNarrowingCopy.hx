package anyparse.check.common.nullsafety;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.RiskyFix;
import anyparse.check.common.design.threads.FieldWrites;
import anyparse.check.common.design.threads.LockTaint.ChainLists;
import anyparse.check.common.design.threads.ReflectiveReach;
import anyparse.check.common.design.threads.SpawnedWriters;
import anyparse.check.common.design.threads.ThreadContexts;
import anyparse.check.common.design.threads.ThreadGraph;
import anyparse.check.common.design.threads.ThreadSafetyOptions;
import anyparse.check.scan.OperatorSelection;
import anyparse.check.scan.UnseenCalls;
import anyparse.query.CallGraph;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.ElementSpan;
import anyparse.query.NodeShape;
import anyparse.query.NominalTypes;
import anyparse.query.ParseGate;
import anyparse.query.Refs;
import anyparse.query.ShapeVocab;
import anyparse.query.SourceText;
import anyparse.query.StableChain;
import anyparse.query.SymbolIndex;
import anyparse.query.TreePath;
import anyparse.query.TypeInfoMemo;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.query.UnchangedLocal;
import anyparse.query.WriteSites;

using StringTools;

/**
 * Flags a local that only copies a field so a null check narrows it — `final listener: Null<F> = onChange; if (listener != null)
 * listener(this);` — and rewrites it to read the field itself: `if (onChange != null) onChange(this);`. Reported at
 * `Severity.Info`; the fix is `RiskyFix`, so it lands only after the project's compiler oracle typechecks the result.
 *
 * ## When the copy goes
 *
 * The compiler narrows a field the same way it narrows a local, but only until something may change it, so the rewrite must
 * leave no room for that. The copy `l` is declared `final` (or never written) from an instance field, a static field or a
 * field chain (`p.o`) that is a data field with no getter, and:
 *
 * - the copy is written with no type or with the field's own (a `Null<T>` aside): another type may convert the value;
 * - at least one use of `l` is a null comparison;
 * - every use lies in one window after the declaration, and between the declaration and the LAST use (evaluation order) no
 *   call runs (a constructor and a method of `l` itself included, unless that call is the window's last action), no write
 *   takes effect (any field, any local), no getter is read and no operator, index access or conversion to a written type
 *   may run code (`UnseenCalls`), and no loop or function literal wraps a use. The window is judged the same in
 *   both null-safety modes: the lenient one accepts more, but then the rewrite could read another value than the copy held;
 * - no name the field's path reads is declared again inside the window, and for a chain the first use is evaluated
 *   unconditionally, so the chain is not read where it used to throw;
 * - no other thread writes the field (`SpawnedWriters`): the project declares `closedWorld` for `thread-safety` and the run
 *   covers it, its `spawns` start every other thread, and no write of the field runs on one. Without that declaration
 *   nothing is known of the field's writers and the rule is silent.
 *
 * ## Grammar-agnostic
 *
 * Driven by `localDeclKinds`, `localDeclContinuationKinds`, `fieldAccessKind`, `callKind`, `newExprKind`, `nullLiteralKind`
 * and `equalityKinds` (any unset → no-op), `ControlFlowSupport.blockKinds` for the statement lists, and `ShapeVocab` for the
 * loops, function values and conditional constructs.
 */
@:nullSafety(Strict)
final class RedundantNarrowingCopy extends RuleBase implements ConfigAware implements RiskyFix {

	private static inline final RULE_ID: String = 'redundant-narrowing-copy';

	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(RULE_ID, 'a local copy of a field made only for a null check, when the field can be read directly', RuleCategory.NullSafety);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final symbols: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		final selection: () -> Null<OperatorSelection> = lazySelection(plugin, files, symbols);
		final local: Array<{ file: String, found: Match }> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, entry.source);
			if (tree != null) for (m in collect(entry.file, selection, entry.source, tree, plugin, seams, symbols))
				local.push({ file: entry.file, found: m });
		}
		if (local.length == 0) return [];
		final threads: ThreadFacts = new ThreadFacts(files, plugin, _resolveConfig);
		return [
			for (l in local) if (threads.steady(l.file, l.found.field, l.found.firstUse)) ({
				file: l.file,
				span: l.found.declSpan,
				rule: RULE_ID,
				severity: Severity.Info,
				message: '${l.found.name} only copies ${l.found.initText} so a null check narrows it — read ${l.found.initText} directly'
			}: Violation)
		];
	}

	/** Drop each flagged declaration and read its field where the copy was read. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null || violations.length == 0) return [];
		final file: String = RunScan.oneFile(violations, RULE_ID);
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		if (tree == null) return [];
		final byKey: Map<String, Match> = [];
		final symbols: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex([{ file: file, source: source }], plugin, index);
		for (m in collect(file, lazySelection(plugin, [{ file: file, source: source }], symbols), source, tree, plugin, seams, symbols))
			byKey['${m.declSpan.from}:${m.declSpan.to}'] = m;
		final edits: Array<FixEdit> = [];
		RunScan.eachMatched(violations, byKey, (m, _) -> {
			edits.push({ span: m.dropSpan, text: '' });
			for (use in m.uses) edits.push({ span: use, text: m.initText });
		});
		return edits;
	}

	/** Every copy of `file` that passes the local conditions, in document order. */
	private static function collect(
		file: String, selection: () -> Null<OperatorSelection>, source: String, tree: QueryNode, plugin: GrammarPlugin, s: Seams,
		symbols: () -> Null<SymbolIndex>
	): Array<Match> {
		final shape: RefShape = s.shape;
		final annotations: () -> Map<Int, String> = TypeInfoMemo.declaredTypeSources(RunScan.typeInfoOf(plugin), source);
		final scan: Scan = {
			source: source,
			tree: tree,
			seams: s,
			chains: new StableChain(tree, shape, new UnchangedLocal(tree, shape), annotations, symbols, file, true),
			writes: WriteSites.of(tree, shape),
			calls: [],
			unseen: new UnseenCalls(plugin, file, source, tree, selection, symbols),
			annotations: annotations,
			typeSyntax: plugin.typeSyntax
		};
		callSpans(tree, s.callKinds, scan.calls);
		final out: Array<Match> = [];
		visit(tree, scan, out);
		return out;
	}

	private static function callSpans(node: QueryNode, kinds: Array<String>, out: Array<Span>): Void {
		final span: Null<Span> = node.span;
		if (span != null && kinds.contains(node.kind)) out.push(span);
		for (c in node.children) callSpans(c, kinds, out);
	}

	private static function visit(node: QueryNode, scan: Scan, out: Array<Match>): Void {
		if (scan.seams.blockKinds.contains(node.kind)) {
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length - 1) {
				final m: Null<Match> = candidate(kids, i, scan);
				if (m != null) out.push(m);
			}
		}
		for (c in node.children) visit(c, scan, out);
	}

	private static function candidate(kids: Array<QueryNode>, at: Int, scan: Scan): Null<Match> {
		final s: Seams = scan.seams;
		final source: String = scan.source;
		final decl: QueryNode = kids[at];
		final name: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		final init: Null<QueryNode> = NodeShape.initOf(decl);
		final initSpan: Null<Span> = init?.span;
		if (name == null || declSpan == null || init == null || initSpan == null) return null;
		if (!s.localDeclKinds.contains(decl.kind) || s.continuationKinds.contains(decl.kind)) return null;
		if (SourceText.isMultiDeclarator(decl, s.continuationKinds) || source.charAt(declSpan.to - 1) != ';') return null;
		final dropSpan: Span = ElementSpan.lineExtendedSpan(source, declSpan);
		if (dropSpan.from == declSpan.from && dropSpan.to == declSpan.to) return null;
		if (CheckScan.hasCommentMarker(source, dropSpan.from, dropSpan.to)) return null;
		final field: Null<String> = fieldOf(init, scan);
		final root: Null<String> = rootName(init, s);
		if (field == null || root == null || CheckScan.escapesConditionalRegion(name, declSpan, scan.tree, s.shape)) return null;
		if (!keepsFieldType(name, declSpan, init, scan)) return null;
		final found: Null<Window> = windowOf(name, declSpan, init, kids[at + 1], root, scan);
		return found == null ? null : {
			name: name,
			field: field,
			initText: source.substring(initSpan.from, initSpan.to),
			declSpan: declSpan,
			dropSpan: dropSpan,
			uses: found.uses,
			firstUse: found.firstUse
		};
	}

	/** The name of the field `init` reads when it is a stable field chain and not a copy of a local; else null. */
	private static function fieldOf(init: QueryNode, scan: Scan): Null<String> {
		final s: Seams = scan.seams;
		if (init.kind != s.identKind && init.kind != s.fieldAccessKind) return null;
		final read: Null<StableRead> = scan.chains.read(init);
		return read == null || (init.kind == s.identKind && read.binding >= 0) ? null : init.name;
	}

	/** The identifier at the root of the chain `init`. */
	private static function rootName(init: QueryNode, s: Seams): Null<String> {
		var node: QueryNode = init;
		while (node.kind == s.fieldAccessKind && node.children.length > 0) node = node.children[0];
		return node.kind == s.identKind ? node.name : null;
	}

	/** The spans of every read of the copy, in order; null when it is written, read inside an interpolation, or never read. */
	private static function readsOf(name: String, declSpan: Span, scan: Scan): Null<Array<Span>> {
		final reads: Array<Span> = [];
		for (h in Refs.find(name, scan.tree, scan.seams.shape)) {
			final bound: Null<Span> = h.bindingSpan;
			if (bound == null || bound.from < declSpan.from || bound.to > declSpan.to) continue;
			if (bound.from == h.span.from && bound.to == h.span.to) continue;
			if (h.kind != RefKind.Read || h.interpolated || h.patternUndecided) return null;
			reads.push(h.span);
		}
		reads.sort((a, b) -> a.from - b.from);
		return reads.length == 0 ? null : reads;
	}

	/** Whether no use sits inside a loop or a function value that opens after the declaration. */
	private static function wrapsNoUse(reads: Array<Span>, declSpan: Span, scan: Scan): Bool {
		for (r in reads) for (a in TreePath.ancestorsAt(scan.tree, r.from)) {
			final from: Null<Int> = a.span?.from;
			if (from != null && from >= declSpan.to && scan.seams.wrapperKinds.contains(a.kind)) return false;
		}
		return true;
	}

	/** Whether some use is an operand of a comparison with null. */
	private static function nullCompared(reads: Array<Span>, scan: Scan): Bool {
		final s: Seams = scan.seams;
		for (r in reads) {
			final path: Array<QueryNode> = TreePath.ancestorsAt(scan.tree, r.from);
			var i: Int = path.length - 1;
			while (i > 0 && !(path[i].kind == s.identKind && path[i].span?.from == r.from)) i--;
			if (
				i > 0
				&& s.equalityKinds.contains(path[i - 1].kind)
				&& NodeShape.nullComparedIdent(path[i - 1], s.identKind, s.nullKind, s.parenKind) == path[i]
			)
				return true;
		}
		return false;
	}

	/** Whether no call runs and no write takes effect between `from` and the start of the last use at `to`. */
	private static function windowIsQuiet(from: Int, to: Int, scan: Scan): Bool {
		return !scan.calls.exists(c -> c.from >= from && c.to <= to) && !scan.writes.exists(w -> from <= w.effect && w.effect <= to);
	}

	/** Whether a declaration of `name` opens between `from` and `to`, so a copy of the text would bind elsewhere. */
	private static function redeclared(name: String, from: Int, to: Int, scan: Scan): Bool {
		return Refs.find(name, scan.tree, scan.seams.shape).exists(h -> h.kind == RefKind.Decl && h.span.from >= from && h.span.from < to);
	}

	/** Whether `first` is evaluated whenever `next`, the statement after the declaration, is: no branch, short-circuit or arm skips it. */
	private static function evaluatedUnconditionally(next: QueryNode, first: Span, s: Seams): Bool {
		if (!TreePath.covers(next, first)) return false;
		for (a in TreePath.ancestorsAt(next, first.from)) {
			if (s.armKinds.contains(a.kind)) return false;
			if (!s.guardKinds.contains(a.kind)) continue;
			final head: Null<Span> = a.children[0]?.span;
			if (head == null || first.from < head.from || first.to > head.to) return false;
		}
		return true;
	}

	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final localDeclKinds: Null<Array<String>> = shape.localDeclKinds;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final nullKind: Null<String> = shape.nullLiteralKind;
		final callKind: Null<String> = shape.callKind;
		final equalityKinds: Null<Array<String>> = shape.equalityKinds;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (
			localDeclKinds == null
			|| fieldAccessKind == null
			|| nullKind == null
			|| callKind == null
			|| equalityKinds == null
			|| support == null
		)
			return null;
		final newKind: Null<String> = shape.newExprKind;
		return {
			shape: shape,
			localDeclKinds: localDeclKinds,
			continuationKinds: shape.localDeclContinuationKinds ?? [],
			identKind: shape.identKind,
			fieldAccessKind: fieldAccessKind,
			nullKind: nullKind,
			parenKind: shape.parenKind,
			equalityKinds: equalityKinds,
			callKinds: newKind == null ? [callKind] : [callKind, newKind],
			blockKinds: support.blockKinds(),
			wrapperKinds: ShapeVocab.loopKinds(shape).concat(ShapeVocab.nestedFunctionKinds(shape)),
			guardKinds: ShapeVocab.conditionalKinds(shape).concat(ShapeVocab.shortCircuitKinds(shape)),
			armKinds: ShapeVocab.switchArmKinds(shape).concat(ShapeVocab.tryKinds(shape))
		};
	}

	/** The uses of the copy `name` when they all sit in a window nothing can change the field in; else null. */
	private static function windowOf(
		name: String, declSpan: Span, init: QueryNode, next: QueryNode, root: String, scan: Scan
	): Null<Window> {
		final reads: Null<Array<Span>> = readsOf(name, declSpan, scan);
		if (reads == null) return null;
		final first: Span = reads[0];
		final last: Span = reads[reads.length - 1];
		if (!wrapsNoUse(reads, declSpan, scan) || !nullCompared(reads, scan)) return null;
		if (!windowIsQuiet(declSpan.to, last.from, scan) || redeclared(root, declSpan.to, last.from, scan)) return null;
		if (scan.unseen.runsCode(declSpan.to, last.from)) return null;
		if (init.kind == scan.seams.fieldAccessKind && !evaluatedUnconditionally(next, first, scan.seams)) return null;

		final uses: Array<Span> = [];
		for (r in reads) {
			final token: Int = SourceText.identTokenOffset(scan.source, r, name);
			if (token < 0) return null;
			uses.push(new Span(token, token + name.length));
		}
		return { uses: uses, firstUse: first.from };
	}

	/**
	 * Whether the copy's uses mean what the field's would: it is written with no type, or with the type the field declares
	 * (a `Null<T>` wrapper aside) — another type may convert the value (`@:from`) and so pick other members at every use.
	 */
	private static function keepsFieldType(name: String, declSpan: Span, init: QueryNode, scan: Scan): Bool {
		final decl: Null<RefHit> = Refs.find(name, scan.tree, scan.seams.shape)
			.find(h -> h.kind == RefKind.Decl && h.span.from >= declSpan.from && h.span.to <= declSpan.to);
		final written: Null<String> = decl == null ? null : scan.annotations()[decl.span.from];
		if (written == null) return true;
		final declared: Null<String> = scan.chains.typeOf(init);
		return declared != null && bare(written, scan) == bare(declared, scan);
	}

	/** `typeText` with its `Null<>` wrappers peeled and its spaces dropped. */
	private static function bare(typeText: String, scan: Scan): String {
		return NominalTypes.memberLookupReceiverSource(typeText, scan.seams.shape.memberTransparentWrapperTypeNames ?? [], scan.typeSyntax)
			.replace(' ', '');
	}

	/** The run's operator table, built on the first window that asks and shared by every file. */
	private static function lazySelection(
		plugin: GrammarPlugin, files: Array<{ file: String, source: String }>, symbols: () -> Null<SymbolIndex>
	): () -> Null<OperatorSelection> {
		var made: Null<OperatorSelection> = null;
		return () -> {
			made ??= OperatorSelection.of(plugin, files, symbols());
			made;
		};
	}

}

/**
 * The run's thread facts: the call graph, every write of the project and the threads that run each function, built once for the
 * findings that passed every local condition — `run` makes none for a project nothing asks about, and none at all for a run where
 * some file's chain declares no `closedWorld`, which could never be complete.
 */
@:nullSafety(Strict)
private final class ThreadFacts {

	private final _known: Null<KnownThreads>;

	public function new(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, resolve: Null<(String) -> LintConfig>
	) {
		_known = files.foreach(f -> ThreadSafetyOptions.read(LintConfig.resolveWith(resolve, f.file)).flag('closedWorld'))
			? known(files, plugin, resolve)
			: null;
	}

	/** Whether the field `field`, read in `file` from offset `at`, is known to hold still under two reads there. */
	public function steady(file: String, field: String, at: Int): Bool {
		final known: Null<KnownThreads> = _known;
		return known != null
			&& known.complete
			&& known.chains[file]?.closedWorld == true
			&& !known.writers.mayChangeUnderRead(field, known.graph.functionAt(file, at));
	}

	private static function known(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, resolve: Null<(String) -> LintConfig>
	): KnownThreads {
		final graph: CallGraph = ThreadGraph.build(files, plugin, false);
		final contexts: ThreadContexts = ThreadContexts.ofGraph(graph, files, plugin, resolve);
		final chains: Map<String, ChainLists> = contexts.byFile;
		final complete: Bool = files.foreach(f -> chains[f.file]?.closedWorld == true);
		final writes: FieldWrites = new FieldWrites(
			graph, plugin, complete, ReflectiveReach.declaredClasses(files, resolve),
			{ seedable: contexts.seedable, inertRef: contexts.inertRef }, ReflectiveReach.declaredMethodHolders(files, resolve)
		);
		return {
			graph: graph,
			chains: chains,
			complete: complete,
			writers: new SpawnedWriters(graph, writes, contexts, plugin.refShape().constructorName)
		};
	}

}

/**
 * What `ThreadFacts` knows of a run: its graph, each file's chain lists,
 * whether every file's `closedWorld` holds, and the thread answer.
 */
private typedef KnownThreads = {
	final graph: CallGraph;
	final chains: Map<String, ChainLists>;
	final complete: Bool;
	final writers: SpawnedWriters;
};

/** One copy that passes the local conditions: where it is declared, the text its uses become, and where the first use sits. */
private typedef Match = {
	final name: String;
	final field: String;
	final initText: String;
	final declSpan: Span;
	final dropSpan: Span;
	final uses: Array<Span>;
	final firstUse: Int;
};

/** The text spans of every use of a copy, and where the first one sits. */
private typedef Window = { final uses: Array<Span>; final firstUse: Int; };

/** One file's scan: its text and tree, the stable-chain reader, every write and the spans of every call. */
private typedef Scan = {
	final source: String;
	final tree: QueryNode;
	final seams: Seams;
	final chains: StableChain;
	final writes: Array<WriteSite>;
	final calls: Array<Span>;
	final unseen: UnseenCalls;
	final annotations: () -> Map<Int, String>;
	final typeSyntax: TypeSyntaxReader;
};

/** The seams the rule reads in `run` and in the fix. */
private typedef Seams = {
	final shape: RefShape;
	final localDeclKinds: Array<String>;
	final continuationKinds: Array<String>;
	final identKind: String;
	final fieldAccessKind: String;
	final nullKind: String;
	final parenKind: Null<String>;
	final equalityKinds: Array<String>;
	final callKinds: Array<String>;
	final blockKinds: Array<String>;
	final wrapperKinds: Array<String>;
	final guardKinds: Array<String>;
	final armKinds: Array<String>;
};
