package unit.query;

import anyparse.query.MoveMember;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.MoveSymbol.MoveResult;

using Lambda;
using StringTools;

/**
 * `MoveMember.move` — a backticked `Src.member` mention in a comment follows the member to its new
 * type, in the destination, in any other file of the scope and in the moved member's own doc.
 */
class MoveMemberDocRefsTest extends Test {

	/**
	 * The destination's own, a third file's and the moved member's own doc mentions all follow.
	 */
	@:pin('control')
	@:killer('M-DOC-MENTION-NOT-REWRITTEN')
	public function testBacktickedMentionsFollowTheMovedMember(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\t/** see `A.foo()` and `B.bar`. */\n\tpublic static function foo():Int return 1;\n}';
		final b: String = 'package pkg;\n\nclass B {\n\tpublic static function bar():Int return 2;\n\n\t/** Uses `A.foo` here. */\n'
			+ '\tpublic static function baz():Int return A.foo();\n}';
		final c: String = 'package pkg;\n\n/** Reads `A.foo`. */\nclass C {}';
		final changes: Array<MoveChange> = moved([
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: b },
			{ file: 'pkg/C.hx', source: c }
		]);
		final newB: String = sourceOf(changes, 'pkg/B.hx');
		Assert.isTrue(newB.contains('/** Uses `B.foo` here. */'), 'the destination\'s own mention should follow:\n$newB');
		Assert.isTrue(newB.contains('/** see `B.foo()` and `B.bar`. */'), 'the moved doc should follow:\n$newB');
		final newC: String = sourceOf(changes, 'pkg/C.hx');
		Assert.isTrue(newC.contains('Reads `B.foo`.'), 'a third file\'s mention should follow:\n$newC');
	}

	/** A longer member name and prose without backticks are not the mention: only `A.foo` itself is. */
	@:pin('control')
	@:killer('M-DOC-MENTION-PREFIX-NAME')
	public function testOnlyTheExactBacktickedPairFollows(): Void {
		final a: String =
			'package pkg;\n\nclass A {\n\tpublic static function foo():Int return 1;\n\n\tpublic static function fooBar():Int return 2;\n}';
		final c: String = 'package pkg;\n\n/** Not `A.fooBar`. */\nclass C {}';
		final changes: Array<MoveChange> = moved([
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {}' },
			{ file: 'pkg/C.hx', source: c }
		]);
		Assert.isFalse(changes.exists(change -> change.file == 'pkg/C.hx'), 'a member whose name only starts with the moved one stays');
	}

	/** Prose without backticks is not a mention. */
	@:pin('control')
	@:killer('M-DOC-MENTION-UNTICKED')
	public function testUntickedProseStays(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function foo():Int return 1;\n}';
		final c: String = 'package pkg;\n\n/** See A.foo in prose and `A.foo`. */\nclass C {}';
		final newC: String = sourceOf(moved([
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {}' },
			{ file: 'pkg/C.hx', source: c }
		]), 'pkg/C.hx');
		Assert.isTrue(newC.contains('See A.foo in prose and `B.foo`.'), 'unticked prose stays, the ticked mention follows:\n$newC');
	}

	/** A file whose `A` is another type — its own — keeps its mention. */
	@:pin('control')
	@:killer('M-DOC-MENTION-OTHER-TYPE')
	public function testAHomonymTypesMentionStays(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function foo():Int return 1;\n}';
		final other: String = 'package other;\n\n/** Its own `A.foo`. */\nclass A {\n\tpublic static function foo():Int return 2;\n}';
		final changes: Array<MoveChange> = moved([
			{ file: 'pkg/A.hx', source: a },
			{ file: 'pkg/B.hx', source: 'package pkg;\n\nclass B {}' },
			{ file: 'other/A.hx', source: other }
		]);
		Assert.isFalse(changes.exists(c -> c.file == 'other/A.hx' && c.newSource.contains('`B.foo`')), 'a homonym\'s mention must stay');
	}

	private static function moved(scopeFiles: Array<{ file: String, source: String }>): Array<MoveChange> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final result: MoveResult = MoveMember.move(
			'pkg/A.hx', 'A', ['foo'], 'B', null, false, false, scopeFiles, plugin, plugin.typeRefShape()
		);
		return switch result {
			case Ok(changes, _): changes;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				[];
		}
	}

	private static function sourceOf(changes: Array<MoveChange>, file: String): String {
		final change: Null<MoveChange> = changes.find(c -> c.file == file);
		Assert.notNull(change, 'no change for $file');
		return change?.newSource ?? '';
	}

}
