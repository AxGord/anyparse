package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.FieldWriteIndex;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags an INSTANCE field (`var` or `final`) that has NO declaration initializer but
 * whose sole write is exactly one unconditional top-level constructor statement
 * `x = expr;` / `this.x = expr;` whose right-hand side is context-independent
 * (references no constructor parameters, no `this`, no other instance members, no
 * constructor locals — only literals, static / global references, and constructions
 * such as `new Shape()`). `Severity.Info`, with an autofix that MOVES `= expr` onto
 * the field declaration and deletes the constructor statement — e.g.
 * `private var _a:Array<Int>;` + constructor `_a = new Array<Int>();` becomes
 * `private var _a:Array<Int> = new Array<Int>();`.
 *
 * ## Soundness — why the move is order-safe
 *
 * A declaration initializer runs BEFORE the constructor body, so moving an init
 * earlier is safe only when the moved expression does not depend on anything the
 * constructor establishes first. The context-free right-hand-side gate guarantees
 * exactly that: every identifier read resolves to a global / type / static member (a
 * value available at declaration-init time), never to a constructor parameter or
 * local (which do not exist yet), another instance member (a field that may be
 * uninitialized), or `this`. Combined with the exactly-one-write proof
 * (`FieldWriteIndex.writeCount == 1` and no unresolved write to the field NAME), the
 * moved statement is the field's SOLE assignment, so the move preserves behaviour.
 *
 * ## Fixpoint chain
 *
 * This rule moves the init to the declaration; the EXISTING decl-assigned case of
 * `prefer-final-field` then catches the now decl-initialized private `var` and
 * rewrites it to `final`. Both rules also independently handle `var` and `final`
 * fields, so any pass ordering converges to the same fixpoint.
 *
 * ## Scope
 *
 * STATIC fields are out of scope (a static's init timing is unrelated to instance
 * construction). A property (`var x(get, set)`) and a function-type field are
 * skipped (a `(` in the declaration head — a conservative over-skip). A
 * multiple-constructor (macro-generated) class is skipped: only a plain single `new`
 * qualifies, so the init timing stays unambiguous.
 */
@:nullSafety(Strict)
final class FieldInitAtDeclaration implements Check {

	public function new() {}

	public function id(): String {
		return 'field-init-at-declaration';
	}

	public function description(): String {
		return 'an instance field initialised with a context-free constant in the constructor that can move to its declaration';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final writeIndex: FieldWriteIndex = FieldWriteIndex.build(files, plugin);
		final classLike: Array<String> = RefactorSupport.classLikeContainerKinds(shape);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = try plugin.parseFile(entry.source) catch (_: Exception) null;
			if (tree != null) walk(tree, entry.file, entry.source, shape, classLike, writeIndex, violations);
		}
		return violations;
	}

	/**
	 * Move each flagged field's constructor init onto its declaration: insert
	 * ` = <rhs>` before the declaration's terminating `;` and delete the constructor
	 * statement's whole line. The edits are re-derived from the violation span so
	 * `fix` needs no state carried from `run`.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (_: Exception) null;
		if (tree == null) return [];
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final loc: Null<{
				container: QueryNode,
				field: QueryNode,
				stmt: QueryNode,
				rhs: QueryNode,
				target: Span
			}> = RefactorSupport.constructorFieldInitAt(tree, span.from, shape);
			if (loc == null) continue;
			final rhsSpan: Null<Span> = loc.rhs.span;
			final fieldSpan: Null<Span> = loc.field.span;
			final stmtSpan: Null<Span> = loc.stmt.span;
			if (rhsSpan == null || fieldSpan == null || stmtSpan == null) continue;
			final insertPos: Int = RefactorSupport.fieldDeclInitInsertPos(source, fieldSpan);
			edits.push({ span: new Span(insertPos, insertPos), text: ' = ' + source.substring(rhsSpan.from, rhsSpan.to) });
			edits.push({ span: RefactorSupport.lineExtendedSpan(source, stmtSpan), text: '' });
		}
		return edits;
	}

	/** Walk `node`, considering every class-like container found. */
	private static function walk(
		node: QueryNode, file: String, source: String, shape: RefShape, classLike: Array<String>, writeIndex: FieldWriteIndex,
		out: Array<Violation>
	): Void {
		if (classLike.contains(node.kind)) considerContainer(node, file, source, shape, writeIndex, out);
		for (child in node.children) walk(child, file, source, shape, classLike, writeIndex, out);
	}

	/**
	 * Flag every movable no-initializer instance field of `container`: exactly one
	 * plain constructor, the field non-static / non-property / no-init, its sole write
	 * the single top-level constructor init, and that init's right-hand side context-free.
	 */
	private static function considerContainer(
		container: QueryNode, file: String, source: String, shape: RefShape, writeIndex: FieldWriteIndex, out: Array<Violation>
	): Void {
		final owner: Null<String> = container.name;
		if (owner == null) return;
		final ctor: Null<QueryNode> = RefactorSupport.soleConstructor(container, shape);
		if (ctor == null) return;
		final statics: Array<Int> = staticMemberFroms(container, shape);
		final fields: Array<String> = shape.fieldDeclKinds ?? [];
		for (member in container.children) if (fields.contains(member.kind)) {
			final span: Null<Span> = member.span;
			final name: Null<String> = member.name;
			if (span == null || name == null) continue;
			if (statics.contains(span.from)) continue;
			if (member.children.length >= 1) continue;
			if (source.substring(span.from, span.to).indexOf('(') >= 0) continue;
			final init: Null<{ stmt: QueryNode, rhs: QueryNode, target: Span }> = RefactorSupport.soleConstructorFieldInit(
				container, ctor, member, shape
			);
			if (init == null) continue;
			if (writeIndex.hasUnresolvedWrite(name)) continue;
			if (writeIndex.writeCount(owner, name) != 1) continue;
			if (!contextFreeRhs(init.rhs, container, statics, shape)) continue;
			out.push({
				file: file,
				span: span,
				rule: 'field-init-at-declaration',
				severity: Severity.Info,
				message: 'field \'$name\' is initialised with a constant in the constructor; move it to the declaration'
			});
		}
	}

	/**
	 * The binding-span starts of `container`'s members preceded by a `Static`
	 * modifier sibling — the static members a right-hand side may safely reference.
	 */
	private static function staticMemberFroms(container: QueryNode, shape: RefShape): Array<Int> {
		final staticKind: Null<String> = shape.staticModifierKind;
		final members: Array<String> = shape.memberDeclKinds ?? [];
		final out: Array<Int> = [];
		if (staticKind == null) return out;
		var pending: Bool = false;
		for (child in container.children) {
			if (child.kind == staticKind)
				pending = true;
			else if (members.contains(child.kind)) {
				if (pending) {
					final sp: Null<Span> = child.span;
					if (sp != null) out.push(sp.from);
				}
				pending = false;
			}
		}
		return out;
	}

	/**
	 * Whether every identifier read in `node` is context-independent: a global / type /
	 * imported name (unresolved within the class) or a static member of the class — a
	 * value available at declaration-init time — and the subtree contains no `this`. A
	 * reference that resolves within the class but is not static (a constructor parameter
	 * or local, or a non-static instance member) makes the init order-dependent and thus
	 * unmovable, since a static member is the only in-class binding whose value exists
	 * before the constructor body runs.
	 */
	private static function contextFreeRhs(node: QueryNode, container: QueryNode, statics: Array<Int>, shape: RefShape): Bool {
		final identKind: String = shape.identKind;
		final selfText: Null<String> = shape.selfReferenceText;
		if (node.kind == identKind) {
			final name: Null<String> = node.name;
			final span: Null<Span> = node.span;
			if (name == null || span == null) return true;
			if (selfText != null && name == selfText) return false;
			final bf: Null<Int> = TypeResolver.resolveBindingFrom(name, span, container, shape);
			return bf == null || statics.contains(bf);
		}
		for (child in node.children) if (!contextFreeRhs(child, container, statics, shape)) return false;
		return true;
	}

}
