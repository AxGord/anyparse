package anyparse.query;

import anyparse.query.CallGraph.FnDeclaration;
import anyparse.query.CallGraph.FnNode;
import anyparse.query.CompilerFacts.ExpansionFact;
import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.CompilerFacts.FactPos;
import anyparse.query.CompilerFacts.FieldFact;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.MemberReach.ReachAccess;
import anyparse.query.MemberReach.ReachStep;
import anyparse.query.MemberReach.ReachUnknown;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.query.ValueCarriers.CarryRelation;
import anyparse.runtime.Span;

using Lambda;

/**
 * The toucher half of `MemberReach`: every access of a member BY BINDING across the project files a
 * call graph holds, what each access does for a `ReachAccess` question (a touch, an escape of the
 * member's value, or a harmless read), and whether a LOCAL's value ever escapes before a region ends. Where the compiler facts are
 * the truth (`FactsView.truth`), a faceted function is read through its typed field accesses instead of its syntax (`typedAccesses`).
 */
@:nullSafety(Strict)
final class MemberTouchScan {

	/**
	 * The uses a typed read of the member may carry (`FieldFact.use`) — every one `classifyTyped` answers for. A read
	 * carrying any other keeps its function read by its syntax.
	 */
	private static final TYPED_USES: Array<String> = [
		'call',
		'index',
		'elemWrite',
		'member',
		'memberWrite',
		'compare',
		'iter',
		'update',
		'value'
	];

	/**
	 * The accesses a typed access of the member may be (`FieldFact.access`): a field of an instance, a static, a structure
	 * or a dynamic receiver.
	 */
	private static final TYPED_ACCESSES: Array<String> = ['FInstance', 'FStatic', 'FAnon', 'FDynamic'];

	/** The marker of a typed body an expression macro expanded into (`TypedFactsProbe`). */
	private static inline final MACRO_EXPANSION: String = 'macro-expansion';

	private final _scope: ReachProject;
	private final _hazards: ReachHazards;

	/** Whether code at a span of a file may run in some configured build (`ReachLiveness.live`): what may not touches nothing. */
	private final _live: (String, Span) -> Bool;

	/** Whether a receiver's value may carry the member (`ValueCarriers.relation`). */
	private final _carriers: ValueCarriers;

	public function new(scope: ReachProject, hazards: ReachHazards, carriers: ValueCarriers, live: (String, Span) -> Bool) {
		_carriers = carriers;
		_live = live;
		_scope = scope;
		_hazards = hazards;
	}

	/**
	 * Every access of `name` that binds to the member `declaring` declares, over the project files the
	 * graph holds: the functions that TOUCH it for `access`, the sites where its value escapes, and the
	 * touch (if any) inside `region` of `regionFile` itself. Any project file that did not
	 * parse, and a raw conditional region spelling the name, is recorded as a blind spot. A file no build
	 * runs (`ReachProject.runsInNoBuild`) is none the graph holds: it touches nothing and hides nothing. Under the truth a faceted
	 * function touches as its compiler facts say (`typedAccesses`, `recordTyped`), its syntax aside, reflective names excepted.
	 */
	public function scan(
		g: CallGraph, name: String, declaring: String, access: ReachAccess, arrayTyped: Bool, regionFile: String, region: Null<Span>
	): MemberTouches {
		final out: MemberTouches = {
			touchers: [],
			notOnSelf: [],
			escapes: [],
			hidden: null,
			inRegion: null
		};
		// a project file that did not parse may declare an override, a subclass, a function value — any code a dispatch
		// or an admission can enter — without spelling the member at all: its mere presence is a blind spot
		for (file in g.skippedFiles) if (_scope.sources.exists(file)) {
			out.hidden = SkipParse(file);
			break;
		}
		final unread: Array<String> = [];
		final typed: Map<String, Array<FieldFact>> = typedAccesses(g, name, declaring, unread) ?? [];
		for (f in _scope.files) {
			final tree: Null<QueryNode> = g.treeOf(f.file);
			if (tree == null) continue;
			// the member is spelled by its own name, or by a name an import of the file binds it to
			final aliases: Array<String> = aliasesIn(g, f.file, name, declaring);
			final words: Array<String> = [name].concat(aliases);
			if (!words.exists(w -> RawSourceScan.mentionsWord(f.source, w))) continue;
			for (w in words) {
				final opaque: Null<Span> = CondRegionScan.opaqueCondRegionMentioning(tree, f.source, w, _scope.shape);
				// a raw region no configured build compiles hides nothing
				if (opaque != null && _live(f.file, opaque) && out.hidden == null) out.hidden = OpaqueCond(f.file, opaque);
			}
			scanFile(
				g, f.file, f.source, tree, name, aliases, declaring, access, arrayTyped, out, f.file == regionFile ? region : null, typed
			);
		}
		for (id => accesses in typed) recordTyped(g, id, name, accesses, access, arrayTyped, out, regionFile, region);
		for (id in unread) recordUnread(g, id, access, out);
		// a field initializer that is not freshly built shares its value from the start
		if (access == Mutate) {
			final site: Null<{ file: String, span: Span }> = sharedInitializer(g, declaring, name);
			if (site != null) out.escapes.push({ file: site.file, span: site.span });
		}
		return out;
	}

	/**
	 * The first site at which the local `name` stops being provably unshared before the region can run for the
	 * last time, or null when it never does. The scan runs to the end of `region` — or, when a loop of `fn`
	 * encloses it and so re-runs it, to the end of the OUTERMOST such loop: an escape later in one iteration
	 * precedes the region in the next. A declaration that is not a local, or whose initializer is not freshly
	 * built, escapes at once.
	 */
	public function localEscape(
		tree: QueryNode, source: String, fn: QueryNode, declaration: QueryNode, name: String, region: Span, ?freshCall: QueryNode -> Bool
	): Null<Span> {
		final shape: RefShape = _scope.shape;
		final declSpan: Null<Span> = declaration.span;
		if (declSpan == null) return fn.span ?? region;
		if (!(shape.localDeclKinds ?? []).contains(declaration.kind)) return declSpan;
		final init: Null<QueryNode> = CtorFieldFold.declInitializer(declaration, shape);
		if (init == null || !isFresh(init, { tree: tree, source: source, call: freshCall })) return init?.span ?? declSpan;
		final closures: Array<String> = (shape.lambdaKinds ?? []).concat(shape.localFunctionKinds ?? []);
		final end: Int = rerunEnd(fn, region);
		var found: Null<Span> = null;
		final declFrom: Int = declSpan.from;
		final lineage: Array<QueryNode> = [];
		function walk(
			node: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>, index: Int, parentIndex: Int, inClosure: Bool
		): Void {
			final at: Null<Span> = node.span;
			if (found != null || at == null) return;
			final span: Span = at;
			if (span.from >= end) return;
			final closure: Bool = inClosure || closures.contains(node.kind);
			if (node.kind == shape.identKind && node.name == name && span.from > declFrom) {
				final verdict: Verdict = classify(node, parent, grand, lineage, index, parentIndex, Mutate, true);
				if (closure || verdict.escape) found = span;
			}
			lineage.push(node);
			for (i in 0...node.children.length) walk(node.children[i], node, parent, i, index, closure);
			lineage.pop();
		}
		walk(fn, null, null, 0, 0, false);
		return found;
	}

	/** Where code that can run before `region` runs again ends: `region.to`, or the end of the outermost loop of `fn` enclosing it. */
	public function rerunEnd(fn: QueryNode, region: Span): Int {
		final loops: Array<String> = (_scope.shape.loopStatementKinds ?? []).concat(_scope.shape.doWhileLoopKinds ?? []);
		var end: Int = region.to;
		function walk(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			if (span == null || span.from > region.from || span.to < region.to) return;
			if (loops.contains(node.kind) && (span.from < region.from || span.to > region.to) && span.to > end) end = span.to;
			for (c in node.children) walk(c);
		}
		walk(fn);
		return end;
	}

	/**
	 * Whether `value` builds a fresh object nothing else holds: an array literal or comprehension, `null`, `new`
	 * of an array type, or — with `ctx` to type the receiver — a call of a method the receiver's built-in array
	 * or string type declares as returning a new object (`xs.copy()`, `'a,b'.split(',')`, `freshResult`), or a call
	 * `ctx.call` proves returns one (a project function whose every `return` hands out a fresh value).
	 */
	public function isFresh(raw: QueryNode, ctx: Null<FreshContext>): Bool {
		final value: QueryNode = BoolExprShape.unwrapParens(raw, _scope.shape.parenKind);
		if (value.kind == _scope.shape.arrayLiteralKind || value.kind == _scope.shape.nullLiteralKind) return true;
		if (value.kind == _scope.shape.newExprKind) return (_scope.shape.arrayTypeNames ?? []).contains(lastSegment(value.name ?? ''));
		if (ctx == null) return false;
		if (freshResult(value, ctx)) return true;
		final call: Null<QueryNode -> Bool> = ctx.call;
		return call != null && value.kind == _scope.shape.callKind && call(value);
	}

	private function scanFile(
		g: CallGraph, file: String, source: String, tree: QueryNode, name: String, aliases: Array<String>, declaring: String,
		access: ReachAccess, arrayTyped: Bool, out: MemberTouches, region: Null<Span>, factsRead: Map<String, Array<FieldFact>>
	): Void {
		// noqa: complexity
		final shape: RefShape = _scope.shape;
		final identKind: String = shape.identKind;
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final bindings: Map<Int, Int> = [];
		for (hits in Refs.findMulti([name].concat(aliases), tree, shape)) for (h in hits) bindings[h.span.from] = h.bindingSpan?.from ?? -1;
		final provider: Null<TypeInfoProvider> = _scope.plugin is TypeInfoProvider ? cast _scope.plugin : null;
		var declaredTypes: Null<Map<Int, String>> = null;
		final stringFold: Null<StringFoldSupport> = _scope.plugin.stringFoldSupport();

		/** Whether the name at `span` binds to a local or a parameter of a function. */
		function boundLocally(span: Span): Bool {
			final bound: Null<Int> = bindings[span.from];
			return bound != null && bound >= 0 && g.functionAt(file, bound) != null;
		}

		function receiverOwns(receiver: QueryNode): Bool {
			// a receiver naming a TYPE (`Store.items`) reaches that type's static member, not an instance one
			if (TypeResolver.receiverRootIsUnboundType(receiver, tree, shape)) {
				final path: String = RefactorSupport.flattenPath(receiver);
				final typeName: String = path.substring(path.lastIndexOf('.') + 1);
				if (g.types.declarationCount(typeName) > 0) return g.types.declaringTypeOf(typeName, name) == declaring;
			}
			// the compiler's type of the receiver, where its facts replace the syntax of the code holding it
			final at: Null<Span> = receiver.span;
			final typed: Null<String> = at == null ? null : g.facts?.view.typeSourceAt(g, file, at);
			if (typed != null) return typedMayCarry(typed, declaring);
			final types: Map<Int, String> = declaredTypes ?? typesOf(provider, source);
			declaredTypes = types;
			final nominal: Null<String> = NominalTypes.expressionTypeNominal(receiver, tree, shape, types, _scope.index, file, null, true);
			// a nullable wrapper holds the value it wraps: which one is not known here
			final known: Null<String> = nominal == null || (shape.nullableWrapperTypeNames ?? []).contains(nominal) ? null : nominal;
			return _carriers.relation(known, declaring) != CannotCarry;
		}

		final lineage: Array<QueryNode> = [];
		function record(node: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>, index: Int, parentIndex: Int): Void {
			final at: Null<Span> = node.span;
			if (at == null) return;
			final span: Span = at;
			// a function read through its compiler facts touches as they say (`recordTyped`), not as its syntax reads
			if (!_live(file, span) || factsRead.exists(g.functionAt(file, span.from) ?? '')) return;
			final verdict: Verdict = classify(node, parent, grand, lineage, index, parentIndex, access, arrayTyped);
			if (verdict.escape) out.escapes.push({ file: file, span: span });
			if (!verdict.touch) return;
			if (within(span, region) && out.inRegion == null) out.inRegion = {
				from: 'entry',
				to: name,
				kind: 'touch',
				file: file,
				span: span
			};
			// an imported name is a static's, never a member of the object under construction
			final onSelf: Bool = node.name == name && (node.kind == shape.identKind || (
				node.children.length > 0 && node.children[0].kind == shape.identKind && node.children[0].name == shape.selfReferenceText
			));
			for (id in touchingNodes(g, file, span.from)) {
				out.touchers[id] = { file: file, span: span };
				if (!onSelf && !out.notOnSelf.exists(id)) out.notOnSelf[id] = { file: file, span: span };
			}
		}

		function walk(
			node: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>, index: Int, parentIndex: Int, type: Null<String>
		): Void {
			if (opaqueKinds.contains(node.kind)) return;
			final current: Null<String> = CallGraphNames.typeNameOf(node) ?? type;
			final span: Null<Span> = node.span;
			final spelled: Null<String> = node.name;
			if (spelled == name && span != null) {
				if (node.kind == identKind) {
					final owner: Null<String> = current == null ? null : g.types.declaringTypeOf(current, name);
					if (!boundLocally(span) && (owner == null || owner == declaring)) record(node, parent, grand, index, parentIndex);
				} else if (_hazards.isAccess(node.kind) && node.children.length > 0 && receiverOwns(node.children[0])) {
					record(node, parent, grand, index, parentIndex);
				}
			} else if (spelled != null && span != null && node.kind == identKind && aliases.contains(spelled)) {
				// the import binds the name only where neither a local nor a member of the enclosing type does
				final member: Bool = current != null && g.types.declaringTypeOf(current, spelled) != null;
				if (!boundLocally(span) && !member) record(node, parent, grand, index, parentIndex);
			}
			final reflected: Null<String> = _hazards.reflectiveNameWith(node, source, stringFold);
			if (reflected == name && span != null && _live(file, span)) {
				final site: Span = span;
				for (id in touchingNodes(g, file, site.from)) {
					out.touchers[id] = { file: file, span: site };
					out.notOnSelf[id] = { file: file, span: site };
				}
				if (within(site, region) && out.inRegion == null) out.inRegion = {
					from: 'entry',
					to: name,
					kind: 'reflection',
					file: file,
					span: site
				};
			}
			lineage.push(node);
			for (i in 0...node.children.length) walk(node.children[i], node, parent, i, index, current);
			lineage.pop();
		}
		walk(tree, null, null, 0, 0, null);
	}

	/**
	 * The names the imports of `file` give the static `name` of `declaring` besides its own (`CallGraphImports.fieldAliases`):
	 * every alias but one whose path names a type proven not to be `declaring` — one declared once, declaring `name` itself.
	 * An alias whose path did not decode may name any static.
	 */
	private static function aliasesIn(g: CallGraph, file: String, name: String, declaring: String): Array<String> {
		final out: Array<String> = [];
		for (a in g.types.imports.fieldAliases(file)) {
			final owner: Null<String> = a.owner;
			final member: Null<String> = a.member;
			final other: Bool = (member != null && member != name) || (
				owner != null && owner != declaring && g.types.declarationCount(owner) == 1 && g.types.declaringTypeOf(owner, name) == owner
			);
			if (!other && a.alias != name && !out.contains(a.alias)) out.push(a.alias);
		}
		return out;
	}

	/**
	 * Under the truth (`FactsView.truth`), each faceted function of the project with the accesses the compiler typed in it of
	 * the member `declaring` declares as `name`: that function is read through them (`recordTyped`), not through its syntax.
	 * Every access of a field in typed code is a `FieldFact`, a property's through its accessor a call, so no access of the
	 * member escapes them. An access binds to the member when its declaring type is one of the typed types standing for
	 * `declaring` (`FactsView.bySimpleName`), or, off a structure or a dynamic receiver, when the receiver's value may carry
	 * the member (`ValueCarriers.relation`). Null without the truth, or when no typed type stands for `declaring`. A method a
	 * build macro made (`CallGraphFacts.adopted`) has no text to fall back on: when its accesses are not all of a shape the
	 * facts answer for, its id goes to `unread`, and it touches the member and lets it escape (`recordUnread`) — and so does a
	 * function whose such access lies in the code an expression macro's expansion built (`nodeAccesses`), which no text holds
	 * either.
	 */
	private function typedAccesses(
		g: CallGraph, name: String, declaring: String, unread: Array<String>
	): Null<Map<String, Array<FieldFact>>> {
		final facts: Null<CallGraphFacts> = g.facts;
		if (facts == null || !facts.view.truth) return null;
		final owners: Array<String> = facts.view.bySimpleName()[declaring] ?? [];
		if (owners.length == 0) return null;
		final out: Map<String, Array<FieldFact>> = [];
		for (id => bodies in facts.faceted) {
			final node: Null<FnNode> = g.node(id);
			if (node == null || !_scope.sources.exists(node.file)) continue;
			final made: Bool = facts.adopted.exists(id);
			switch nodeAccesses(g, node, bodies, name, declaring, owners, facts.view, made) {
				case Typed(accesses):
					out[id] = accesses;
				case Unread:
					unread.push(id);
				case BySyntax:
			}
		}
		return out;
	}

	/**
	 * The typed accesses of the member (see `typedAccesses`) in the faceted `node`, whose bodies are `bodies`: their own and
	 * those of every function the compiler made inside them that the graph declares no node for (a `.bind` closure) — one it
	 * does declare is read as that node is. `BySyntax` — the syntax reads `node` — when such an access is of a shape
	 * `classifyTyped` does not answer for, or lies outside the text of every declaration of `node` (`CallGraph.declarationsOf`),
	 * when a call names a field of the member's name (a call of the value a variable holds is a call fact, never a field
	 * one), or when a function inside it was placed by a macro. A body a build macro made (`made`, `CallGraphFacts.adopted`)
	 * is read whole, wherever its facts lie and every function nested in it with it: no text holds any of it, so where that
	 * reading fails it is `Unread`. So is the code an expression macro's expansion built (`expansionCode`), which no text
	 * holds either: an access there is read where the call of the macro was (`expansionRuns`), and one that cannot be read —
	 * of a shape `classifyTyped` does not answer for, a call of a field of the member's name, a function the macro placed
	 * that names it — leaves the node `Unread`.
	 */
	private function nodeAccesses(
		g: CallGraph, node: FnNode, bodies: Array<FactNode>, name: String, declaring: String, owners: Array<String>, view: FactsView,
		made: Bool
	): TypedTouches {
		final declared: Array<FnDeclaration> = g.declarationsOf(node.id);
		if (declared.length == 0 && !made) return BySyntax;
		final unreadable: TypedTouches = made ? Unread : BySyntax;
		final out: Array<FieldFact> = [];
		final work: Array<FactNode> = bodies.copy();
		var unread: Bool = false;
		while (work.length > 0) {
			final n: Null<FactNode> = work.pop();
			if (n == null) return unreadable;
			if (n.generated && !made) return BySyntax;
			// a field the compiler calls — a function a variable holds, a dynamic receiver's field — is a call, no field fact
			for (c in n.calls) if (calledField(c.target) == name) {
				if (made || !expansionCode(g, node, n, c.at, view)) return unreadable;
				unread = true;
			}
			for (f in n.fields) if (f.field == name && bindsTo(f, declaring, owners)) {
				final expanded: Bool = !made && expansionCode(g, node, n, f.at, view);
				if (!typedShape(f)) {
					if (!expanded) return unreadable;
					unread = true;
				} else if (expanded)
					for (run in expansionRuns(n, f)) out.push(run)
				else if (made || declarationHolding(g, node.id, f.at, view) != null)
					out.push(f)
				else
					return BySyntax;
			}
			for (child in n.fns) {
				final nested: Null<FactNode> = view.table.node(child);
				if (nested == null) return unreadable;
				// a function an expansion placed outside its type's file runs whenever its value is called: what it does to a
				// name of the member no reading places
				if (!made && nested.generated && expansionCode(g, node, n, nested.at, view)) {
					if (nested.fields.exists(f -> f.field == name) || nested.calls.exists(c -> calledField(c.target) == name))
						unread = true;
				} else if (made || CallGraphFacts.graphNodeOf(g, node, child, view) == null)
					work.push(nested);
			}
		}
		return unread ? Unread : Typed(out);
	}

	/**
	 * Whether the fact at `at` of `node`'s body `n` lies in code an expression macro's expansion built, under the truth: `n`
	 * holds an expansion (`macro-expansion`), and `at` lies outside the text of every declaration of `node` and in no body
	 * an inlined call spliced in (`CompilerFacts.spliceOf`), whose method's own text answers for it.
	 */
	private static function expansionCode(g: CallGraph, node: FnNode, n: FactNode, at: FactPos, view: FactsView): Bool {
		return view.truth && n.incomplete.contains(MACRO_EXPANSION) && declarationHolding(g, node.id, at, view) == null
			&& CompilerFacts.spliceOf(n, at) == null;
	}

	/**
	 * The typed access `f` of code an expression macro's expansion built into `n`, read where it runs: at each site the
	 * expansion holding it runs at (`CompilerFacts.expansionSites`), or over the whole of `n` when none is known.
	 */
	private static function expansionRuns(n: FactNode, f: FieldFact): Array<FieldFact> {
		final expansion: Null<ExpansionFact> = CompilerFacts.expansionOf(n, f.at);
		final sites: Array<Span> = (expansion == null ? null : CompilerFacts.expansionSites(n, expansion)) ?? [n.at.span];
		return [
			for (s in sites)
				{
					owner: f.owner,
					field: f.field,
					access: f.access,
					receiver: f.receiver,
					type: f.type,
					write: f.write,
					at: { file: n.at.file, span: s },
					use: f.use,
					method: f.method,
					fresh: f.fresh
				}
		];
	}

	/**
	 * Record into `out` how the faceted node `id` — one reading a name several types share as one type's member
	 * (`CallGraphFacts.qualify`), made after `scan` — touches the member `declaring` declares as `name`, read through its
	 * typed accesses (`nodeAccesses`, `recordTyped`) as `scan` reads every faceted function of the project. False when the
	 * facts do not answer for them: the node is then none the walk can read as that type's.
	 */
	public function scanNode(
		g: CallGraph, id: String, name: String, declaring: String, access: ReachAccess, arrayTyped: Bool, out: MemberTouches,
		regionFile: String, region: Null<Span>
	): Bool {
		final facts: Null<CallGraphFacts> = g.facts;
		final node: Null<FnNode> = g.node(id);
		final bodies: Null<Array<FactNode>> = facts?.faceted[id];
		if (facts == null || node == null || bodies == null || !facts.view.truth) return false;
		final owners: Array<String> = facts.view.bySimpleName()[declaring] ?? [];
		if (owners.length == 0) return false;
		return switch nodeAccesses(g, node, bodies, name, declaring, owners, facts.view, false) {
			case Typed(accesses):
				recordTyped(g, id, name, accesses, access, arrayTyped, out, regionFile, region);
				true;
			case BySyntax, Unread: false;
		};
	}

	/**
	 * Record the method `id` a build macro made (`CallGraphFacts.adopted`) whose facts do not say how it accesses a name of
	 * the member (`typedAccesses`): it touches the member, and — for `Mutate` — lets its value escape, both where its body is.
	 */
	private function recordUnread(g: CallGraph, id: String, access: ReachAccess, out: MemberTouches): Void {
		final node: Null<FnNode> = g.node(id);
		final body: Null<FactNode> = g.facts?.adopted[id];
		if (node == null || body == null) return;
		final at: Occurrence = { file: node.file, span: node.span ?? body.at.span };
		out.touchers[id] = at;
		out.notOnSelf[id] = at;
		if (access == Mutate) out.escapes.push(at);
	}

	/**
	 * Whether the typed field access `f` binds to the member `declaring` declares: its declaring type is one of `owners`,
	 * or it names no declaring type — a structure's or a dynamic receiver's field — and the receiver's value may carry the
	 * member.
	 */
	private function bindsTo(f: FieldFact, declaring: String, owners: Array<String>): Bool {
		final owner: Null<String> = f.owner;
		return owner == null ? typedMayCarry(FactsView.simpleSource(f.receiver), declaring) : owners.contains(owner);
	}

	/**
	 * Whether a receiver the compiler typed `typed` — a facts type spelled as source declares it, null when it names no
	 * declaration — may hold an object carrying the member `declaring` declares (`ValueCarriers.relation`).
	 */
	private function typedMayCarry(typed: Null<String>, declaring: String): Bool {
		final wrappers: Array<String> = _scope.shape.memberTransparentWrapperTypeNames ?? [];
		final known: Null<String> = typed == null ? null : NominalTypes.unwrapNullable(typed, wrappers, _scope.plugin.typeSyntax);
		return _carriers.relation(known, declaring) != CannotCarry;
	}

	/**
	 * Record the typed accesses `accesses` of the member in the function `id` (`typedAccesses`): each touch, escape and
	 * touch meeting `region` of `regionFile`, as `classifyTyped` reads it. A touch is on the function's own `this` only
	 * where its text spells the bare name or `this.name` (`onSelf`). The facts are code a listed build compiled, so no
	 * liveness is asked of them.
	 */
	private function recordTyped(
		g: CallGraph, id: String, name: String, accesses: Array<FieldFact>, access: ReachAccess, arrayTyped: Bool, out: MemberTouches,
		regionFile: String, region: Null<Span>
	): Void {
		final held: Null<String> = g.node(id)?.file;
		final view: Null<FactsView> = g.facts?.view;
		if (held == null || view == null) return;
		// a body a build macro made lies in no text: none of it is the region's, and none is `this.name` spelled
		final made: Bool = g.facts?.adopted.exists(id) == true;
		for (f in accesses) {
			final span: Span = f.at.span;
			// the text of the declaration holding the access, which may be another than the node's first (`nodeAccesses`)
			final file: String = made ? held : declarationHolding(g, id, f.at, view)?.file ?? held;
			final verdict: Verdict = classifyTyped(f, access, arrayTyped);
			if (verdict.escape) out.escapes.push({ file: made ? f.at.file : file, span: span });
			if (!verdict.touch) continue;
			// the compiler may place what it made of an expression at a range wider than the expression's own
			if (!made && file == regionFile && meets(span, region) && out.inRegion == null) out.inRegion = {
				from: 'entry',
				to: name,
				kind: 'touch',
				file: file,
				span: span
			};
			out.touchers[id] = { file: file, span: span };
			if ((made || !onSelf(g, file, span, name)) && !out.notOnSelf.exists(id)) out.notOnSelf[id] = { file: file, span: span };
		}
	}

	/**
	 * What the typed access `f` of the member does for `access` — `classify`, read off the facts: a write touches, and for
	 * `Mutate` escapes unless it stores a value only the field holds (`FieldFact.fresh`); a read touches for `Read`, and for
	 * `Mutate` touches and escapes by its use: an element write or a write of a field of the member's value touches, a
	 * method call is a read only for one of the array type's own readers on an array-typed member (the facts name the
	 * method the receiver's type declares, never an extension), and a value handed on escapes.
	 */
	private function classifyTyped(f: FieldFact, access: ReachAccess, arrayTyped: Bool): Verdict {
		if (f.write) return switch access {
			case Read: { touch: false, escape: false };
			case Write: { touch: true, escape: false };
			case Mutate: { touch: true, escape: !f.fresh };
		};
		if (access != Mutate) return { touch: access == Read, escape: false };
		return switch f.use {
			case 'call':
				final method: String = f.method ?? '';
				final reads: Bool = arrayTyped && (_scope.shape.execution?.nonMutatingArrayMethods ?? []).contains(method);
				final own: Bool = arrayTyped && (reads || (_scope.shape.execution?.mutatingArrayMethods ?? []).contains(method));
				{ touch: !reads, escape: !own };
			case 'elemWrite', 'memberWrite': { touch: true, escape: false };
			case 'value': { touch: false, escape: true };
			case _: { touch: false, escape: false };
		};
	}

	/** Whether the text at `span` of `file` spells the member `name` on its own `this`: the bare name, or `this.name`. */
	private function onSelf(g: CallGraph, file: String, span: Span, name: String): Bool {
		final shape: RefShape = _scope.shape;
		var found: Bool = false;
		function walk(node: QueryNode): Void {
			final at: Null<Span> = node.span;
			if (found || (at != null && (at.from > span.from || at.to < span.to))) return;
			if (at != null && at.from == span.from && at.to == span.to && node.name == name) {
				final receiver: Null<QueryNode> = node.children.length > 0 ? node.children[0] : null;
				final self: Bool = receiver != null && receiver.kind == shape.identKind && receiver.name == shape.selfReferenceText;
				if (node.kind == shape.identKind || (_hazards.isAccess(node.kind) && self)) found = true;
			}
			// a node with no span of its own may still hold the text
			for (c in node.children) walk(c);
		}
		final tree: Null<QueryNode> = g.treeOf(file);
		if (tree != null) walk(tree);
		return found;
	}

	/**
	 * The graph nodes an occurrence at `offset` of `file` belongs to: its innermost
	 * function, or the type's initializer pseudo-nodes outside every function.
	 */
	private function touchingNodes(g: CallGraph, file: String, offset: Int): Array<String> {
		final fn: Null<String> = g.functionAt(file, offset);
		if (fn != null) return [fn];
		final tree: Null<QueryNode> = g.treeOf(file);
		final type: Null<String> = tree == null ? null : typeAt(tree, offset);
		return type == null ? [] : ['$type.${CallGraph.INIT_NAME}', '$type.${CallGraph.STATIC_INIT_NAME}'];
	}

	/**
	 * What an occurrence of the member does for `access`: `touch` when it is the kind of access asked
	 * about, `escape` when (for `Mutate`) the member's value leaves for a place the analysis does not
	 * follow, or a value that was not freshly built is stored into it. A method call on the member is a
	 * read only when the member is an ARRAY (`arrayTyped`) and the method one of the array type's own
	 * readers; a method the array type does not declare may be a static extension handed the array itself.
	 */
	private function classify(
		node: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>, lineage: Array<QueryNode>, index: Int, parentIndex: Int,
		access: ReachAccess, arrayTyped: Bool
	): Verdict {
		// noqa: complexity
		final shape: RefShape = _scope.shape;
		if (parent == null) return { touch: access == Read, escape: access == Mutate };
		final pk: String = parent.kind;
		if (shape.writeParentKinds.contains(pk) && index == 0) {
			final plain: Bool = pk == shape.assignKind;
			return switch access {
				case Read: { touch: !plain, escape: false };
				case Write: { touch: true, escape: false };
				case Mutate: { touch: true, escape: !storesFreshValue(lineage) };
			};
		}
		if (access == Write) return { touch: false, escape: false };
		if (access == Read) return { touch: true, escape: false };
		final writes: Null<QueryNode> -> Int -> Bool = (n, i) -> n != null && shape.writeParentKinds.contains(n.kind) && i == 0;
		if (pk == shape.indexAccessKind && index == 0) return { touch: writes(grand, parentIndex), escape: false };
		if (_hazards.isAccess(pk) && index == 0) {
			if (grand != null && grand.kind == shape.callKind && parentIndex == 0) {
				final method: String = parent.name ?? '';
				final reads: Bool = arrayTyped && (shape.execution?.nonMutatingArrayMethods ?? []).contains(method);
				final own: Bool = arrayTyped && (reads || (shape.execution?.mutatingArrayMethods ?? []).contains(method));
				return { touch: !reads, escape: !own };
			}
			return { touch: writes(grand, parentIndex), escape: false };
		}
		if (pk == shape.forStmtKind && isIterableOf(parent, node)) return { touch: false, escape: false };
		if ((shape.equalityKinds ?? []).contains(pk)) return { touch: false, escape: false };
		if (pk == shape.parenKind)
			return classify(parent, grand, null, lineage.slice(0, lineage.length - 1), parentIndex, 0, access, arrayTyped);
		return { touch: false, escape: true };
	}

	/**
	 * Whether the write that ends `lineage` (the chain of nodes from the root down to it) leaves its target holding a value
	 * nothing else holds: a plain or null-coalescing assignment of a freshly built value whose own value goes nowhere —
	 * a statement whose value is discarded (`valueDiscarded`), or the expression
	 * body of a function declared to return nothing. Any other write — a compound
	 * operator, an increment, a stored value that is not fresh — may leave an alias there, and an assignment used as a
	 * value hands what it stored on too.
	 */
	private function storesFreshValue(lineage: Array<QueryNode>): Bool {
		final shape: RefShape = _scope.shape;
		final at: Int = lineage.length - 1;
		final write: Null<QueryNode> = at >= 0 ? lineage[at] : null;
		if (write == null || write.children.length < 2 || at < 1) return false;
		final replacing: Bool = write.kind == shape.assignKind || write.kind == shape.nullCoalAssignKind;
		if (!replacing || !isFresh(write.children[1], null)) return false;
		final holder: QueryNode = lineage[at - 1];
		if (holder.kind == shape.exprStatementKind) return valueDiscarded(lineage, at - 1);
		final owner: Null<QueryNode> = at >= 2 ? lineage[at - 2] : null;
		if (owner == null || !(shape.expressionBodyKinds ?? []).contains(holder.kind)) return false;
		final memberFunctions: Array<String> = [
			for (k in shape.functionKinds ?? []) if (!(shape.lambdaKinds ?? []).contains(k)) k
		];
		return memberFunctions.contains(owner.kind)
			&& owner.children.exists(c -> (shape.typeAnnotationKinds ?? []).contains(c.kind) && c.name == shape.voidTypeName);
	}

	/**
	 * Whether the value of the statement `lineage[at]` is discarded: it is followed by another statement of its block or
	 * arm, or it ends one whose own value is discarded — a function's block body (never its value), a loop's body, or a
	 * statement `if` / `switch` / `try` branch or nested block that is itself discarded. The last statement of a block, arm
	 * or branch in value position is that construct's value, and any shape not listed counts as not discarded.
	 */
	private function valueDiscarded(lineage: Array<QueryNode>, at: Int): Bool {
		final shape: RefShape = _scope.shape;
		if (at < 1) return false;
		final node: QueryNode = lineage[at];
		final parent: QueryNode = lineage[at - 1];
		final kind: String = parent.kind;
		final sequence: Bool = kind == shape.blockStmtKind || kind == shape.blockBodyKind || (shape.branchScopeKinds ?? []).contains(kind);
		if (sequence && parent.children[parent.children.length - 1] != node) return true;
		if ((shape.loopStatementKinds ?? []).concat(shape.doWhileLoopKinds ?? []).contains(kind)) return true;
		if (kind == shape.blockBodyKind) return at >= 2 && bodyDiscardsItsValue(lineage[at - 2]);
		final statementForms: Array<String> = (shape.ifStatementKinds ?? []).concat(shape.switchStatementKinds ?? [])
			.concat(shape.tryStatementKinds ?? []);
		// an arm or a catch is climbed to its `switch` / `try`, which decides for itself
		final climbs: Bool = kind == shape.blockStmtKind || statementForms.contains(kind) || (shape.branchScopeKinds ?? []).contains(kind)
			|| kind == shape.catchClauseKind;
		return climbs && valueDiscarded(lineage, at - 1);
	}

	/**
	 * Whether `owner`, holding a block body, discards the body's last statement: a `function` does, an arrow lambda
	 * yields it, and a `do` loop runs it as a statement.
	 */
	private function bodyDiscardsItsValue(owner: QueryNode): Bool {
		final shape: RefShape = _scope.shape;
		final arrows: Array<String> = [
			for (k in shape.lambdaKinds ?? []) if (k != shape.fnExprKind && k != shape.namedFnExprKind) k
		];
		final discarding: Array<String> = (shape.functionKinds ?? []).concat(shape.lambdaKinds ?? []).concat(shape.doWhileLoopKinds ?? []);
		return !arrows.contains(owner.kind) && discarding.contains(owner.kind);
	}

	/** Whether `node` is the ITERABLE of the `for` statement `loop`, not its body. */
	private function isIterableOf(loop: QueryNode, node: QueryNode): Bool {
		return NominalTypes.iterationIterable(loop, _scope.shape.iterationValueBinderKinds ?? []) == node;
	}

	/**
	 * Whether `value` is a call of a method its receiver's type ITSELF declares as returning a new object
	 * (`ExecutionShape.freshReturningMethods`, keyed by type) — a member always wins over a `using` extension of the
	 * same name, so only a receiver whose type is known counts: an array or string literal, an identifier
	 * declared of the type, or another such call, whose result is the array type. When the index holds the
	 * type's declaration, it must declare the method too.
	 */
	private function freshResult(value: QueryNode, ctx: FreshContext): Bool {
		if (value.kind != _scope.shape.callKind || value.children.length == 0) return false;
		final callee: QueryNode = value.children[0];
		final method: Null<String> = callee.name;
		if (!_hazards.isAccess(callee.kind) || callee.children.length != 1 || method == null) return false;
		final receiverType: Null<String> = builtinTypeOf(BoolExprShape.unwrapParens(callee.children[0], _scope.shape.parenKind), ctx);
		if (receiverType == null || !((_scope.shape.execution?.freshReturningMethods ?? [])[receiverType] ?? []).contains(method))
			return false;
		final declared: Null<FileInfo> = _scope.index.fileInfo(_scope.siteOf(receiverType)?.file ?? '');
		final decl: Null<TypeDeclInfo> = declared?.types.find(t -> t.name == receiverType);
		return decl == null || decl.members.exists(m -> m.name == method);
	}

	/**
	 * The built-in array or string type `node` is known to hold — a literal, an identifier declared of the
	 * type, or a fresh-returning call (whose result is an array) — or null.
	 */
	private function builtinTypeOf(node: QueryNode, ctx: FreshContext): Null<String> {
		final arrays: Array<String> = _scope.shape.arrayTypeNames ?? [];
		final strings: Array<String> = stringTypeNames();
		if (node.kind == _scope.shape.arrayLiteralKind) return arrays[0];
		if ((_scope.shape.stringLiteralKinds ?? []).contains(node.kind)) return strings[0];
		if (freshResult(node, ctx)) return arrays[0];
		final provider: Null<TypeInfoProvider> = _scope.plugin is TypeInfoProvider ? cast _scope.plugin : null;
		final bound: Null<Int> = TypeResolver.identBindingFrom(node, ctx.tree, _scope.shape);
		final written: Null<String> = bound == null || provider == null ? null : provider.declaredTypeSources(ctx.source)[bound];
		final outer: Null<String> = written == null ? null : NominalTypes.outerNominalOf(written, _scope.plugin.typeSyntax);
		return outer != null && (arrays.contains(outer) || strings.contains(outer)) ? outer : null;
	}

	/** The type names the grammar's string literals denote (`RefShape.literalTypeNames`). */
	private function stringTypeNames(): Array<String> {
		final literalTypes: Map<String, String> = _scope.shape.literalTypeNames ?? [];
		return [
			for (kind in _scope.shape.stringLiteralKinds ?? []) if (literalTypes.exists(kind)) literalTypes[kind] ?? ''
		];
	}

	/**
	 * The initializer of member `name` on `declaring` that is not freshly built — its value is shared from the start —
	 * in any declaration of the member: one per branch of a conditional region, each of them what some build runs.
	 */
	private function sharedInitializer(g: CallGraph, declaring: String, name: String): Null<{ file: String, span: Span }> {
		final site: Null<{ file: String, span: Span }> = _scope.siteOf(declaring);
		if (site == null) return null;
		final tree: Null<QueryNode> = g.treeOf(site.file);
		if (tree == null) return null;
		final declared: Array<MemberInfo> = [
			for (t in _scope.index.fileInfo(site.file)?.types ?? []) if (t.name == declaring) for (m in t.members) if (m.name == name) m
		];
		for (info in declared) {
			final decl: Null<QueryNode> = RefactorSupport.nodeAtFrom(tree, info.declFrom);
			final init: Null<QueryNode> = decl == null || decl.name != name ? null : CtorFieldFold.declInitializer(decl, _scope.shape);
			final span: Null<Span> = init?.span;
			if (init != null && span != null && !isFresh(init, null)) return { file: site.file, span: span };
		}
		return null;
	}

	/** The innermost type declaration of `tree` enclosing `offset`. */
	public static function typeAt(tree: QueryNode, offset: Int): Null<String> {
		var found: Null<String> = null;
		function walk(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			if (span != null && (offset < span.from || offset >= span.to)) return;
			final name: Null<String> = CallGraphNames.typeNameOf(node);
			if (name != null) found = name;
			for (c in node.children) walk(c);
		}
		walk(tree);
		return found;
	}

	/** The field a call fact's `target` names (`pack.Type.field`, a bare field name), or null for a call of no field. */
	private static function calledField(target: Null<String>): Null<String> {
		return target == null ? null : target.substr(target.lastIndexOf('.') + 1);
	}

	/** The declaration of the node `id` (`CallGraph.declarationsOf`) whose text holds the fact position `at`, or null. */
	private static function declarationHolding(g: CallGraph, id: String, at: FactPos, view: FactsView): Null<FnDeclaration> {
		return g.declarationsOf(id)
			.find(d -> at.file == view.table.keyOf(d.file) && d.span.from <= at.span.from && at.span.to <= d.span.to);
	}

	/** Whether `span` shares a position with `region`; false when there is no region. */
	private static function meets(span: Span, region: Null<Span>): Bool {
		return region != null && span.from < region.to && region.from < span.to;
	}

	/**
	 * Whether the typed access `f` is of a shape `classifyTyped` answers for: a field of an instance, a static, a structure
	 * or a dynamic receiver, written, or read with a use it lists (`TYPED_USES`) — a call naming its method.
	 */
	private static function typedShape(f: FieldFact): Bool {
		if (!TYPED_ACCESSES.contains(f.access)) return false;
		final use: Null<String> = f.use;
		return f.write || (use != null && TYPED_USES.contains(use) && (use != 'call' || f.method != null));
	}

	/** Whether `span` lies inside `region`; false when there is no region. */
	private static function within(span: Span, region: Null<Span>): Bool {
		return region != null && span.from >= region.from && span.to <= region.to;
	}

	private static function typesOf(provider: Null<TypeInfoProvider>, source: String): Map<Int, String> {
		return provider == null ? [] : provider.declaredTypes(source);
	}

	private static function lastSegment(path: String): String {
		final dot: Int = path.lastIndexOf('.');
		return dot < 0 ? path : path.substring(dot + 1);
	}

}

/** A site of a member occurrence. */
typedef Occurrence = {
	var file: String;
	var span: Span;
}

/**
 * The scan's result: toucher node id -> its touch site, the escape sites,
 * a blind spot in the project, and a touch inside the entry region.
 */
typedef MemberTouches = {
	var touchers: Map<String, Occurrence>;

	/** Toucher id -> a touch it makes on an object other than its own `this` (absent when every touch is on `this`). */
	var notOnSelf: Map<String, Occurrence>;

	var escapes: Array<Occurrence>;
	var hidden: Null<ReachUnknown>;
	var inRegion: Null<ReachStep>;
}

/** What `MemberTouchScan.isFresh` needs to type a method call's receiver: the file's tree and text. */
typedef FreshContext = {
	var tree: QueryNode;
	var source: String;

	/** Whether a call node of `tree` returns an object nothing else holds; absent, no call but a built-in one is fresh. */
	@:optional var call: Null<QueryNode -> Bool>;
}

private typedef Verdict = {
	var touch: Bool;
	var escape: Bool;
}

/** How the typed accesses of a member in a faceted function are read (`MemberTouchScan.nodeAccesses`). */
private enum TypedTouches {

	/** Through these accesses, each where it runs. */
	Typed(accesses: Array<FieldFact>);

	/** Through the function's syntax: some access is of a shape the facts do not answer for, and its text holds it. */
	BySyntax;

	/** By neither: such an access lies in code no text holds — a build macro's method, an expression macro's expansion. */
	Unread;

}
