package unit.cli;

import anyparse.query.Cli;
import anyparse.query.cli.CliRegistry;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `apq --help` and five usage pages, pinned as the BYTES the pre-seam binary printed.
 *
 * Wave 2 moved 66 commands out of `Cli.dispatch`, and each of them carried four
 * parts across: the name, the `--help` line, the usage page and the run. Three of
 * the four have a natural gate — the run is compared invocation by invocation, the
 * name is what `dispatch` looks up. The `--help` line has none, because the only
 * other place it exists after the move is `summary()` itself: a fixture that asks
 * `CliRegistry.helpLine` what `summary()` says cannot fail, whatever the move did
 * to the text. S69 shipped exactly that fixture and watched it survive an arm that
 * rewords a summary.
 *
 * So the expectations below are the SECOND instance of the declaration, and they
 * come from outside this tree: `node bin/apq.js --help` and `node bin/apq.js <cmd>
 * --help` run against the worktree built at base `3deca1d3`, copied verbatim. They
 * discriminate every part of the rendering at once — the summary text, the padding
 * column, the over-long-name gaps, and the ORDER, which is now the registration
 * order in `CliRegistry.commands()` rather than 69 hand-placed literals.
 *
 * KILLED by: rewording any `summary()`; dropping a command from `commands()`;
 * swapping two entries of `commands()`; changing `HELP_NAME_WIDTH` or `helpGap`.
 */
@:nullSafety(Strict)
class CliHelpListingPinTest extends Test {

	/** Every line of the `Commands:` block, from the base binary, in its order. */
	private static final BASE_HELP_LISTING: Array<String> = [
		'  ast           Dump parsed AST (S-expr or JSON)',
		'  probe         AST/writer probe with inline source (no file IO)',
		'  search        Structural pattern search',
		'  refs          Symbol references (value bindings; scope-aware)',
		'  rename        Scope-correct, format-preserving symbol rename',
		'  move          Move a type declaration to another file (same package)',
		'  move-member   Move members to another type (any package if all static), rewriting call sites',
		'  extract-interface  Generate an interface from a class\'s public methods + implement it',
		'  pull-up       Move an instance member up to its superclass',
		'  push-down     Move an instance member down to a subclass',
		'  extract-superclass  Generate a superclass, pull members up into it + extend it',
		'  safe-delete   Remove a member only if unreferenced across the scope',
		'  encapsulate-field   Turn a var field into a get/set property (@:isVar)',
		'  make-final    Turn a never-reassigned var field into final',
		'  introduce-parameter-object  Fold contiguous params into one object param',
		'  symbols       List top-level type declarations across a scope (cross-file)',
		'  importers     List files importing a given module (cross-file)',
		'  declares      Declaration site(s) of one named type (ambiguity check)',
		'  lint          Run analysis checks and report violations (e.g. unused-import)',
		'  lint-diff     Multiset diff of two lint --format json snapshots (blast radius)',
		'  oracle        Typecheck the project once and record the verdict for lint',
		'  mutation-verdict  Classify one utest transcript as KILLED/SURVIVED/… for mutation-check',
		'  shard-plan    Deal a runner\'s test classes onto N APQ_TEST shards',
		'  inline        Inline a local variable into its uses',
		'  inline-method Inline a single-return function into its call sites + delete it',
		'  extract-var   Hoist an expression into a new local final',
		'  extract-constant Replace a repeated single-quoted literal with a named constant',
		'  extract-method Extract a statement run into a local function (closure)',
		'  add-param     Add a backward-compatible parameter to a function',
		'  change-sig    Reorder a function\'s parameters + call-site args',
		'  remove-param  Remove a function parameter + call-site args',
		'  add-member    Append a member to a type body (writer-formatted, canonical-gated)',
		'  add-import    Add an import / using to a module (writer-formatted, canonical-gated)',
		'  add-meta      Add one @:metadata entry to a type or member (canonical-gated)',
		'  add-element   Insert a sibling element — statement/case/list elem (--after/--before)',
		'  replace-node  Replace a node\'s source span (--select / --at; writer-formatted)',
		'  patch         Replace ONE unique fragment inside a node (old ==== new, stdin)',
		'  remove-element Remove a sibling element by cursor (inverse of add-element)',
		'  remove-import Remove an import / using by module path (backend of lint --fix)',
		'  remove-member Remove a member by --type + name (inverse of add-member)',
		'  uses          Type references (field/param/type-param positions)',
		'  meta          Annotation-on-decl shortcut',
		'  blast         Change-impact checklist (uses + refs + member-access)',
		'  lit           Leaf-name probe (string literals, identifiers — prose-in-code)',
		'  mentions      Every named-leaf occurrence (uses + refs + lit --any-kind --exact)',
		'  cases         Precise case-pattern lookup (case Ctor: / case Ctor(_): / case A | Ctor:)',
		'  callees       Transitive call tree FROM a function (approximate call graph)',
		'  callers       Transitive call tree INTO a function (approximate call graph)',
		'  reach         Shortest call path(s) --from A --to B over the call graph',
		'  clusters      Partition a type\'s members by call-edge connectivity (hub bucket + components)',
		'  stdlib-dup    Report pure functions a differential run proves equal to a stdlib call',
		'  gates         List @:fmt(trailOptParseGate/trailOptShapeGate) annotations + predicate names',
		'  diff          Structural AST diff between two files',
		'  strip         Sed-strip + parse-check (sole-blocker confirmation)',
		'  writer-equals Byte-equality check on writer output (trivia + --plain)',
		'  writer-probe  Emit trivia + plain writer outputs side-by-side',
		'  recon         Skip-parse drill — corpus sweep + locus-cluster histogram',
		'  sweep         Read corpus sweep snapshot totals + Δ vs prior',
		'  set-modifier  Flip visibility / add-remove modifiers at a cursor (no retype)',
		'  test-summary  Parse utest stdout transcript into tests/assertions/failures',
		'  rewrite       Structural search-and-replace (search-pattern metavars)',
		'  set-doc       Add/replace a declaration\'s doc-comment at a cursor',
		'  set-comment   Replace the comment at a cursor (line run or block)',
		'  comment-rewrite  Text find/replace inside comments (write-twin of lit; --regex)',
		'  self-status   List .hx files the grammar plugin cannot parse (dogfood gap)',
		'  new           Create a new module — final class / implements <iface> (canonical)',
		'  source        Emit RAW verbatim file lines (no parse; --range L:L2)',
		'  show          Alias of `source`, for a sandbox that vetoes that word',
		'  fmt           Canonicalise Haxe source (writer round-trip; --write / --list)'
	];

	/** The whole of `apq --help`, from the base binary — header and global options included. */
	private static final BASE_HELP: Array<String> = [
		'apq — anyparse query CLI',
		'',
		'Usage: apq <command> [options] <file>',
		'',
		'Commands:',
		'  ast           Dump parsed AST (S-expr or JSON)',
		'  probe         AST/writer probe with inline source (no file IO)',
		'  search        Structural pattern search',
		'  refs          Symbol references (value bindings; scope-aware)',
		'  rename        Scope-correct, format-preserving symbol rename',
		'  move          Move a type declaration to another file (same package)',
		'  move-member   Move members to another type (any package if all static), rewriting call sites',
		'  extract-interface  Generate an interface from a class\'s public methods + implement it',
		'  pull-up       Move an instance member up to its superclass',
		'  push-down     Move an instance member down to a subclass',
		'  extract-superclass  Generate a superclass, pull members up into it + extend it',
		'  safe-delete   Remove a member only if unreferenced across the scope',
		'  encapsulate-field   Turn a var field into a get/set property (@:isVar)',
		'  make-final    Turn a never-reassigned var field into final',
		'  introduce-parameter-object  Fold contiguous params into one object param',
		'  symbols       List top-level type declarations across a scope (cross-file)',
		'  importers     List files importing a given module (cross-file)',
		'  declares      Declaration site(s) of one named type (ambiguity check)',
		'  lint          Run analysis checks and report violations (e.g. unused-import)',
		'  lint-diff     Multiset diff of two lint --format json snapshots (blast radius)',
		'  oracle        Typecheck the project once and record the verdict for lint',
		'  mutation-verdict  Classify one utest transcript as KILLED/SURVIVED/… for mutation-check',
		'  shard-plan    Deal a runner\'s test classes onto N APQ_TEST shards',
		'  inline        Inline a local variable into its uses',
		'  inline-method Inline a single-return function into its call sites + delete it',
		'  extract-var   Hoist an expression into a new local final',
		'  extract-constant Replace a repeated single-quoted literal with a named constant',
		'  extract-method Extract a statement run into a local function (closure)',
		'  add-param     Add a backward-compatible parameter to a function',
		'  change-sig    Reorder a function\'s parameters + call-site args',
		'  remove-param  Remove a function parameter + call-site args',
		'  add-member    Append a member to a type body (writer-formatted, canonical-gated)',
		'  add-import    Add an import / using to a module (writer-formatted, canonical-gated)',
		'  add-meta      Add one @:metadata entry to a type or member (canonical-gated)',
		'  add-element   Insert a sibling element — statement/case/list elem (--after/--before)',
		'  replace-node  Replace a node\'s source span (--select / --at; writer-formatted)',
		'  patch         Replace ONE unique fragment inside a node (old ==== new, stdin)',
		'  remove-element Remove a sibling element by cursor (inverse of add-element)',
		'  remove-import Remove an import / using by module path (backend of lint --fix)',
		'  remove-member Remove a member by --type + name (inverse of add-member)',
		'  uses          Type references (field/param/type-param positions)',
		'  meta          Annotation-on-decl shortcut',
		'  blast         Change-impact checklist (uses + refs + member-access)',
		'  lit           Leaf-name probe (string literals, identifiers — prose-in-code)',
		'  mentions      Every named-leaf occurrence (uses + refs + lit --any-kind --exact)',
		'  cases         Precise case-pattern lookup (case Ctor: / case Ctor(_): / case A | Ctor:)',
		'  callees       Transitive call tree FROM a function (approximate call graph)',
		'  callers       Transitive call tree INTO a function (approximate call graph)',
		'  reach         Shortest call path(s) --from A --to B over the call graph',
		'  clusters      Partition a type\'s members by call-edge connectivity (hub bucket + components)',
		'  stdlib-dup    Report pure functions a differential run proves equal to a stdlib call',
		'  gates         List @:fmt(trailOptParseGate/trailOptShapeGate) annotations + predicate names',
		'  diff          Structural AST diff between two files',
		'  strip         Sed-strip + parse-check (sole-blocker confirmation)',
		'  writer-equals Byte-equality check on writer output (trivia + --plain)',
		'  writer-probe  Emit trivia + plain writer outputs side-by-side',
		'  recon         Skip-parse drill — corpus sweep + locus-cluster histogram',
		'  sweep         Read corpus sweep snapshot totals + Δ vs prior',
		'  set-modifier  Flip visibility / add-remove modifiers at a cursor (no retype)',
		'  test-summary  Parse utest stdout transcript into tests/assertions/failures',
		'  rewrite       Structural search-and-replace (search-pattern metavars)',
		'  set-doc       Add/replace a declaration\'s doc-comment at a cursor',
		'  set-comment   Replace the comment at a cursor (line run or block)',
		'  comment-rewrite  Text find/replace inside comments (write-twin of lit; --regex)',
		'  self-status   List .hx files the grammar plugin cannot parse (dogfood gap)',
		'  new           Create a new module — final class / implements <iface> (canonical)',
		'  source        Emit RAW verbatim file lines (no parse; --range L:L2)',
		'  show          Alias of `source`, for a sandbox that vetoes that word',
		'  fmt           Canonicalise Haxe source (writer round-trip; --write / --list)',
		'',
		'Global options:',
		'  --lang <name>   Pick grammar plugin (default: haxe)',
		'  -h, --help      Show help'
	];

	/** `apq refs --help`, from the base binary. */
	private static final BASE_USAGE_REFS: Array<String> = [
		'Usage: apq refs [options] <name> <file-or-dir-or-glob>...',
		'',
		'Options:',
		'  --json              Emit JSON instead of text',
		'  --decls             Filter to declarations',
		'  --reads             Filter to read references',
		'  --writes            Filter to write references (Phase 3.3)',
		'  --doc               Also emit each hit\'s leading doc-comment',
		'  --source            Also emit each hit\'s verbatim source slice — the HIT\'s own',
		'                      span, NOT a declaration group, so a decl hit prints without',
		'                      its modifiers. This is a listing snippet; copy from',
		'                      apq source --select (or apq ast --select --source) when the',
		'                      text is going back into an op.',
		'  --flat              Legacy flat `file:line:col:` format (default: grouped-by-file)',
		'  --limit <n>         Stop after n hits total (default: no limit)',
		'  --lang <name>       Grammar plugin (default: haxe)',
		'',
		'Phase 3.1: name-only matching, no lexical scope. Filters combine',
		'inclusively — passing `--decls --reads` keeps both kinds.'
	];

	/** `apq set-doc --help`, from the base binary. */
	private static final BASE_USAGE_SET_DOC: Array<String> = [
		'Usage: apq set-doc <file> (<line>[:<col>] | --select \'<sel>\' | --match \'<pattern>\') (<text> | --from-file <path> | -) [--reformat] [--write]',
		'',
		'Addressing:',
		'  <line>[:<col>]      1-based position; column omitted = the line\'s first',
		'                      non-whitespace character',
		'  --select \'<sel>\'    Selector: Kind / Kind:name / A > B (child) / A >> B',
		'                      (descendant), e.g. --select \'FnMember:walk\'; exactly one',
		'  --match \'<pattern>\' apq-search structural pattern; exactly one',
		'  --nth <k>           Pick the k-th (1-based) of several matches',
		'',
		'Options:',
		'  --from-file <path>  Read the doc text from a file instead of the argument',
		'  --reformat          Canonicalise the whole file (allow a non-canonical input)',
		'  --write             Overwrite <file> in place (default: emit to stdout)',
		'  --lang <name>       Grammar plugin (default: haxe)',
		'',
		'Add or replace the doc-comment of the addressed declaration. The text is',
		'formatted into a doc-comment block and spliced before the declaration; an',
		'existing leading doc comment is replaced, the declaration itself is left',
		'untouched. The text may be inline, --from-file, or - for stdin',
		'(heredoc-friendly, multi-line). Writer-formatted + validated.',
		'',
		'The text is PLAIN prose, one line per doc line: this op owns the ` * `',
		'gutter and adds it. A gutter you write yourself is stripped rather than',
		'doubled, and only the two spellings the writer emits count as one, so a',
		'`* bullet` and an indented code sample keep what they were given.'
	];

	/** `apq safe-delete --help`, from the base binary. */
	private static final BASE_USAGE_SAFE_DELETE: Array<String> = [
		'Usage: apq safe-delete <srcFile> <member> --scope <dir> [options]',
		'',
		'Remove a member only when no reference to it survives under the scope —',
		'the guarded, cross-file, any-visibility form of remove-member. Any',
		'x.member field access or bare in-type reference blocks the deletion and',
		'is listed. Self-references (recursion) do not count.',
		'',
		'Options:',
		'  --type <Src>   Declaring type name (default: the file\'s main type)',
		'  --scope <dir>  Reference-check scope (dir/glob; srcFile auto-included)',
		'  --reformat     Canonicalise the file if it has drifted',
		'  --write        Apply in place (default: print the rewritten file)',
		'  --lang <name>  Grammar plugin (default haxe)'
	];

	/** `apq diff --help`, from the base binary. */
	private static final BASE_USAGE_DIFF: Array<String> = [
		'Usage: apq diff [options] <a> <b>',
		'',
		'Options:',
		'  --flat              Legacy flat `file:line:col:` per-hit format (default: paired-header)',
		'  --limit <n>         Stop after n hits (default: no limit)',
		'  --lang <name>       Grammar plugin (default: haxe)',
		'',
		'Structural AST diff: walks both trees pairwise and reports nodes',
		'where kind / name slot / child count diverges. No LCS realignment',
		'— mid-list inserts cascade the tail as `differs`. Useful for strip-',
		'test reconciliation when a byte diff is whitespace-noisy.'
	];

	/** `apq recon --help`, from the base binary. */
	private static final BASE_USAGE_RECON: Array<String> = [
		'Usage: apq recon [<dir>] [--top N | --all] [--cluster <substr> [--source]]',
		'                 [--predict-strip --replace <pat> --with <repl> ... [--source]]',
		'                 [--probe <file>]',
		'',
		'Sweep mode: walks every .hxtest under <dir> (section-2 auto-extracted),',
		'runs the trivia parser, clusters failures by normalised forward-locus,',
		'and prints SKIP lines + histogram. Default <dir> is',
		'$$ANYPARSE_HXFORMAT_FORK/test/testcases when the env var is set.',
		'',
		'Options:',
		'  --lang <name>           Grammar plugin (default: haxe)',
		'  --top N                 Show top N clusters (default: 30)',
		'  --all                   Show every cluster',
		'  --cluster <key>         Drill into ONE cluster: full path list instead of',
		'                          histogram. EXACT match against the cluster key',
		'                          shown in the histogram (with \\n / \\t escapes).',
		'                          0-match exits non-zero with top keys for ref.',
		'  --no-target-cluster <expected-msg>',
		'                          With --predict-relax: drill into ONE bucket of the',
		'                          footer NO TARGET breakdown — print every fixture',
		'                          whose predict-relax outcome is NoTarget with',
		'                          message == <expected-msg>. EXACT match against the',
		'                          key shown in the footer histogram. Bridges the',
		'                          footer aggregate to the file list — --cluster uses',
		'                          a different namespace (forward-locus on raw bytes).',
		'                          0-match exits non-zero with top NO TARGET keys.',
		'                          Mutex with --cluster / --probe.',
		'  --source                With --cluster, append a windowed source slice',
		'                          around the fail-locus for each path (L±3).',
		'                          With --predict-strip, also emits the window for',
		'                          each STILL FAIL entry around the NEW fail-locus',
		'                          (the moved-locus payload). With --predict-relax,',
		'                          emits the window for STILL FAIL (around NEW locus',
		'                          in patched source) and for NO TARGET entries in',
		'                          drill/probe modes (around the ORIGINAL fail-locus,',
		'                          which has no patch). Sweep-mode NO TARGET stays',
		'                          collapsed into the footer histogram. Usage error',
		'                          outside these modes.',
		'  --predict-strip         Apply substitutions to each skip-parse source',
		'                          and retry; print PREDICT UNBLOCK / STILL FAIL /',
		'                          NO MATCH per file. Requires --replace/--with or',
		'                          --delete; combinable with --cluster.',
		'  --replace <pat> --with <repl>',
		'                          Substitution pair (with --predict-strip; repeatable).',
		'  --delete <pat>          Shortcut for --replace <pat> --with "".',
		'  --regex                 Treat --replace / --delete patterns as EReg patterns',
		'                          (global, applies to every match) instead of literal',
		'                          substrings. Requires --predict-strip. One regex',
		'                          covers every site of a construct in the corpus.',
		'  --candidates <regex>    Cross-cluster enumeration: walk skip-parse fixtures,',
		'                          print `<path> :: N matches` for every file with ≥1',
		'                          regex hit (sorted by count desc) + summary. Use when',
		'                          the histogram clusters by exact forward-locus and a',
		'                          construct lives in differently-shaped multi-blocker',
		'                          fixtures. Mutually exclusive with --predict-strip /',
		'                          --cluster / --probe / --regression-probe.',
		'  --probe <file>          Single-file probe instead of sweep. Composes with',
		'                          --predict-strip: applies substitutions to the file and',
		'                          retries the parse, printing PREDICT UNBLOCK / STILL',
		'                          FAIL / NO MATCH + per-pattern totals + typo guard',
		'                          (same shape as sweep mode).',
		'  --regression-probe      Diff current corpus parse OK / SKIP_PARSE state against',
		'                          the prior sweep snapshot (`bin/.last-sweep.json`).',
		'                          Reports every fixture whose parse status FLIPPED since',
		'                          the snapshot — REGRESSED (was PASS / FAIL / SKIP_WRITE,',
		'                          now skip-parse) and UNBLOCKED (was SKIP_PARSE, now',
		'                          parses). Cheap pre-edit / post-edit sanity check —',
		'                          only runs the trivia parse, no writer / no expected-',
		'                          bytes diff. Non-zero exit when any regression found.',
		'                          Mutually exclusive with --probe / --predict-strip /',
		'                          --cluster.',
		'  --permissive-construct  Field-optionalization predictor for Slice 40\'s',
		'                          `@:optional + @:lead + @:trail` mechanism. Walks every',
		'                          `mandatory-ref-lead-trail` candidate from `apq gates',
		'                          --mechanism mandatory-ref-lead-trail`, strips the',
		'                          `<lead>...<trail>` bracket-pair from each skip-parse',
		'                          fixture, re-parses, and aggregates UNBLOCK / STILL FAIL',
		'                          / NO MATCH per candidate. THE pre-edit upper-bound',
		'                          view of which field-optionalization would unblock',
		'                          which fixtures. Mutually exclusive with every other',
		'                          recon mode.',
		'  --writer-equals         After --probe PARSE OK, also run writer round-trip +',
		'                          byte-equality check vs the fixture\'s expected section',
		'                          (or `--expected <path>` for plain .hx). Prints WRITER',
		'                          PASS / FAIL upfront so you see whether the slice would',
		'                          yield +1 PASS or skip→fail without running the corpus',
		'                          sweep. Incompatible with --predict-strip / --predict-',
		'                          relax (their patched source diverges from expected by',
		'                          construction). Requires --probe.',
		'  --writer-equals-plain   Same as --writer-equals but routes through the PLAIN',
		'                          (non-trivia) pipeline (HxModuleParser → HxModuleWriter).',
		'  --expected <path>       Override the expected-bytes source (default: .hxtest',
		'                          section 3, or the input itself for raw .hx). Requires',
		'                          --writer-equals.',
		'  -h, --help              Show this help.'
	];

	/**
	 * The listing the registry renders IS the listing the hand-written block printed.
	 *
	 * One assertion over the whole block rather than one per command, so a swapped
	 * pair fails as loudly as a reworded line: order is part of the expectation.
	 */
	public function testTheRenderedListingIsTheBaseBinarysBytes(): Void {
		final rendered: Array<String> = [
			for (command in CliRegistry.commands()) CliRegistry.helpLine(command.name()).rtrim()
		];
		Assert.same(BASE_HELP_LISTING, rendered, 'apq --help no longer lists what the pre-seam binary listed');
	}

	/** …and the page around it, so the header and the global-options block are pinned too. */
	public function testTheWholeHelpPageIsTheBaseBinarysBytes(): Void {
		#if nodejs
		final printed: Array<String> = CliFixture.captureStdout(() -> Cli.run(['--help'])).split('\n');
		if (printed.length > 0 && printed[printed.length - 1] == '') printed.pop();
		Assert.same(BASE_HELP, printed, 'apq --help is no longer byte-identical to the pre-seam binary');
		#else
		Assert.pass();
		#end
	}

	/**
	 * One usage page per command SHAPE, byte for byte.
	 *
	 * `refs` is a walk, `set-doc` an addressed single-file edit, `safe-delete` a
	 * `--scope` edit, `diff` a read-only non-walker, and `recon` the sys-guarded
	 * family whose `usage()` sits inside its own `#if`. The five between them exercise
	 * every shape the wave had to reproduce.
	 */
	public function testTheUsagePagesAreTheBaseBinarysBytes(): Void {
		#if nodejs
		assertPage(BASE_USAGE_REFS, 'refs');
		assertPage(BASE_USAGE_SET_DOC, 'set-doc');
		assertPage(BASE_USAGE_SAFE_DELETE, 'safe-delete');
		assertPage(BASE_USAGE_DIFF, 'diff');
		assertPage(BASE_USAGE_RECON, 'recon');
		#else
		Assert.pass();
		#end
	}

	/**
	 * Every registered command is REACHABLE through `dispatch`, and answers its own page.
	 *
	 * The listing pin above proves a command is described; this proves it can be run.
	 * Dropping one from `commands()` turns its `--help` into the unknown-subcommand
	 * path — exit 2 and the global listing — which is what this catches and the
	 * listing pin catches from the other side.
	 */
	public function testEveryRegisteredCommandIsReachableThroughDispatch(): Void {
		#if nodejs
		for (command in CliRegistry.commands()) {
			var exit: Int = -1;
			final page: String = CliFixture.captureStdout(() -> exit = Cli.run([command.name(), '--help']));
			Assert.equals(0, exit, '"${command.name()} --help" did not reach the command');
			Assert.isTrue(page.length > 0, '"${command.name()} --help" printed nothing');
			Assert.isTrue(
				page.indexOf('Commands:') < 0, '"${command.name()} --help" printed the global listing, so dispatch did not find it'
			);
		}
		#else
		Assert.pass();
		#end
	}

	/** The registry owns every command the listing names, and no more. */
	public function testTheRegistryHoldsExactlyTheListedCommands(): Void {
		final names: Array<String> = [for (command in CliRegistry.commands()) command.name()];
		final listed: Array<String> = [
			for (line in BASE_HELP_LISTING) line.substring(2, line.indexOf(' ', 2))
		];
		Assert.same(listed, names, 'the registry and the pre-seam listing name the same commands, in the same order');
	}

	#if nodejs
	private function assertPage(expected: Array<String>, command: String): Void {
		final printed: Array<String> = CliFixture.captureStdout(() -> Cli.run([command, '--help'])).split('\n');
		if (printed.length > 0 && printed[printed.length - 1] == '') printed.pop();
		Assert.same(expected, printed, 'apq $command --help drifted from the pre-seam binary');
	}
	#end

}
