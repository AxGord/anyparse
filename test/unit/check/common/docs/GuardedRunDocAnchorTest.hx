package unit.check.common.docs;

import anyparse.check.LintConfig;
import anyparse.check.common.docs.DocCoverage;
import anyparse.check.common.docs.MisplacedTypeDoc;
import anyparse.check.common.docs.PreferDocComment;

/**
 * `doc-coverage` and `prefer-doc-comment` read a declaration's leading run through
 * `CheckScan.leadingRuns` with the entry test `misplaced-type-doc` uses, so a `#if … #end`
 * region holding only metadata or modifiers is part of the run for all three: the doc anchor
 * is above the region, and a doc between the region and the declaration is not its doc.
 */
class GuardedRunDocAnchorTest extends Test {

	private static inline final MEMBER_DOC: String = '{"rules":{"doc-coverage":{"requireMemberDoc":true,"requireTypeDoc":false}}}';

	@:pin('control')
	@:killer('M-COVERAGE-RUN-UNGUARDED')
	public function testDocAboveGuardedMetaDocumentsTheType(): Void {
		Assert.equals(0, coverage('{}', 'package p;\n\n/** Doc. */\n#if !macro\n@:keep\n#end\nclass C {}\n').length);
	}

	@:pin('control')
	@:killer('M-COVERAGE-RUN-UNGUARDED')
	public function testDocAboveGuardedModifierDocumentsTheMember(): Void {
		final src: String = 'package p;\n\n/** C. */\nclass C {\n\t/** F. */\n\t#if (haxe_ver >= 4.2) extern #else @:extern #end\n'
			+ '\tpublic inline function f(): Void {}\n}\n';
		Assert.equals(0, coverage(MEMBER_DOC, src).length);
	}

	/** The doc `misplaced-type-doc` moves out of the run is the doc `doc-coverage` does not count. */
	@:pin('control')
	@:killer('M-COVERAGE-RUN-UNGUARDED')
	public function testDocBelowGuardedMetaIsNotTheTypeDoc(): Void {
		final src: String = 'package p;\n\n#if !macro\n@:keep\n#end\n/** Doc. */\nclass C {}\n';
		Assert.equals(1, CheckFixture.violations(new MisplacedTypeDoc(), src).length);
		Assert.equals(1, coverage('{}', src).length);
	}

	@:pin('control')
	@:killer('M-COVERAGE-RUN-UNGUARDED')
	public function testPrivateBeforeGuardedMetaKeepsTheTypePrivate(): Void {
		Assert.equals(0, coverage('{}', 'package p;\n\nprivate\n#if !macro\n@:keep\n#end\nclass C {}\n').length);
	}

	@:pin('control')
	@:killer('M-COVERAGE-RUN-UNGUARDED')
	public function testPublicBeforeGuardedMetaKeepsTheMemberPublic(): Void {
		final src: String = 'package p;\n\n/** C. */\nclass C {\n\tpublic\n\t#if !macro @:keep #end\n\tfunction f(): Void {}\n}\n';
		Assert.equals(1, coverage(MEMBER_DOC, src).length);
	}

	@:pin('control')
	@:killer('M-PREFER-DOC-RUN-UNGUARDED')
	public function testLineCommentAboveGuardedMetaBecomesTheTypeDoc(): Void {
		Assert.equals(
			'package p;\n\n/** Doc. */\n#if !macro\n@:keep\n#end\nclass C {}\n',
			CheckFixture.fixedSource(new PreferDocComment(), 'package p;\n\n// Doc.\n#if !macro\n@:keep\n#end\nclass C {}\n')
		);
	}

	@:pin('control')
	@:killer('M-PREFER-DOC-RUN-UNGUARDED')
	public function testLineCommentAboveGuardedModifierBecomesTheMemberDoc(): Void {
		final src: String = 'package p;\n\n/** C. */\nclass C {\n\t/** A. */\n\tpublic var a: Int = 0;\n\n\t// F.\n'
			+ '\t#if (haxe_ver >= 4.2) extern #else @:extern #end\n\tpublic inline function f(): Void {}\n}\n';
		Assert.equals(1, CheckFixture.violations(new PreferDocComment(), src).length);
	}

	private function coverage(configJson: String, src: String): Array<Violation> {
		final check: DocCoverage = new DocCoverage();
		final cfg: LintConfig = LintConfig.parse(configJson);
		check.setConfigResolver((_) -> cfg);
		return CheckFixture.violations(check, src);
	}

}
