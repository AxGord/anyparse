package unit.check.common.members;

/**
 * Where `trivial-getter` reads a comment before the accessor clause it deletes: a real comment between the declaration's
 * start and the `(`, in the head the collapse rewrites, refuses the finding; a `//` spelled inside a string of an
 * annotation there is no comment.
 */
class TrivialGetterClauseCommentTest extends TrivialGetterCheckTestBase {

	@:pin('control')
	@:killer('M-ACCESSOR-REMOVAL-COMMENT-IGNORED')
	public function testCommentBeforeTheClauseRefusesTheCollapse(): Void {
		Assert.equals(0, violations(source('public var /* c */')).length);
	}

	public function testCommentFreeHeadCollapses(): Void {
		assertFixContains(source('public var'), 'public var active:Bool = false;');
	}

	private function source(head: String): String {
		return cls(
			'$head active(get, set):Bool;\n\tprivate var _active:Bool = false;\n\tfunction get_active():Bool return _active;\n'
			+ '\tfunction set_active(v:Bool):Bool return _active = v;'
		);
	}

}
