package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.AddElement;
import anyparse.query.RefactorSupport.EditResult;
import haxe.Exception;
import utest.Assert;
import utest.Test;

/**
 * `AddElement.addElement` — insert a sibling element (statement / `case` /
 * comma-list element) next to an existing one, WRITER-FORMATTED.
 *
 * The element is spliced with the slot's separator (a newline for
 * self-terminated statement / case lists, a `,` for comma lists) and the
 * whole file is re-emitted through `RefactorSupport.canonicalize`, so each
 * accepted test asserts the EXACT canonical output. The source must be
 * writer-canonical unless `reformat` is passed. Refusal cases assert
 * `Err`; every `Ok` is additionally re-parsed.
 *
 * Coordinates are the positions `apq refs` prints; `line:col` points at
 * the FIRST TOKEN of an existing sibling element.
 */
class AddElementSliceTest extends Test {

	/** Insert a statement AFTER another in a block (self-terminated, newline). */
	public function testInsertStatementAfter(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tb();\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tc();\n\t\tb();\n\t}\n}\n';
		assertAdd(source, 3, 3, After, 'c();', true, expected);
	}

	/** Insert a statement BEFORE another in a block. */
	public function testInsertStatementBefore(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tb();\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tc();\n\t\tb();\n\t}\n}\n';
		assertAdd(source, 4, 3, Before, 'c();', true, expected);
	}

	/** Insert a `case` into a switch (self-delimited by the next `case`). */
	public function testInsertSwitchCaseAfter(): Void {
		final source: String =
			'class C {\n\tfunction f(x:Int):Void {\n\t\tswitch x {\n\t\t\tcase 0: a();\n\t\t\tcase 1: b();\n\t\t}\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f(x:Int):Void {\n\t\tswitch x {\n\t\t\tcase 0: a();\n\t\t\tcase 2: c();\n'
			+ '\t\t\tcase 1: b();\n\t\t}\n\t}\n}\n';
		assertAdd(source, 4, 4, After, 'case 2: c();', true, expected);
	}

	/** Insert an array element (comma list — separator detected by adjacency). */
	public function testInsertArrayElementAfter(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [1, 2];\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [1, 3, 2];\n\t}\n}\n';
		assertAdd(source, 3, 12, After, '3', true, expected);
	}

	/** Insert a call argument (comma list). */
	public function testInsertCallArgumentAfter(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tfoo(x, y);\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tfoo(x, z, y);\n\t}\n}\n';
		assertAdd(source, 3, 7, After, 'z', true, expected);
	}

	/**
	 * Insert an object field into a SINGLE-field object literal — the
	 * adjacency check finds no comma, so the comma separator comes from the
	 * `ObjectLit` parent kind. The generality test: a one-element comma
	 * list still gets a `,`.
	 */
	public function testInsertObjectFieldSingleField(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar o = {a: 1};\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar o = {a: 1, b: 2};\n\t}\n}\n';
		assertAdd(source, 3, 12, After, 'b: 2', true, expected);
	}

	/** On a canonical source the gate passes WITHOUT reformat. */
	public function testCanonicalGatePassesWithoutReformat(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tb();\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tc();\n\t\tb();\n\t}\n}\n';
		assertAdd(source, 3, 3, After, 'c();', false, expected);
	}

	/** A non-canonical source without reformat is refused by the gate. */
	public function testRefuseNonCanonicalWithoutReformat(): Void {
		final source: String = 'class C {\n    function f():Void {\n        a();\n    }\n}\n';
		assertRefused(source, 3, 9, After, 'b();', false);
	}

	/** A position not on an element's first token is refused. */
	public function testRefuseNotOnElementStart(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t}\n}\n';
		assertRefused(source, 3, 1, After, 'b();', true);
	}

	/** --append: add a member to a class body by pointing at the `class` keyword (= add-member). */
	public function testAppendMemberToClass(): Void {
		final source: String = 'class C {\n\tvar x:Int;\n}\n';
		final expected: String = 'class C {\n\tvar x:Int;\n\tvar y:Int;\n}\n';
		assertAppend(source, 1, 1, 'var y:Int;', true, expected);
	}

	/** --append: a container with no sibling to point at — append the first member to an empty class. */
	public function testAppendToEmptyClass(): Void {
		final source: String = 'class C {}\n';
		final expected: String = 'class C {\n\tvar x:Int;\n}\n';
		assertAppend(source, 1, 1, 'var x:Int;', true, expected);
	}

	/** --append: add a statement to the end of a block by pointing at the block `{`. */
	public function testAppendStatementToBlock(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\ta();\n\t\tb();\n\t}\n}\n';
		assertAppend(source, 2, 20, 'b();', true, expected);
	}

	/** --append: add an array element (comma list) by pointing at the `[`. */
	public function testAppendArrayElement(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [1, 2];\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [1, 2, 3];\n\t}\n}\n';
		assertAppend(source, 3, 11, '3', true, expected);
	}

	/** --append: first element of an empty array (no separator). */
	public function testAppendToEmptyArray(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [];\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [1];\n\t}\n}\n';
		assertAppend(source, 3, 11, '1', true, expected);
	}

	/** --append: add a call argument by pointing at the callee (resolves the Call, not the ExprStmt). */
	public function testAppendCallArgument(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tfoo(x);\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tfoo(x, y);\n\t}\n}\n';
		assertAppend(source, 3, 3, 'y', true, expected);
	}

	/** --append: add a case to a switch by pointing at the `switch` keyword. */
	public function testAppendCaseToSwitch(): Void {
		final source: String = 'class C {\n\tfunction f(x:Int):Void {\n\t\tswitch x {\n\t\t\tcase 0: a();\n\t\t}\n\t}\n}\n';
		final expected: String =
			'class C {\n\tfunction f(x:Int):Void {\n\t\tswitch x {\n\t\t\tcase 0: a();\n\t\t\tcase 1: b();\n\t\t}\n\t}\n}\n';
		assertAppend(source, 3, 3, 'case 1: b();', true, expected);
	}

	/** --append on a canonical source passes the gate WITHOUT reformat. */
	public function testAppendCanonicalGateWithoutReformat(): Void {
		final source: String = 'class C {\n\tvar x:Int;\n}\n';
		final expected: String = 'class C {\n\tvar x:Int;\n\tvar y:Int;\n}\n';
		assertAppend(source, 1, 1, 'var y:Int;', false, expected);
	}

	/** --append on a position that is not a container's first token (a literal) is refused. */
	public function testRefuseAppendNotOnContainer(): Void {
		final source: String = 'class C {\n\tvar x:Int = 5;\n}\n';
		assertAppendRefused(source, 2, 14, 'y', true);
	}

	/**
	 * --before a MODIFIED module decl inserts before the WHOLE decl, not
	 * between its `private` modifier and the `typedef` keyword: the new decl
	 * lands ahead of `private typedef B`, leaving the modifier with B.
	 */
	public function testInsertBeforeModifiedDecl(): Void {
		final source: String = 'typedef A = Int;\nprivate typedef B = Int;\n';
		final expected: String = 'typedef A = Int;\ntypedef D = Int;\nprivate typedef B = Int;\n';
		assertAdd(source, 2, 9, Before, 'typedef D = Int;', true, expected);
	}

	/**
	 * Pointing at a MODIFIER sibling (`private`) targets the decl it
	 * precedes — --after lands past the decl's body, not just past the
	 * modifier.
	 */
	public function testInsertAfterByPointingAtModifier(): Void {
		final source: String = 'typedef A = Int;\nprivate typedef B = Int;\n';
		final expected: String = 'typedef A = Int;\nprivate typedef B = Int;\ntypedef D = Int;\n';
		assertAdd(source, 2, 1, After, 'typedef D = Int;', true, expected);
	}

	/**
	 * --before a class member with modifiers inserts before the modifier
	 * run (`public function f` keeps its `public`), not between `public` and
	 * `function`.
	 */
	public function testInsertBeforeModifiedMember(): Void {
		final source: String = 'class C {\n\tvar a:Int;\n\tpublic function f():Void {}\n}\n';
		final expected: String = 'class C {\n\tvar a:Int;\n\tvar b:Int;\n\n\tpublic function f():Void {}\n}\n';
		assertAdd(source, 3, 2, Before, 'var b:Int;', true, expected);
	}

	/** --append tolerates a column ONE PAST the opening `{` (the off-by-one `ast --at` masks). */
	public function testAppendObjectLitTolerant(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar o = {a: 1};\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar o = {a: 1, b: 2};\n\t}\n}\n';
		assertAppend(source, 3, 12, 'b: 2', true, expected);
	}

	/** --append tolerates a cursor INSIDE the callee name, not only on its first character. */
	public function testAppendTolerantWithinCallee(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tfoo(x);\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tfoo(x, y);\n\t}\n}\n';
		assertAppend(source, 3, 4, 'y', true, expected);
	}

	/** --after tolerates a cursor INSIDE an element's identifier, not only on its first character. */
	public function testInsertAfterTolerantWithinIdent(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [abc, def];\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [abc, xyz, def];\n\t}\n}\n';
		assertAdd(source, 3, 13, After, 'xyz', true, expected);
	}

	/**
	 * A `;`-terminated element aimed at a comma-separated container is refused
	 * with the replace-node recipe — a statement never belongs in call
	 * arguments, and the old behaviour surfaced only as a cryptic parse error.
	 */
	public function testStatementIntoCommaListRefused(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tfoo(1, 2);\n\t}\n}\n';
		// Sibling insert: the cursor on `1` addresses a call-argument slot.
		assertRefused(source, 3, 7, After, 'bar();', true);
		// Append: the cursor on the callee resolves the Call container.
		assertAppendRefused(source, 3, 3, 'bar();', true);
	}

	/**
	 * --append past a trailing LINE comment: the separator stays glued to the
	 * last element and the new element lands on its own line PAST the comment.
	 * The splice used to land on the comment's last byte, so `, 2` became part
	 * of `// one` — the array kept ONE element, the file still parsed and
	 * stayed byte-canonical, so no downstream gate could see the loss.
	 */
	public function testAppendArrayPastTrailingLineComment(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [\n\t\t\t1 // one\n\t\t];\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [\n\t\t\t1, // one\n\t\t\t2\n\t\t];\n\t}\n}\n';
		assertAppend(source, 3, 11, '2', false, expected);
	}

	/** --append past a trailing BLOCK comment: same rule — the `,` stays with the last element. */
	public function testAppendArrayPastTrailingBlockComment(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [\n\t\t\t1 /* one */\n\t\t];\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [\n\t\t\t1, /* one */\n\t\t\t2\n\t\t];\n\t}\n}\n';
		assertAppend(source, 3, 11, '2', false, expected);
	}

	/**
	 * A container holding ONLY a line comment is EMPTY — no separator. The
	 * whitespace-only back-scan read the comment text as content, so the
	 * element was spliced into `// none` behind a `,`.
	 */
	public function testAppendToLineCommentOnlyArray(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [\n\t\t\t// none\n\t\t];\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [\n\t\t\t// none\n\t\t\t2\n\t\t];\n\t}\n}\n';
		assertAppend(source, 3, 11, '2', false, expected);
	}

	/** A container holding ONLY a block comment is EMPTY too — the stray `,` used to make the result unparseable. */
	public function testAppendToBlockCommentOnlyArray(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [\n\t\t\t/* none */\n\t\t];\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [\n\t\t\t/* none */\n\t\t\t2\n\t\t];\n\t}\n}\n';
		assertAppend(source, 3, 11, '2', false, expected);
	}

	/** A self-terminated statement list already splices past a trailing comment — locked so the comma fix keeps it. */
	public function testAppendStatementPastTrailingLineComment(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\ta(); // one\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\ta(); // one\n\t\tb();\n\t}\n}\n';
		assertAppend(source, 2, 20, 'b();', false, expected);
	}

	/** A block holding only a line comment: the statement lands on its own line below it. */
	public function testAppendToLineCommentOnlyBlock(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\t// none\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\t// none\n\t\tb();\n\t}\n}\n';
		assertAppend(source, 2, 20, 'b();', false, expected);
	}

	/**
	 * An escaped `\/\/` inside a regex literal reads as a line comment to a plain
	 * lexical scan, and that false comment runs PAST the container's `]`. Only a
	 * comment token lying entirely inside the container is trusted, so this
	 * appends normally instead of splicing into the regex.
	 */
	public function testAppendAfterRegexWithEscapedSlashes(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [~/^https?:\\/\\//];\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar a = [~/^https?:\\/\\//, ~/b/];\n\t}\n}\n';
		assertAppend(source, 3, 11, '~/b/', false, expected);
	}

	/**
	 * A brace-less `if` body GAINS braces and the new statement lands INSIDE it. Without the
	 * wrap the splice puts the statement after the whole `if`, where it runs unconditionally —
	 * source that parses and compiles, so nothing downstream catches it.
	 */
	public function testBraceLessIfBodyGainsBraces(): Void {
		final source: String = 'class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) a();\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) {\n\t\t\ta();\n\t\t\tb();\n\t\t}\n\t}\n}\n';
		assertAdd(source, 3, 10, After, 'b();', false, expected);
	}

	/** The same slot from the other side — the new statement goes first, inside the new braces. */
	public function testBraceLessIfBodyGainsBracesBefore(): Void {
		final source: String = 'class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) a();\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) {\n\t\t\tb();\n\t\t\ta();\n\t\t}\n\t}\n}\n';
		assertAdd(source, 3, 10, Before, 'b();', false, expected);
	}

	/** A brace-less `else` body gains braces the same way — the `if` branch is untouched. */
	public function testBraceLessElseBodyGainsBraces(): Void {
		final source: String = 'class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) a();\n\t\telse b();\n\t}\n}\n';
		final expected: String =
			'class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) a();\n\t\telse {\n\t\t\tb();\n\t\t\td();\n\t\t}\n\t}\n}\n';
		assertAdd(source, 4, 8, After, 'd();', false, expected);
	}

	/** A brace-less loop body gains braces — the condition/subject child is never the target. */
	public function testBraceLessLoopBodyGainsBraces(): Void {
		final source: String = 'class C {\n\tfunction f(xs:Array<Int>):Void {\n\t\tfor (x in xs) a(x);\n\t}\n}\n';
		final expected: String =
			'class C {\n\tfunction f(xs:Array<Int>):Void {\n\t\tfor (x in xs) {\n\t\t\ta(x);\n\t\t\tb(x);\n\t\t}\n\t}\n}\n';
		assertAdd(source, 3, 17, After, 'b(x);', false, expected);
	}

	/**
	 * An arrow lambda's EXPRESSION body gains braces, and the held expression gains the `;` a
	 * block needs (`terminated`). Note the value move this implies: the block's value is now
	 * `b()`, where the expression body's was `a()` — `--before` is the value-preserving side.
	 */
	public function testLambdaExpressionBodyGainsBraces(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\trun(() -> a());\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\trun(() -> {\n\t\t\ta();\n\t\t\tb();\n\t\t});\n\t}\n}\n';
		assertAdd(source, 3, 13, After, 'b();', false, expected);
	}

	/** GUARD: a body that ALREADY has braces takes the ordinary sibling path, unchanged. */
	public function testBracedIfBodyKeepsOneBlock(): Void {
		final source: String = 'class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) {\n\t\t\ta();\n\t\t}\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f(c:Bool):Void {\n\t\tif (c) {\n\t\t\ta();\n\t\t\tb();\n\t\t}\n\t}\n}\n';
		assertAdd(source, 4, 4, After, 'b();', false, expected);
	}

	// A doc comment is trivia OUTSIDE the declaration's node span, so both
	// insertion offsets used to land on the wrong side of one: `Before` at
	// `span.from` sits BELOW the target's own doc, and a MODULE-level span
	// runs to the first token of the NEXT declaration, so `After` at
	// `span.to` sits BELOW that neighbour's doc. Either way the doc came to
	// document the insertion and the declaration was left bare — while the
	// result parsed, stayed byte-canonical and drew no lint finding.

	/** `--before` a doc'd type: the insert goes ABOVE the doc, which stays with its class. */
	public function testInsertBeforeTypeGoesAboveItsDoc(): Void {
		final source: String = 'using StringTools;\n\n/**\n * Doc for C.\n */\nclass C {\n\n\tpublic function new() {}\n\n}\n';
		final expected: String =
			'using StringTools;\nusing haxe.io.Path;\n\n/**\n * Doc for C.\n */\nclass C {\n\n\tpublic function new() {}\n\n}\n';
		assertAdd(source, 6, 1, Before, 'using haxe.io.Path;', true, expected);
	}

	/** `--before` a doc'd MEMBER: same offset defect, inside a type body. */
	public function testInsertBeforeMemberGoesAboveItsDoc(): Void {
		final source: String = 'class C {\n\n\t/**\n\t * Doc m1.\n\t */\n\tpublic function m1(): Int return 1;\n\n}\n';
		final expected: String = 'class C {\n\n\tpublic function mx():Int\n\t\treturn 0;\n\n\t/**\n\t * Doc m1.\n\t */\n'
			+ '\tpublic function m1():Int\n\t\treturn 1;\n\n}\n';
		assertAdd(source, 6, 2, Before, 'public function mx(): Int return 0;', true, expected);
	}

	/** `--after` a module-level type: the insert stops SHORT of the next declaration's doc. */
	public function testInsertAfterTypeStopsShortOfTheNeighboursDoc(): Void {
		final source: String =
			'/**\n * Doc A.\n */\ntypedef A = {\n\tvar a: Int;\n}\n\n/**\n * Doc B.\n */\ntypedef B = {\n\tvar b: Int;\n}\n';
		final expected: String = '/**\n * Doc A.\n */\ntypedef A = {\n\tvar a:Int;\n}\n\ntypedef Mid = {var m:Int;}\n\n'
			+ '/**\n * Doc B.\n */\ntypedef B = {\n\tvar b:Int;\n}\n';
		assertAdd(source, 4, 1, After, 'typedef Mid = { var m: Int; }', true, expected);
	}

	/** CONTROL — a type MEMBER's span is tight, so `--after` there never overshot. */
	public function testInsertAfterMemberStillLandsBeforeTheNextDoc(): Void {
		final source: String = 'class C {\n\n\tpublic function m1(): Int return 1;\n\n\t/**\n\t * Doc m2.\n\t */\n'
			+ '\tpublic function m2(): Int return 2;\n\n}\n';
		final expected: String = 'class C {\n\n\tpublic function m1():Int\n\t\treturn 1;\n\n\tpublic function mx():Int\n'
			+ '\t\treturn 0;\n\n\t/**\n\t * Doc m2.\n\t */\n\tpublic function m2():Int\n\t\treturn 2;\n\n}\n';
		assertAdd(source, 3, 2, After, 'public function mx(): Int return 0;', true, expected);
	}

	// The first shape this fix took trimmed the WHOLE span with
	// `trailingTrimmedSpan`, which cuts trailing comment tokens off `span.to`.
	// That is right for a delete (it PRESERVES what it excludes) and exactly
	// wrong for an insert: the two shapes below then landed BETWEEN an element
	// and its own trailing comment, moving the comment onto the insertion — the
	// same defect in the other direction, and equally invisible to every gate.
	// Both offsets now ask `docExtendedSpan`, which walks back only over `/**`
	// blocks that START THEIR LINE, so a trailing comment is never crossed.

	/** `--after` a module type whose span swallows its own trailing line comment. */
	public function testInsertAfterTypeKeepsItsTrailingComment(): Void {
		final source: String = 'typedef A = {\n\tvar a:Int;\n} // trailing note about A\n\ntypedef B = {var b:Int;}\n';
		final expected: String =
			'typedef A = {\n\tvar a:Int;\n} // trailing note about A\n\ntypedef Mid = {var m:Int;}\ntypedef B = {var b:Int;}\n';
		assertAdd(source, 1, 1, After, 'typedef Mid = {var m: Int;}', true, expected);
	}

	/** `--after` a comma-list element whose span swallows its own trailing block comment. */
	public function testInsertAfterCommaElementKeepsItsTrailingComment(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tfinal o = {\n\t\t\ta: 1 /* about a */,\n\t\t\tb: 2\n\t\t};\n\t}\n}\n';
		final expected: String =
			'class C {\n\tfunction f():Void {\n\t\tfinal o = {\n\t\t\ta: 1 /* about a */,\n\t\t\tc: 3,\n\t\t\tb: 2\n\t\t};\n\t}\n}\n';
		assertAdd(source, 4, 4, After, 'c: 3', true, expected);
	}

	private function assertAppend(source: String, line: Int, col: Int, code: String, reformat: Bool, expected: String): Void {
		final result: EditResult = appendOf(source, line, col, code, reformat);
		switch result {
			case Ok(text):
				Assert.equals(expected, text);
				assertReparses(text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertAppendRefused(source: String, line: Int, col: Int, code: String, reformat: Bool): Void {
		final result: EditResult = appendOf(source, line, col, code, reformat);
		switch result {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(_):
				Assert.pass();
		}
	}

	private function assertAdd(
		source: String, line: Int, col: Int, side: InsertSide, code: String, reformat: Bool, expected: String
	): Void {
		final result: EditResult = addOf(source, line, col, side, code, reformat);
		switch result {
			case Ok(text):
				Assert.equals(expected, text);
				assertReparses(text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertRefused(source: String, line: Int, col: Int, side: InsertSide, code: String, reformat: Bool): Void {
		final result: EditResult = addOf(source, line, col, side, code, reformat);
		switch result {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(_):
				Assert.pass();
		}
	}

	private function assertReparses(text: String): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		try {
			plugin.parseFile(text);
			Assert.pass();
		} catch (exception: Exception) {
			Assert.fail('add-element output failed to re-parse: ${exception.message}\n$text');
		}
	}

	private static function appendOf(source: String, line: Int, col: Int, code: String, reformat: Bool): EditResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return AddElement.appendElement(source, line, col, code, reformat, plugin);
	}

	private static function addOf(source: String, line: Int, col: Int, side: InsertSide, code: String, reformat: Bool): EditResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return AddElement.addElement(source, line, col, side, code, reformat, plugin);
	}

}
