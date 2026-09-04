package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.MemberBranchScan;
import anyparse.query.Refs.RefKind;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;
using Lambda;

/**
 * WHERE a field is written, and whether that write is reached on every path. The query layer
 * under every check that reasons about a field's initialisation — `prefer-final-field`,
 * `prefer-read-only-field`, `field-init-in-constructor`, `field-init-at-declaration` — and the
 * layer `CtorFieldFold` builds its edits on.
 *
 * Two proofs, and they are the whole module. FINDING the write: `soleConstructor` and the
 * `soleConstructorField*` pair locate the ONE assignment to a field, refusing the moment there
 * is more than one. PROVING it unconditional: `ctorWriteUnconditional` walks up from the
 * assignment through the whitelist of node kinds that evaluate a child on every path, and
 * `ctorPrefixUnconditional` proves every statement before it completes normally. Both refusals
 * are conservative by construction — an unrecognised kind fails the walk — because a wrong
 * `true` here promotes a field to `final` that some path leaves unassigned.
 *
 * `contextFreeRhs`, `abstractMethodMayMutate` and `reassignedInScope` are the value-side
 * companions: whether the expression written means the same thing elsewhere, and whether
 * anything else in scope writes the binding at all.
 */
@:nullSafety(Strict)
final class CtorFieldWrite {

	/**
	 * Simple names of stdlib value / container types whose methods never reassign an
	 * abstract `this`, so a method call on a binding of one is not a write that blocks
	 * `final`: `String` is immutable; `Array` / `Map` and the others mutate their
	 * contents, not the binding. The `final`-conversion checks keep suggesting `final`
	 * for such bindings even when their type is not resolvable in the lint scope.
	 *
	 * This MUTABILITY fact is NOT derivable from a declaration — a method signature
	 * never states whether it reassigns `this` — so, unlike the extension-method and
	 * static-return tables now derived from the std sources via `StdResolver`, this
	 * list is intrinsic semantic knowledge and stays hand-maintained.
	 */
	private static final finalSafeStdlibTypes: Array<String> = [
		'String',
		'Array',
		'Map',
		'List',
		'Vector',
		'StringBuf',
		'StringMap',
		'IntMap',
		'ObjectMap',
		'EnumValueMap',
		'Bytes',
		'BytesBuffer',
		'EReg',
		'Date',
		'Xml'
	];

	/**
	 * Visit every mutable `var` field member of every visibility-bearing type in
	 * `files`, with the enclosing type's simple name, the field node, its source, file,
	 * and whether its preceding modifier run marks it exported (non-default visibility).
	 * The shared container walk behind the field-immutability checks
	 * (`prefer-final-field` private path, `prefer-final-public-field`,
	 * `prefer-read-only-field`) — each filters by `exported` and applies its own proof.
	 * Skip-parse tolerant; a grammar lacking the visibility kind-sets yields nothing.
	 *
	 * A field written inside a member-position `#if` region is visited too: the region is ONE
	 * child of the container holding every branch's fields flattened, so scanning the container's
	 * direct children alone silently exempted every guarded field. `MemberBranchScan.fold` descends
	 * into it branch by branch, and merges the exported flag a branch carries out with OR — the
	 * fail-closed direction here. A field the merge calls exported when some build makes it private
	 * is at worst reported by the public-field rules instead of the private one; the AND reading
	 * would hand `prefer-final-field`'s file-confined write proof a field that is PUBLIC in another
	 * build, where an out-of-file writer it never scans can exist.
	 */
	public static function eachFieldMember(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin,
		visit: (owner:String, field:QueryNode, source:String, file:String, exported:Bool) -> Void
	): Void {
		final shape: RefShape = plugin.refShape();
		final containers: Array<String> = shape.visibilityContainerKinds ?? [];
		final members: Array<String> = shape.memberDeclKinds ?? [];
		final mutableFields: Array<String> = shape.mutableFieldDeclKinds ?? [];
		final visibility: Array<String> = shape.visibilityModifierKinds ?? [];
		final defaultVis: Null<String> = shape.defaultVisibilityModifierText;
		if (containers.length == 0 || members.length == 0 || mutableFields.length == 0 || visibility.length == 0 || defaultVis == null)
			return;
		// Re-bound to a non-null local: a narrowing does not reach into an anonymous struct literal.
		final vis: String = defaultVis;
		for (entry in files) {
			final tree: Null<QueryNode> = try plugin.parseFile(entry.source) catch (_: Exception) null;
			if (tree != null) walkFieldContainers(tree, {
				source: entry.source,
				file: entry.file,
				containers: containers,
				members: members,
				mutableFields: mutableFields,
				visibility: visibility,
				defaultVis: vis,
				branch: MemberBranchScan.seamsOf(shape, entry.source, plugin.lexicalRegions.bind(entry.source)),
				visit: visit
			});
		}
	}

	/**
	 * The single constructor (`FnMember` named `new`) directly declared in `container`,
	 * or null when there is not exactly one — a multiple-constructor (macro-generated)
	 * class is skipped so a field's init timing stays a plain single `new`.
	 */
	public static function soleConstructor(container: QueryNode, shape: RefShape): Null<QueryNode> {
		final ctorName: Null<String> = shape.constructorName;
		final members: Array<String> = shape.memberDeclKinds ?? [];
		if (ctorName == null) return null;
		var found: Null<QueryNode> = null;
		var several: Bool = false;
		// Every member host, not just the container's direct children: a constructor written inside a
		// member-position `#if` is one level down, and reading it as absent let a caller treat a
		// SECOND, guarded constructor's assignments as if they did not exist.
		MemberKinds.eachMemberHost(container, host -> {
			for (child in host.children) if (members.contains(child.kind) && child.name == ctorName) {
				if (found != null) several = true;
				found = child;
			}
		});
		return several ? null : found;
	}

	/**
	 * The single unconditional top-level constructor statement that assigns `field`
	 * (`field = expr` or `this.field = expr`, a DIRECT child of the constructor's block
	 * body — not nested in a branch / loop / closure), paired with the assignment's
	 * right-hand side and the assignment target's span, or null when there is not
	 * exactly one. `container` scopes binding resolution, so a bare `field =` that
	 * resolves to a shadowing constructor local / parameter does NOT match this field.
	 */
	public static function soleConstructorFieldInit(
		container: QueryNode, ctor: QueryNode, field: QueryNode, shape: RefShape
	): Null<{ stmt: QueryNode, rhs: QueryNode, target: Span }> {
		final bodyKind: Null<String> = shape.blockBodyKind;
		final stmtKind: Null<String> = shape.exprStatementKind;
		final assignKind: Null<String> = shape.assignKind;
		final fieldSpan: Null<Span> = field.span;
		final fieldName: Null<String> = field.name;
		if (bodyKind == null || stmtKind == null || assignKind == null || fieldSpan == null || fieldName == null) return null;
		final fieldFrom: Int = fieldSpan.from;
		final body: Null<QueryNode> = ctor.children.find(c -> c.kind == bodyKind);
		if (body == null) return null;
		var match: Null<{ stmt: QueryNode, rhs: QueryNode, target: Span }> = null;
		for (stmt in body.children) if (stmt.kind == stmtKind && stmt.children.length >= 1) {
			final assign: QueryNode = stmt.children[0];
			if (assign.kind != assignKind || assign.children.length < 2) continue;
			final target: QueryNode = assign.children[0];
			final tSpan: Null<Span> = target.span;
			if (tSpan == null) continue;
			if (!ctorTargetIsField(target, fieldFrom, fieldName, container, shape)) continue;
			if (match != null) return null;
			match = { stmt: stmt, rhs: assign.children[1], target: tSpan };
		}
		return match;
	}

	/**
	 * The single assignment to `field` ANYWHERE in `ctor`'s body — `field = expr` /
	 * `this.field = expr` at any expression depth, including one EMBEDDED in a call argument
	 * (`super([_a = new Row(…)])`, the layout-tree idiom) — paired with its right-hand side and
	 * the target's span, or null when there is not exactly one.
	 *
	 * A strict SUPERSET of `soleConstructorFieldInit`, which admits only a direct child of the
	 * body's statement list. A caller whose edit DELETES the statement must keep using that one:
	 * an embedded write's value is consumed in place, so deleting its line deletes live code.
	 * `container` scopes binding resolution, so a bare `field =` resolving to a shadowing
	 * constructor local / parameter does NOT match.
	 *
	 * A write inside a CLOSURE refuses, and that is the one nesting Haxe itself rejects:
	 * `new() { run(() -> _a = 1); }` over a `final _a` fails with `This expression cannot be
	 * accessed for writing` plus `Some final fields are uninitialized in this class` (4.3.7,
	 * `--interp`). Every OTHER nesting — an `if` / `switch` branch, a loop body, a ternary arm, an
	 * `&&` right operand — the compiler ACCEPTS for a `final` field, measured on the same build, so
	 * this predicate admits them: it answers "is this the field's sole assignment", never "does it
	 * run exactly once". A consumer that MOVES the right-hand side therefore owes the separate
	 * `ctorWriteUnconditional` proof; a consumer that only rewrites the declaration's `var` to
	 * `final` does not, since the keyword changes no evaluation.
	 */
	public static function soleConstructorFieldWrite(
		container: QueryNode, ctor: QueryNode, field: QueryNode, shape: RefShape
	): Null<{ assign: QueryNode, rhs: QueryNode, target: Span }> {
		final bodyKind: Null<String> = shape.blockBodyKind;
		final assignKind: Null<String> = shape.assignKind;
		final fieldSpan: Null<Span> = field.span;
		final fieldName: Null<String> = field.name;
		if (bodyKind == null || assignKind == null || fieldSpan == null || fieldName == null) return null;
		final body: Null<QueryNode> = ctor.children.find(c -> c.kind == bodyKind);
		if (body == null) return null;
		final found: Array<{ assign: QueryNode, inClosure: Bool }> = [];
		collectCtorFieldWrites(body, fieldSpan.from, fieldName, container, shape, assignKind, closureHostKinds(shape), false, found);
		if (found.length != 1 || found[0].inClosure) return null;
		final assign: QueryNode = found[0].assign;
		final targetSpan: Null<Span> = assign.children[0].span;
		return targetSpan == null ? null : {
			assign: assign,
			rhs: assign.children[1],
			target: targetSpan
		};
	}

	/**
	 * Whether the assignment node starting at `writeFrom` sits in an UNCONDITIONALLY EVALUATED
	 * position of `ctor`'s body — every step from one of the body's top-level statements down to it
	 * evaluates its operand exactly once, whatever the data. The question to ask before hoisting
	 * that write's right-hand side into the declaration prologue, which runs always: a write nested
	 * in an `if`, a ternary arm, an `&&` operand or a loop body runs conditionally, and
	 * `soleConstructorFieldWrite` deliberately admits all of those because Haxe accepts them for a
	 * `final` field. The two predicates split on exactly that line.
	 *
	 * Decided as a POSITIVE WHITELIST of transparent node kinds, never as a negative "and not an
	 * `if`, and not a ternary, and not …" list — a negative list leaks by CATEGORY, admitting
	 * whatever lazily-evaluated shape nobody enumerated. Admitted, each read off its own `RefShape`
	 * seam: an expression statement, a local declaration, a parenthesis, a call (callee and every
	 * argument), a `new`, an array literal, an object literal and its fields, and an outer
	 * assignment's right-hand side. Anything else refuses — including any kind whose seam the
	 * grammar leaves unset, so a plugin declaring none of them admits nothing rather than
	 * everything.
	 */
	public static function ctorWriteUnconditional(ctor: QueryNode, writeFrom: Int, shape: RefShape): Bool {
		final bodyKind: Null<String> = shape.blockBodyKind;
		if (bodyKind == null) return false;
		final body: Null<QueryNode> = ctor.children.find(c -> c.kind == bodyKind);
		if (body == null) return false;
		final transparent: Array<String> = unconditionalOperandKinds(shape);
		return body.children.exists(stmt -> transparent.contains(stmt.kind) && reachesThroughOperands(stmt, writeFrom, transparent));
	}

	/**
	 * Whether the constructor statement starting at `boundary` is UNCONDITIONALLY REACHED:
	 * every top-level statement lexically before it COMPLETES NORMALLY, so control arrives at
	 * `boundary` on every path. The question to ask before hoisting that statement's code into
	 * the declaration PROLOGUE, which runs ahead of the constructor body and therefore ahead of
	 * every guard the body holds — a guarded initialisation moved there becomes an unguarded
	 * one, and nothing downstream notices: the result still type-checks and still parses.
	 *
	 * Decided as a POSITIVE WHITELIST, never as a negative "and not an `if`, and not a
	 * `switch`, and not …" list — a negative list leaks by CATEGORY, letting through whatever
	 * statement shape nobody thought to enumerate. `completesNormally` holds the admitted
	 * kinds, each read off its own `RefShape` seam: an expression statement, a local
	 * declaration (plain or `static`), an `if`, a `switch`, a `try` / `catch`, a local
	 * `function` / `inline function` DECLARATION (it binds a name; its body does not run here),
	 * and a `#if` region. A top-level statement of ANY other kind before `boundary` refuses.
	 * `super(…)` projects as a plain expression statement on the Haxe grammar and stays allowed
	 * — this predicate answers only "is `boundary` reached", so a consumer that moves code
	 * ACROSS a `super(…)` owes its own judgement of that crossing (see
	 * `FieldInitAtDeclaration`'s "Known gaps").
	 *
	 * LOOPS ARE THE ONE DELIBERATE OMISSION, and they are the whitelist's only unique
	 * contribution: a loop cannot be proven to terminate, so it cannot be proven to complete.
	 * `while (true) { }` before `boundary` holds no control-exit node ANYWHERE, so the subtree
	 * scan below finds nothing to object to and only the kind check refuses it. Every other
	 * shape the whitelist used to refuse, the scan refuses too — which is what made widening it
	 * free.
	 *
	 * A kind whitelist alone is not enough, because a statement's KIND does not bound what its
	 * SUBTREE holds, and the subtree scan closes two separate holes:
	 *
	 * - A CONTROL EXIT HIDING INSIDE AN ACCEPTED KIND. A non-block `try` body projects as a
	 *   plain expression statement (`try return catch (e:Dynamic) {}` is
	 *   `ExprStmt(TryExpr(VoidReturnExpr …))`), and an admitted `if` / `switch` is exactly the
	 *   `if (!flag) return;` guard this predicate exists to refuse.
	 * - A LOOP HIDING INSIDE AN ACCEPTED KIND. Admitting `if` / `switch` / `try` / `#if` at top
	 *   level means `if (c) { while (true) {} }` would pass both the whitelist (its kind is an
	 *   `if`) and an exit-only scan (it holds no return or throw) — the loop omission would
	 *   stop holding one level down, and a top-level `for` would be refused while a nested one
	 *   was accepted, which is incoherent.
	 *
	 * The scan therefore runs over `controlExitKinds` UNION `loopStatementKinds`: any node of
	 * either set starting before `boundary` anywhere in the body subtree refuses.
	 *
	 * Three residual gaps, all measured and all accepted:
	 *
	 * - AN EXPRESSION STATEMENT THAT CANNOT RETURN IS ACCEPTED ANYWAY. `Sys.exit(0);`, or a call
	 *   to an always-throwing helper, reads as an ordinary expression statement, so the prefix is
	 *   judged straight-line and the hoist proceeds even though the constructor never reaches
	 *   `boundary`. Nothing short of interprocedural analysis sees through the call, so this one
	 *   is open by construction rather than by choice.
	 * - THE OVER-REFUSAL IS WIDER THAN A RARE SHAPE. The subtree scan is positional, not
	 *   scope-aware, so a `return` that exits NOTHING in the constructor still refuses: inside a
	 *   lambda passed as an argument, inside a local `function` / `inline function` declaration,
	 *   and inside a `macro { … }` block (all probed). A local `inline function` helper is an
	 *   idiom this project's own style prefers, so the cost is real rather than theoretical —
	 *   and doubly so now that such a declaration is an ADMITTED top-level kind, reaching the
	 *   scan only to be refused by its own body. The loop half of the scan inherits the same
	 *   imprecision: a loop inside a lambda before `boundary` refuses too.
	 * - `loopStatementKinds` DOES NOT COVER `do … while`. On the Haxe grammar it is
	 *   `['ForStmt', 'WhileStmt']`; `DoWhileStmt` lives in the separate `doWhileLoopKinds` seam,
	 *   whose consumers read the body off `children[0]`. A TOP-LEVEL `do … while (true)` is still
	 *   refused — no whitelist entry admits it — but one NESTED inside an admitted `if` is
	 *   invisible to the scan, and the prefix is judged to complete.
	 *
	 * Fails closed three ways: with no resolvable block body, with `controlExitKinds` unset (an
	 * empty set would make the subtree scan a silent no-op that accepts every early return,
	 * exactly the reasoning `guardReachedIntact` records for its own use of that seam), and with
	 * a prefix statement carrying no span. `loopStatementKinds` unset does NOT fail closed — it
	 * only makes the loop half of the scan inert, which is the behaviour that held before the
	 * scan learned about loops.
	 */
	public static function ctorPrefixUnconditional(ctor: QueryNode, boundary: Int, shape: RefShape): Bool {
		final bodyKind: Null<String> = shape.blockBodyKind;
		final exitKinds: Array<String> = shape.controlExitKinds ?? [];
		if (bodyKind == null || exitKinds.length == 0) return false;
		final body: Null<QueryNode> = ctor.children.find(c -> c.kind == bodyKind);
		if (body == null) return false;
		for (stmt in body.children) {
			final span: Null<Span> = stmt.span;
			// A statement whose position is unknown cannot be placed relative to the boundary.
			if (span == null) return false;
			if (span.from < boundary && !completesNormally(stmt.kind, shape)) return false;
		}
		return !kindStartsBefore(body, exitKinds.concat(shape.loopStatementKinds ?? []), boundary);
	}

	/**
	 * Whether every identifier read in `node` is context-independent: a global / type /
	 * imported name (unresolved within the class) or a static member of the class — a
	 * value available at declaration-init time — and the subtree contains no `this`. A
	 * reference that resolves within the class but is not static (a constructor parameter
	 * or local, or a non-static instance member) makes the init order-dependent and thus
	 * unmovable, since a static member is the only in-class binding whose value exists
	 * before the constructor body runs.
	 *
	 * Shared by the two rules that move an expression out of the constructor BODY and into
	 * the declaration prologue — `field-init-at-declaration` hoists a whole right-hand side,
	 * `join-array-pushes` folds a pushed element into an array literal's initializer. Both
	 * need the SAME proof, and it settles two questions at once: the moved text must be
	 * LEGAL at declaration-initializer position (Haxe rejects `this` and a sibling-instance
	 * read there) and INDEPENDENT of the constructor's context (a parameter or local does
	 * not exist yet).
	 *
	 * `allowStatics` false additionally refuses an in-class STATIC read — the stricter form
	 * `field-init-at-declaration`'s prologue-order gate asks for. `mayBeInherited` answers
	 * "could this unresolved lowercase name be a member the container INHERITS?"; a caller
	 * holding no positive evidence passes `_ -> true`, which keeps the closed direction.
	 */
	public static function contextFreeRhs(
		node: QueryNode, container: QueryNode, statics: Array<Int>, shape: RefShape, allowStatics: Bool, mayBeInherited: (String) -> Bool
	): Bool {
		final identKind: String = shape.identKind;
		final selfText: Null<String> = shape.selfReferenceText;
		// `$p` inside a single-quoted string projects as the interp `Ident` kind, not
		// `IdentExpr` - it is a reference all the same, and the resolver binds it by the
		// same scope rules, so the two share one arm (`${p}` blocks carry a regular
		// IdentExpr child and were already reached by the child walk).
		if (node.kind != identKind && node.kind != shape.stringInterpIdentKind)
			return node.children.foreach(child -> contextFreeRhs(child, container, statics, shape, allowStatics, mayBeInherited));
		final name: Null<String> = node.name;
		final span: Null<Span> = node.span;
		if (name == null || span == null) return false;
		if (selfText != null && name == selfText) return false;
		final bf: Null<Int> = TypeResolver.resolveBindingFrom(name, span, container, shape);
		// An unresolved ident is the provably-global case (imports/statics) - UNLESS the
		// container has a supertype clause: an INHERITED member is invisible to the
		// single-file resolver and indistinguishable from a global, so under `extends` /
		// `implements` an unresolved lowercase ident fails closed too (type refs like
		// `Colors.WHITE` keep their uppercase root and stay movable).
		if (bf != null) return allowStatics && statics.contains(bf);
		if (!hasSupertypeClause(container, shape)) return true;
		final c0: Int = StringTools.fastCodeAt(name, 0);
		// An uppercase root is a TYPE reference (`Colors.WHITE`) — never an inherited member, and
		// decided without touching the index. A lowercase one asks the index whether any ancestor
		// could declare it.
		return c0 >= 'A'.code && c0 <= 'Z'.code || !mayBeInherited(name);
	}

	/**
	 * Whether `container` carries any supertype clause (`extends` / `implements`) — the
	 * condition under which an unresolved bare ident may actually be an inherited member
	 * rather than a global, and the coarse fallback a base-constructor gate degrades to when
	 * the call itself cannot be recognised.
	 *
	 * Answers false when `supertypeClauseKinds` is unset, which degrades OPEN: a grammar
	 * declaring none of the inheritance seams gets no gate rather than a coarse one.
	 * Deliberately not closed by making an undeclared seam refuse every container — that
	 * would disarm the callers for any language with no inheritance concept.
	 */
	public static function hasSupertypeClause(container: QueryNode, shape: RefShape): Bool {
		final clauses: Array<String> = shape.supertypeClauseKinds ?? [];
		return clauses.length != 0 && container.children.exists(c -> clauses.contains(c.kind));
	}

	/**
	 * Collect every call in `node`'s subtree whose callee is the bare identifier `superText` —
	 * the explicit base-constructor calls. A `super.foo()` is deliberately NOT one: it is a
	 * base-MEMBER access, whose callee is a field access on `super` rather than `super` itself.
	 */
	public static function collectSuperCalls(
		node: QueryNode, superText: String, callKind: String, identKind: String, out: Array<QueryNode>
	): Void {
		if (node.kind == callKind && node.children.length > 0) {
			final callee: QueryNode = node.children[0];
			if (callee.kind == identKind && callee.name == superText) out.push(node);
		}
		for (child in node.children) collectSuperCalls(child, superText, callKind, identKind, out);
	}

	/**
	 * The class-like container and the field member declared at `fieldFrom`, found by
	 * re-walking `tree` — the fix-side re-derivation from a violation's span (a
	 * violation carries only its file and span, so the container and field are
	 * recovered from the parsed source).
	 */
	public static function classLikeFieldAt(
		tree: QueryNode, fieldFrom: Int, shape: RefShape
	): Null<{ container: QueryNode, field: QueryNode }> {
		return findFieldContainer(tree, fieldFrom, MemberKinds.classLikeContainerKinds(shape), shape.fieldDeclKinds ?? []);
	}

	/**
	 * Locate, from a parsed `tree`, the field at `fieldFrom` together with its
	 * class-like container and the single unconditional top-level constructor statement
	 * that initialises it — the shared entry point for `field-init-at-declaration`'s fix
	 * and `prefer-final-field`'s no-initializer case. Null when the field is not in a
	 * class-like container, the container has no single constructor, or the field is not
	 * assigned by exactly one top-level constructor statement.
	 */
	public static function constructorFieldInitAt(tree: QueryNode, fieldFrom: Int, shape: RefShape): Null<{
		container: QueryNode,
		field: QueryNode,
		stmt: QueryNode,
		rhs: QueryNode,
		target: Span
	}> {
		final loc: Null<{ container: QueryNode, field: QueryNode }> = classLikeFieldAt(tree, fieldFrom, shape);
		if (loc == null) return null;
		final ctor: Null<QueryNode> = soleConstructor(loc.container, shape);
		if (ctor == null) return null;
		final init: Null<{ stmt: QueryNode, rhs: QueryNode, target: Span }> = soleConstructorFieldInit(
			loc.container, ctor, loc.field, shape
		);
		return init == null ? null : {
			container: loc.container,
			field: loc.field,
			stmt: init.stmt,
			rhs: init.rhs,
			target: init.target
		};
	}

	/**
	 * The offset just before a field declaration's terminating `;`, where a moved
	 * `= <init>` is spliced. A `VarMember` / `FinalMember` span INCLUDES the trailing
	 * `;`, so the insert goes before it rather than at `span.to`; a span with no
	 * terminating `;` (skip-parse edge) falls back to `span.to`.
	 */
	public static function fieldDeclInitInsertPos(source: String, fieldSpan: Span): Int {
		var i: Int = fieldSpan.to - 1;
		while (i > fieldSpan.from) {
			final c: Int = source.fastCodeAt(i);
			if (c == ' '.code || c == '\t'.code || c == '\r'.code || c == '\n'.code) {
				i--;
				continue;
			}
			break;
		}
		return i > fieldSpan.from && source.fastCodeAt(i) == ';'.code ? i : fieldSpan.to;
	}

	/**
	 * Whether `field` is a plain field with an initializer and is NOT a property — the
	 * shared candidate-shape gate of the `final`-conversion field checks. False when the
	 * field has no initializer (its first child carries no span) or its head before the
	 * initializer contains a `(` (a property accessor clause).
	 */
	public static function isInitializedNonPropertyField(source: String, field: QueryNode): Bool {
		final span: Null<Span> = field.span;
		if (span == null || field.children.length < 1) return false;
		final initSpan: Null<Span> = field.children[0].span;
		return initSpan != null && source.substring(span.from, initSpan.from).indexOf('(') < 0;
	}

	/**
	 * Whether a never-reassigned `var` (field or local) named `name` with declared
	 * simple type `declType` must STAY mutable because a method call on it may reassign
	 * an `abstract`'s underlying `this` — a mutation the assignment-operator write scans
	 * cannot see (`abstract Step(Int) { function next():Void this = this + 1; }` mutated
	 * only via `_s.next()`). Finalizing such a binding produces code the compiler rejects
	 * ("Cannot modify abstract value of final field").
	 *
	 * `index` is forced lazily — only after a method call is found — so most runs never build it. When
	 * the plugin carries a resolution scope, the forced index resolves against the configured libraries
	 * too, so a library abstract (e.g. openfl `ByteArray`) is recognised rather than treated as unknown.
	 *
	 * True (keep the `var`) when `name` has a method call in `source` outside its own declaration
	 * `exclude` AND its type either resolves to an abstract that may REBIND `this`
	 * (`TypeTraits.abstractRebindsThis`) or is an UNRESOLVED non-stdlib type whose abstractness cannot
	 * be ruled out. False — the `final` suggestion stays sound and useful — for a resolved non-abstract
	 * type, a RESOLVED abstract whose only `this`-writes are in its constructor (the compiler forbids
	 * `this =` outside inline members and `final` rejects an inline this-writer transitively, so a
	 * ctor-only writer like `ByteArray` is final-safe) or that only `@:forward`s to a class underlying
	 * (which mutates the object, never the binding), a stdlib value type, an untyped binding, or no
	 * method call. A `@:build` abstract bails conservative (its members may be macro-generated and
	 * invisible).
	 *
	 * The `finalSafeStdlibTypes` whitelist is the ONE place this can be wrong, and its authority now
	 * extends past the fully-unresolved case: an abstract whose `@:forward` underlying the index cannot
	 * resolve answers `null` (see `TypeTraits.abstractRebindsThis`), so a WHITELISTED simple name
	 * shadowed by such an abstract is called final-safe on the whitelist's word. Everything else only
	 * ever KEEPS a `var`.
	 */
	public static function abstractMethodMayMutate(
		source: String, name: String, declType: Null<String>, exclude: Span, index: () -> Null<SymbolIndex>, abstractKinds: Array<String>
	): Bool {
		if (declType == null || !methodCalledOn(source, name, exclude)) return false;
		final idx: Null<SymbolIndex> = index();
		final resolvedRebind: Null<Bool> = idx?.traits.abstractRebindsThis(declType, abstractKinds);
		return resolvedRebind ?? !finalSafeStdlibTypes.contains(declType);
	}

	/**
	 * Whether the field declared by `field` can become `final` off its CONSTRUCTOR
	 * assignment: it has no declaration initializer (a `final` with one cannot be
	 * reassigned in the constructor) and no `(` in its declaration head (which covers
	 * properties and parenthesised function types), its sole write is exactly one
	 * constructor assignment `x = expr` / `this.x = expr` OUTSIDE a closure
	 * (`soleConstructorFieldWrite`), it is not static (`static final` requires a
	 * declaration initializer), and no other write to its name appears anywhere in
	 * `source` — a conservative text scan (`MemberWriteScan.writtenInRange`) that also
	 * sees `#if` bodies the structural walkers cannot. A `@:build` macro injecting a
	 * writer is the residual blind spot, shared with every other arm of the three
	 * consumers and surfacing as a loud compile error at the injected write.
	 *
	 * The write need NOT be a top-level STATEMENT — an assignment embedded in a call
	 * argument (`super([_a = new Row(…)])`) qualifies, because `var` -> `final` changes
	 * no evaluation and the only nesting Haxe rejects for a `final` field is a closure,
	 * which `soleConstructorFieldWrite` refuses. A shadowing local or parameter that
	 * owns the assignment leaves the field a `var`.
	 *
	 * The shared core of the constructor arms of `prefer-final-field` /
	 * `prefer-final-public-field` AND of `prefer-read-only-field`'s cession of the same
	 * candidates — all three MUST agree on it, or a ctor-assigned field either gets two
	 * conflicting fixes or none. A new single-file soundness gate for the arm therefore
	 * belongs INSIDE this predicate, never in one consumer — and mind its cost:
	 * predicate-false routes the field to `prefer-read-only-field`'s `(default, null)`.
	 * Each check wraps it in its own cross-file write gates; this predicate is
	 * single-file only.
	 */
	public static function ctorSoleAssignmentFinalizable(source: String, field: QueryNode, plugin: GrammarPlugin): Bool {
		final name: Null<String> = field.name;
		final span: Null<Span> = field.span;
		if (name == null || span == null) return false;
		if (field.children.length >= 1) return false;
		if (source.substring(span.from, span.to).indexOf('(') >= 0) return false;
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (_: Exception) null;
		if (tree == null) return false;
		final shape: RefShape = plugin.refShape();
		final loc: Null<{ container: QueryNode, field: QueryNode }> = classLikeFieldAt(tree, span.from, shape);
		if (loc == null) return false;
		final ctor: Null<QueryNode> = soleConstructor(loc.container, shape);
		if (ctor == null) return false;
		// `soleConstructorFieldWrite` rather than `soleConstructorFieldInit`: the write need not be a
		// top-level STATEMENT, only the constructor's sole assignment to the field, so an assignment
		// EXPRESSION consumed in place (`super([_a = new Row(…)])`) qualifies.
		final write: Null<{ assign: QueryNode, rhs: QueryNode, target: Span }> = soleConstructorFieldWrite(
			loc.container, ctor, loc.field, shape
		);
		if (write == null) return false;
		final writeSpan: Null<Span> = write.assign.span;
		// Haxe would ALSO accept `final` for a write nested in a branch, a loop or a lazy operand — it
		// runs no definite-assignment analysis — but this predicate keeps demanding an unconditional
		// position, which is what a top-level statement gave it before. Widening that is a separate
		// judgement about whether a conditionally-assigned `final` is worth reporting, not a
		// consequence of admitting the embedded shape, and `testNoInitConditionalNotFlagged` pins the
		// answer the three consumers ship today.
		if (writeSpan == null || !ctorWriteUnconditional(ctor, writeSpan.from, shape)) return false;
		return !MemberKinds.staticMemberFroms(loc.container, shape).contains(span.from)
			&& !MemberWriteScan.writtenInRange(source, name, write.target, 0, source.length);
	}

	/**
	 * Whether `name` is REASSIGNED anywhere inside `scope` — the shared write test behind
	 * `prefer-final`'s verdict and `prefer-comprehension`'s `var`-vs-`final` choice.
	 *
	 * `Refs.find` is COMPLETE for writes: every write is a structural assignment / `++` / `--`
	 * node, and the only reference a source scan would miss — simple `'$x'` interpolation — can
	 * only ever be a read. Attribution is by POSITION-in-scope rather than by the resolver's
	 * binding, which is immune to the same-named-sibling-`case`-branch collision: a local can only
	 * be reassigned from inside its own scope, so no real reassignment is missed, and the other
	 * direction (a sibling branch's write of the same name) only ever keeps the mutable spelling.
	 */
	public static function reassignedInScope(name: String, tree: QueryNode, shape: RefShape, scope: Span): Bool {
		return Refs.find(name, tree, shape)
			.exists(hit -> hit.kind == RefKind.Write && hit.span.from >= scope.from && hit.span.from < scope.to);
	}

	/** Whether `target` (a constructor assignment's left-hand side) writes the field at `fieldFrom`. */
	public static function ctorTargetIsField(
		target: QueryNode, fieldFrom: Int, fieldName: String, container: QueryNode, shape: RefShape
	): Bool {
		final identKind: String = shape.identKind;
		final faKind: Null<String> = shape.fieldAccessKind;
		final selfText: Null<String> = shape.selfReferenceText;
		if (faKind != null && target.kind == faKind) {
			final recv: Null<QueryNode> = target.children.length > 0 ? target.children[0] : null;
			return target.name == fieldName && recv != null && recv.kind == identKind && selfText != null && recv.name == selfText;
		}
		if (target.kind != identKind) return false;
		final name: Null<String> = target.name;
		final span: Null<Span> = target.span;
		return name != null && span != null && TypeResolver.resolveBindingFrom(name, span, container, shape) == fieldFrom;
	}

	/** Whether `node`'s subtree holds a node of one of `kinds` that STARTS before `boundary`. */
	public static function kindStartsBefore(node: QueryNode, kinds: Array<String>, boundary: Int): Bool {
		final span: Null<Span> = node.span;
		// Spans are monotone, so a subtree starting past the boundary holds no match.
		if (span != null && span.from >= boundary) return false;
		return span != null && kinds.contains(node.kind) || node.children.exists(child -> kindStartsBefore(child, kinds, boundary));
	}

	/**
	 * Whether every explicit base-constructor call in `ctor` starts at or after `boundary` — the
	 * gate a default MOVING DOWN into the constructor owes, since the declaration prologue runs
	 * ahead of the base constructor and an overridden method called from there would stop seeing
	 * the default. With `superReferenceText` or `callKind` unset the call cannot be recognised at
	 * all and the gate degrades to refusing every container carrying a supertype clause.
	 */
	public static function superCallsFollow(container: QueryNode, ctor: QueryNode, boundary: Int, shape: RefShape): Bool {
		final superText: Null<String> = shape.superReferenceText;
		final callKind: Null<String> = shape.callKind;
		if (superText == null || callKind == null) return !hasSupertypeClause(container, shape);
		final calls: Array<QueryNode> = [];
		collectSuperCalls(ctor, superText, callKind, shape.identKind, calls);
		for (call in calls) {
			final span: Null<Span> = call.span;
			if (span == null || span.from < boundary) return false;
		}
		return true;
	}

	/** Whether `kinds` is set and holds `kind` — an unset seam contributes nothing. */
	private static inline function kindIn(kinds: Null<Array<String>>, kind: String): Bool {
		return kinds != null && kinds.contains(kind);
	}

	/**
	 * Whether a top-level constructor statement of `kind` ALWAYS COMPLETES NORMALLY — control
	 * reaches the statement after it, whatever the statement does internally. Membership only:
	 * the KIND is what is decided here, never the subtree, which is `ctorPrefixUnconditional`'s
	 * scan's job. A LOOP is deliberately absent; that entry documents why.
	 *
	 * Each set is read straight off its `RefShape` seam and tested in place rather than folded
	 * into one array: the seams never change during a run, and this is asked once per prefix
	 * statement per candidate FIELD, so building the union per call would allocate for nothing.
	 */
	private static function completesNormally(kind: String, shape: RefShape): Bool {
		return kind == shape.exprStatementKind || CondRegionScan.isConditionalKind(kind) || kindIn(shape.localDeclKinds, kind)
			|| kindIn(shape.staticLocalDeclKinds, kind) || kindIn(shape.ifStatementKinds, kind) || kindIn(shape.switchKinds, kind)
			|| kindIn(shape.tryStatementKinds, kind) || kindIn(shape.localFunctionKinds, kind) || kindIn(shape.inlineFunctionKinds, kind);
	}

	/**
	 * Collect every assignment to the field declared at `fieldFrom` under `fieldName` in `node`'s
	 * subtree, each tagged with whether a closure host encloses it. The walk descends INTO closures
	 * on purpose: a closure write must be COUNTED (else a second writer hides and the caller
	 * concludes "sole assignment") even though the caller then refuses it.
	 */
	private static function collectCtorFieldWrites(
		node: QueryNode, fieldFrom: Int, fieldName: String, container: QueryNode, shape: RefShape, assignKind: String,
		closures: Array<String>, inClosure: Bool, out: Array<{ assign: QueryNode, inClosure: Bool }>
	): Void {
		final enclosed: Bool = inClosure || closures.contains(node.kind);
		if (
			node.kind == assignKind && node.children.length >= 2
			&& ctorTargetIsField(node.children[0], fieldFrom, fieldName, container, shape)
		) out.push({
			assign: node,
			inClosure: enclosed
		});
		for (child in node.children)
			collectCtorFieldWrites(child, fieldFrom, fieldName, container, shape, assignKind, closures, enclosed, out);
	}

	/** The kinds that host a deferred body — a lambda, a local `function`, a local `inline function`. */
	private static function closureHostKinds(shape: RefShape): Array<String> {
		return (shape.lambdaKinds ?? []).concat(shape.localFunctionKinds ?? []).concat(shape.inlineFunctionKinds ?? []);
	}

	/**
	 * The node kinds through which evaluation of a child operand is UNCONDITIONAL — the whitelist
	 * `ctorWriteUnconditional` walks. Every entry comes from its own `RefShape` seam, so an unset
	 * seam simply contributes nothing.
	 */
	private static function unconditionalOperandKinds(shape: RefShape): Array<String> {
		final kinds: Array<String> = [];
		inline function admit(kind: Null<String>): Void if (kind != null && !kinds.contains(kind)) kinds.push(kind);
		admit(shape.exprStatementKind);
		admit(shape.parenKind);
		admit(shape.callKind);
		admit(shape.newExprKind);
		admit(shape.arrayLiteralKind);
		admit(shape.objectLiteralKind);
		admit(shape.objectFieldKind);
		admit(shape.assignKind);
		for (kind in shape.localDeclKinds ?? []) admit(kind);
		return kinds;
	}

	/** Whether `writeFrom` is reachable from `node` through `transparent` kinds only. */
	private static function reachesThroughOperands(node: QueryNode, writeFrom: Int, transparent: Array<String>): Bool {
		final span: Null<Span> = node.span;
		return span != null
			&& (span.from == writeFrom || transparent.contains(node.kind)
				&& node.children.exists(child -> reachesThroughOperands(child, writeFrom, transparent)));
	}

	/** Recursively find the class-like container whose direct field member starts at `fieldFrom`. */
	private static function findFieldContainer(
		node: QueryNode, fieldFrom: Int, classLike: Array<String>, fields: Array<String>
	): Null<{ container: QueryNode, field: QueryNode }> {
		// Every member host of the container, not just its direct children: a field written inside a
		// member-position `#if` sits one level down, and reading it as absent left the fix side unable
		// to re-find a field its own detection had flagged.
		if (classLike.contains(node.kind)) {
			var found: Null<QueryNode> = null;
			MemberKinds.eachMemberHost(node, host -> {
				for (child in host.children) if (fields.contains(child.kind)) {
					final sp: Null<Span> = child.span;
					if (sp != null && sp.from == fieldFrom) found = child;
				}
			});
			final field: Null<QueryNode> = found;
			if (field != null) return { container: node, field: field };
		}
		for (child in node.children) {
			final hit: Null<{ container: QueryNode, field: QueryNode }> = findFieldContainer(child, fieldFrom, classLike, fields);
			if (hit != null) return hit;
		}
		return null;
	}

	/**
	 * Whether a word-bounded occurrence of `name` outside `exclude` is the receiver of a
	 * method call — followed, past whitespace and comments, by `.`, then an identifier,
	 * then `(`. Matches `name.m(...)` and `this.name.m(...)` alike (the `name` token in
	 * `this.name` is bounded by the preceding `.`). A plain field read (`name.x`) or a
	 * method reference without a call (`name.m`) is not a match — only a `this`-mutating
	 * abstract method call is a write the assignment scans miss.
	 */
	private static function methodCalledOn(source: String, name: String, exclude: Span): Bool {
		final n: Int = source.length;
		final len: Int = name.length;
		if (len == 0) return false;
		var from: Int = 0;
		while (true) {
			final idx: Int = source.indexOf(name, from);
			if (idx < 0) return false;
			from = idx + len;
			final boundedBefore: Bool = idx == 0 || !SourceText.isIdentChar(source.fastCodeAt(idx - 1));
			final boundedAfter: Bool = from >= n || !SourceText.isIdentChar(source.fastCodeAt(from));
			if (boundedBefore && boundedAfter && (idx < exclude.from || idx >= exclude.to) && callFollows(source, from)) return true;
		}
	}

	/** Whether the tokens starting at `pos` are `.` <identifier> ... `(` — a method call, ignoring interposed whitespace and comments. */
	private static function callFollows(source: String, pos: Int): Bool {
		final n: Int = source.length;
		var i: Int = SourceComments.skipForwardTrivia(source, pos);
		if (i >= n || source.fastCodeAt(i) != '.'.code) return false;
		i = SourceComments.skipForwardTrivia(source, i + 1);
		if (i >= n || !SourceText.isIdentStartChar(source.fastCodeAt(i))) return false;
		while (i < n && SourceText.isIdentChar(source.fastCodeAt(i))) i++;
		i = SourceComments.skipForwardTrivia(source, i);
		return i < n && source.fastCodeAt(i) == '('.code;
	}

	/** Recursive worker for `eachFieldMember`: visit a container's mutable fields, tracking exported state. */
	private static function walkFieldContainers(node: QueryNode, ctx: FieldMemberCtx): Void {
		if (ctx.containers.contains(node.kind)) {
			final name: Null<String> = node.name;
			// Re-bound to a non-null local: a narrowing does not survive into the closure below.
			if (name != null) {
				final owner: String = name;
				MemberBranchScan.fold(ctx.branch, node.children, false, (exported, child) -> {
					if (ctx.visibility.contains(child.kind)) {
						final span: Null<Span> = child.span;
						return exported || span != null && StringTools.trim(ctx.source.substring(span.from, span.to)) != ctx.defaultVis;
					}
					if (!ctx.members.contains(child.kind)) return exported;
					if (ctx.mutableFields.contains(child.kind)) ctx.visit(owner, child, ctx.source, ctx.file, exported);
					return false;
				}, (a, b) -> a || b);
			}
		}
		for (child in node.children) walkFieldContainers(child, ctx);
	}

}

/**
 * What `RefactorSupport.eachFieldMember`'s container walk threads through every frame — the
 * kind-sets it matches on, the branch seams its member fold descends `#if` regions with, and the
 * visitor. Resolved once per file.
 */
private typedef FieldMemberCtx = {
	final source: String;
	final file: String;
	final containers: Array<String>;
	final members: Array<String>;
	final mutableFields: Array<String>;
	final visibility: Array<String>;
	final defaultVis: String;
	final branch: MemberBranchSeams;
	final visit: (owner:String, field:QueryNode, source:String, file:String, exported:Bool) -> Void;
};
