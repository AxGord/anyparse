package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.AddImport;
import anyparse.query.RefactorSupport.EditResult;
import haxe.Exception;
import utest.Assert;
import utest.Test;

/**
 * `AddImport.addImport` — add an `import` / `using`, WRITER-FORMATTED.
 *
 * The statement is placed (after the last import / using, else after
 * `package`, else file-top) and the whole file is re-emitted through the
 * writer, so the result is canonical (the writer separates the import and
 * using blocks with a blank line). The source must already be canonical
 * unless `reformat` is passed. Each `Ok` asserts the EXACT canonical
 * output and is re-parsed; refusal cases assert `Err`.
 */
class AddImportSliceTest extends Test {

	/** Add an import after an existing one — same-kind imports group. */
	public function testAddAfterExistingImport(): Void {
		final source: String = 'package foo;\n\nimport a.B;\n\nclass C {}\n';
		final expected: String = 'package foo;\n\nimport a.B;\nimport c.D;\n\nclass C {}\n';
		assertAdd(source, 'c.D', false, expected);
	}

	/** An ordered block keeps its order — the fresh import takes its slot, not the block's end. */
	public function testAddTakesTheOrderedSlot(): Void {
		final source: String = 'package foo;\n\nimport a.B;\nimport m.N;\n\nclass C {}\n';
		final expected: String = 'package foo;\n\nimport a.B;\nimport c.D;\nimport m.N;\n\nclass C {}\n';
		assertAdd(source, 'c.D', false, expected);
	}

	/** A block carrying no recognisable order is appended to, never resorted. */
	public function testUnorderedBlockStillAppends(): Void {
		final source: String = 'package foo;\n\nimport z.Zed;\nimport a.Al;\n\nclass C {}\n';
		final expected: String = 'package foo;\n\nimport z.Zed;\nimport a.Al;\nimport m.Mid;\n\nclass C {}\n';
		assertAdd(source, 'm.Mid', false, expected);
	}

	/**
	 * A block no order explains is still appended to WITHIN its run. The op's own fallback anchor
	 * is the file's last import statement — which for a file whose imports are followed by a
	 * `using` sits PAST that `using`, opening a stray third run that every later insert extends.
	 * This is the TM incident shape: an unordered run, a `using`, and a fixer adding one import.
	 */
	public function testUnorderedRunKeepsTheImportBeforeTheUsing(): Void {
		final source: String = 'package foo;\n\nimport m.Mid;\nimport z.Zed;\nimport a.Al;\n\nusing e.Ext;\n\nclass C {}\n';
		final expected: String =
			'package foo;\n\nimport m.Mid;\nimport z.Zed;\nimport a.Al;\nimport b.Bee;\n\nusing e.Ext;\n\nclass C {}\n';
		assertAdd(source, 'b.Bee', false, expected);
	}

	/** Two runs split by a `using`: the fresh import takes its slot in the run it sorts into, not the last run's end. */
	public function testAddLandsInTheRunItSortsInto(): Void {
		final source: String =
			'package foo;\n\nimport a.Al;\nimport m.Mid;\n\nusing e.Ext;\n\nimport b.Bee;\nimport c.Cee;\n\nclass C {}\n';
		final expected: String =
			'package foo;\n\nimport a.Al;\nimport h.Host;\nimport m.Mid;\n\nusing e.Ext;\n\nimport b.Bee;\nimport c.Cee;\n\nclass C {}\n';
		assertAdd(source, 'h.Host', false, expected);
	}

	/**
	 * A path whose SIMPLE NAME an existing import already binds appends. Haxe lets the LAST import
	 * of a name win, so an ordered slot ahead of the incumbent would add an import that binds
	 * nothing — the op must still deliver the name the caller asked for.
	 */
	public function testSameSimpleNameAppendsSoTheFreshImportWins(): Void {
		final source: String = 'package foo;\n\nimport m.Mid;\nimport z.Foo;\n\nclass C {}\n';
		final expected: String = 'package foo;\n\nimport m.Mid;\nimport z.Foo;\nimport a.Foo;\n\nclass C {}\n';
		assertAdd(source, 'a.Foo', false, expected);
	}

	/** A WILDCARD binds names the plain-import ordering cannot see, so it appends like a `using`. */
	public function testWildcardAppendsRatherThanTakingASlot(): Void {
		final source: String = 'package foo;\n\nimport a.B;\nimport z.Y;\n\nclass C {}\n';
		final expected: String = 'package foo;\n\nimport a.B;\nimport z.Y;\nimport m.*;\n\nclass C {}\n';
		assertAdd(source, 'm.*', false, expected);
	}

	/** With no imports but a `package`, the import opens a block after it. */
	public function testAddAfterPackageOnly(): Void {
		final source: String = 'package foo;\n\nclass C {}\n';
		final expected: String = 'package foo;\n\nimport a.B;\n\nclass C {}\n';
		assertAdd(source, 'a.B', false, expected);
	}

	/** With no package and no imports, the import lands at the file start. */
	public function testAddNoPackageNoImports(): Void {
		final source: String = 'class C {}\n';
		final expected: String = 'import a.B;\n\nclass C {}\n';
		assertAdd(source, 'a.B', false, expected);
	}

	/** A `using` is added with the `using` keyword, in its own block. */
	public function testAddUsing(): Void {
		final source: String = 'package foo;\n\nimport a.B;\n\nclass C {}\n';
		final expected: String = 'package foo;\n\nimport a.B;\n\nusing c.D;\n\nclass C {}\n';
		assertAdd(source, 'c.D', true, expected);
	}

	/** Refuse an import already present as the same kind. */
	public function testRefuseDuplicateImport(): Void {
		final source: String = 'import a.B;\n\nclass C {}\n';
		assertRefused(source, 'a.B', false);
	}

	/**
	 * An import already present, but ONLY inside a `#if … #end`
	 * conditional-compilation region, must not be silently re-added as
	 * an unguarded top-level duplicate — the top-level structural scan
	 * does not descend into `Conditional` children, so a naive
	 * duplicate check misses it entirely.
	 */
	public function testRefuseDuplicateInsideConditional(): Void {
		final source: String = '#if sys\nimport a.B;\n#end\n\nclass C {}\n';
		assertRefused(source, 'a.B', false);
	}

	/** `import a.B` does NOT block `using a.B` — dedup is per-kind. */
	public function testUsingNotBlockedByImportOfSamePath(): Void {
		final source: String = 'import a.B;\n\nclass C {}\n';
		final expected: String = 'import a.B;\n\nusing a.B;\n\nclass C {}\n';
		assertAdd(source, 'a.B', true, expected);
	}

	/** Refuse a non-canonical file (no blank lines) without `--reformat`. */
	public function testRefuseNonCanonicalWithoutReformat(): Void {
		final source: String = 'package foo;\nimport a.B;\nclass C {}\n';
		assertRefused(source, 'c.D', false);
	}

	/** `reformat` proceeds on a non-canonical file, canonicalising it. */
	public function testReformatProceedsOnNonCanonical(): Void {
		final source: String = 'package foo;\nimport a.B;\nclass C {}\n';
		final expected: String = 'package foo;\n\nimport a.B;\nimport c.D;\n\nclass C {}\n';
		assertAdd(source, 'c.D', false, expected, true);
	}

	/**
	 * A module whose WHOLE body sits inside one `#if … #end` carries its import run there, so the
	 * fresh import takes its ordered slot INSIDE the guard. Read at the top level only, the file
	 * offers no run at all and the import lands on an island above the `#if` — in scope for nothing
	 * the guarded code declares.
	 */
	public function testGuardedRunTakesItsOrderedSlot(): Void {
		final source: String = 'package foo;\n\n#if DEBUG\nimport a.Al;\nimport m.Mid;\n\nclass C {}\n#end\n';
		final expected: String = 'package foo;\n\n#if DEBUG\nimport a.Al;\nimport c.Cee;\nimport m.Mid;\n\nclass C {}\n#end\n';
		assertAdd(source, 'c.Cee', false, expected);
	}

	/**
	 * The macro-builder shape — every import behind `#if macro`, the TYPE outside it — anchors at
	 * MODULE level, above the region. It is not a near-miss of the case above: a region declaring no
	 * type guards no code, so `ModuleScan.guardedBodyRegion` refuses it, and rightly. A line spliced
	 * inside would be in scope only where the condition holds, while the class it serves resolves in
	 * every build; module level is the only position that covers the class.
	 */
	public function testGuardedImportsWithAnUnguardedTypeAnchorAtModuleLevel(): Void {
		final source: String = 'package foo;\n\n#if macro\nimport a.Al;\nimport m.Mid;\n#end\n\nclass C {}\n';
		final expected: String = 'package foo;\n\nimport c.Cee;\n#if macro\nimport a.Al;\nimport m.Mid;\n#end\n\nclass C {}\n';
		assertAdd(source, 'c.Cee', false, expected);
	}

	/**
	 * A header with BOTH kinds sorts the fresh line into the UNGUARDED run and leaves the guarded one
	 * untouched. The guarded run is not a candidate — `runsOf` ends a run at a `#if` region — and
	 * that is the sound reading: what an unguarded run binds, every build sees.
	 */
	public function testAMixedHeaderSortsIntoTheUnguardedRun(): Void {
		final source: String = 'package foo;\n\nimport a.Al;\nimport m.Mid;\n#if macro\nimport z.Zed;\n#end\n\nclass C {}\n';
		final expected: String =
			'package foo;\n\nimport a.Al;\nimport c.Cee;\nimport m.Mid;\n#if macro\nimport z.Zed;\n#end\n\nclass C {}\n';
		assertAdd(source, 'c.Cee', false, expected);
	}

	/**
	 * TWO disjoint guarded regions are no header at all: neither guards the whole body (the first
	 * gate is ONE region at the top level), so there is no region whose condition every build of this
	 * module's code satisfies, and picking either would put the line in scope for a strict subset of
	 * the file. Module level again.
	 */
	public function testTwoDisjointGuardedRegionsAnchorAtModuleLevel(): Void {
		final source: String = 'package foo;\n\n#if macro\nimport a.Al;\n#end\n#if js\nimport z.Zed;\n#end\n\nclass C {}\n';
		final expected: String =
			'package foo;\n\nimport c.Cee;\n#if macro\nimport a.Al;\n#end\n#if js\nimport z.Zed;\n#end\n\nclass C {}\n';
		assertAdd(source, 'c.Cee', false, expected);
	}

	/** A ROOT-package `package;` still anchors the import BELOW it — an import above `package` does not compile. */
	public function testEmptyPackageStillAnchorsBelowIt(): Void {
		final source: String = 'package;\n\nclass C {}\n';
		final expected: String = 'package;\n\nimport a.Al;\n\nclass C {}\n';
		assertAdd(source, 'a.Al', false, expected);
	}

	/**
	 * A fresh `using` lands ABOVE the file's existing `using` group, never past it. Haxe ranks static
	 * extensions in REVERSE declaration order, so appending below would give the new module TOP
	 * priority and silently re-target every same-named extension call the file already makes.
	 */
	public function testUsingLandsBelowTheImportsAndAboveTheUsingGroup(): Void {
		final source: String = 'package foo;\n\nimport a.Al;\nimport m.Mid;\n\nusing e.Ext;\n\nclass C {}\n';
		final expected: String = 'package foo;\n\nimport a.Al;\nimport m.Mid;\n\nusing z.Zed;\nusing e.Ext;\n\nclass C {}\n';
		assertAdd(source, 'z.Zed', true, expected);
	}

	/** A wildcard takes no ordered slot, but it still joins the IMPORT block rather than landing past the `using` group. */
	public function testWildcardJoinsTheImportBlockNotTheUsingGroup(): Void {
		final source: String = 'package foo;\n\nimport a.Al;\nimport m.Mid;\n\nusing e.Ext;\n\nclass C {}\n';
		final expected: String = 'package foo;\n\nimport a.Al;\nimport m.Mid;\nimport q.*;\n\nusing e.Ext;\n\nclass C {}\n';
		assertAdd(source, 'q.*', false, expected);
	}

	private function assertAdd(source: String, path: String, isUsing: Bool, expected: String, reformat: Bool = false): Void {
		final result: EditResult = addOf(source, path, isUsing, reformat);
		switch result {
			case Ok(text):
				Assert.equals(expected, text);
				assertReparses(text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertRefused(source: String, path: String, isUsing: Bool, reformat: Bool = false): Void {
		final result: EditResult = addOf(source, path, isUsing, reformat);
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
			Assert.fail('add-import output failed to re-parse: ${exception.message}\n$text');
		}
	}

	private static function addOf(source: String, path: String, isUsing: Bool, reformat: Bool): EditResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return AddImport.addImport(source, path, isUsing, reformat, plugin);
	}

}
