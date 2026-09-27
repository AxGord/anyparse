package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CasePatterns;
import anyparse.query.Inline;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.Rename;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * A bare lowercase identifier in a `case` pattern CAPTURES: it declares a new binding for the arm
 * and never compares against a same-named local, parameter or field (verified on `--interp`). The
 * resolver must bind it that way, or every consumer reading its answer treats the capture as a read
 * of the outer declaration - `inline` then splices the outer initializer into the pattern and
 * `rename` renames the pattern along with the declaration it shadows.
 *
 * Each fixture is small enough to read the expected resolution off it: `render` spells every hit as
 * `<kind> <line>:<col>` plus `-> <line>:<col>` of the binding it resolves to, and a `?` after the
 * kind marks `RefHit.patternUndecided`.
 */
class CaseCaptureTest extends Test {

	/** The capture declares, the arm's reads bind to it, and a read past the switch still binds to the parameter. */
	@:pin('control')
	@:killer('M-CAPTURE-ARM-BIND')
	public function testBareCaptureBindsItsArm(): Void {
		final source: String = lines([
			'class C {',
			'\tfunction f(o:String, t:String) {',
			'\t\tswitch o {',
			'\t\t\tcase t: use(t);',
			'\t\t}',
			'\t\tuse(t);',
			'\t}',
			'}'
		]);
		Assert.equals('decl 2:23 | decl? 4:9 | read 4:16 -> 4:9 | read 6:7 -> 2:23', render(source, 't'));
	}

	/**
	 * Every alternative of `case A(x), B(x):` binds the same name, so the later ones resolve to the FIRST
	 * capture. The reference walk has no view of the files lookup order (its imports, its `import.hx`
	 * chain), so a bare capture is never proven there: every one is undecided.
	 */
	@:pin('control')
	@:killer('M-CAPTURE-ALT-SELF')
	public function testAlternativesShareTheFirstCapture(): Void {
		final arm: Array<String> = [
			'class C {',
			'\tfunction f(o:E, x:Int) {',
			'\t\tswitch o {',
			'\t\t\tcase A(x), B(x): use(x);',
			'\t\t}',
			'\t}',
			'}'
		];
		Assert.equals('decl 2:18 | decl? 4:11 | decl? 4:17 -> 4:11 | read 4:25 -> 4:11', render(lines(arm), 'x'));
	}

	/**
	 * A name a constant declaration may claim stays a READ: of the file's sole constant of that name
	 * it is decided (Haxe compares), past a local that shadows it it is undecided (the local makes
	 * it a capture, an `enum abstract` value of the subject's type would still compare).
	 */
	@:pin('control')
	@:killer('M-PATTERN-CONST-DECIDED')
	public function testConstantNamedPatternIsARead(): Void {
		final source: String = lines([
			'class C {',
			'\tstatic inline var si:String = "si";',
			'\tfunction f(o:String) {',
			'\t\tswitch o {',
			'\t\t\tcase si: use(si);',
			'\t\t}',
			'\t}',
			'\tfunction g(o:String, si:String) {',
			'\t\tswitch o {',
			'\t\t\tcase si: use(si);',
			'\t\t}',
			'\t}',
			'}'
		]);
		Assert.equals(
			'decl 2:16 | read 5:9 -> 2:16 | read 5:17 -> 2:16 | decl 8:23 | read? 10:9 -> 8:23 | read 10:17 -> 8:23', render(source, 'si')
		);
	}

	/** A constructor call's callee and an extractor's expression are READS; only the sub-patterns bind. */
	@:pin('control')
	@:killer('M-PATTERN-CALLEE-CAPTURE')
	public function testCalleeAndExtractorStayReads(): Void {
		final source: String = lines([
			'class C {',
			'\tfunction f(o:E, g:Int -> Int, w:Int) {',
			'\t\tswitch o {',
			'\t\t\tcase g(w): w;',
			'\t\t\tcase g(_) => w: w;',
			'\t\t}',
			'\t}',
			'}'
		]);
		Assert.equals('decl 2:18 | read 4:9 -> 2:18 | read 5:9 -> 2:18', render(source, 'g'));
		Assert.equals('decl 2:32 | decl? 4:11 | read 4:15 -> 4:11 | decl? 5:17 | read 5:20 -> 5:17', render(source, 'w'));
	}

	/** `inline` of a local a pattern captures under the same name substitutes only the reads that are the local's. */
	@:pin('control')
	@:killer('M-CAPTURE-ARM-BIND')
	public function testInlineLeavesTheCaptureAlone(): Void {
		final source: String = lines([
			'class C {',
			'\tfunction f(other:String) {',
			'\t\tfinal k:String = "lit";',
			'\t\tswitch other {',
			'\t\t\tcase var k: use(k);',
			'\t\t}',
			'\t\tuse(k);',
			'\t}',
			'}'
		]);
		final expected: String = lines([
			'class C {',
			'\tfunction f(other:String) {',
			'\t\tswitch other {',
			'\t\t\tcase var k: use(k);',
			'\t\t}',
			'\t\tuse("lit");',
			'\t}',
			'}'
		]);
		switch inlineAt(source, 3, 9) {
			case Ok(text):
				Assert.equals(expected, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/**
	 * A read site where a binding of an initializer's name shadows it — a case capture or a lambda
	 * parameter — would make the substituted identifier read that binding instead.
	 */
	@:pin('control')
	@:killer('M-INLINE-RECAPTURE')
	public function testInlineRefusesARecapturedRead(): Void {
		final capture: String = lines([
			'class C {',
			'\tfunction f(other:String) {',
			'\t\tfinal a:String = "A";',
			'\t\tfinal y:String = a;',
			'\t\tswitch other {',
			'\t\t\tcase a: use(y);',
			'\t\t}',
			'\t}',
			'}'
		]);
		assertInlineRefused(capture, 4, 9, 'different declaration');
		final lambda: String = lines([
			'class C {',
			'\tfunction f() {',
			'\t\tfinal a:String = "A";',
			'\t\tfinal y:String = a;',
			'\t\tuse((a:String) -> y);',
			'\t}',
			'}'
		]);
		assertInlineRefused(lambda, 4, 9, 'different declaration');
	}

	/** A pattern naming the local that a constant may also claim cannot be decided, so the inline refuses. */
	@:pin('control')
	@:killer('M-INLINE-UNDECIDED')
	public function testInlineRefusesAnUndecidedPattern(): Void {
		final source: String = lines([
			'class C {',
			'\tstatic inline var si:String = "si";',
			'\tfunction f(v:String) {',
			'\t\tfinal si:String = "local";',
			'\t\tswitch v {',
			'\t\t\tcase si: use(si);',
			'\t\t}',
			'\t}',
			'}'
		]);
		assertInlineRefused(source, 4, 9, 'cannot prove');
	}

	/** `rename` of a declaration a pattern capture shadows leaves the capture and its reads alone. */
	@:pin('control')
	@:killer('M-CAPTURE-ARM-BIND')
	public function testRenameLeavesTheCaptureAlone(): Void {
		final source: String = lines([
			'class C {',
			'\tfunction f(other:String) {',
			'\t\tfinal t:String = "outer";',
			'\t\tswitch other {',
			'\t\t\tcase var t: use(t);',
			'\t\t}',
			'\t\tuse(t);',
			'\t}',
			'}'
		]);
		final expected: String = lines([
			'class C {',
			'\tfunction f(other:String) {',
			'\t\tfinal z:String = "outer";',
			'\t\tswitch other {',
			'\t\t\tcase var t: use(t);',
			'\t\t}',
			'\t\tuse(z);',
			'\t}',
			'}'
		]);
		assertRenamed(source, 3, 9, 'z', expected);
	}

	/** Renaming a capture whose subject type comes from another file would assume that type has no constant of the name. */
	@:pin('control')
	@:killer('M-RENAME-UNDECIDED')
	public function testRenameRefusesAnUndecidedCapture(): Void {
		final source: String = lines([
			'class C {',
			'\tfunction f(other:Kind) {',
			'\t\tswitch other {',
			'\t\t\tcase fresh: use(fresh);',
			'\t\t}',
			'\t}',
			'}'
		]);
		switch renameAt(source, 4, 20, 'z') {
			case Ok(text):
				Assert.fail('expected Err, got Ok:\n$text');
			case Err(message):
				Assert.stringContains('cannot prove', message);
		}
	}

	/** The alternatives of one arm are ONE binding: renaming from any of them, or from a read, rewrites all. */
	@:pin('control')
	@:killer('M-RENAME-DECL-SELF')
	@:killer('M-BINDING-FROM-DECL-SELF')
	public function testRenameMovesEveryAlternative(): Void {
		final source: String = lines([
			'class C {',
			'\tfunction f(o:E, x:Int) {',
			'\t\tswitch o {',
			'\t\t\tcase x = A(_), x = B(_): use(x);',
			'\t\t}',
			'\t}',
			'}'
		]);
		final expected: String = lines([
			'class C {',
			'\tfunction f(o:E, x:Int) {',
			'\t\tswitch o {',
			'\t\t\tcase z = A(_), z = B(_): use(z);',
			'\t\t}',
			'\t}',
			'}'
		]);
		assertRenamed(source, 4, 33, 'z', expected);
		assertRenamed(source, 4, 19, 'z', expected);
	}

	/**
	 * An extractor's LEFT side is an expression evaluated on the subject, so it reads the binding OUTSIDE
	 * the arm: a capture of the same name is visible only from the end of the pattern. Inlining the outer
	 * local must reach it (`--interp`: `got 3` before and after).
	 */
	@:pin('control')
	@:killer('M-CAPTURE-VISIBLE-FROM-ARM')
	public function testExtractorLeftSideReadsTheOuterBinding(): Void {
		final source: String = lines([
			'class C {',
			'\tfunction f() {',
			'\t\tfinal n:Int = 2;',
			'\t\tswitch 3 {',
			'\t\t\tcase n = add(_, n) => 5: use(n);',
			'\t\t}',
			'\t}',
			'}'
		]);
		Assert.equals('decl 3:3 | decl 5:9 | read 5:20 -> 3:3 | read 5:33 -> 5:9', render(source, 'n'));
		final expected: String = lines([
			'class C {',
			'\tfunction f() {',
			'\t\tswitch 3 {',
			'\t\t\tcase n = add(_, 2) => 5: use(n);',
			'\t\t}',
			'\t}',
			'}'
		]);
		switch inlineAt(source, 3, 9) {
			case Ok(text):
				Assert.equals(expected, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/**
	 * A capture that is not PROVEN may still compare, and then the arm's reads of the name are the OUTER
	 * binding's: renaming or inlining that binding refuses. The extractor's right side has an expected type
	 * this file does not see; a subject of another file's type may be an `enum abstract` with that value.
	 */
	@:pin('control')
	@:killer('M-CAPTURE-SHADOWS-OUTER')
	public function testOuterBindingOfAnUndecidedCaptureRefuses(): Void {
		final extractor: String = lines([
			'class C {',
			'\tfunction f() {',
			'\t\tfinal n:Int = 2;',
			'\t\tswitch 3 {',
			'\t\t\tcase add(_, n) => n: use(n);',
			'\t\t}',
			'\t}',
			'}'
		]);
		assertInlineRefused(extractor, 3, 9, 'case pattern');
		assertRenameRefused(extractor, 3, 9);
		final foreignSubject: String = lines([
			'class C {',
			'\tfunction f(k:Kind) {',
			'\t\tfinal value:Kind = k;',
			'\t\tswitch k {',
			'\t\t\tcase value: use(1);',
			'\t\t}',
			'\t\tuse(value);',
			'\t}',
			'}'
		]);
		assertRenameRefused(foreignSubject, 3, 9);
	}

	/** An or-pattern `A(n) | B(n)` is inside the whitelist: both sides are scanned, and the scan stays modelled. */
	@:pin('control')
	@:killer('M-PATTERN-OR-UNMODELLED')
	public function testOrPatternIsModelled(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile('class C { function f(o:E) { switch o { case A(n) | B(n): use(n); } } }');
		final arm: Null<QueryNode> = findKind(tree, 'CaseBranch');
		Assert.notNull(arm);
		if (arm == null) return;
		final found: PatternScan = CasePatterns.scan(arm, plugin.refShape(), []);
		Assert.isTrue(found.modelled);
		Assert.equals('n,n', [for (ident in found.idents) ident.name].join(','));
	}

	private function assertInlineRefused(source: String, line: Int, col: Int, fragment: String): Void {
		switch inlineAt(source, line, col) {
			case Ok(text):
				Assert.fail('expected Err, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf(fragment) >= 0, 'message lacks "$fragment": $message');
		}
	}

	private function assertRenameRefused(source: String, line: Int, col: Int): Void {
		switch renameAt(source, line, col, 'z') {
			case Ok(text):
				Assert.fail('expected Err, got Ok:\n$text');
			case Err(message):
				Assert.stringContains('case pattern', message);
		}
	}

	private function assertRenamed(source: String, line: Int, col: Int, newName: String, expected: String): Void {
		switch renameAt(source, line, col, newName) {
			case Ok(text):
				Assert.equals(expected, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private static function inlineAt(source: String, line: Int, col: Int): InlineResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return Inline.inlineVar(source, line, col, plugin, plugin.refShape());
	}

	private static function renameAt(source: String, line: Int, col: Int, newName: String): RenameResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return Rename.rename(source, line, col, newName, plugin, plugin.refShape());
	}

	/** Every hit of `name`: kind (`?` when pattern-undecided), position, and the position it binds to unless it self-binds. */
	private static function render(source: String, name: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final hits: Array<RefHit> = Refs.find(name, plugin.parseFile(source), plugin.refShape());
		return hits.map(h -> {
			final at: String = pos(source, h.span);
			final head: String = '${h.kind.toString()}${h.patternUndecided ? '?' : ''} $at';
			final bound: Null<Span> = h.bindingSpan;
			return bound == null || bound.from == h.span.from ? head : '$head -> ${pos(source, bound)}';
		}).join(' | ');
	}

	private static function findKind(node: QueryNode, kind: String): Null<QueryNode> {
		if (node.kind == kind) return node;
		for (child in node.children) {
			final found: Null<QueryNode> = findKind(child, kind);
			if (found != null) return found;
		}
		return null;
	}

	private static inline function lines(parts: Array<String>): String {
		return parts.join('\n');
	}

	private static function pos(source: String, span: Span): String {
		final at: Position = span.lineCol(source);
		return '${at.line}:${at.col}';
	}

}
