package unit.check.common.design;

import anyparse.check.Check.FixEdit;
import anyparse.check.LintConfig;
import anyparse.check.Severity;
import anyparse.check.common.design.PreferHelper;
import anyparse.query.CanonicalEdit;

/**
 * The `prefer-helper` check: a run of statements repeating the body of a helper carrying the configured marker, its
 * parameters and top-level locals as holes, becomes a call of that helper (`final ys = m[k] ?? []; ys.push(v); m[k] = ys;`
 * → `Groups.push(m, k, v);`). A near miss with a statement between the copy's own, a local the code after the copy still
 * reads or an argument reads, a hole that binds an impure value, a comment the call would drop and the helper's own body
 * are each pinned by a fixture of their own, and so is a marked helper that is no template.
 */
class PreferHelperCheckTest extends Test {

	/** The marked helpers: a three-statement template with a local, and a one-statement template. */
	private static final GROUPS: String = 'package util;\n\nclass Groups {\n\t@:preferHelper\n'
		+ '\tpublic static function push<K, V>(m:Map<K, Array<V>>, k:K, v:V):Void {\n'
		+ '\t\tfinal xs:Array<V> = m[k] ?? [];\n\t\txs.push(v);\n\t\tm[k] = xs;\n\t}\n\n\t@:preferHelper\n'
		+ '\tpublic static function pushUnique<T>(xs:Array<T>, x:T):Void {\n\t\tif (!xs.contains(x)) xs.push(x);\n\t}\n}\n';

	/** Marked helpers that are no template: one reads a name that is no parameter, one leaves the function early. */
	private static final REFUSED: String = 'package util;\n\nclass Groups {\n\tstatic final LIMIT:Int = 3;\n\n\t@:preferHelper\n'
		+ '\tpublic static function cap(xs:Array<Int>):Void {\n\t\txs.push(LIMIT);\n\t}\n\n\t@:preferHelper\n'
		+ '\tpublic static function pushFirst<T>(xs:Array<T>, x:T):Void {\n\t\tif (xs.length > 0) return;\n\t\txs.push(x);\n\t}\n}\n';

	private static final CONFIG: String = '{"rules":{"prefer-helper":{"marker":"@:preferHelper"}}}';
	private static final PUSH: String = 'final ys = m[k] ?? [];\n\t\tys.push(v);\n\t\tm[k] = ys;';

	@:pin('control')
	@:killer('M-PREFER-HELPER-NO-SITE')
	public function testACopyBecomesTheHelperCall(): Void {
		final vs: Array<Violation> = violationsOf(user(PUSH));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-helper', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('util.Groups.push(m, k, v)') != -1, vs[0].message);
		final out: String = fixResultOf(user(PUSH));
		Assert.isTrue(out.indexOf('\t\tGroups.push(m, k, v);\n') != -1, out);
		Assert.isTrue(out.indexOf('import util.Groups;\n') != -1, out);
		Assert.isTrue(out.indexOf('ys.push') == -1, out);
	}

	public function testAOneStatementCopyBecomesTheHelperCall(): Void {
		Assert.equals('Groups.pushUnique(xs, x);', onlyEditText(user('if (!xs.contains(x)) xs.push(x);')));
	}

	/** The local is a hole and its written type is not part of the pattern. */
	public function testAnAnnotatedLocalUnderAnotherNameMatches(): Void {
		Assert.equals(
			'Groups.push(m, k, v);', onlyEditText(user('final group:Array<Int> = m[k] ?? [];\n\t\tgroup.push(v);\n\t\tm[k] = group;'))
		);
	}

	/** The copy's statements are adjacent in the body's order; one between them is no match. */
	@:pin('guard')
	public function testAnExtraStatementBetweenDeclines(): Void {
		Assert.equals(0, violationsOf(user('final ys = m[k] ?? [];\n\t\tys.push(v);\n\t\tx = v;\n\t\tm[k] = ys;')).length);
	}

	/** The call no longer declares `ys`, so a later read of it would bind to nothing. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-USED-LATER')
	public function testALocalReadAfterTheCopyDeclines(): Void {
		Assert.equals(0, violationsOf(user('$PUSH\n\t\tx = ys.length;')).length);
	}

	/** `m[key()]` runs `key()` twice in the copy and once in the call. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-NO-PURITY')
	public function testAnImpureHoleReadTwiceDeclines(): Void {
		Assert.equals(0, violationsOf(user('final ys = m[key()] ?? [];\n\t\tys.push(v);\n\t\tm[key()] = ys;')).length);
	}

	/** The call would run `key()` before the body's first statement reads `m[k]`, where the copy runs it after. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-NO-PURITY')
	public function testAHoleReadOnceThatBindsAnImpureValueDeclines(): Void {
		Assert.equals(0, violationsOf(user('final ys = m[k] ?? [];\n\t\tys.push(key().length);\n\t\tm[k] = ys;')).length);
	}

	/** The call no longer declares `ys`, so an argument reading it would bind to nothing. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-ARG-READS-LOCAL')
	public function testAnArgumentReadingTheCopysOwnLocalDeclines(): Void {
		Assert.equals(0, violationsOf(user('final ys = m[k] ?? [];\n\t\tys.push(ys);\n\t\tm[k] = ys;')).length);
	}

	/** `LIMIT` is no hole: a site's `LIMIT` may be another value, so `cap` is no template and says why. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-FOREIGN-NAME')
	public function testAHelperReadingAForeignNameIsNoTemplate(): Void {
		final notes: Array<ConfigNote> = [];
		Assert.equals(0, violationsOf(user('xs.push(LIMIT);', REFUSED), null, notes).length);
		final said: String = notes.map(n -> n.message).join('');
		Assert.isTrue(said.indexOf('util.Groups.cap is no template: it reads LIMIT') != -1, said);
	}

	/** A copy's `return` leaves the site's own function, the call's only the helper. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-EARLY-EXIT')
	public function testAHelperThatReturnsEarlyIsNoTemplate(): Void {
		final notes: Array<ConfigNote> = [];
		Assert.equals(0, violationsOf(user('if (xs.length > 0) return;\n\t\txs.push(x);', REFUSED), null, notes).length);
		final said: String = notes.map(n -> n.message).join('');
		Assert.isTrue(said.indexOf('util.Groups.pushFirst is no template: it leaves the function early') != -1, said);
	}

	public function testACommentTheCallWouldDropDeclines(): Void {
		Assert.equals(0, violationsOf(user('final ys = m[k] ?? []; // start\n\t\tys.push(v);\n\t\tm[k] = ys;')).length);
		Assert.equals(0, violationsOf(user('$PUSH // stored')).length);
	}

	@:pin('control')
	@:killer('M-PREFER-HELPER-OWN-BODY')
	public function testTheHelpersOwnBodyIsNeverASite(): Void {
		Assert.equals(0, violationsOf(user('x = v;')).length);
	}

	public function testNoMarkerIsInert(): Void {
		Assert.equals(0, violationsOf(user(PUSH), '{}').length);
		Assert.equals('needs-config', new PreferHelper().skipReason('app/User.hx', LintConfig.parse('{}')));
		Assert.isNull(new PreferHelper().skipReason('app/User.hx', LintConfig.parse(CONFIG)));
	}

	/** The fixture set: the user file first (its findings are the ones fixed), then the helpers. */
	private function user(body: String, ?helpers: String): Array<{ file: String, source: String }> {
		final source: String = 'package app;\n\nclass User {\n\tpublic function new() {}\n\n'
			+ '\tfunction f(m:Map<String, Array<Int>>, k:String, v:Int, xs:Array<Int>, x:Int):Void {\n\t\t$body\n\t}\n\n'
			+ '\tfunction key():String {\n\t\treturn \'k\';\n\t}\n}\n';
		return [
			{ file: 'app/User.hx', source: source },
			{ file: 'util/Groups.hx', source: helpers ?? GROUPS }
		];
	}

	private function check(config: String): PreferHelper {
		final rule: PreferHelper = new PreferHelper();
		rule.setConfigResolver(resolver(config));
		return rule;
	}

	/** `notes`, when given, collects the rule's config diagnostics. */
	private function violationsOf(
		files: Array<{ file: String, source: String }>, ?config: String, ?notes: Array<ConfigNote>
	): Array<Violation> {
		final rule: PreferHelper = check(config ?? CONFIG);
		rule.setConfigNotes(notes);
		return CheckFixture.violationsIn(rule, files, null, resolver(config ?? CONFIG));
	}

	private function editsOf(files: Array<{ file: String, source: String }>): Array<FixEdit> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final rule: PreferHelper = check(CONFIG);
		final own: Array<Violation> = CheckFixture.violationsIn(rule, files, plugin, resolver(CONFIG)).filter(v -> v.file == files[0].file);
		return own.length == 0 ? [] : rule.fix(files[0].source, own, plugin, CheckFixture.index(files, plugin));
	}

	/** The call edit alone, without the import riding on it. */
	private function onlyEditText(files: Array<{ file: String, source: String }>): String {
		final calls: Array<FixEdit> = editsOf(files).filter(e -> e.text.indexOf('import ') == -1);
		Assert.equals(1, calls.length);
		return calls.length == 1 ? calls[0].text : '';
	}

	/** `files[0]` with its own findings fixed, canonicalised WITHOUT reformatting, exactly as `apq lint --fix` writes it. */
	private function fixResultOf(files: Array<{ file: String, source: String }>): String {
		switch CanonicalEdit.canonicalize(files[0].source, editsOf(files), false, new HaxeQueryPlugin()) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
		return '';
	}

	/** `config` as the run's per-file resolver, which `Linter.collect` also asks the file gate through. */
	private static function resolver(config: String): (String) -> LintConfig {
		return _ -> LintConfig.parse(config);
	}

}
