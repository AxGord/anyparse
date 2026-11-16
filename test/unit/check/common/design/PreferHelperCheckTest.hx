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

	/**
	 * Marked helpers over a function or a closing return: a descent returning the first answer of a function parameter, two
	 * pushes whose second value is read after the first push, and a body that also reads its function parameter as a value.
	 */
	private static final ARRAYS: String = 'package util;\n\nclass Arrays {\n\t@:preferHelper\n'
		+ '\tpublic static function findMap<T, R>(xs:Iterable<T>, f:T->Null<R>):Null<R> {\n\t\tfor (x in xs) {\n'
		+ '\t\t\tfinal y:Null<R> = f(x);\n\t\t\tif (y != null) return y;\n\t\t}\n\t\treturn null;\n\t}\n\n\t@:preferHelper\n'
		+ '\tpublic static function pushTwo<T>(xs:Array<T>, a:T, b:T):Void {\n\t\txs.push(a);\n\t\txs.push(b);\n\t}\n\n\t@:preferHelper\n'
		+ '\tpublic static function pushDouble(xs:Array<Int>, a:Int):Void {\n\t\txs.push(a + a);\n\t}\n\n\t@:preferHelper\n\tpublic static '
		+ 'function each<T>(xs:Array<T>, f:T->Void, fs:Array<T->Void>):Void {\n\t\tfor (x in xs) f(x);\n\t\tfs.push(f);\n\t}\n}\n';

	private static final CONFIG: String = '{"rules":{"prefer-helper":{"marker":"@:preferHelper"}}}';
	private static final DESCENT: String =
		'for (c in xs) {\n\t\t\tfinal found = name(c);\n\t\t\tif (found != null) return found;\n\t\t}\n\t\treturn null;';
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

	/**
	 * `m[key()]` runs `key()` twice in the copy and once in the call. Held twice: `k` is also read after the body's first
	 * effect, so the late-hole gate declines it as well.
	 */
	@:pin('guard')
	public function testAnImpureHoleReadTwiceDeclines(): Void {
		Assert.equals(0, violationsOf(user('final ys = m[key()] ?? [];\n\t\tys.push(v);\n\t\tm[key()] = ys;')).length);
	}

	/**
	 * The call would run `key()` before the body's first statement reads `m[k]`, where the copy runs it after. Held twice:
	 * `v` is read after the body's first effect, so the late-hole gate declines it as well.
	 */
	@:pin('guard')
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

	/** The loop's call of the function parameter is the hole: the site's expression in its place becomes a lambda. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-NO-LAMBDA')
	public function testAFindMapDescentBecomesAReturnOfTheHelperCall(): Void {
		final vs: Array<Violation> = violationsOf(finder(DESCENT));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('util.Arrays.findMap(xs, f)') != -1, vs[0].message);
		final out: String = fixResultOf(finder(DESCENT));
		Assert.isTrue(out.indexOf('\t\treturn Arrays.findMap(xs, c -> name(c));\n\t}') != -1, out);
		Assert.isTrue(out.indexOf('import util.Arrays;\n') != -1, out);
	}

	/** A second statement before the return, or a closing return of another value, is no copy of the descent. */
	@:pin('guard')
	public function testANearMissOfTheDescentDeclines(): Void {
		Assert.equals(
			0,
			violationsOf(finder(
				'for (c in xs) {\n\t\t\tfinal a = c + 1;\n\t\t\tfinal f = name(a);\n\t\t\tif (f != null) return f;\n\t\t}\n\t\treturn null;'
			)).length
		);
		Assert.equals(
			0,
			violationsOf(finder('for (c in xs) {\n\t\t\tfinal f = name(c);\n\t\t\tif (f != null) return f;\n\t\t}\n\t\treturn \'\';'))
				.length
		);
	}

	/** `b` is read after the first push: the copy reads `xs.length` there, the call before it, so only a plain value may bind it. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-LATE-PLAIN')
	public function testALateHoleBindsAPlainValueOnly(): Void {
		Assert.equals(0, violationsOf(finder('xs.push(v);\n\t\txs.push(xs.length);\n\t\treturn null;')).length);
		Assert.equals('Arrays.pushTwo(xs, xs.length, v);', onlyEditText(finder('xs.push(xs.length);\n\t\txs.push(v);\n\t\treturn null;')));
		Assert.equals('Arrays.pushTwo(xs, v, 1);', onlyEditText(finder('xs.push(v);\n\t\txs.push(1);\n\t\treturn null;')));
	}

	/** `a` is read twice before the push: the copy runs `n()` twice, the call once, so only a pure value may bind it. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-NO-PURITY')
	public function testAnImpureHoleReadTwiceBeforeAnyEffectDeclines(): Void {
		Assert.equals(0, violationsOf(finder('xs.push(n() + n());\n\t\treturn null;')).length);
		Assert.equals('Arrays.pushDouble(xs, v);', onlyEditText(finder('xs.push(v + v);\n\t\treturn null;')));
	}

	/** A function parameter is a hole only where the body calls it; one it also reads as a value makes no template. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-MIXED-READ')
	public function testAFunctionParameterReadAsAValueIsNoTemplate(): Void {
		final notes: Array<ConfigNote> = [];
		Assert.equals(0, violationsOf(finder('return null;'), null, notes).length);
		final said: String = notes.map(n -> n.message).join('');
		Assert.isTrue(said.indexOf('util.Arrays.each is no template: it reads f other than by calling it') != -1, said);
	}

	/** The copy's `return` inside the call's expression leaves the site's function; in the lambda it would leave only the lambda. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-LAMBDA-JUMP')
	public function testALambdaHoleHoldingAReturnDeclines(): Void {
		Assert.equals(
			0,
			violationsOf(finder(
				'for (c in xs) {\n\t\t\tfinal found = switch c {\n\t\t\t\tcase 0: return null;\n\t\t\t\tcase _: name(c);\n\t\t\t}\n'
				+ '\t\t\tif (found != null) return found;\n\t\t}\n\t\treturn null;'
			)).length
		);
	}

	/** A helper ending in a value return that holds a function of its own is no template: that function's return leaves it alone. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-NESTED-FUNCTION')
	public function testAReturningHelperHoldingAFunctionIsNoTemplate(): Void {
		final helpers: String = 'package util;\n\nclass Groups {\n\t@:preferHelper\n'
			+ '\tpublic static function firstPlus(xs:Array<Int>, v:Int):Int {\n'
			+ '\t\tfinal plus = function(x:Int):Int {\n\t\t\treturn x + v;\n\t\t};\n\t\treturn plus(xs[0]);\n\t}\n}\n';
		final notes: Array<ConfigNote> = [];
		Assert.equals(0, violationsOf(user('xs.push(x);', helpers), null, notes).length);
		final said: String = notes.map(n -> n.message).join('');
		Assert.isTrue(
			said.indexOf('util.Groups.firstPlus is no template: it holds a function, whose return would leave that function') != -1, said
		);
	}

	public function testNoMarkerIsInert(): Void {
		Assert.equals(0, violationsOf(user(PUSH), '{}').length);
		Assert.equals('needs-config', new PreferHelper().skipReason('app/User.hx', LintConfig.parse('{}')));
		Assert.isNull(new PreferHelper().skipReason('app/User.hx', LintConfig.parse(CONFIG)));
	}

	/** A finder whose body is `body`, with the function and closing-return helpers and a std `Array` its reads resolve to. */
	private function finder(body: String): Array<{ file: String, source: String }> {
		final source: String = 'package app;\n\nclass Finder {\n\tpublic function new() {}\n\n'
			+ '\tfunction g(xs:Array<Int>, v:Int):Null<String> {\n\t\t$body\n\t}\n\n\tfunction name(c:Int):Null<String> {'
			+ '\n\t\treturn c > 1 ? \'n\' : null;\n\t}\n\n\tfunction n():Int {\n\t\treturn 1;\n\t}\n}\n';
		return [
			{ file: 'app/Finder.hx', source: source },
			{ file: 'util/Arrays.hx', source: ARRAYS },
			{ file: 'Array.hx', source: 'extern class Array<T> { var length(default, null):Int; function push(x:T):Int; }' }
		];
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
