package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import anyparse.query.RefactorSupport;
import anyparse.query.RemoveElement;
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
 * The eight refusal tests written for the guard's first slice are RED against `1218170f`
 * (8 failures / 9 successes of 17 assertions). Six of them WROTE the corrupted file and
 * reported success; `do` and `catch` failed there on the re-parse gate instead, with a message
 * that names nothing about the cause — the second thing the guard buys. Nine more refusals came
 * with the RESULT-side question that followed: a non-blank replacement that drops the body, one
 * that is itself an unfinished construct, one that is no construct at all, a construct the
 * replacement BUILDS over a plain statement, one an INSERTION drops in, and a swallow whose end
 * lands in a second, unrelated edit — every one of them measured on a program that stopped
 * printing at rc 0.
 *
 * The eleven CONTROL tests are green on both sides by construction and are the other half of
 * the pin: a guard that refused a `case` arm, a braced body, an ordinary block statement, a
 * sole `catch` clause, a header rewritten over its own body or a body somebody braced by hand
 * would be a worse regression than the bug, since those edits mean exactly what they say. Each names the line it pins and how disabling that line flips it — except one, which says
 * plainly that nothing flips it and why it is still here.
 */
class BodySlotGuardSliceTest extends Test {

	/**
	 * Every `QueryNode.kind` these fixtures can reach, none of which may appear in a refusal.
	 *
	 * The messages used to be built from `host.kind` and `child.kind`, so the user of
	 * `if (1) f();` was told about an `IfStmt` with an empty `IntLit` slot — two names that are
	 * nowhere in their file. The slot half was the worse one: it is the kind of whatever happened
	 * to sit in the slot, so one construct produced `ExprStmt`, `Call` or `IntLit` by turns.
	 */
	private static final KIND_LEAKS: Array<String> = [
		'IfStmt',
		'IfExpr',
		'ForStmt',
		'ForExpr',
		'WhileStmt',
		'WhileExpr',
		'DoWhileStmt',
		'TryCatchStmt',
		'TryExpr',
		'CatchClause',
		'ExprStmt',
		'IdentExpr',
		'IntLit'
	];

	/** A brace-less `if` whose body is `a();`, followed by `b();` — the shape the campaign reported. */
	private static final IF_STMT: String = 'class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) a();\n\t\tb();\n\t}\n}\n';

	/** A brace-less `if` whose CONDITION is a unique call, so an edit can blank exactly that slot. */
	private static final IF_COND_STMT: String = 'class C {\n\tfunction f():Void {\n\t\tif (ready()) a();\n\t\tb();\n\t}\n}\n';

	/** The same with an `else` branch and a third statement after it. */
	private static final IF_ELSE_STMT: String =
		'class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c)\n\t\t\ta();\n\t\telse\n\t\t\tb();\n\t\tc();\n\t}\n}\n';

	/** An `if` EXPRESSION whose then-branch is the distinctive literal `11`. */
	private static final IF_EXPR: String = 'class C {\n\tfunction f(c:Bool):Int {\n\t\treturn if (c) 11 else 22;\n\t}\n}\n';

	/** A `try` EXPRESSION whose body is the distinctive literal `11`. */
	private static final TRY_EXPR: String = 'class C {\n\tfunction f():Int {\n\t\treturn try 11 catch (e:Dynamic) 22;\n\t}\n}\n';

	/** A brace-less `while` whose body is `a();`, followed by `b();` — the `if` fixture's loop twin. */
	private static final WHILE_STMT: String = 'class C {\n\tfunction f(c:Bool):Void {\n\t\twhile (c) a();\n\t\tb();\n\t}\n}\n';

	/** A brace-less `try` with ONE `catch`, followed by `b();`. */
	private static final TRY_CATCH_STMT: String =
		'class C {\n\tfunction f():Void {\n\t\ttry a() catch (e:Dynamic) d();\n\t\tb();\n\t}\n}\n';

	/** The same with a trailing line comment after it — trivia the `try`\'s own span runs into. */
	private static final TRY_CATCH_COMMENT_STMT: String =
		'class C {\n\tfunction f():Void {\n\t\ttry a() catch (e:Dynamic) d(); // note\n\t\tb();\n\t}\n}\n';

	/** Two plain statements and no control construct anywhere — what a replacement can BUILD one over. */
	private static final PLAIN_STMTS: String = 'class C {\n\tfunction f(c:Bool):Void {\n\t\ta();\n\t\tb();\n\t}\n}\n';

	/** The then-branch of a brace-less `if` — the shape the campaign reported. */
	public function testRefusesBracelessIfBody(): Void {
		assertRefusedNaming('class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) a();\n\t\tb();\n\t}\n}\n', 3, 10, 'if');
	}

	/** The then-branch when an `else` follows — the leftover `if (c) else …` does not compile. */
	public function testRefusesBracelessIfBodyWithElse(): Void {
		assertRefusedNaming('class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) a();\n\t\telse d();\n\t\tb();\n\t}\n}\n', 3, 10, 'if');
	}

	/**
	 * The ELSE branch. The deletion span runs to the end of its line, which is also the end
	 * of the `if`, so a guard that skipped any host an edit reached past the end of let this
	 * one through — it was caught only by re-running the sweep after the first fix.
	 */
	public function testRefusesBracelessElseBody(): Void {
		assertRefusedNaming(
			'class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c)\n\t\t\ta();\n\t\telse\n\t\t\td();\n\t\tb();\n\t}\n}\n', 6, 4, 'if'
		);
	}

	/** A `for` body — the following statement would run once per iteration. */
	public function testRefusesBracelessForBody(): Void {
		assertRefusedNaming('class C {\n\tfunction f(n:Int):Void {\n\t\tfor (i in 0...n) a();\n\t\tb();\n\t}\n}\n', 3, 20, 'for');
	}

	/** A `while` body — the following statement becomes the loop, and nothing advances it. */
	public function testRefusesBracelessWhileBody(): Void {
		assertRefusedNaming('class C {\n\tfunction f(c:Bool):Void {\n\t\twhile (c) a();\n\t\tb();\n\t}\n}\n', 3, 13, 'while');
	}

	/** A `do` body. This one the re-parse gate happened to catch; now it says WHY. */
	public function testRefusesBracelessDoBody(): Void {
		assertRefusedNaming('class C {\n\tfunction f(c:Bool):Void {\n\t\tdo a();\n\t\twhile (c);\n\t\tb();\n\t}\n}\n', 3, 6, 'do');
	}

	/**
	 * A bare `catch` body. Like `do`, this one the re-parse gate already rejected at base —
	 * `error at 3:29: unexpected input (expected //)`, which names nothing about the cause;
	 * measured on `1218170f`. The guard replaces that with a refusal that says which
	 * construct lost its body.
	 */
	public function testRefusesBracelessCatchBody(): Void {
		assertRefusedNaming('class C {\n\tfunction f():Void {\n\t\ttry a() catch (e:Dynamic) d();\n\t\tb();\n\t}\n}\n', 3, 29, 'catch');
	}

	/**
	 * The branch of an `if` EXPRESSION. Nothing pinned any of the four expression-form kinds
	 * before, so a typo in one of those strings was invisible to the suite; at base this is
	 * an `Err` too, but the message is the re-parse gate's and names nothing.
	 */
	public function testRefusesIfExprBranch(): Void {
		assertRefusalNames(spliceOf(IF_EXPR, '11', ''), 'if');
	}

	/** The body of a `try` EXPRESSION — the kind the statement forms' doc claimed and the list omitted. */
	public function testRefusesTryExprBody(): Void {
		assertRefusalNames(spliceOf(TRY_EXPR, '11', ''), 'try');
	}

	/**
	 * A COMMENT is not whitespace, and it is not a statement either. `apq patch` replacing
	 * the body of `if (c) a();` with `// gone` wrote `if (c) // gone` and pulled `b();` into
	 * the branch — rc 0, and the probe stopped printing. Red against the whole slice as
	 * first written: the guard's blankness test was `trim()`, which reads a comment as
	 * content and returns before it ever parses.
	 */
	public function testRefusesCommentReplacementOfBracelessIfBody(): Void {
		assertRefusalNames(spliceOf(IF_STMT, 'a();', '// gone'), 'if');
	}

	/**
	 * A replacement that is NOT blank and still drops the body — the shape S30 left open.
	 * `apq patch` with `if (flag) log.push('x');` ==== `if (flag)` wrote `if (flag)` followed by
	 * the NEXT statement, which parses and silently re-binds it into the branch: measured on a
	 * program that went from printing `in-branch,after` / `after` to printing `after` / nothing,
	 * rc 0 and `wrote <file>` throughout.
	 *
	 * Neither source-side test can see it. The pre-filter reads the edit TEXT, and `if (flag)` is
	 * not blank, so the guard used to return before it ever parsed; and `surviving` splices a
	 * super-span edit's whole text into every clipped sub-region, so host and slot BOTH read
	 * non-blank even once it does. The answer is on the RESULT: the construct ends up covering
	 * source text that used to follow it.
	 */
	public function testRefusesNonBlankReplacementDroppingBracelessIfBody(): Void {
		assertRefusalNames(spliceOf(IF_STMT, 'if (c) a();', 'if (c)'), 'if');
	}

	/** The same one-node-over: a `while` header kept, its body dropped, the next statement pulled in. */
	public function testRefusesNonBlankReplacementDroppingBracelessWhileBody(): Void {
		assertRefusalNames(spliceOf(WHILE_STMT, 'while (c) a();', 'while (c)'), 'while');
	}

	/**
	 * The construct the replacement BUILDS, over a statement that had no construct around it.
	 * `a();` ==== `if (c)` in a plain block wrote `if (c) b();` — rc 0, and a probe went from
	 * printing `one,two` twice to printing `two` and then nothing. NOTHING in the source lost a
	 * body here, so every source-side reading of the edits is silent by construction; only the
	 * result says what happened. The first shape this guard's own trigger was too narrow to see.
	 */
	public function testRefusesConstructBuiltOverAPlainStatement(): Void {
		assertRefusalNames(spliceOf(PLAIN_STMTS, 'a();', 'if (c)'), 'if');
	}

	/**
	 * The construct's end landing in a SECOND, unrelated edit. Two independent pairs — one on the
	 * brace-less body, one on the statement after it — wrote `if (c) a() + d();` with the second
	 * statement inside the branch, rc 0, because the end sat inside a replacement and the rule read
	 * every such end as authored. A replacement only authors an end it reaches back to.
	 */
	public function testRefusesSwallowEndingInAnUnrelatedEdit(): Void {
		assertRefusalNames(splicesOf(IF_STMT, [{ find: 'a();', text: 'a() +' }, { find: 'b();', text: 'd();' }]), 'if');
	}

	/**
	 * The same swallow from an edit that DELETES NOTHING. `apq add-element --before` with the bare
	 * element `if (c)` wrote `if (c) b();` — rc 0 — and the pre-filter, which asked for an edit
	 * with a non-empty span, returned before parsing. An insertion replaced nothing, so it owns
	 * nothing: a construct born there may end inside the inserted text and nowhere else.
	 */
	public function testRefusesConstructBornAtAPureInsertion(): Void {
		assertRefusalNames(insertOf(PLAIN_STMTS, 'b();', 'if (c)\n\t\t'), 'if');
	}

	/**
	 * CONTROL for the comment half of `trimmedEnd`, green on both sides: the sole-`catch` removal
	 * again, with a trailing `// note` after the statement. A node span runs into trailing trivia
	 * and the two sides carry different amounts of it, so trimming only WHITESPACE made this
	 * ordinary `remove-element` a refusal — one comment was the whole discriminator, and the
	 * comment-free twin below stayed green throughout.
	 */
	public function testAllowsSoleCatchClauseRemovalWithATrailingComment(): Void {
		final out: String = assertRemoved(TRY_CATCH_COMMENT_STMT, 3, 11);
		Assert.isTrue(out.indexOf('catch') == -1, 'the catch clause is gone: $out');
		Assert.isTrue(out.indexOf('// note') != -1 && out.indexOf('b();') != -1, 'the comment and the next statement stay: $out');
	}

	/**
	 * The same corruption from an edit CONTAINED in the slot, which the crossing trigger alone
	 * does not see: the replacement is itself a construct that needs a body. `apq patch` with
	 * `log.push('in-branch');` ==== `if (log.length > 0)` wrote
	 * `if (flag) if (log.length > 0) log.push('after');` — rc 0, `wrote <file>`, and the probe
	 * stopped printing. `surviving` reads this slot exactly and it is NOT blank; what changed is
	 * that the construct no longer ends where it did.
	 */
	public function testRefusesHeaderShapedReplacementOfBracelessIfBody(): Void {
		assertRefusalNames(spliceOf(IF_STMT, 'a();', 'if (c)'), 'if');
	}

	/**
	 * The swallow with NO construct in the replacement at all: an unterminated EXPRESSION.
	 * `a();` ==== `a() +` leaves `if (c) a() + b();`, so `b()` moved inside the branch — and the
	 * construct that took it in is the one already standing in SURVIVING source, not one the
	 * replacement built. It is the only fixture that reads its limit off the source construct at
	 * the same position rather than off the edit.
	 */
	public function testRefusesUnterminatedExpressionReplacementOfBracelessIfBody(): Void {
		assertRefusalNames(spliceOf(IF_STMT, 'a();', 'a() +'), 'if');
	}

	/**
	 * The near-miss neighbour of the refusal above, green on both sides: the SAME edit span,
	 * replaced by a construct that DOES end. The rule must read "the `;` moved" as different
	 * from "the `;` went", and the two fixtures differ in nothing but that.
	 *
	 * No single mutation of the guard flips this one — every line whose removal would refuse it
	 * is already pinned by a fixture that refuses. It is here as the near-miss, not as a line's
	 * proof.
	 */
	public function testAllowsTerminatedReplacementOfBracelessIfBody(): Void {
		final out: String = assertSpliced(IF_STMT, 'a();', 'if (c) d();');
		Assert.isTrue(out.indexOf('if (c) if (c) d();') != -1, 'the nested construct landed whole: $out');
		Assert.isTrue(out.indexOf('b();') != -1, 'and the statement after it stays outside the branch: $out');
	}

	/**
	 * CONTROL for the authored-end rule, green on both sides: a construct whose END sits inside
	 * the REPLACEMENT is the shape the caller wrote out, however much it takes in. Bracing a body
	 * around the following statement is a rewrite somebody spelled; only a construct that ends in
	 * SURVIVING source can have taken in what nobody asked for. Drop the `editEnd` test in
	 * `reached` and this goes red while every refusal above stays green.
	 */
	public function testAllowsAuthoredBodyThatTakesInTheNextStatement(): Void {
		final out: String = assertSpliced(IF_STMT, 'a();\n\t\tb();', '{\n\t\t\ta();\n\t\t\tb();\n\t\t}');
		Assert.isTrue(out.indexOf('if (c) {') != -1, 'the caller\'s braces are what the construct now holds: $out');
		Assert.isTrue(out.indexOf('a();') != -1 && out.indexOf('b();') != -1, 'both statements survive inside them: $out');
	}

	/**
	 * CONTROL for `ownedEnd`, green on both sides: a super-span edit that rewrites the HEADER
	 * leaves the body where it was, so nothing is swallowed. It is what stops the rule from reading
	 * every edit that spans a construct as a dropped body — make the inserted-start limit the
	 * EDIT's own end instead of the region it replaced and this one goes red while every refusal
	 * stays green.
	 */
	public function testAllowsHeaderRewriteOfBracelessConstruct(): Void {
		final out: String = assertSpliced(WHILE_STMT, 'while (c)', 'if (c)');
		Assert.isTrue(out.indexOf('if (c) a();') != -1, 'the header was rewritten over its own body: $out');
		Assert.isTrue(out.indexOf('while') == -1 && out.indexOf('b();') != -1, 'nothing else moved: $out');
	}

	/**
	 * CONTROL, and a correction to the brief that queued this slice: removing the SOLE `catch`
	 * clause is NOT the brace-less-body class. Haxe 4.3.7 accepts a catch-less `try` — measured
	 * on `-js` and `--interp`, braced and brace-less, statement and expression form, all rc 0 —
	 * so the result is valid code that means what the edit says, and the guard must stay out of
	 * the way.
	 *
	 * It is also the one shape that reaches the guard's whitespace-lead rule: the lead between a
	 * try body and its first `catch` is a single space, so the slot is skipped. That skip is
	 * correct here, which is why the "hole" was left as it is.
	 */
	public function testAllowsSoleCatchClauseRemoval(): Void {
		final out: String = assertRemoved(TRY_CATCH_STMT, 3, 11);
		Assert.isTrue(out.indexOf('catch') == -1, 'the catch clause is gone: $out');
		Assert.isTrue(out.indexOf('a()') != -1 && out.indexOf('b();') != -1, 'the try body and the next statement stay: $out');
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

	/**
	 * T217, the BRACKETED slot: emptying a CONDITION must not advise braces.
	 *
	 * Reproduced on the base build — `apq patch` blanking the `cond1` of `if (cond1) trace('a');`
	 * answered `this would leave the IfStmt at 6:3 with an empty IdentExpr slot … brace the body
	 * first`. Two node kinds as user vocabulary, and a remedy that is not available: `if ({ … })`
	 * is not what the author wants and does not parse. The slot is read off the SOURCE — the lead
	 * ends with an opener and the closer follows the slot — so no grammar vocabulary is added.
	 */
	public function testBracketedSlotRefusalDoesNotAdviseBraces(): Void {
		assertRemedy(spliceOf(IF_COND_STMT, 'ready()', ''), 'nothing between `(` and `)`', 'brace the body');
	}

	/**
	 * T217, the VALUE slot: emptying the branch of an `if` EXPRESSION must not advise braces either,
	 * for the opposite reason — `{ }` there is an empty BLOCK, so `final v = if (c) { } else 22;`
	 * trades the refusal for a type error. Base build answered `empty IntLit slot … brace the body
	 * first`, which is the exact wrong advice this pins.
	 */
	public function testUnprovedPositionNamesBothRepairs(): Void {
		assertRemedy(spliceOf(IF_EXPR, '11', ''), 'an expression if it is a value', 'brace the body first');
	}

	/**
	 * T217, the BODY slot, and the CONTROL for the two above: a statement construct still gets the
	 * braces advice, which is right there. Green at base in substance and red in wording — the base
	 * message names `IfStmt`, which `assertRemedy` refuses through `KIND_LEAKS`.
	 *
	 * The three arms differ only in the slot, so a `statementSlot` / `enclosingBrackets` that
	 * collapsed any two of them flips one of these.
	 */
	public function testStatementBodyRefusalAdvisesBraces(): Void {
		assertRemedy(spliceOf(IF_STMT, 'a();', ''), 'brace the body first (`{ … }`)', 'put an expression there');
	}

	/**
	 * T217, the propagated statement position: a `catch` body inside a STATEMENT `try` is braceable,
	 * and the first version of this rewrite got it wrong by reading the immediate parent — a
	 * `CatchClause`'s parent is `TryCatchStmt`, which is no block kind, so it was told to put an
	 * EXPRESSION where braces are exactly right. `statementSlot` passes the position DOWN through
	 * fixed-slot constructs; reverting it to a parent-kind test flips this one and nothing else.
	 */
	public function testCatchBodyInAStatementTryAdvisesBraces(): Void {
		assertRemedy(spliceOf(TRY_CATCH_STMT, 'd();', ''), 'brace the body first (`{ … }`)', 'put an expression there');
	}

	/**
	 * T217, the shape SELF-REVIEW found after the first draft: a brace-less `if` that is the FIRST
	 * statement of a `case` arm. `blockKinds()` is the `dead-code` / `empty-block` vocabulary and
	 * deliberately holds no `CaseBranch`, so the parent walk stops at the `switch` and the position
	 * is unproved — the draft asserted VALUE there and told the author to put an EXPRESSION where
	 * braces are exactly right, which is the same class of wrong advice the whole item is about.
	 *
	 * So the message names BOTH repairs and the condition that picks between them, and this pins
	 * that it names both: an `assertRemedy` for either half alone would pass on a message that
	 * asserted the other. Restoring the value-only wording flips it.
	 */
	public function testCaseArmBodyNamesBothRepairs(): Void {
		final source: String = 'class C {\n\tfunction f(c:Bool):Void {\n\t\tswitch (c) {\n\t\t\tcase true:\n\t\t\t\tif (c) a();\n'
			+ '\t\t\t\tb();\n\t\t\tcase false:\n\t\t}\n\t}\n}\n';
		assertRemedy(spliceOf(source, 'a();', ''), 'braces (`{ … }`) if this `if` is a statement', 'brace the body first');
		assertRemedy(spliceOf(source, 'a();', ''), 'an expression if it is a value', 'brace the body first');
	}

	/**
	 * The other half of the same fix, and what `startsAStatement` buys: the SAME `case` arm one
	 * statement further in. A `;` before the construct proves it stands where a statement stands
	 * whatever its parent kind is, so this one gets the sharp advice while its first-statement twin
	 * above does not. Dropping the `startsAStatement` OR-term in `scan` flips this and leaves the
	 * twin green — the pair is what makes either of them say anything.
	 */
	public function testStatementAfterASemicolonInACaseArmAdvisesBraces(): Void {
		final source: String = 'class C {\n\tfunction f(c:Bool):Void {\n\t\tswitch (c) {\n\t\t\tcase true:\n\t\t\t\td();\n'
			+ '\t\t\t\tif (c) a();\n\t\t\t\tb();\n\t\t\tcase false:\n\t\t}\n\t}\n}\n';
		assertRemedy(spliceOf(source, 'a();', ''), 'brace the body first (`{ … }`)', 'an expression if it is a value');
	}

	/** Refused by `remove-element`, and the message names the construct so the caller knows what to brace. */
	private function assertRefusedNaming(source: String, line: Int, col: Int, word: String): Void {
		assertRefusalNames(removeOf(source, line, col), word);
	}

	/** An `Err` whose message names `kind` — a refusal that says WHICH construct lost its slot. */
	private function assertRefusalNames(result: EditResult, word: String): Void {
		switch result {
			case Ok(text):
				Assert.fail('expected a refusal, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(
					message.indexOf('`$word`') != -1, 'the refusal names the construct by the word the author wrote (`$word`): $message'
				);
				for (leak in KIND_LEAKS)
					Assert.isTrue(message.indexOf(leak) == -1, 'the refusal leaks the node kind "$leak" as user vocabulary: $message');
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

	/** The refusal carries `wanted`, does NOT carry `refused`, and leaks no node kind. */
	private function assertRemedy(result: EditResult, wanted: String, refused: String): Void {
		switch result {
			case Ok(text):
				Assert.fail('expected a refusal, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf(wanted) != -1, 'the refusal offers the remedy that fits ("$wanted"): $message');
				Assert.isTrue(message.indexOf(refused) == -1, 'and not the one that does not ("$refused"): $message');
				for (leak in KIND_LEAKS)
					Assert.isTrue(message.indexOf(leak) == -1, 'the refusal leaks the node kind "$leak" as user vocabulary: $message');
		}
	}

	/** One pure INSERTION before `before`, through `canonicalize` — an edit whose span deletes nothing. */
	private static inline function insertOf(source: String, before: String, text: String): EditResult {
		return SeamEdit.insert(source, before, text);
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
		return splicesOf(source, [{ find: fragment, text: text }]);
	}

	/**
	 * SEVERAL hand-built edits over `source`, through `canonicalize` — the shape a `patch`
	 * multi-pair payload and one `lint --fix` check's edit set both produce, and the only one where
	 * a construct's end can land in an edit OTHER than the one that touched its body.
	 */
	private static function splicesOf(source: String, pairs: Array<{ find: String, text: String }>): EditResult {
		return SeamEdit.apply(source, [
			for (pair in pairs) { find: pair.find, covered: pair.find.length, text: pair.text }
		]);
	}

}
