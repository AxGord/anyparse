package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.RiskyFix;
import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * The statement-position spine an embedded assignment may sit under, resolved once per run from
 * `RefShape` + `ControlFlowSupport`. `containers` are the DATA-STRUCTURE literals that separate a
 * buried assignment from a plainly-visible one; `passThrough` are the construction nodes a
 * candidate may sit under WITHOUT being buried (a call, a `new`, a paren, a field-access receiver,
 * an object-literal field). Every kind outside both sets ends the descent -- see the class doc.
 */
private typedef Spine = {
	final assign: String;
	final ident: String;
	final hosts: Array<String>;
	final containers: Array<String>;
	final passThrough: Array<String>;
	final blocks: Array<String>;
}

/** One statement and every assignment the rule hoists out of it, in source order. */
private typedef HoistSite = {
	final stmt: QueryNode;
	final assigns: Array<QueryNode>;
}

/**
 * Flags an assignment written INSIDE a data structure -- an array or object literal being built as
 * one expression -- and hoists it in front of the statement, leaving the bare name where the
 * assignment was:
 *
 * ```haxe
 * content = new Col([new Row([new Label(a), _headerLabel = new Label(b)])]);
 * // ->
 * _headerLabel = new Label(b);
 * content = new Col([new Row([new Label(a), _headerLabel])]);
 * ```
 *
 * The write is the one thing in that statement a reader must not miss, and it is the one thing
 * four indent levels of layout tree hide. `Info` -- the code is correct -- and `DefaultOff`:
 * "hold a handle while building the tree" is a house style, and a project that likes it should
 * not be nagged.
 *
 * ## THE SEPARATING GATE IS DEPTH, NOT THE SHAPE OF THE ASSIGNMENT
 *
 * The tempting rule is "an assignment used as a value" -- and it is wrong, because it breaks a
 * living idiom. `_container.addChild(_resizeDot = createResizeDot(x, y))` is an assignment in
 * value position too, and hoisting it doubles the block for nothing: the write is already in
 * plain sight, one node under the statement's own call. Measured on the projected tree, the two
 * shapes are not near-misses of each other:
 *
 * ```
 * c.addChild(_d = mk(1));
 *   ExprStmt > Call > Assign                                              (depth 2)
 * content = new Col([new Row([a, _h = new L(2)])]);
 *   ExprStmt > Assign > NewExpr > ArrayExpr > NewExpr > ArrayExpr > Assign (depth 6)
 * ```
 *
 * So the criterion is POSITIVE and structural: hoist when at least one CONTAINER LITERAL
 * (`arrayLiteralKind` / `objectLiteralKind`) separates the assignment from the statement root.
 * A call's own argument list is not a data structure; an array literal is. Nothing else in the
 * path counts, which is why an argument-position assignment at ANY nesting of plain calls stays
 * untouched.
 *
 * ## The descent is a whitelist, so an unmodelled shape refuses itself
 *
 * A candidate is reached only through `passThrough` / `containers` kinds -- eagerly and
 * unconditionally evaluated construction nodes. Everything else ends the descent, and ends it
 * with a REFUSAL of the whole statement if an assignment hides anywhere inside it. That is what
 * keeps three unsound hoists out without naming any of them:
 *
 * - a lambda body (`new Button(() -> _x = f())`) -- hoisting would run the write at construction
 *   time instead of at call time;
 * - a ternary / short-circuit arm (`[c ? (_x = a) : b]`) -- hoisting would make it unconditional;
 * - a conditional-compilation region inside the literal (`ConditionalArgs` in the Haxe grammar) --
 *   hoisting would lift the write out of its `#if` guard, so a build that excludes the branch
 *   would get a write it never had. This is the shape that refuses the TM
 *   `RegisterLoginTypeForm` site, which otherwise reads exactly like the rest of the family.
 *
 * ## Evaluation order -- what moves, and the two gates that make it safe
 *
 * The hoist runs the write before the neighbours that were built ahead of it. Two gates bound
 * what that can change:
 *
 * - the target is not mentioned again anywhere inside the statement (a single mention, the
 *   assignment's own l-value). So no neighbour reads the handle being written, and two candidates
 *   can never name each other;
 * - the only assignments in the statement are the hoisted ones and, optionally, the statement's
 *   OWN root assignment. Any other assignment refuses the statement outright, so no write can be
 *   reordered against another write.
 *
 * The statement's own root assignment (`content = …`) needs no gate of its own: an r-value is
 * fully evaluated before the l-value is written, so a candidate inside it already ran before that
 * write and still does after the hoist.
 *
 * With several candidates in one statement, ALL of them hoist, in source order -- a partial hoist
 * would reverse two writes against each other, so `fix` declines a subset.
 *
 * ## Why the fix is `RiskyFix`
 *
 * The hoist is structurally sound and still not type-NEUTRAL, so the edit goes through the
 * compiler-oracle verify-and-revert path instead of being trusted. Two measured reasons, neither
 * of them provable from the tree:
 *
 * - STRICT NULL SAFETY loses a narrowing as soon as there are SEVERAL candidates. A field read
 *   IMMEDIATELY after its own assignment is still narrowed, so a lone hoist typechecks; the
 *   second hoisted statement resets the first field's narrowing, and the literal then rejects
 *   the `Null<T>` read. Measured on Haxe 4.3.7 / `--interp`:
 *   `_a = new L(); _b = new L(); new Row2([_a, _b]);` under `@:nullSafety(Strict)` gives
 *   `Null safety: Cannot use nullable value of Null<L> as an item in Array<L>`, while the same
 *   code with both assignments left inside the literal compiles.
 * - A PROPERTY target with an asymmetric accessor pair changes VALUE: `_h = v` yields whatever
 *   `set_h` returns, and the hoisted literal reads `get_h()` instead.
 *
 * ## What it does not claim
 *
 * The host must be an expression STATEMENT or a LOCAL DECLARATION, and it must be a direct child of
 * a statement list. A brace-less `if (c) content = new Col([_h = …]);` has nowhere to put a second
 * statement, so it is refused -- a deliberate boundary, not an oversight. A local declaration is
 * admitted for the same reason the statement's own root assignment is: the initializer is fully
 * evaluated before the local is bound, so a candidate inside it already ran ahead of that binding
 * and still does. A multi-variable continuation (`localDeclContinuationKinds`) is NOT a host: it is
 * part of the declaration ahead of it, not a statement of its own.
 */
@:nullSafety(Strict)
final class HoistEmbeddedAssignment implements Check implements DefaultOff implements RiskyFix {

	private static inline final ID: String = 'hoist-embedded-assignment';

	public function new() {}

	public function id(): String {
		return ID;
	}

	public function description(): String {
		return 'an assignment buried inside an array / object literal — hoist it in front of the statement';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final spine: Null<Spine> = spineOf(plugin);
		if (spine == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			for (site in sites(tree, spine)) for (assign in site.assigns) {
				final span: Null<Span> = assign.span;
				final name: Null<String> = targetName(assign);
				if (span != null && name != null) violations.push({
					file: entry.file,
					span: span,
					rule: ID,
					severity: Severity.Info,
					message: 'assignment to `$name` is buried inside a data structure — hoist it in front of the statement'
				});
			}
		}
		return violations;
	}

	/**
	 * Two edits per hoisted assignment plus one per statement: each assignment's span collapses to
	 * its bare target name, and the statement's own start receives every hoisted assignment
	 * verbatim, in source order, each terminated by `;`. Layout is the writer's job -- the caller
	 * re-emits the whole spliced file, which is what lets the motivating site come out SHORTER
	 * than it went in (four indent levels dropped fit the value on fewer lines).
	 *
	 * A statement whose candidates are not ALL present in `violations` is skipped: hoisting a
	 * subset would reorder the remaining write against the hoisted ones.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final spine: Null<Spine> = spineOf(plugin);
		if (spine == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final flagged: Array<String> = [];
		for (violation in violations) {
			final span: Null<Span> = violation.span;
			if (span != null) flagged.push(spanKey(span));
		}
		final edits: Array<{ span: Span, text: String }> = [];
		for (site in sites(tree, spine)) {
			final stmtSpan: Null<Span> = site.stmt.span;
			if (stmtSpan == null) continue;
			var prefix: String = '';
			var complete: Bool = true;
			final pending: Array<{ span: Span, text: String }> = [];
			for (assign in site.assigns) {
				final span: Null<Span> = assign.span;
				final name: Null<String> = targetName(assign);
				if (span == null || name == null || !flagged.contains(spanKey(span))) {
					complete = false;
					break;
				}
				prefix += '${source.substring(span.from, span.to)};\n';
				pending.push({ span: span, text: name });
			}
			if (!complete || pending.length == 0) continue;
			for (edit in pending) edits.push(edit);
			edits.push({ span: new Span(stmtSpan.from, stmtSpan.from), text: prefix });
		}
		return edits;
	}

	private static inline function spanKey(span: Span): String {
		return '${span.from}:${span.to}';
	}

	/** The rule's kind vocabulary, or null when the grammar declares too little of it to run. */
	private static function spineOf(plugin: GrammarPlugin): Null<Spine> {
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return null;
		final shape: RefShape = plugin.refShape();
		final assign: Null<String> = shape.assignKind;
		final exprStmt: Null<String> = shape.exprStatementKind;
		if (assign == null || exprStmt == null) return null;
		final continuations: Array<String> = shape.localDeclContinuationKinds ?? [];
		final hosts: Array<String> = [exprStmt];
		for (kind in shape.localDeclKinds ?? []) if (!continuations.contains(kind)) hosts.push(kind);
		final containers: Array<String> = [];
		final array: Null<String> = shape.arrayLiteralKind;
		final object: Null<String> = shape.objectLiteralKind;
		if (array != null) containers.push(array);
		if (object != null) containers.push(object);
		if (containers.length == 0) return null;
		final passThrough: Array<String> = containers.copy();
		passThrough.push(shape.identKind);
		for (kind in [
			shape.callKind,
			shape.newExprKind,
			shape.parenKind,
			shape.fieldAccessKind,
			shape.objectFieldKind
		]) if (kind != null) passThrough.push(kind);
		return {
			assign: assign,
			ident: shape.identKind,
			hosts: hosts,
			containers: containers,
			passThrough: passThrough,
			blocks: support.blockKinds()
		};
	}

	/** Every hoistable statement in `root`, outermost first. */
	private static function sites(root: QueryNode, spine: Spine): Array<HoistSite> {
		final out: Array<HoistSite> = [];
		collectSites(root, spine, out);
		return out;
	}

	private static function collectSites(node: QueryNode, spine: Spine, out: Array<HoistSite>): Void {
		if (spine.blocks.contains(node.kind)) for (child in node.children) if (spine.hosts.contains(child.kind)) {
			final site: Null<HoistSite> = siteOf(child, spine);
			if (site != null) out.push(site);
		}
		for (child in node.children) collectSites(child, spine, out);
	}

	/** `stmt`'s hoistable assignments, or null when any gate refuses the statement. */
	private static function siteOf(stmt: QueryNode, spine: Spine): Null<HoistSite> {
		final found: Array<QueryNode> = [];
		for (child in stmt.children) if (!descend(child, spine, false, true, found)) return null;
		if (found.length == 0) return null;
		for (assign in found) {
			final name: Null<String> = targetName(assign);
			if (name == null || mentions(stmt, name) != 1) return null;
		}
		return { stmt: stmt, assigns: found };
	}

	/**
	 * Walk one construction node. Returns false the moment the statement must be refused: an
	 * assignment outside a container literal, an l-value that is not a bare name, a nested
	 * assignment inside a candidate's value, or an assignment anywhere under a node the spine
	 * does not model.
	 */
	private static function descend(node: QueryNode, spine: Spine, inContainer: Bool, statementRoot: Bool, found: Array<QueryNode>): Bool {
		if (node.kind == spine.assign) {
			if (statementRoot) {
				return node.children.foreach(child -> descend(child, spine, inContainer, false, found));
			}
			if (!inContainer || node.children.length != 2) return false;
			final target: QueryNode = node.children[0];
			if (target.kind != spine.ident || target.name == null) return false;
			if (subtreeHas(node.children[1], spine.assign)) return false;
			found.push(node);
			return true;
		}
		if (!spine.passThrough.contains(node.kind)) return !subtreeHas(node, spine.assign);
		final within: Bool = inContainer || spine.containers.contains(node.kind);
		return node.children.foreach(child -> descend(child, spine, within, false, found));
	}

	/** The bare name an assignment writes, or null when its l-value is not one. */
	private static function targetName(assign: QueryNode): Null<String> {
		return assign.children.length == 0 ? null : assign.children[0].name;
	}

	private static function subtreeHas(node: QueryNode, kind: String): Bool {
		if (node.kind == kind) return true;
		return node.children.exists(child -> subtreeHas(child, kind));
	}

	/** How many nodes in `node`'s subtree carry `name` — any kind, so a read through any form counts. */
	private static function mentions(node: QueryNode, name: String): Int {
		var count: Int = node.name == name ? 1 : 0;
		for (child in node.children) count += mentions(child, name);
		return count;
	}

}
