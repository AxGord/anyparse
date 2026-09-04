package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.FieldRename;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import unit.CheckFixture;
import utest.Assert;
import utest.Test;

/**
 * The backing-field rename walk, driven DIRECTLY — without the `trivial-getter` check that used
 * to own it.
 *
 * That is the whole point of the seam and the reason these assertions are worth their bytes: the
 * walk answers a question about BINDINGS, and until this slice it could only be reached through a
 * property-collapse classifier, so every fixture for it had to be a collapsible property first
 * and a binding shape second. Here the classifier is absent: the fixture names a class, a backing
 * field and a target name, and the walk's own contract is what is asserted.
 *
 * Each assertion compares the WHOLE rewritten source in one string, so a rewrite that gets one
 * reference right and another wrong cannot satisfy it — the qualified and the unqualified forms
 * of the same name sit in one expected value.
 */
class FieldRenameTest extends Test {

	/**
	 * One backing field read four ways: a `this.` access in the getter, a bare read, a `$_active`
	 * interpolation read, and a bare read under a loop binding that shadows the PROPERTY name.
	 * The shadow lives in its own method on purpose — `shadowsProp` is decided per enclosing
	 * function, and an interpolation read has no qualifier to carry, so the two cannot share one.
	 */
	private static final FIXTURE: String = 'class C {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
		+ '\tfunction get_active():Bool return this._active;\n\tfunction m():Void {\n\t\ttrace(_active);\n\t\ttrace(\'a=$$_active\');\n'
		+ '\t}\n\tfunction shadowed():Void {\n\t\tfor (active in [true]) trace(active && _active);\n\t}\n}';

	/**
	 * Every reference form the walk accepts, rewritten in one pass: `this._active` keeps its
	 * receiver and loses only the underscore, a bare read becomes the bare property name, a
	 * `$_active` interpolation renames the identifier alone, and the bare read inside the method
	 * whose loop binds `active` becomes `this.active` — a plain `active` there would read the
	 * loop variable. The backing field's own declaration is NOT rewritten: it is the `fieldNode`,
	 * which the walk skips because the caller deletes it.
	 */
	public function testEveryAcceptedReferenceFormIsRewrittenInOnePass(): Void {
		final expected: String = 'class C {\n\tpublic var active(get, never):Bool;\n\tprivate var _active:Bool = false;\n'
			+ '\tfunction get_active():Bool return this.active;\n\tfunction m():Void {\n\t\ttrace(active);\n\t\ttrace(\'a=$$active\');\n'
			+ '\t}\n\tfunction shadowed():Void {\n\t\tfor (active in [true]) trace(active && this.active);\n\t}\n}';
		Assert.equals(expected, renamed(FIXTURE, '_active', 'active', false));
	}

	/**
	 * A STATIC property is not reachable through `this` from anywhere, so a shadowed reference is
	 * class-qualified in every method — the `propStatic` half of `shadowQualifier`, which the
	 * instance fixture above cannot exercise.
	 */
	public function testStaticPropertyShadowIsClassQualified(): Void {
		final source: String = 'class C {\n\tpublic static var total(get, never):Int;\n\tprivate static var _total:Int = 0;\n'
			+ '\tstatic function m():Void {\n\t\tfor (total in [1]) trace(total + _total);\n\t}\n}';
		final expected: String = 'class C {\n\tpublic static var total(get, never):Int;\n\tprivate static var _total:Int = 0;\n'
			+ '\tstatic function m():Void {\n\t\tfor (total in [1]) trace(total + C.total);\n\t}\n}';
		Assert.equals(expected, renamed(source, '_total', 'total', true));
	}

	/**
	 * A reference the walk cannot prove is the field refuses the WHOLE set, not just that one
	 * edit: `other._active` names the same member on a foreign receiver, and rewriting it would
	 * retarget someone else's field. Null, not a partial edit list, is the contract.
	 */
	public function testForeignReceiverRefusesTheWholeRename(): Void {
		final source: String = 'class C {\n\tprivate var _active:Bool = false;\n\tfunction m(other:C):Void trace(other._active);\n}';
		Assert.isNull(editsFor(source, '_active'));
	}

	/** `source` with every edit the walk proposes for `field` -> `propName` applied, last-first. */
	private static function renamed(source: String, field: String, propName: String, propStatic: Bool): String {
		final edits: Null<Array<{ span: Span, text: String }>> = editsFor(source, field, propName, propStatic);
		if (edits != null) return CheckFixture.applyEdits(source, edits);
		Assert.fail('the walk refused the rename of $field, so no reference form could be checked');
		return '';
	}

	/** The walk's proposal for `source`, or null when it refuses. */
	private static function editsFor(
		source: String, field: String, propName: String = 'active', propStatic: Bool = false
	): Null<Array<{ span: Span, text: String }>> {
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(source);
		final cls: Null<QueryNode> = firstOfKind(tree, 'ClassDecl');
		if (cls == null) throw 'the fixture must declare a class';
		final fieldNode: Null<QueryNode> = firstNamed(cls, 'VarMember', field);
		if (fieldNode == null) throw 'the fixture must declare a backing field named $field';
		return FieldRename.collectRenameEdits(cls, source, field, [], fieldNode, propName, propStatic);
	}

	/** The first node of `kind` in pre-order, or null. */
	private static function firstOfKind(node: QueryNode, kind: String): Null<QueryNode> {
		if (node.kind == kind) return node;
		for (c in node.children) {
			final hit: Null<QueryNode> = firstOfKind(c, kind);
			if (hit != null) return hit;
		}
		return null;
	}

	/** The first node of `kind` named `name` in pre-order, or null. */
	private static function firstNamed(node: QueryNode, kind: String, name: String): Null<QueryNode> {
		if (node.kind == kind && node.name == name) return node;
		for (c in node.children) {
			final hit: Null<QueryNode> = firstNamed(c, kind, name);
			if (hit != null) return hit;
		}
		return null;
	}

}
