package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * What a node REFERENCES or BINDS, by bare name — the grammar-level recognizers every
 * backing-field rewrite shares, with no opinion about what the caller does with the answer.
 *
 * Split out of `TrivialGetter`, where the same three questions were answered for three
 * different consumers of one 86-member type: the in-class rename walk (`FieldRename`), the
 * cross-file subtype attribution and the external read/write census (`anyparse.check`'s
 * `BackingFieldRefs`). Each is a walk with its OWN policy; all three needed the same
 * primitives, which is what a shared question looks like before it has a home.
 *
 * Three questions, and they are not interchangeable:
 *
 * - `fieldRefName` / `writeTargetField` / `mentionsField` — does this node NAME the field, and
 *   in a read or a write position? Deliberately narrow: only a bare identifier, a simple
 *   `$name` interpolation and a `this.<name>` access resolve. Every other receiver shape
 *   answers null, and each caller treats that as "not provably mine", which is the fail-closed
 *   direction for all three.
 * - `isFnScope` / `functionBindsName` / `bindsNameHere` — does an enclosing function bind this
 *   NAME? A walk asks it to decide whether a bare reference would re-bind to a local rather
 *   than to the member, and over-answering true only costs a `this.` qualifier.
 * - `hidesBindingNamed` — does this node bind the field's own name, so the field is hidden
 *   here? Over-answering true refuses the rewrite, again fail-closed.
 *
 * Every kind this module decides by is READ OFF THE HANDED `RefShape`; none is spelled here.
 * The note this replaces said the opposite — that threading a shape through would cost eight
 * signatures and thirteen call sites and "could not express what these ask anyway
 * (`RefShape` names no pattern kind, no `this` identifier and no interpolation-read kind)".
 * All three of those exist: `plainCasePatternKind`, `selfReferenceText` and
 * `stringInterpIdentKind`. The price was real and was paid — the shape is threaded through every external caller of the eight
 * functions (counted by `hxq mentions` at the S204 tip: 16 call sites in `src` across `BackingFieldRefs`, `TrivialGetter`,
 * `FieldRename`, and 9 in `test`; a reading of that tree, not an invariant) — and what it buys is the differential: a name inside a
 * `RefShape` field is checked against the projected vocabulary by
 * `unit.query.RefShapeKindProjectionTest`, and a name in a private array here is checked by
 * nothing. The retired `LambdaParam` kind sat in `bindsNameHere` for three months matching
 * nothing, and that test is what eventually found it.
 */
@:nullSafety(Strict)
final class FieldRefScan {

	/** Whether `node` opens a new function scope (method / local fn / lambda) that binds parameters and locals. */
	public static inline function isFnScope(node: QueryNode, shape: RefShape): Bool {
		return fnScopeKinds(shape).contains(node.kind);
	}

	/**
	 * Whether `kind` is an assignment / compound-assignment / increment / decrement whose first child is its
	 * write target — the grammar's `writeParentKinds`, whose doc states exactly that contract ("ctors whose
	 * first positional child carries the binding being modified").
	 *
	 * This used to be a hand-written sixteen-name switch, and it was missing `NullCoalAssign`: `_x ??= v`
	 * IS a write of `_x` that no consumer here saw. Two more names arrive with the shared vocabulary and
	 * are DEAD for this grammar's target — `BoolAndAssign` / `BoolOrAssign` are parsed but rejected by Haxe
	 * 4.3.7 ("The operators ||= and &&= are not supported"), so they widen the vocabulary and reach no
	 * source. Nothing was dropped.
	 */
	public static inline function isWriteNodeKind(kind: String, shape: RefShape): Bool {
		return shape.writeParentKinds.contains(kind);
	}

	/**
	 * Whether the subtree `node` binds `name` in ANY form the language offers (`bindsNameHere`).
	 * Scanned subtree-wide from a function scope, so a nested function's binding also trips it —
	 * over-qualifying a backing-field reference with `this.` / `C.` is always semantically
	 * correct, while MISSING a binder silently re-binds the reference to it (a loop variable
	 * named like the property turned `if (color == _color)` into the always-true `color == color`).
	 */
	public static function functionBindsName(node: QueryNode, name: String, shape: RefShape): Bool {
		return subtreeBindsName(node, name, BinderScan.binderKinds(shape), shape);
	}

	/**
	 * Whether `node` BINDS `field`, hiding the backing field from the by-name shadow refusal in
	 * `renameWalk`. A self-scoped iteration node binds its iterator, or, in the key-value form
	 * `for (k => _x in m)` / `[for (k => _x in m) …]`, a second name on the value-binder child.
	 *
	 * A multi-variable declaration's later bindings project as the grammar's local-declaration
	 * CONTINUATION kind, so the multi-var arm ASKS THE TREE for one: a text-level comma scan cannot
	 * tell `var a = 1, b = 2` from the comma inside a `Map<K, V>` annotation, and refused the
	 * latter. In that one arm any word-match of `field` in the declaration refuses the fix
	 * (conservative: a multi-var INIT reading the real field also refuses). A missing span refuses
	 * everywhere — an unreadable construct binds everything.
	 *
	 * The declaration arm reads `localDeclKinds` MINUS `localDeclContinuationKinds`: the
	 * continuation is a member of the first, and a continuation node reached on its own is not the
	 * head of a multi-var list. That is the same pair of sets the old two-name arm spelled by hand.
	 */
	public static function hidesBindingNamed(node: QueryNode, span: Null<Span>, source: String, field: String, shape: RefShape): Bool {
		final continuations: Array<String> = shape.localDeclContinuationKinds ?? [];
		if ((shape.localDeclKinds ?? []).contains(node.kind) && !continuations.contains(node.kind)) {
			return span == null || node.children.exists(c -> continuations.contains(c.kind))
				&& SourceText.identTokenOffset(source, span, field) >= 0;
		}
		final selfScoped: Array<String> = (shape.iterationBindingKinds ?? []).concat(shape.iterationValueBinderKinds ?? []);
		return selfScoped.contains(node.kind) && (span == null || node.name == field);
	}

	/**
	 * The field name a node references as a bare `IdentExpr <name>`, a simple `$<name>`
	 * string-interpolation `Ident`, or a `this.<name>` `FieldAccess`, else null.
	 */
	public static function fieldRefName(node: QueryNode, shape: RefShape): Null<String> {
		if (node.kind == shape.identKind || node.kind == shape.stringInterpIdentKind) return node.name;
		final self: Null<String> = shape.selfReferenceText;
		if (self == null || node.kind != shape.fieldAccessKind || node.children.length != 1) return null;
		final receiver: QueryNode = node.children[0];
		return receiver.kind == shape.identKind && receiver.name == self ? node.name : null;
	}

	/** The field targeted by an assignment / compound-assignment / incr / decr node (bare or `this.`), else null. */
	public static function writeTargetField(node: QueryNode, shape: RefShape): Null<String> {
		return isWriteNodeKind(node.kind, shape) && node.children.length >= 1 ? fieldRefName(node.children[0], shape) : null;
	}

	/** Whether `node`'s subtree references `field` (bare identifier / `this.<field>`, read or write target). */
	public static function mentionsField(node: QueryNode, field: String, shape: RefShape): Bool {
		return fieldRefName(node, shape) == field || node.children.exists(child -> mentionsField(child, field, shape));
	}

	/**
	 * Whether `node` ITSELF binds `name`, `binders` being `BinderScan.binderKinds` — the derived
	 * vocabulary of every binding form the grammar projects as a NAMED node: the parameter slots
	 * (the bare-arrow spelling arrives as a plain parameter through `HxArrowParamProjection`), the
	 * local declarations in their statement, expression, `static` and continuation spellings, the
	 * local functions in both forms, the named function literal, the catch variable, the
	 * self-scoped iteration nodes and the value binder of a key-value iteration, and the case
	 * binder. Derived once by the caller and threaded, since this runs per node of a subtree.
	 *
	 * One shape carries no named binding node and is recovered here: a case PATTERN
	 * (`plainCasePatternKind`) projects its captures as bare identifiers, so ANY mention of `name`
	 * inside one counts (a constructor name that happens to match only over-qualifies). That kind
	 * is AMBIGUOUS in this grammar — `HxAnonVarBody` spells it too — and the overlap costs a false
	 * negative, never a wrong rewrite.
	 *
	 * The eighteen names this arm used to spell are the same eighteen the derivation produces, so
	 * the replacement moved no behaviour. What it moved is who checks them: a retired kind in a
	 * private array here (`LambdaParam`, dead for three months) is invisible, while every name a
	 * `RefShape` field carries is held against the projected vocabulary by
	 * `unit.query.RefShapeKindProjectionTest`.
	 */
	private static function bindsNameHere(node: QueryNode, name: String, binders: Array<String>, shape: RefShape): Bool {
		final casePattern: Null<String> = shape.plainCasePatternKind;
		return casePattern != null && node.kind == casePattern
			? mentionsField(node, name, shape)
			: binders.contains(node.kind) && node.name == name;
	}

	/**
	 * The function scopes a shadowed member reference can be RE-QUALIFIED from — every function VALUE
	 * (`MemberKinds.nestedFunctionKinds`) plus the METHOD declarations, which is `functionKinds` minus the
	 * local functions (already function values) and minus the module-level declarations.
	 *
	 * That last exclusion is a decision, not an omission: a shadowed reference is rewritten to `this.` /
	 * `C.`, and neither is spellable at module level, so a module-level `function` must not count as a
	 * scope this walk can repair. It reads off `moduleValueDeclKinds` — the grammar's own name for the
	 * module-level VALUE bindings — rather than naming `FnDecl`.
	 */
	private static function fnScopeKinds(shape: RefShape): Array<String> {
		final out: Array<String> = MemberKinds.nestedFunctionKinds(shape);
		final localOrModule: Array<String> = (shape.localFunctionKinds ?? []).concat(shape.moduleValueDeclKinds);
		for (kind in shape.functionKinds ?? []) if (!localOrModule.contains(kind) && !out.contains(kind)) out.push(kind);
		return out;
	}

	/** Whether any node of `node`'s subtree binds `name`, `binders` being the derived binder vocabulary. */
	private static function subtreeBindsName(node: QueryNode, name: String, binders: Array<String>, shape: RefShape): Bool {
		return bindsNameHere(node, name, binders, shape) || node.children.exists(c -> subtreeBindsName(c, name, binders, shape));
	}

}
