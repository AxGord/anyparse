package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Severity;
import anyparse.check.Suppression;
import anyparse.runtime.Span;

/**
 * Probe for `anyparse.check.Suppression` — inline `// noqa` matched against a
 * finding's WHOLE line span, not just its start line. A finding the writer
 * reflows across several lines must still be silenced by a `noqa` on any line
 * the finding covers (start, continuation, or last); a `noqa` outside the span
 * leaves it reported, and a named `noqa: <rule>` still filters by rule.
 *
 * Drives `Suppression.apply` directly on a synthetic `Violation` whose span is
 * built from line:col coordinates via `Span.offsetOf`, so the span need not
 * match a real AST node — the unit under test is the line-range overlap.
 */
class SuppressionSliceTest extends Test {

	/** A `noqa` on a CONTINUATION line (not the finding's start line) suppresses it. */
	public function testNoqaOnContinuationLineSuppresses(): Void {
		final src: String = 'package p;\nclass C {\n\tvar a = b\n\t\t+ c; // noqa\n}';
		Assert.equals(0, applyAt(src, 3, 6, 4, 8).length);
	}

	/** A `noqa` on the finding's first line still suppresses it (unchanged behaviour). */
	public function testNoqaOnFirstLineSuppresses(): Void {
		final src: String = 'package p;\nclass C {\n\tvar a = b // noqa\n\t\t+ c;\n}';
		Assert.equals(0, applyAt(src, 3, 6, 4, 6).length);
	}

	/** A `noqa` OUTSIDE the finding's line span leaves the finding reported. */
	public function testNoqaOutsideSpanKept(): Void {
		final src: String = 'package p;\nclass C {\n\tvar a = b;\n\tvar d = 1; // noqa\n}';
		Assert.equals(1, applyAt(src, 3, 6, 3, 11).length);
	}

	/** A named `noqa: <rule>` on a continuation line silences only that rule. */
	public function testNoqaNamedRuleOnContinuation(): Void {
		final src: String = 'package p;\nclass C {\n\tvar a = b\n\t\t+ c; // noqa: other-rule\n}';
		Assert.equals(1, applyAt(src, 3, 6, 4, 8).length);
	}

	/**
	 * A CHECKSTYLE:OFF/ON region silences a finding REPORTED inside it, but NOT a
	 * wide finding reported OUTSIDE the region whose span merely straddles it
	 * (region semantics match the report line, unlike a range-matched noqa).
	 */
	public function testCheckstyleRegionMatchesReportLineNotStraddle(): Void {
		final src: String = 'package p;\nclass C {\n\tfunction f() {\n\t\t// CHECKSTYLE:OFF\n\t\tvar a = 1;\n\t\t// CHECKSTYLE:ON\n\t}\n}';
		Assert.equals(1, applyAt(src, 3, 2, 7, 2).length);
		Assert.equals(0, applyAt(src, 5, 3, 5, 11).length);
	}

	private function applyAt(src: String, fromLine: Int, fromCol: Int, toLine: Int, toCol: Int): Array<Violation> {
		final v: Violation = {
			file: 'p/C.hx',
			span: new Span(Span.offsetOf(src, fromLine, fromCol), Span.offsetOf(src, toLine, toCol)),
			rule: 'demo-rule',
			severity: Severity.Warning,
			message: 'demo'
		};
		return Suppression.apply([v], [{ file: 'p/C.hx', source: src }]);
	}

}
