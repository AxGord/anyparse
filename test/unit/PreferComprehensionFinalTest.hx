package unit;

import anyparse.check.Check.Violation;
import anyparse.check.PreferComprehension;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The comprehension rewrite upgrades `var` to `final` — but only when nothing REASSIGNS the
 * binding afterwards.
 *
 * `var cmd = []; for (…) cmd.push(…); cmd = cmd.concat(extra);` came back as
 * `final cmd = [for …]; cmd = cmd.concat(extra);` — `Cannot assign to final`, on a tree that
 * compiled. The rule already proved the name is referenced after the loop; it did not ask
 * whether that reference is a read or a write, and only the second one decides the keyword.
 */
class PreferComprehensionFinalTest extends Test {

	public function testAReassignedLocalKeepsVar(): Void {
		Assert.stringContains('var cmd', rewritten('\t\tcmd = cmd.concat(extra);\n\t\treturn cmd;'));
	}

	public function testANeverReassignedLocalBecomesFinal(): Void {
		Assert.stringContains('final cmd', rewritten('\t\ttrace(cmd);\n\t\treturn cmd;'));
	}

	public function testACompoundAssignmentCountsAsAReassignment(): Void {
		Assert.stringContains('var cmd', rewritten('\t\tcmd += extra;\n\t\treturn cmd;'));
	}

	/** The declaration + loop, followed by `tail`, run through the check's own fix. */
	private function rewritten(tail: String): String {
		final source: String = 'class C {\n\tstatic function f(xs: Array<String>, extra: Array<String>): Array<String> {\n'
			+ '\t\tvar cmd: Array<String> = [];\n\t\tfor (x in xs) cmd.push(x);\n$tail\n\t}\n}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: PreferComprehension = new PreferComprehension();
		final violations: Array<Violation> = check.run([{ file: 'C.hx', source: source }], plugin);
		Assert.equals(1, violations.length, tail);
		final edits: Array<{ span: Span, text: String }> = check.fix(source, violations, plugin);
		Assert.isTrue(edits.length > 0, tail);
		return edits.length > 0 ? edits[0].text : '';
	}

}
