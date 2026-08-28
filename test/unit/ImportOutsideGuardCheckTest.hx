package unit;

import anyparse.check.Check;
import anyparse.check.ImportOutsideGuard;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `import-outside-guard` check: a header declaration written above the `#if … #end` region
 * that guards the module's whole body is reported once per file, and the autofix MOVES the whole
 * stranded header inside the guard — imports above the guard's first import, `using` lines above
 * its first `using` (the reverse-ranking priority the original order carried).
 *
 * The refusals are pinned by their own fixtures: an `#else` branch, a type declared outside the
 * region, two top-level regions, and a declaration that cannot be lifted as a whole line.
 */
class ImportOutsideGuardCheckTest extends Test {

	/** The incident, in miniature: `using` stranded above a guard whose own header is an import run. */
	private static inline final STRANDED_USING: String =
		'package debug;\n\nusing ext.One;\n\n#if FLAG\nimport sub.Widget;\n\nclass C {}\n#end\n';

	public function testStrandedUsingFlagged(): Void {
		final vs: Array<Violation> = violations(STRANDED_USING);
		Assert.equals(1, vs.length);
		Assert.equals('import-outside-guard', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		final span: Null<Span> = vs[0].span;
		Assert.notNull(span);
		if (span != null) Assert.equals('using ext.One;', STRANDED_USING.substring(span.from, span.to));
	}

	public function testStrandedUsingMovesBelowTheGuardedImports(): Void {
		Assert.equals('package debug;\n\n\n#if FLAG\nimport sub.Widget;\nusing ext.One;\n\nclass C {}\n#end\n', fixedRaw(STRANDED_USING));
	}

	/** The writer decides the blank lines — what `apq lint --fix` actually leaves on disk. */
	public function testCanonicalisedResultSeparatesTheMovedUsing(): Void {
		Assert.equals(
			'package debug;\n\n#if FLAG\nimport sub.Widget;\n\nusing ext.One;\n\nclass C {}\n#end\n', fixedCanonical(STRANDED_USING)
		);
	}

	public function testStrandedImportJoinsTheGuardedRunAtItsHead(): Void {
		Assert.equals(
			'package debug;\n\n\n#if FLAG\nimport ext.Two;\nimport sub.Widget;\n\nclass C {}\n#end\n',
			fixedRaw('package debug;\n\nimport ext.Two;\n\n#if FLAG\nimport sub.Widget;\n\nclass C {}\n#end\n')
		);
	}

	/**
	 * The moved `using` lands ABOVE the guarded one. Haxe ranks static extensions in REVERSE
	 * declaration order, so the stranded line — written earlier, therefore LOWER priority — has
	 * to stay earlier, or every same-named extension call in the file re-targets.
	 */
	public function testMovedUsingKeepsItsLowerPriority(): Void {
		Assert.equals(
			'package debug;\n\n\n#if FLAG\nimport sub.Widget;\n\nusing ext.One;\nusing ext.Two;\n\nclass C {}\n#end\n',
			fixedRaw('package debug;\n\nusing ext.One;\n\n#if FLAG\nimport sub.Widget;\n\nusing ext.Two;\n\nclass C {}\n#end\n')
		);
	}

	/** A guard carrying no header of its own anchors both halves on the `#if` directive's own line end. */
	public function testGuardWithoutHeaderTakesTheDirectiveLine(): Void {
		Assert.equals(
			'package debug;\n\n\n#if FLAG\nimport ext.Two;\nusing ext.One;\nclass C {}\n#end\n',
			fixedRaw('package debug;\n\nimport ext.Two;\nusing ext.One;\n\n#if FLAG\nclass C {}\n#end\n')
		);
	}

	public function testElseBranchNotFlagged(): Void {
		// The branches project as flat siblings, so a line moved into the `#if` body is absent from
		// the `#else` build — `UsingScan`'s seam gate refuses the region before this rule sees it.
		Assert.equals(
			0,
			violations('package debug;\n\nusing ext.One;\n\n#if FLAG\nimport sub.Widget;\n\nclass C {}\n#else\nclass C {}\n#end\n').length
		);
	}

	public function testTypeOutsideTheGuardNotFlagged(): Void {
		Assert.equals(
			0, violations('package debug;\n\nusing ext.One;\n\n#if FLAG\nimport sub.Widget;\n\nclass C {}\n#end\n\nclass D {}\n').length
		);
	}

	public function testTwoTopLevelRegionsNotFlagged(): Void {
		Assert.equals(
			0, violations('package debug;\n\nusing ext.One;\n\n#if A\nimport sub.Widget;\n#end\n\n#if B\nclass C {}\n#end\n').length
		);
	}

	public function testUnguardedModuleNotFlagged(): Void {
		Assert.equals(0, violations('package debug;\n\nusing ext.One;\nimport sub.Widget;\n\nclass C {}\n').length);
	}

	public function testHeaderAlreadyInsideTheGuardNotFlagged(): Void {
		Assert.equals(0, violations('package debug;\n\n#if FLAG\nimport sub.Widget;\n\nusing ext.One;\n\nclass C {}\n#end\n').length);
	}

	/** A trailing block comment makes the line unliftable, and the move is all-or-nothing — so the finding stays report-only. */
	public function testUnliftableLineReportedOnly(): Void {
		final source: String = 'package debug;\n\nimport ext.Two; /* pinned */\n\n#if FLAG\nimport sub.Widget;\n\nclass C {}\n#end\n';
		Assert.equals(1, violations(source).length);
		Assert.equals(0, edits(source).length);
	}

	public function testRegisteredAndOnByDefault(): Void {
		final check: Null<Check> = Linter.byId('import-outside-guard');
		Assert.notNull(check);
		Assert.isFalse(Std.isOfType(check, DefaultOff), 'the rule reports a header nothing can read — no opt-in');
		Assert.equals(176, Linter.builtins().length);
	}

	// --- helpers -------------------------------------------------------------------

	/** The check's findings for `src`. */
	private function violations(src: String): Array<Violation> {
		return new ImportOutsideGuard().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** The check's autofix edits for `src`'s own findings. */
	private function edits(src: String): Array<{ span: Span, text: String }> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: ImportOutsideGuard = new ImportOutsideGuard();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
	}

	/** `src` with the edits spliced in VERBATIM — the relocation alone, before any writer pass. */
	private function fixedRaw(src: String): String {
		return RefactorSupport.applyEdits(src, edits(src));
	}

	/** `src` fixed and canonicalized with `reformat` FALSE, exactly as `apq lint --fix` does it. */
	private function fixedCanonical(src: String): String {
		switch RefactorSupport.canonicalize(src, edits(src), false, new HaxeQueryPlugin()) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
		return '';
	}

}
