package unit.query;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.AddElement;
import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.GrammarPlugin;
import anyparse.query.OrphanContinuation;
import anyparse.query.Patch;
import anyparse.query.QueryNode;
import anyparse.query.ReplaceNode.ReplaceTarget;
import anyparse.query.cli.command.FmtCommand;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `OrphanContinuation` — the grammar accepts an `else` with no `if` in front of it
 * (`OrphanElseStmt`, there for conditional compilation), so a writing tool could strand one and
 * the re-parse gate called the result valid. Before the gate, `apq patch` turning
 * `} else if (b) {` into `} else if (b)` + `else if (b) {` wrote `if (b) else if (b) { … }` and
 * reported `wrote`; `haxe` rejects it with `Expected expression`.
 *
 * The refusal tests (`patch`, `add-element`, the `fmt` writer net) are RED at base: each WROTE the
 * stranded clause. The shape tables pin the predicate against the compiler: every row's verdict
 * was read off the compiler (`--interp`), with and without the define the row names, and an
 * orphan is unjustified exactly where no define makes the compiler accept it.
 */
class OrphanContinuationTest extends Test {

	/** A writer-canonical if / else-if chain: the input every refusal below starts from. */
	private static final CHAIN: String =
		'class C {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a) {\n\t\t\tx();\n\t\t} else if (b) {\n\t\t\ty();\n\t\t}\n\t}\n}\n';

	/** What the patch below makes of `CHAIN` at base — canonical, parseable, and rejected by the compiler. */
	private static final STRANDED: String = 'class C {\n\tfunction f(a:Bool, b:Bool):Void {\n\t\tif (a) {\n\t\t\tx();\n\t\t} else if (b)\n'
		+ '\t\t\telse if (b) {\n\t\t\t\ty();\n\t\t\t}\n\t}\n}\n';

	/** Statements placed into a `main` body; the compiler rejects each in every build. */
	private static final REJECTED: Array<String> = [
		'if (c) f() else g(); else g();',
		'f(); else g();',
		'if (c) { f(); } else { g(); } else { g(); }',
		'if (c) f(); else if (d) g(); else g(); else f();',
		'{ if (c) f(); } else g();',
		'if (c)\nelse if (d) g();',
		'if (c) f(); else if (d)\nelse if (d) g();',
		'while (c) else g();',
		'if (c) f(); else else g();',
		'{ #if a f(); #end } else g();',
		'if (c) f(); #if a else g(); else f(); #end',
		// a region ending in front of a SLOT, not a statement: the `if` body is an `else`
		'if (#if a c #else d #end) else g();'
	];

	/** Statements the compiler accepts under at least one of `-D a` / no define. */
	private static final ACCEPTED: Array<String> = [
		'#if a if (c) f(); #end else g();',
		'if (c) { f(); } #if a else if (d) { g(); } #end',
		'#if a if (c) #else if (d) #end f(); else g();',
		'if (c) f(); #if a #end else g();',
		'if (c) f(); #if a else g(); #end',
		'if (c) f(); #if a else g(); #else else f(); #end',
		'switch (x) { case 1: #if a if (c) f(); #end else g(); case _: }',
		'#if a if (c) { #else if (d) { #end f(); } else g();',
		// openfl `TextEngine`: the region closes an expression statement's value, not a statement.
		'x = if (!c) 1; #if !html5 else if (d)\n2; #end\nelse 3;'
	];

	/** `REJECTED` — each holds exactly one clause no seam explains. */
	@:pin('control')
	@:killer('M-ORPHAN-SEAM-END-ANY')
	@:killer('M-ORPHAN-ANY-PARENT')
	public function testCompilerRejectedShapesAreUnjustified(): Void {
		for (body in REJECTED) {
			final source: String = inMain(body);
			Assert.isTrue(orphanCount(source) > 0, 'the fixture must hold an orphan at all: $body');
			Assert.equals(1, unjustifiedIn(source).length, body);
		}
	}

	/** `ACCEPTED` — every clause sits next to a `#if` seam. */
	@:pin('control')
	@:killer('M-ORPHAN-BRANCH-OPEN-NEVER')
	@:killer('M-ORPHAN-SEAM-END-NEVER')
	@:killer('M-ORPHAN-SEAM-END-SELF-ONLY')
	@:killer('M-ORPHAN-SEAM-END-UNTRIMMED')
	@:killer('M-ORPHAN-NO-CASE-ARMS')
	public function testSeamShapesAreJustified(): Void {
		for (body in ACCEPTED) {
			final source: String = inMain(body);
			Assert.isTrue(orphanCount(source) > 0, 'the fixture must hold an orphan at all: $body');
			Assert.equals(0, unjustifiedIn(source).length, body);
		}
	}

	/** The reported reproduction: a header duplicated without its `{` strands the copy. RED at base (`Ok`). */
	@:pin('control')
	@:killer('M-ORPHAN-GATE-OFF')
	public function testPatchStrandingAnElseIsRefused(): Void {
		final result: EditResult = Patch.patchNode(
			CHAIN, BySelector('FnMember:f'), '\t\t} else if (b) {', '\t\t} else if (b)\n\t\telse if (b) {', false, new HaxeQueryPlugin()
		);
		switch result {
			case Err(message):
				Assert.isTrue(message.contains('`else` at line 6, column 3'), message);
				Assert.isTrue(message.contains('compiler rejects'), message);
			case Ok(text, _):
				Assert.fail('the stranded `else` was written:\n$text');
		}
	}

	/** The gate is the shared finalize, not a `patch` rule: inserting a bare `else` is refused too. RED at base. */
	@:pin('control')
	@:killer('M-ORPHAN-GATE-OFF')
	public function testAddElementOfABareElseIsRefused(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t}\n}\n';
		switch AddElement.addElement(source, 3, 3, After, 'else b();', false, new HaxeQueryPlugin()) {
			case Err(message):
				Assert.isTrue(message.contains('`else`'), message);
			case Ok(text, _):
				Assert.fail('the bare `else` was written:\n$text');
		}
	}

	/**
	 * The floor is the INPUT's own count, not zero: a file that already carries an orphan is still
	 * editable. Disabling the comparison (refusing any orphan in the result) turns this red.
	 */
	@:pin('control')
	@:killer('M-ORPHAN-FLOOR-ZERO')
	public function testAnOrphanTheSourceAlreadyHadDoesNotBlockAnEdit(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\telse b();\n\t\tc();\n\t}\n}\n';
		switch Patch.patchNode(source, BySelector('FnMember:f'), 'c();', 'd();', false, new HaxeQueryPlugin()) {
			case Ok(text, _):
				Assert.isTrue(text.contains('d();'), text);
			case Err(message):
				Assert.fail(message);
		}
	}

	/** A second orphan is refused even when the file had one, and the refusal names the NEW one. */
	@:pin('control')
	@:killer('M-ORPHAN-NEW-CLAUSE-FIRST')
	public function testRefusalNamesTheClauseTheEditMade(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\telse b();\n\t\tc();\n\t}\n}\n';
		switch Patch.patchNode(source, BySelector('FnMember:f'), 'c();', 'c();\n\t\telse d();', false, new HaxeQueryPlugin()) {
			case Err(message):
				Assert.isTrue(message.contains('line 6'), message);
				Assert.isTrue(message.contains('source has 1'), message);
			case Ok(text, _):
				Assert.fail('the second stranded `else` was written:\n$text');
		}
	}

	/**
	 * `fmt`'s net for a writer that strands an `else`: the real writer re-emits the tree it parsed
	 * and cannot be made to, so `OrphanInjectingPlugin` plays the defect. RED at base: the file was
	 * rewritten to the invalid text.
	 */
	@:pin('control')
	@:killer('M-ORPHAN-FMT-GATE-OFF')
	public function testFmtRefusesAWriterThatStrandsAnElse(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('orphan_fmt_net', CHAIN);
		CliFixture.always(() -> sys.FileSystem.deleteFile(path), () -> {
			var result: Null<FmtFileResult> = null;
			final stderr: String = CliFixture.captureStderr(() ->
				result = callFormatOneFile(new OrphanInjectingPlugin(CHAIN, STRANDED), path)
			);
			Assert.isTrue(result?.failed == true, 'the stranded output must fail the file');
			#if nodejs
			Assert.isTrue(stderr.contains('`else` at line 6') && stderr.contains('left unchanged'), stderr);
			#end
			Assert.equals(CHAIN, File.getContent(path), 'the file must be left unchanged');
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The decision for an input that ALREADY holds an orphan `else`: `fmt` formats it as it stands
	 * and writes it. The count does not grow, and `fmt` is not the compiler.
	 */
	@:pin('control')
	@:killer('M-ORPHAN-FLOOR-ZERO')
	public function testFmtKeepsAnOrphanTheInputAlreadyHad(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('orphan_fmt_keep', 'class C {\n\tfunction f():Void {\n\t\ta();   else b();\n\t}\n}\n');
		CliFixture.always(() -> sys.FileSystem.deleteFile(path), () -> {
			final result: FmtFileResult = callFormatOneFile(new HaxeQueryPlugin(), path);
			Assert.isFalse(result.failed);
			Assert.isTrue(result.changed);
			Assert.equals(1, unjustifiedIn(File.getContent(path)).length);
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:access(anyparse.query.cli.command.FmtCommand)
	private static function callFormatOneFile(plugin: GrammarPlugin, path: String): FmtFileResult {
		return FmtCommand.formatOneFile(plugin, 'haxe', path, true, false);
	}

	private static function inMain(body: String): String {
		return 'class Main {\n\tstatic function main() {\n$body\n\t}\n}\n';
	}

	private static function unjustifiedIn(source: String): Array<QueryNode> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return OrphanContinuation.unjustified(plugin.parseFile(source), source, plugin);
	}

	private static function orphanCount(source: String): Int {
		return countKind(new HaxeQueryPlugin().parseFile(source), 'OrphanElseStmt');
	}

	private static function countKind(node: QueryNode, kind: String): Int {
		var count: Int = node.kind == kind ? 1 : 0;
		for (child in node.children) count += countKind(child, kind);
		return count;
	}

}
