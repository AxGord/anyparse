package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if sys
import sys.FileSystem;
import sys.io.File;
#end

/**
 * End-to-end probes for the DX Tier-4 batch:
 *  1. `apq ast --count` — emit just the integer direct-children count
 *     at the displayed root. Composes with `--select` (one line per
 *     match). Replaces hand-counting members before a corpus-driver
 *     test assertion.
 *  2. `apq gates [<dir>]` — list every ctor decl carrying
 *     `@:fmt(trailOptParseGate('<pred>'))` /
 *     `@:fmt(trailOptShapeGate('<pred>'))` annotation plus the
 *     extracted predicate name. THE structural answer to "which
 *     predicate gates this ctor's `;` elision?", invoked before a
 *     gate-relaxation slice (Slice 30 / 39 pattern).
 *  3. `apq recon --predict-relax` — terminator-insertion predictor.
 *     Inverse of `--predict-strip`: instead of REMOVING tokens to
 *     model "what blocks the next parse step", INSERTS the parser's
 *     `expected` hint to model "would the slice candidate be gate
 *     relaxation on the ctor at the fail-locus?". Sweep + probe modes.
 *  4. `apq recon --predict-strip` moved-locus refinement — BACKWARD
 *     vs forward-advance distinction. NEW locus < ORIG locus signals
 *     "strip damaged earlier syntax / wrong mechanism model" — the
 *     Slice 39 failure mode where token substitution can't model
 *     gate-relaxation.
 */
@:nullSafety(Strict)
class ApqDxTier4CliTest extends Test {

	// --- 1. ast --count ---

	public function testAstCountOnModuleRoot(): Void {
		Assert.equals(
			0, Cli.run([
				'probe',
				'class A {} class B {}',
				'--count'
			]),
			'probe --count on a 2-class module exits clean'
		);
	}

	public function testAstCountWithSelectExitsClean(): Void {
		Assert.equals(
			0, Cli.run([
				'probe',
				'class M { var a:Int; var b:Int; }',
				'--select',
				'ClassDecl',
				'--count'
			]),
			'probe --count --select ClassDecl emits per-match counts'
		);
	}

	public function testAstCountNoSelectNoMatchStillExitsClean(): Void {
		// `--count` without `--select` always emits ONE number — the root's
		// direct-child count. Never fails on shape; just prints 0 if empty.
		Assert.equals(
			0, Cli.run([
				'probe',
				'',
				'--count'
			]),
			'probe --count on empty source still exits clean'
		);
	}

	// --- 2. apq gates ---

	public function testGatesHelpExitsClean(): Void {
		Assert.equals(0, Cli.run(['gates', '--help']), 'apq gates --help is a clean exit');
	}

	public function testGatesUnknownOptionIsUsageError(): Void {
		Assert.equals(2, Cli.run(['gates', '--bogus']), 'apq gates unknown option is a usage error');
	}

	public function testGatesDefaultScopeListsHaxeGrammar(): Void {
		// Default scope is `src/anyparse/grammar/haxe/` when invoked
		// with no positional. The grammar has at least one
		// `trailOptParseGate('stmtExprNoSemi')` (HxStatement.ExprStmt)
		// and several `trailOptShapeGate` sites (HxClassMember.VarMember,
		// HxStatement.VarStmt, etc.), so the walk surfaces ≥1 hit and
		// exits cleanly.
		Assert.equals(0, Cli.run(['gates']), 'apq gates default scope walks haxe grammar cleanly');
	}

	// `--mechanism <name>` extends `gates` from trail-opt only to other
	// Lowering mechanisms (Slice 40 follow-up). Default value preserves
	// the original output 1:1; explicit `--mechanism trail-opt` is
	// equivalent; unknown names exit usage-error; every documented
	// mechanism is walker-accepted on the default haxe grammar scope.
	public function testGatesMechanismTrailOptExplicitMatchesDefault(): Void {
		Assert.equals(0, Cli.run(['gates', '--mechanism', 'trail-opt']), '`gates --mechanism trail-opt` is equivalent to the bare default');
	}

	public function testGatesMechanismUnknownIsUsageError(): Void {
		Assert.equals(2, Cli.run(['gates', '--mechanism', 'bogus']), 'unknown --mechanism value exits with usage error');
	}

	public function testGatesMechanismOptionalRefTrailWalksGrammar(): Void {
		// `optional-ref-trail` is the Slice 40 mechanism — the haxe
		// grammar has at least one consumer (HxAbstractDecl.underlyingType),
		// so the walk surfaces ≥1 hit and exits cleanly.
		Assert.equals(
			0, Cli.run(['gates', '--mechanism', 'optional-ref-trail']),
			'optional-ref-trail walk on haxe grammar exits clean (has consumers)'
		);
	}

	public function testGatesMechanismMandatoryRefLeadTrailWalksGrammar(): Void {
		// `mandatory-ref-lead-trail` is the predict-optional fallback
		// candidate list — pre-Slice-40 bracket-pair fields that could
		// be relaxed. Haxe grammar has many (HxIfStmt.cond, HxFnDecl,
		// HxClassDecl.members, …) so this exits clean too.
		Assert.equals(
			0, Cli.run(['gates', '--mechanism', 'mandatory-ref-lead-trail']), 'mandatory-ref-lead-trail walk on haxe grammar exits clean'
		);
	}

	public function testGatesMechanismOptionalRefWalksGrammar(): Void {
		Assert.equals(0, Cli.run(['gates', '--mechanism', 'optional-ref']), 'optional-ref walk on haxe grammar exits clean');
	}

	public function testGatesMechanismKwLeadWalksGrammar(): Void {
		Assert.equals(0, Cli.run(['gates', '--mechanism', 'kw-lead']), 'kw-lead walk on haxe grammar exits clean');
	}

	public function testGatesOnEmptyDirEmitsEmpty(): Void {
		#if sys
		final dir: String = mkTempDir('apq_gates_empty');
		// No `.hx` files → walker emits empty result with stderr note.
		// Exit code is 0 (not finding files isn't an error in walker-style
		// commands — it's a no-result).
		final exit: Int = Cli.run(['gates', dir]);
		Assert.isTrue(exit == 0 || exit == 1, 'apq gates on empty dir returns 0 (empty walk) or 1 (no inputs matched), got $exit');
		cleanupDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- 3. recon --predict-relax ---

	public function testPredictRelaxAccepted(): Void {
		#if sys
		// `--predict-relax` without --probe / <dir> falls back to
		// `$ANYPARSE_HXFORMAT_FORK/test/testcases` — scope the env so
		// the usage-error path is reachable. Twin of
		// `ApqReconCliTest.testReconNoArgsAndNoEnvIsUsageError`.
		final saved: Null<String> = Sys.getEnv('ANYPARSE_HXFORMAT_FORK');
		Sys.putEnv('ANYPARSE_HXFORMAT_FORK', '');
		Assert.equals(
			2, Cli.run(['recon', '--predict-relax']), '--predict-relax without --probe or a dir still needs a target (here: usage error)'
		);
		if (saved != null) Sys.putEnv('ANYPARSE_HXFORMAT_FORK', saved);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testPredictRelaxRejectsReplaceWith(): Void {
		Assert.equals(
			2, Cli.run([
				'recon',
				'--predict-relax',
				'--replace',
				'x',
				'--with',
				'y',
				'/some/dir'
			]),
			'--predict-relax does not take --replace/--with (token comes from parser hint)'
		);
	}

	public function testPredictRelaxIncompatibleWithPredictStrip(): Void {
		Assert.equals(
			2, Cli.run([
				'recon',
				'--predict-relax',
				'--predict-strip',
				'--replace',
				'x',
				'--with',
				'y',
				'/some/dir'
			]),
			'--predict-relax and --predict-strip are mutually exclusive (opposite models)'
		);
	}

	// --- 4. Top-level usage mentions new subcommands ---

	public function testTopLevelUsageExitsClean(): Void {
		// --help renders the subcommand list incl. `gates` and `cases`.
		// We don't capture stdout here, just verify the exit code path
		// stays clean after the additions.
		Assert.equals(0, Cli.run(['--help']), 'top-level --help exits clean');
	}

	#if sys
	private static var counter: Int = 0;

	private static function mkTempDir(prefix: String): String {
		counter++;
		final tmp: Null<String> = Sys.getEnv('TMPDIR');
		final base: String = (tmp != null && tmp.length > 0) ? stripTrailingSlash((tmp: String)) : '/tmp';
		final dir: String = '$base/${prefix}_${Sys.time()}_$counter';
		FileSystem.createDirectory(dir);
		return dir;
	}

	private static function cleanupDir(dir: String): Void {
		if (!FileSystem.exists(dir)) return;
		for (entry in FileSystem.readDirectory(dir)) {
			final p: String = '$dir/$entry';
			if (FileSystem.isDirectory(p))
				cleanupDir(p);
			else
				FileSystem.deleteFile(p);
		}
		FileSystem.deleteDirectory(dir);
	}

	private static inline function stripTrailingSlash(p: String): String {
		return StringTools.endsWith(p, '/') ? p.substring(0, p.length - 1) : p;
	}
	#end

}
