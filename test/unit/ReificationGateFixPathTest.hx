package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check;
import anyparse.check.CheckScan;
import anyparse.check.CompilerOracle;
import anyparse.check.FixVerifier;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * The reification gate on the `RiskyFix` FIX path, driven through the REAL `FixVerifier.verify`
 * with a real compiler oracle behind it. That path calls `Linter.collect` itself rather than
 * flowing through `Linter.run`, so it is the one place `ReificationGateTest` cannot reach.
 *
 * ## Why a test double and not `avoid-dynamic`
 *
 * `avoid-dynamic` is the only `RiskyFix` builtin, and it is the rule the real-tree measurement
 * caught REPORTING inside quotations — but measured here, it emits no fix EDIT there even with the
 * gate removed: its narrowing classifier already declines under a `macro …` subtree for reasons of
 * its own (the same body one scope out is narrowed and applied, so it is the quotation that stops
 * it, not the shape). A fixture built on it would assert `applied == 0` on input that satisfies
 * that with the gate reverted — green for the wrong reason, which is exactly the coverage hole
 * this file exists to close.
 *
 * So the subject is a double whose edit is unconditional and trivially valid: rewrite the string
 * `'AAA'` to `'BBB'`. It typechecks either way, so the ORACLE cannot be what stops it — the only
 * thing that can is the gate. The fixture carries one `'AAA'` inside a quotation and one outside:
 * the outside edit must land (proving the path ran at all) and the quoted one must not.
 */
class ReificationGateFixPathTest extends Test {

	#if (sys || nodejs)
	/** One rewritable literal inside a `macro …` quotation, one as real code. */
	// DEFAULT-canonical (no space after the type colon): `FixVerifier` canonicalises with no
	// `hxformat.json` in hand, and a non-canonical input makes it refuse the edit rather than
	// verify it — which would leave this test green for the wrong reason.
	private static final SRC: String = 'import haxe.macro.Expr;\n\nclass Good {\n\n\tstatic function build():Expr {\n'
		+ '\t\treturn macro {\n\t\t\ttrace(\'AAA\');\n\t\t};\n\t}\n\n\tstatic function main() {\n\t\ttrace(\'AAA\');\n'
		+ '\t\ttrace(build());\n\t}\n\n}\n';

	private static final HXML: String = '-cp .\n-main Good\n';
	#end

	public function testQuotedEditNeverReachesTheVerifier(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('reifyfix', [{ name: 'Good.hx', source: SRC }, { name: 'check.hxml', source: HXML }]);
		final path: String = '$dir/Good.hx';
		final files: Array<{ file: String, source: String }> = [{ file: path, source: SRC }];
		// Both literals ARE findings of the double; it is the gate that halves them on the way in.
		Assert.equals(2, new LiteralRewriteCheck().run(files, new HaxeQueryPlugin()).length, 'the double itself sees both literals');
		final result: FixVerifyResult = FixVerifier.verify(
			files,
			[new LiteralRewriteCheck()],
			new HaxeQueryPlugin(), 'check.hxml', dir, (p, c) -> File.saveContent(p, c)
		);
		Assert.equals(1, result.applied.length, 'the unquoted rewrite is applied, so the verifier path really ran');
		Assert.equals(0, result.reverted.length);
		final onDisk: String = File.getContent(path);
		Assert.isTrue(onDisk.indexOf('macro {\n\t\t\ttrace(\'AAA\');') != -1, 'the QUOTED literal is untouched');
		Assert.isTrue(onDisk.indexOf('\t\ttrace(\'BBB\');') != -1, 'the unquoted literal IS rewritten');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private function oracleWorks(): Bool {
		final dir: String = CliFixture.writeDir('reifyfix', [{ name: 'Good.hx', source: SRC }, { name: 'check.hxml', source: HXML }]);
		final ok: Bool = switch CompilerOracle.typecheck('check.hxml', dir) {
			case Confirmed: true;
			case _: false;
		};
		CliFixture.removeDir(dir);
		return ok;
	}
	#end

}

/**
 * A `RiskyFix` double that rewrites every `'AAA'` string literal to `'BBB'`. Deliberately
 * unconditional: the edit is always available and always typechecks, so nothing in the pipeline
 * except the reification gate can decline it.
 */
private class LiteralRewriteCheck implements Check implements RiskyFix {

	private static inline final TARGET: String = '\'AAA\'';
	private static inline final REPLACEMENT: String = '\'BBB\'';

	public function new() {}

	public function id(): String {
		return 'literal-rewrite-double';
	}

	public function description(): String {
		return 'a test double rewriting every AAA literal to BBB';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final out: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(out, entry.file, entry.source, tree);
		}
		return out;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (violation in violations) {
			final span: Null<Span> = violation.span;
			if (span != null) edits.push({ span: span, text: REPLACEMENT });
		}
		return edits;
	}

	private function walk(out: Array<Violation>, file: String, source: String, node: QueryNode): Void {
		final span: Null<Span> = node.span;
		if (span != null && source.substring(span.from, span.to) == TARGET) out.push({
			file: file,
			span: span,
			rule: id(),
			severity: Severity.Info,
			message: 'rewritable literal'
		});
		for (child in node.children) walk(out, file, source, child);
	}

}
