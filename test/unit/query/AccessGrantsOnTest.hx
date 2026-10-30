package unit.query;

import anyparse.query.AddMeta;
import anyparse.query.ParseGate;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;

/**
 * `RefactorSupport.accessGrantsOn` reads every `@:access` entry in front of a declaration, across the modifiers mixed into
 * that run; `AddMeta.entriesEdit` adds several entries in one edit, one per line.
 */
class AccessGrantsOnTest extends Test {

	public function testGrantsReadAcrossModifiers(): Void {
		final tree: QueryNode = parse(
			'class C {\n\t@:access(a.A)\n\tpublic static function f(): Void {}\n\n\t@:access(b.B) private var x: Int = 0;\n}'
		);
		Assert.same(['a.A'], RefactorSupport.accessGrantsOn(tree, member(tree, 'FnMember'), '@:access'));
		Assert.same(['b.B'], RefactorSupport.accessGrantsOn(tree, member(tree, 'VarMember'), '@:access'));
	}

	public function testEntriesEditAddsOnePerLine(): Void {
		final src: String = 'class C {\n\tpublic function f(): Void {}\n}';
		final tree: QueryNode = parse(src);
		final edit: Null<{ span: anyparse.runtime.Span, text: String }> = AddMeta.entriesEdit(
			src, tree, member(tree, 'FnMember'), ['@:access(a.A)', '@:access(b.B)']
		);
		Assert.notNull(edit);
		if (edit != null) Assert.equals('@:access(a.A)\n\t@:access(b.B)\n\tp', edit.text);
	}

	private static function parse(src: String): QueryNode {
		final tree: Null<QueryNode> = ParseGate.parseOrNull(new HaxeQueryPlugin(), src);
		if (tree == null) throw 'fixture does not parse';
		return tree;
	}

	/** The first node of `kind` under `node`, pre-order. */
	private static function member(node: QueryNode, kind: String): QueryNode {
		function find(n: QueryNode): Null<QueryNode> {
			if (n.kind == kind) return n;
			for (c in n.children) {
				final hit: Null<QueryNode> = find(c);
				if (hit != null) return hit;
			}
			return null;
		}
		final hit: Null<QueryNode> = find(node);
		if (hit == null) throw 'no $kind';
		return hit;
	}

}
