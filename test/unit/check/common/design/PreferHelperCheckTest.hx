package unit.check.common.design;

import anyparse.check.Check.FixEdit;
import anyparse.check.Check.GroupedEdit;
import anyparse.check.LintConfig;
import anyparse.check.Severity;
import anyparse.check.SourceEntry;
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

	/** A marked helper named after a member `Array` declares, so a call on an array reads as the member, not as the helper. */
	private static final SHADOWED: String = 'package util;\n\nclass Groups {\n\t@:preferHelper\n'
		+ '\tpublic static function push<T>(xs:Array<T>, x:T):Void {\n\t\tif (!xs.contains(x)) xs.push(x);\n\t}\n}\n';

	/** The std `Array` the receiver resolves to: no `pushUnique`, a `push`. */
	private static final ARRAY: String =
		'extern class Array<T> { var length(default, null):Int; function push(x:T):Int; function contains(x:T):Bool; }';

	/** `util.Groups` spelled as an extension, as `prefer-static-extension` is configured to. */
	private static final EXT: String =
		'{"rules":{"prefer-helper":{"marker":"@:preferHelper"},"prefer-static-extension":{"types":["util.Groups"]}}}';

	private static final UNIQUE: String = 'if (!xs.contains(x)) xs.push(x);';

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

	/** The import a rewrite needs shares that rewrite's bisect group, so the oracle's revert of the rewrite takes the import along. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-IMPORT-UNGROUPED')
	public function testTheImportSharesTheGroupOfItsRewrite(): Void {
		final edits: Array<GroupedEdit> = groupedEditsOf(user(PUSH));
		final imports: Array<GroupedEdit> = edits.filter(e -> e.text.indexOf('import ') != -1);
		final calls: Array<GroupedEdit> = edits.filter(e -> e.text.indexOf('import ') == -1);
		Assert.equals(1, imports.length);
		Assert.equals(1, calls.length);
		if (imports.length != 1 || calls.length != 1) return;
		Assert.notNull(imports[0].group);
		Assert.equals(imports[0].group, calls[0].group);
	}

	/** A rewrite whose helper type the file already imports needs no import edit, so it stays a bisect unit of its own. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-IMPORTED-GROUPED')
	public function testARewriteOfAnImportedHelperIsItsOwnGroup(): Void {
		final files: Array<{ file: String, source: String }> = user(PUSH);
		final imported: Array<{ file: String, source: String }> = [
			{ file: files[0].file, source: files[0].source.replace('package app;\n', 'package app;\n\nimport util.Groups;\n') }
		].concat(files.slice(1));
		final edits: Array<GroupedEdit> = groupedEditsOf(imported);
		Assert.equals(1, edits.length);
		if (edits.length != 1) return;
		Assert.equals('Groups.push(m, k, v);', edits[0].text);
		Assert.isNull(edits[0].group);
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

	/** The call of a helper of a module the project spells as an extension becomes `recv.member(…)`, and the file gains its `using`. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-EXT-OFF')
	public function testAListedModuleIsCalledAsAnExtension(): Void {
		final vs: Array<Violation> = violationsOf(typed(UNIQUE), EXT);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('as `xs.pushUnique(x)`') != -1, vs[0].message);
		final out: String = fixResultOf(typed(UNIQUE), EXT);
		Assert.isTrue(out.indexOf('\t\txs.pushUnique(x);\n') != -1, out);
		Assert.isTrue(out.indexOf('using util.Groups;\n') != -1, out);
		Assert.isTrue(out.indexOf('import util.Groups') == -1, out);
		Assert.isTrue(out.indexOf('Groups.pushUnique') == -1, out);
	}

	/** The `using` shares the group of its rewrite, so the oracle's revert of the rewrite takes the declaration along. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-USING-UNGROUPED')
	public function testTheUsingSharesTheGroupOfItsRewrite(): Void {
		final edits: Array<GroupedEdit> = groupedEditsOf(typed(UNIQUE), EXT);
		final usings: Array<GroupedEdit> = edits.filter(e -> e.text.indexOf('using ') != -1);
		final calls: Array<GroupedEdit> = edits.filter(e -> e.text.indexOf('using ') == -1);
		Assert.equals(2, edits.length);
		Assert.equals(1, usings.length);
		Assert.equals(1, calls.length);
		if (usings.length != 1 || calls.length != 1) return;
		Assert.notNull(usings[0].group);
		Assert.equals(usings[0].group, calls[0].group);
	}

	/** A `using` the file already declares is no edit, so the rewrite stays a bisect unit of its own. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-USING-ALWAYS')
	public function testADeclaredUsingAddsNoEdit(): Void {
		final files: Array<SourceEntry> = typed(UNIQUE);
		final declared: Array<SourceEntry> = [
			{ file: files[0].file, source: files[0].source.replace('package app;\n', 'package app;\n\nusing util.Groups;\n') }
		].concat(files.slice(1));
		final edits: Array<GroupedEdit> = groupedEditsOf(declared, EXT);
		Assert.equals(1, edits.length);
		if (edits.length != 1) return;
		Assert.equals('xs.pushUnique(x);', edits[0].text);
		Assert.isNull(edits[0].group);
	}

	/** A helper of a module the project does not list keeps the qualified call and its import, whatever else it lists. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-UNLISTED-EXT')
	public function testAModuleNotListedStaysQualified(): Void {
		final files: Array<SourceEntry> = typed(UNIQUE).concat([{ file: 'util/Arrays.hx', source: ARRAYS }]);
		final config: String = EXT.replace('util.Groups', 'util.Arrays');
		final vs: Array<Violation> = violationsOf(files, config);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('as `') == -1 && vs[0].message.indexOf('qualified') == -1, vs[0].message);
		final out: String = fixResultOf(files, config);
		Assert.isTrue(out.indexOf('\t\tGroups.pushUnique(xs, x);\n') != -1, out);
		Assert.isTrue(out.indexOf('import util.Groups;\n') != -1, out);
		Assert.isTrue(out.indexOf('using util') == -1, out);
	}

	/** An instance member of the receiver's type outranks a static extension, so the call stays qualified and the finding says why. */
	@:pin('control')
	@:killer('M-RECEIVER-SHADOW-MEMBER')
	public function testAReceiverMemberOfTheNameKeepsTheQualifiedCall(): Void {
		final vs: Array<Violation> = violationsOf(typed(UNIQUE, SHADOWED), EXT);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('qualified: the receiver\'s type declares a member `push`') != -1, vs[0].message);
		final out: String = fixResultOf(typed(UNIQUE, SHADOWED), EXT);
		Assert.isTrue(out.indexOf('\t\tGroups.push(xs, x);\n') != -1, out);
		Assert.isTrue(out.indexOf('import util.Groups;\n') != -1, out);
		Assert.isTrue(out.indexOf('using util') == -1, out);
	}

	/** A receiver the index cannot type may declare the name, so the call stays qualified. */
	@:pin('control')
	@:killer('M-RECEIVER-SHADOW-LACKS')
	public function testAnUnresolvedReceiverKeepsTheQualifiedCall(): Void {
		final vs: Array<Violation> = violationsOf(user(UNIQUE), EXT);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('qualified: the receiver\'s type') != -1, vs[0].message);
		final out: String = fixResultOf(user(UNIQUE), EXT);
		Assert.isTrue(out.indexOf('\t\tGroups.pushUnique(xs, x);\n') != -1, out);
	}

	/** A project that forbids inserting a `using` gets the qualified call where the file declares none. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-ADDUSING-OFF')
	public function testAddUsingOffKeepsTheQualifiedCall(): Void {
		final config: String = EXT.replace('"types"', '"addUsing":false,"types"');
		final vs: Array<Violation> = violationsOf(typed(UNIQUE), config);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('addUsing is off') != -1, vs[0].message);
		Assert.isTrue(fixResultOf(typed(UNIQUE), config).indexOf('\t\tGroups.pushUnique(xs, x);\n') != -1);
	}

	/** A `using` only a `#if` region declares does not bind the call outside it, and a second one would change the region's own calls. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-GUARDED-USING')
	public function testAUsingOnlyARegionDeclaresKeepsTheQualifiedCall(): Void {
		final files: Array<SourceEntry> = typed(UNIQUE);
		final guarded: Array<SourceEntry> = [
			{
				file: files[0].file,
				source: files[0].source.replace('package app;\n', 'package app;\n\n#if (sys || nodejs)\nusing util.Groups;\n#end\n')
			}
		].concat(files.slice(1));
		final vs: Array<Violation> = violationsOf(guarded, EXT);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('only inside a `#if` region') != -1, vs[0].message);
		final texts: Array<String> = editsOf(guarded, EXT).map(e -> e.text);
		Assert.isTrue(texts.filter(t -> t.endsWith('Groups.pushUnique(xs, x);')).length == 1, texts.join(' | '));
		Assert.isTrue(texts.filter(t -> t.indexOf('using ') != -1).length == 0, texts.join(' | '));
	}

	/** A listed and an unlisted module in one body: a `using` for the extension call, an `import` for the qualified one, in two groups. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-USING-GROUP-COLLIDES')
	public function testAListedAndAnUnlistedSiteEachKeepTheirOwnGroup(): Void {
		final files: Array<SourceEntry> = typed('if (!xs.contains(x)) xs.push(x);\n\t\txs.push(1);\n\t\txs.push(2);')
			.concat([{ file: 'util/Arrays.hx', source: ARRAYS }]);
		final edits: Array<GroupedEdit> = groupedEditsOf(files, EXT);
		final usings: Array<GroupedEdit> = edits.filter(e -> e.text.indexOf('using util.Groups;') != -1);
		final imports: Array<GroupedEdit> = edits.filter(e -> e.text.indexOf('import util.Arrays;') != -1);
		Assert.equals(1, usings.length);
		Assert.equals(1, imports.length);
		if (usings.length != 1 || imports.length != 1) return;
		Assert.notNull(usings[0].group);
		Assert.notNull(imports[0].group);
		Assert.notEquals(usings[0].group, imports[0].group);
		final out: String = fixResultOf(files, EXT);
		Assert.isTrue(out.indexOf('\t\txs.pushUnique(x);\n') != -1, out);
		Assert.isTrue(out.indexOf('\t\tArrays.pushTwo(xs, 1, 2);\n') != -1, out);
		Assert.isTrue(out.indexOf('using util.Groups;\n') != -1, out);
		Assert.isTrue(out.indexOf('import util.Arrays;\n') != -1, out);
	}

	/** A helper that cannot be called on its first argument (`@:noUsing`) keeps the qualified call even when its module is listed. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-EXTENSIBLE-ALWAYS')
	public function testAHelperExcludedFromExtensionsKeepsTheQualifiedCall(): Void {
		final helpers: String = GROUPS.replace(
			'\t@:preferHelper\n\tpublic static function pushUnique', '\t@:preferHelper\n\t@:noUsing\n\tpublic static function pushUnique'
		);
		final vs: Array<Violation> = violationsOf(typed(UNIQUE, helpers), EXT);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('qualified: the helper cannot be called on its first argument') != -1, vs[0].message);
		final out: String = fixResultOf(typed(UNIQUE, helpers), EXT);
		Assert.isTrue(out.indexOf('\t\tGroups.pushUnique(xs, x);\n') != -1, out);
		Assert.isTrue(out.indexOf('using util') == -1, out);
	}

	/** Another `using` that could supply the same name would take the call over: the call stays qualified, the finding says why. */
	@:pin('control')
	@:killer('M-PREFER-HELPER-USING-CONFLICT-IGNORED')
	public function testAnotherUsingSupplyingTheNameKeepsTheQualifiedCall(): Void {
		final other: String = 'package util;\n\nclass Other {\n\tpublic static function pushUnique<T>(xs:Array<T>, x:T):Void {}\n}\n';
		final files: Array<SourceEntry> = typed(UNIQUE);
		final withOther: Array<SourceEntry> = [
			{ file: files[0].file, source: files[0].source.replace('package app;\n', 'package app;\n\nusing util.Other;\n') }
		].concat(files.slice(1)).concat([{ file: 'util/Other.hx', source: other }]);
		final vs: Array<Violation> = violationsOf(withOther, EXT);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('qualified: another `using` in the file could also supply `pushUnique`') != -1, vs[0].message);
		final out: String = fixResultOf(withOther, EXT);
		Assert.isTrue(out.indexOf('\t\tGroups.pushUnique(xs, x);\n') != -1, out);
		Assert.isTrue(out.indexOf('using util.Groups') == -1, out);
	}

	/**
	 * The quoted call and the qualified note leave the blast-radius key: one finding reads alike in every spelling.
	 */
	@:pin('control')
	@:killer('M-PREFER-HELPER-IDENTITY-RAW')
	public function testMessageIdentityIgnoresTheQuotedCall(): Void {
		final plain: Array<Violation> = violationsOf(typed(UNIQUE));
		final ext: Array<Violation> = violationsOf(typed(UNIQUE), EXT);
		Assert.equals(1, plain.length);
		Assert.equals(1, ext.length);
		Assert.notEquals(plain[0].message, ext[0].message);
		final rule: PreferHelper = new PreferHelper();
		Assert.equals(rule.messageIdentity(plain[0].message), rule.messageIdentity(ext[0].message));
		Assert.equals(rule.messageIdentity(ext[0].message), rule.messageIdentity(rule.messageIdentity(ext[0].message)));
		Assert.isTrue(rule.messageIdentity(ext[0].message).indexOf('repeats the body of util.Groups.pushUnique') == 0, ext[0].message);
		final held: Array<Violation> = violationsOf(typed(UNIQUE, SHADOWED));
		final qualified: Array<Violation> = violationsOf(typed(UNIQUE, SHADOWED), EXT);
		Assert.equals(1, held.length);
		Assert.equals(1, qualified.length);
		Assert.isTrue(qualified[0].message.indexOf(', qualified: ') != -1, qualified[0].message);
		Assert.equals(rule.messageIdentity(held[0].message), rule.messageIdentity(qualified[0].message));
	}

	/** A finder whose body is `body`, with the function and closing-return helpers and a std `Array` its reads resolve to. */
	private function finder(body: String): Array<SourceEntry> {
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
	private function user(body: String, ?helpers: String): Array<SourceEntry> {
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

	/** `files[0]`'s own findings fixed through `fixGrouped`, each edit with its bisect group. */
	private function groupedEditsOf(files: Array<{ file: String, source: String }>, ?config: String): Array<GroupedEdit> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final rule: PreferHelper = check(config ?? CONFIG);
		final own: Array<Violation> = CheckFixture.violationsIn(rule, files, plugin, resolver(config ?? CONFIG))
			.filter(v -> v.file == files[0].file);
		return own.length == 0 ? [] : rule.fixGrouped(files[0].source, own, plugin, CheckFixture.index(files, plugin));
	}

	private function editsOf(files: Array<{ file: String, source: String }>, ?config: String): Array<FixEdit> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final rule: PreferHelper = check(config ?? CONFIG);
		final own: Array<Violation> = CheckFixture.violationsIn(rule, files, plugin, resolver(config ?? CONFIG))
			.filter(v -> v.file == files[0].file);
		return own.length == 0 ? [] : rule.fix(files[0].source, own, plugin, CheckFixture.index(files, plugin));
	}

	/** The call edit alone, without the import riding on it. */
	private function onlyEditText(files: Array<{ file: String, source: String }>): String {
		final calls: Array<FixEdit> = editsOf(files).filter(e -> e.text.indexOf('import ') == -1);
		Assert.equals(1, calls.length);
		return calls.length == 1 ? calls[0].text : '';
	}

	/** `files[0]` with its own findings fixed, canonicalised WITHOUT reformatting, exactly as `apq lint --fix` writes it. */
	private function fixResultOf(files: Array<{ file: String, source: String }>, ?config: String): String {
		switch CanonicalEdit.canonicalize(files[0].source, editsOf(files, config), false, new HaxeQueryPlugin()) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
		return '';
	}

	/** The user fixture with the std `Array` its receivers resolve to. */
	private function typed(body: String, ?helpers: String): Array<SourceEntry> {
		return user(body, helpers).concat([{ file: 'Array.hx', source: ARRAY }]);
	}

	/** `config` as the run's per-file resolver, which `Linter.collect` also asks the file gate through. */
	private static function resolver(config: String): (String) -> LintConfig {
		return _ -> LintConfig.parse(config);
	}

}
