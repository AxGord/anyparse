package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import anyparse.query.RefactorSupport;
import anyparse.query.RemoveElement;
import anyparse.runtime.Span;
import haxe.Exception;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.io.File;
#end

/**
 * `BodySlotGuard` — the structural half of the writer-emit gate.
 *
 * Removing the sole body of a brace-less construct used to SUCCEED: the result
 * re-parsed, so the only gate there was passed it, and the construct silently took the
 * FOLLOWING statement as its new body. Measured before the guard, on a file whose
 * `run(false)` printed `B`:
 *
 * ```
 * if (c) b.add("A");   ->   if (c) b.add("B");
 * b.add("B");
 * ```
 *
 * — `apq remove-element` reported `wrote <file>`, rc 0, and `run(false)` then printed
 * nothing. `apq lint --fix` reached the identical result through `unused-local` on
 * `if (c) var y: Int = 1;`.
 *
 * All eight refusal tests are RED against `1218170f` (8 failures / 9 successes of 17
 * assertions). Six of them WROTE the corrupted file and reported success; `do` and
 * `catch` failed there on the re-parse gate instead, with a message that names nothing
 * about the cause — the second thing the guard buys.
 *
 * The three CONTROL tests are green on both sides by construction and are the other
 * half of the pin: a guard that refused a `case` arm, a braced body or an ordinary
 * block statement would be a worse regression than the bug, since those deletions mean
 * exactly what they say.
 */
class BodySlotGuardSliceTest extends Test {

	/** A brace-less `if` whose body is `a();`, followed by `b();` — the shape the campaign reported. */
	private static final IF_STMT: String = 'class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) a();\n\t\tb();\n\t}\n}\n';

	/** The same with an `else` branch and a third statement after it. */
	private static final IF_ELSE_STMT: String =
		'class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c)\n\t\t\ta();\n\t\telse\n\t\t\tb();\n\t\tc();\n\t}\n}\n';

	/** An `if` EXPRESSION whose then-branch is the distinctive literal `11`. */
	private static final IF_EXPR: String = 'class C {\n\tfunction f(c:Bool):Int {\n\t\treturn if (c) 11 else 22;\n\t}\n}\n';

	/** A `try` EXPRESSION whose body is the distinctive literal `11`. */
	private static final TRY_EXPR: String = 'class C {\n\tfunction f():Int {\n\t\treturn try 11 catch (e:Dynamic) 22;\n\t}\n}\n';

	/** The then-branch of a brace-less `if` — the shape the campaign reported. */
	public function testRefusesBracelessIfBody(): Void {
		assertRefusedNaming('class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) a();\n\t\tb();\n\t}\n}\n', 3, 10, 'IfStmt');
	}

	/** The then-branch when an `else` follows — the leftover `if (c) else …` does not compile. */
	public function testRefusesBracelessIfBodyWithElse(): Void {
		assertRefusedNaming('class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) a();\n\t\telse d();\n\t\tb();\n\t}\n}\n', 3, 10, 'IfStmt');
	}

	/**
	 * The ELSE branch. The deletion span runs to the end of its line, which is also the end
	 * of the `if`, so a guard that skipped any host an edit reached past the end of let this
	 * one through — it was caught only by re-running the sweep after the first fix.
	 */
	public function testRefusesBracelessElseBody(): Void {
		assertRefusedNaming(
			'class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c)\n\t\t\ta();\n\t\telse\n\t\t\td();\n\t\tb();\n\t}\n}\n', 6, 4, 'IfStmt'
		);
	}

	/** A `for` body — the following statement would run once per iteration. */
	public function testRefusesBracelessForBody(): Void {
		assertRefusedNaming('class C {\n\tfunction f(n:Int):Void {\n\t\tfor (i in 0...n) a();\n\t\tb();\n\t}\n}\n', 3, 20, 'ForStmt');
	}

	/** A `while` body — the following statement becomes the loop, and nothing advances it. */
	public function testRefusesBracelessWhileBody(): Void {
		assertRefusedNaming('class C {\n\tfunction f(c:Bool):Void {\n\t\twhile (c) a();\n\t\tb();\n\t}\n}\n', 3, 13, 'WhileStmt');
	}

	/** A `do` body. This one the re-parse gate happened to catch; now it says WHY. */
	public function testRefusesBracelessDoBody(): Void {
		assertRefusedNaming('class C {\n\tfunction f(c:Bool):Void {\n\t\tdo a();\n\t\twhile (c);\n\t\tb();\n\t}\n}\n', 3, 6, 'DoWhileStmt');
	}

	/**
	 * A bare `catch` body. Like `do`, this one the re-parse gate already rejected at base —
	 * `error at 3:29: unexpected input (expected //)`, which names nothing about the cause;
	 * measured on `1218170f`. The guard replaces that with a refusal that says which
	 * construct lost its body.
	 */
	public function testRefusesBracelessCatchBody(): Void {
		assertRefusedNaming(
			'class C {\n\tfunction f():Void {\n\t\ttry a() catch (e:Dynamic) d();\n\t\tb();\n\t}\n}\n', 3, 29, 'CatchClause'
		);
	}

	/**
	 * The branch of an `if` EXPRESSION. Nothing pinned any of the four expression-form kinds
	 * before, so a typo in one of those strings was invisible to the suite; at base this is
	 * an `Err` too, but the message is the re-parse gate's and names nothing.
	 */
	public function testRefusesIfExprBranch(): Void {
		assertRefusalNames(spliceOf(IF_EXPR, '11', ''), 'IfExpr');
	}

	/** The body of a `try` EXPRESSION — the kind the statement forms' doc claimed and the list omitted. */
	public function testRefusesTryExprBody(): Void {
		assertRefusalNames(spliceOf(TRY_EXPR, '11', ''), 'TryExpr');
	}

	/**
	 * A COMMENT is not whitespace, and it is not a statement either. `apq patch` replacing
	 * the body of `if (c) a();` with `// gone` wrote `if (c) // gone` and pulled `b();` into
	 * the branch — rc 0, and the probe stopped printing. Red against the whole slice as
	 * first written: the guard's blankness test was `trim()`, which reads a comment as
	 * content and returns before it ever parses.
	 */
	public function testRefusesCommentReplacementOfBracelessIfBody(): Void {
		assertRefusalNames(spliceOf(IF_STMT, 'a();', '// gone'), 'IfStmt');
	}

	/**
	 * CONTROL, green on both sides: a `case` arm holds a LIST, so emptying it leaves an arm
	 * that does nothing — which is what removing its only statement means. The following
	 * arm keeps its own statements.
	 */
	public function testAllowsSoleCaseArmStatement(): Void {
		final out: String = assertRemoved(
			'class C {\n\tfunction f(n:Int):Void {\n\t\tswitch n {\n\t\t\tcase 0:\n\t\t\t\ta();\n\t\t\tcase _:\n\t\t\t\td();\n\t\t}\n'
			+ '\t}\n}\n',
			5, 5
		);
		Assert.isTrue(out.indexOf('a();') == -1, 'the arm statement is gone: $out');
		Assert.isTrue(out.indexOf('case 0:') != -1, 'the emptied arm survives: $out');
		Assert.isTrue(out.indexOf('d();') != -1, 'the NEXT arm keeps its own statement: $out');
	}

	/** CONTROL, green on both sides: a braced body is a block, so one statement fewer is one statement fewer. */
	public function testAllowsBracedIfBodyStatement(): Void {
		final out: String = assertRemoved(
			'class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) {\n\t\t\ta();\n\t\t\td();\n\t\t}\n\t\tb();\n\t}\n}\n', 4, 4
		);
		Assert.isTrue(out.indexOf('a();') == -1, 'the block statement is gone: $out');
		Assert.isTrue(out.indexOf('d();') != -1, 'its sibling stays inside the block: $out');
	}

	/** CONTROL, green on both sides: an ordinary block statement. */
	public function testAllowsPlainBlockStatement(): Void {
		final out: String = assertRemoved('class C {\n\tfunction f():Void {\n\t\ta();\n\t\tb();\n\t}\n}\n', 3, 3);
		Assert.isTrue(out.indexOf('a();') == -1, 'the statement is gone: $out');
		Assert.isTrue(out.indexOf('b();') != -1, 'its sibling stays: $out');
	}

	/**
	 * CONTROL for the LEAD rule, which nothing else pins. Blanking a whole `else` branch
	 * takes the `else` keyword with it, so the `if` is being reshaped rather than left
	 * reaching, and the guard must stay out of the way. Disable the lead test in `BodySlotGuard.emptiedChild` and every refusal test above stays
	 * green while this one goes red (measured) — the three membership controls cannot see
	 * that line at all.
	 *
	 * It goes through `canonicalize` because an `else` branch is not a NODE: no addressed op
	 * can hand the guard an edit spanning the keyword and its body together.
	 */
	public function testAllowsWholeElseBranchRemoval(): Void {
		final out: String = assertSpliced(IF_ELSE_STMT, 'else\n\t\t\tb();', '');
		Assert.isTrue(out.indexOf('else') == -1, 'the else branch is gone: $out');
		Assert.isTrue(out.indexOf('a();') != -1 && out.indexOf('c();') != -1, 'both remaining statements stay: $out');
	}

	/**
	 * CONTROL for whole-host removal: a host whose own text does not survive is not being
	 * emptied, it is gone. `if-false-dead-code` deleting a whole `if (false) g();` is this
	 * shape.
	 *
	 * It pins the PAIR, not one line. Measured: disabling the host-survival test alone, or
	 * the lead test alone, leaves this green — each covers whole-host removal on its own —
	 * and only disabling BOTH turns it red. The sibling control above is the one that pins
	 * the lead test by itself.
	 */
	public function testAllowsWholeBracelessIfRemoval(): Void {
		final out: String = assertSpliced(IF_STMT, 'if (c) a();', '');
		Assert.isTrue(out.indexOf('if (c)') == -1, 'the whole construct is gone: $out');
		Assert.isTrue(out.indexOf('b();') != -1, 'and the statement after it stays: $out');
	}

	/**
	 * The same shape through `apq lint --fix`, which reaches `canonicalize` by a different
	 * road: `unused-local` on a declaration that IS a brace-less `if` body. The declaration
	 * must survive, and — the reason the filter sits per-CHECK rather than per-file — the
	 * OTHER rule with work in this file must still land its edit.
	 */
	public function testLintFixKeepsBracelessIfBodyDeclaration(): Void {
		#if (sys || nodejs)
		final src: String =
			'package p;\n\nclass C {\n\tpublic function f(c:Bool):String {\n\t\tif (c) var y:Int = 1;\n\t\treturn "B";\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('bodyslot', [{ name: 'Foo.hx', source: src }]);
		final path: String = '$dir/Foo.hx';
		Assert.equals(0, Cli.run(['lint', '--fix', '--no-oracle', path]), 'lint --fix exits ok');
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('var y') != -1, 'unused-local must not empty the brace-less if body: $out');
		Assert.isTrue(out.indexOf("return 'B';") != -1, 'the OTHER rule in the same file still lands its edit: $out');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Refused by `remove-element`, and the message names the construct so the caller knows what to brace. */
	private function assertRefusedNaming(source: String, line: Int, col: Int, kind: String): Void {
		assertRefusalNames(removeOf(source, line, col), kind);
	}

	/** An `Err` whose message names `kind` — a refusal that says WHICH construct lost its slot. */
	private function assertRefusalNames(result: EditResult, kind: String): Void {
		switch result {
			case Ok(text):
				Assert.fail('expected a refusal, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf(kind) != -1, 'the refusal names the construct ($kind): $message');
		}
	}

	/** Removed, re-parsed, and handed back for the caller's own assertions. */
	private function assertRemoved(source: String, line: Int, col: Int): String {
		return assertOk(removeOf(source, line, col));
	}

	/** Spliced through `canonicalize`, re-parsed, and handed back for the caller's own assertions. */
	private function assertSpliced(source: String, fragment: String, text: String): String {
		return assertOk(spliceOf(source, fragment, text));
	}

	/** The `Ok` text, proved to re-parse; an `Err` fails the test with its own message. */
	private function assertOk(result: EditResult): String {
		switch result {
			case Ok(text):
				final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
				try
					plugin.parseFile(text)
				catch (exception: Exception)
					Assert.fail('the result failed to re-parse: ${exception.message}\n$text');
				return text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return '';
		}
	}

	private static function removeOf(source: String, line: Int, col: Int): EditResult {
		return RemoveElement.removeElement(source, line, col, true, new HaxeQueryPlugin());
	}

	/**
	 * One hand-built edit over `source`, through `canonicalize` — the seam every writer-emit
	 * op shares, and the only entry that can splice a region no addressed op can name (a
	 * whole `else` branch) or a replacement no op will generate on its own (a comment).
	 * `reformat` is true so the fixture does not also have to be writer-canonical.
	 */
	private static function spliceOf(source: String, fragment: String, text: String): EditResult {
		final at: Int = source.indexOf(fragment);
		if (at < 0) throw new Exception('the fixture does not contain "$fragment"');
		final edits: Array<{ span: Span, text: String }> = [{ span: new Span(at, at + fragment.length), text: text }];
		return RefactorSupport.canonicalize(source, edits, true, new HaxeQueryPlugin());
	}

}
