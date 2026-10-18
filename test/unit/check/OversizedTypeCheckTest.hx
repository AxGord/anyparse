package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.OversizedType;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;
import unit.CheckFixture;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * The `oversized-type` check: a type whose member count or line extent exceeds
 * the default thresholds (50 members / 2000 lines) is flagged `Warning`; a
 * smaller one is not. Both boundaries are pinned (== max is quiet, over
 * flags); `#if`-guarded members count; an `apqlint.json` overrides both
 * thresholds. Report-only — `fix` yields no edits.
 */
class OversizedTypeCheckTest extends Test {

	/** The option that lowers the line threshold to 50, for the cases that need a line ceiling in reach of a small fixture. */
	private static inline final LINES_50: String = '"maxLines": 50, ';

	public function testSmallTypeNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tvar x:Int;\n\tfunction f():Int { return x; }\n}').length);
	}

	public function testMemberBoundaryNotFlagged(): Void {
		// Exactly 50 members == max -> quiet (the check flags only >).
		Assert.equals(0, violations(classWithMembers(50)).length);
	}

	public function testOverMemberLimitFlagged(): Void {
		final vs: Array<Violation> = violations(classWithMembers(51));
		Assert.equals(1, vs.length);
		Assert.equals('oversized-type', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.contains("type 'C'"));
		Assert.isTrue(vs[0].message.contains('51 members (max 50)'));
		Assert.isTrue(vs[0].message.contains('hxq clusters'));
	}

	public function testOverLineLimitFlagged(): Void {
		// One member, but the type body spans > 2000 lines.
		final blanks: String = [for (_ in 0...2001) '\n'].join('');
		final vs: Array<Violation> = violations('class C {\n$blanks\tvar x:Int;\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('2004 lines (max 2000)'));
	}

	public function testLineBoundaryNotFlagged(): Void {
		// Exactly 2000 lines == max -> quiet.
		final blanks: String = [for (_ in 0...1997) '\n'].join('');
		Assert.equals(0, violations('class C {\n$blanks\tvar x:Int;\n}').length);
	}

	public function testConditionalMembersCounted(): Void {
		// 48 plain + 3 `#if`-guarded members = 51 > 50 — guarded members count.
		final src: String = classWithMembers(48).replace('\n}', '\n\t#if debug\n\tvar ca:Int;\n\tvar cb:Int;\n\tvar cc:Int;\n\t#end\n}');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('51 members (max 50)'));
	}

	public function testBareNoqaInsideBodyDoesNotSuppress(): Void {
		// Regression (WriterLowering miss): the reported span is the type HEADER line
		// only — an unrelated bare `// noqa` deep inside the body must not swallow the
		// type-level finding (span-covers suppression would clear a whole-body span).
		final src: String = classWithMembers(51).replace('\tvar v25:Int;', '\tvar v25:Int; // noqa');
		final vs: Array<Violation> = suppressed(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('51 members (max 50)'));
	}

	public function testNoqaOnHeaderLineSuppresses(): Void {
		// Deliberate suppression: a named noqa ON the header line clears the finding.
		final src: String = classWithMembers(51).replace('class C {', 'class C { // noqa: oversized-type');
		Assert.equals(0, suppressed(src).length);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = classWithMembers(51);
		final check: OversizedType = new OversizedType();
		Assert.equals(0, CheckFixture.edits(check, src).length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { var x ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('oversized-type'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('oversized-type'));
	}

	public function testRespectsApqlintThresholdsFromDisk(): Void {
		// End-to-end: an apqlint.json discovered by walking up from the file lowers
		// both thresholds; a 3-member, 5-line type exceeds both, and the one finding
		// names both in a single message.
		final tmp: Null<String> = Sys.getEnv('TMPDIR');
		final base: String = tmp != null && tmp.length > 0 ? tmp : '/tmp';
		final dir: String = '$base/anyparse_ot_cfg_${Sys.time()}';
		FileSystem.createDirectory(dir);
		File.saveContent('$dir/apqlint.json', '{"rules": {"oversized-type": {"maxMembers": 2, "maxLines": 3}}}');
		final path: String = '$dir/Foo.hx';
		final src: String = 'class Foo {\n\tvar a:Int;\n\tvar b:Int;\n\tvar c:Int;\n}';
		File.saveContent(path, src);
		final vs: Array<Violation> = CheckFixture.violationsIn(new OversizedType(), [{ file: path, source: src }]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('3 members (max 2)'));
		Assert.isTrue(vs[0].message.contains('5 lines (max 3)'));
		FileSystem.deleteFile(path);
		FileSystem.deleteFile('$dir/apqlint.json');
		FileSystem.deleteDirectory(dir);
	}

	/**
	 * The anti-drift pin for `VolatileMessage`: the mask is anchored on a literal fragment of
	 * this rule's own wording, so a reworded message would turn it into a silent no-op and the
	 * blast-radius gate would go back to reporting a reflow as movement. The input here is a
	 * message `run` PRODUCED, never a hand-written one — that is the whole point of the case.
	 */
	public function testMessageIdentityMasksBothItsOwnMeasurementsAndKeepsTheThresholds(): Void {
		final blanks: String = [for (_ in 0...2001) '\n'].join('');
		final check: OversizedType = new OversizedType();
		final message: String = CheckFixture.violations(check, classWithMembers(51).replace('\n}', '$blanks\n}'))[0].message;
		Assert.isTrue(message.contains('51 members (max 50)'), 'the message states both measurements');
		Assert.isTrue(message.contains('lines (max 2000)'));
		final identity: String = check.messageIdentity(message);
		// BOTH measurements leave the key, the two CONFIGURED thresholds stay. The member count
		// used to stay too, on the argument that a type crossing the limit IS the finding — but
		// crossing it is what makes the finding APPEAR, which the key already shows, while the
		// count then drifts on every unrelated member added anywhere in the type. That drift has
		// produced blast-radius lines none of which was a real movement.
		Assert.isTrue(identity.contains('# members (max 50)'), 'the member count leaves the key - it drifts');
		Assert.isTrue(identity.contains('# lines (max 2000)'), 'so does the line extent');
		Assert.equals(identity, check.messageIdentity(identity), 'and the normalization is idempotent');
	}

	public function testMessageIdentityCollapsesAMemberCountBump(): Void {
		// The movement the mask exists to absorb: 51 members and 52 members are the same
		// finding about the same type, and the blast-radius gate must not report the growth as
		// one added plus one removed.
		final check: OversizedType = new OversizedType();
		final fiftyOne: String = CheckFixture.violations(check, classWithMembers(51))[0].message;
		final fiftyTwo: String = CheckFixture.violations(check, classWithMembers(52))[0].message;
		Assert.notEquals(fiftyOne, fiftyTwo);
		Assert.equals(check.messageIdentity(fiftyOne), check.messageIdentity(fiftyTwo));
	}

	/**
	 * The message the finding ENDS with is the no-seam half of this rule: when connected
	 * components find no seam, saying "see hxq clusters" costs the reader a run of a tool that
	 * will answer "the whole type is one component". `blob(51)` is that shape by construction —
	 * every member calls the next two, wrapping, so no cut of the small share of members auto
	 * mode is allowed to extract as hubs disconnects it. Geometry of this exact fixture: 51 members,
	 * 6 hubs, components 37 + 8, so the largest holds well over `BLOB_SHARE` of the non-hub members.
	 */
	public function testOneComponentTypeIsToldThereIsNoMemberSeam(): Void {
		final vs: Array<Violation> = violations(blob(51));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('51 members (max 50)'), vs[0].message);
		Assert.isTrue(
			vs[0].message.endsWith(
				'— a decomposition candidate; no member-reference seam — look for an architectural one '
				+ '(a command / handler / responsibility per module)'
			),
			vs[0].message
		);
		Assert.isFalse(vs[0].message.contains('hxq clusters'), 'and it no longer points at the tool that has nothing to show');
	}

	/**
	 * The other arm, and the one that keeps the first honest: the SAME member count split into
	 * two halves that never call across still gets the old wording, because `hxq clusters` has
	 * a real answer for it. Geometry: 51 members, 1 hub, components 25 + 25 — the largest holds
	 * exactly half of the non-hub members, under `BLOB_SHARE`.
	 */
	public function testATypeWithTwoComponentsStillPointsAtClusters(): Void {
		final vs: Array<Violation> = violations(halves(51));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.endsWith('— a decomposition candidate (see hxq clusters)'), vs[0].message);
	}

	/**
	 * A type of FIELDS with no methods has no call graph, so `Clusters.analyze` answers
	 * nothing — and the finding then keeps the old wording rather than claiming "no seam".
	 * This is the arm that would go red if the null report were read as a blob.
	 */
	public function testAFieldOnlyTypeKeepsTheClustersWording(): Void {
		final vs: Array<Violation> = violations(classWithMembers(51));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.endsWith('— a decomposition candidate (see hxq clusters)'), vs[0].message);
	}

	/**
	 * The per-type grant, end to end through a discovered `apqlint.json`: an entry naming the
	 * type, a CEILING above the rule's threshold and a reason clears the finding while the type
	 * stays within that ceiling.
	 */
	public function testGrantWithinItsCeilingClearsTheFinding(): Void {
		Assert.equals(
			0,
			withConfig(
				'{"rules": {"oversized-type": {"grants": ["C <= 60 members: one algorithm, no seam to cut"]}}}', classWithMembers(51)
			).length
		);
	}

	/** A ceiling is inclusive, like the thresholds: a type AT its grant's ceiling is still granted. */
	public function testGrantAtItsCeilingStaysSilent(): Void {
		Assert.equals(0, granted(['C <= 55 members: one algorithm'], classWithMembers(55)).length);
	}

	/**
	 * What the ceiling is for: a granted type that GROWS past it is reported again, measured
	 * against the ceiling rather than the rule's threshold, and the message names the grant it
	 * outgrew. Before the ceiling a grant silenced the type at any size.
	 */
	@:pin('control')
	@:killer('M-OVERSIZED-GRANT-UNBOUNDED', 'M-OVERSIZED-BEYOND-UNNAMED')
	public function testGrantPastItsCeilingReportsTheTypeAgain(): Void {
		final vs: Array<Violation> = granted(['C <= 55 members: one algorithm'], classWithMembers(56));
		Assert.equals(1, vs.length);
		Assert.equals('C.hx', vs[0].file);
		Assert.isTrue(vs[0].message.contains("type 'C' has 56 members (max 55) — beyond its grant 'C <= 55 members'"), vs[0].message);
	}

	/**
	 * Each dimension has its own ceiling: a type within its member ceiling and past its line
	 * ceiling reports the lines alone. 51 members, 53 lines + 20 blank ones.
	 */
	@:pin('control')
	@:killer('M-OVERSIZED-GRANT-LINES-UNBOUNDED')
	public function testLineCeilingIsJudgedOnItsOwn(): Void {
		final entry: String = 'C <= 60 members / 70 lines: one algorithm';
		Assert.equals(0, granted([entry], classWithMembers(51), LINES_50).length, 'within both ceilings');
		final vs: Array<Violation> = granted(
			[entry], classWithMembers(51).replace('\n}', '${[for (_ in 0...20) '\n'].join('')}\n}'), LINES_50
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("has 73 lines (max 70) — beyond its grant 'C <= 60 members / 70 lines'"), vs[0].message);
	}

	/**
	 * A dimension the grant gives no ceiling keeps the rule's threshold: a members-only grant does
	 * not forgive a type that also crosses the line limit, and the finding says which grant did
	 * not cover it.
	 */
	@:pin('control')
	@:killer('M-OVERSIZED-UNGRANTED-DIMENSION')
	public function testAnUngrantedDimensionKeepsTheThreshold(): Void {
		final vs: Array<Violation> = granted(['C <= 60 members: one algorithm'], classWithMembers(51), LINES_50);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("has 53 lines (max 50) — beyond its grant 'C <= 60 members'"), vs[0].message);
		Assert.isFalse(vs[0].message.contains('members (max'), vs[0].message);
	}

	/**
	 * The grant syntax before ceilings (`Name: reason`) is REFUSED, not read as an unbounded
	 * grant: the type keeps its finding and a file-less finding says how to migrate the entry.
	 */
	@:pin('control')
	@:killer('M-OVERSIZED-LEGACY-GRANT', 'M-OVERSIZED-PROBLEM-SILENT')
	public function testACeilingLessGrantIsRefusedWithAMigrationMessage(): Void {
		final vs: Array<Violation> = granted(['C: one algorithm, no seam to cut'], classWithMembers(51));
		Assert.equals(2, vs.length);
		final type: Null<Violation> = vs.find(v -> v.file == 'C.hx');
		Assert.isTrue(type != null && type.message.contains("type 'C' has 51 members (max 50) —") && !type.message.contains('grant'));
		final problem: Null<Violation> = vs.find(v -> v.file == '');
		Assert.notNull(problem);
		if (problem == null) return;
		Assert.equals('oversized-type', problem.rule);
		Assert.equals(Severity.Warning, problem.severity);
		Assert.isNull(problem.span);
		Assert.isTrue(problem.message.contains('grant "C" has no ceiling'), problem.message);
		Assert.isTrue(problem.message.contains('"C <= <N> members / <M> lines: <reason>"'), problem.message);
	}

	/** Every other shape of the head is refused the same way: the type keeps its finding, the entry is named. */
	@:pin('control')
	@:killer('M-OVERSIZED-GRANT-NAME', 'M-OVERSIZED-CLAUSE-ORDER', 'M-OVERSIZED-CLAUSE-REPEATED', 'M-OVERSIZED-CEILING-DIGITS')
	public function testAMalformedGrantIsRefused(): Void {
		for (entry in [
			'C <= many members: r',
			'C <= 60: r',
			'C <= 60 lines / 70 members: r',
			'C <= 60 members / 70 members: r',
			'C => 60 members: r',
			'C <= 60 members, 70 lines: r',
			'C <= 60 members / 70 lines / 80 lines: r',
			'C<T> <= 60 members: r',
			'<= 60 members: r',
			'C <= 9999999999 members: r'
		]) {
			final vs: Array<Violation> = granted([entry], classWithMembers(51));
			Assert.equals(2, vs.length, entry);
			Assert.isTrue(vs.exists(v -> v.file == '' && v.message.contains('is malformed')), entry);
		}
	}

	/** A reason is still required, after a ceiling as before it. */
	@:pin('control')
	@:killer('M-OVERSIZED-GRANT-REASONLESS')
	public function testAGrantWithoutAReasonIsRefused(): Void {
		for (entry in ['C <= 60 members', 'C <= 60 members:', 'C <= 60 members:   ', 'C']) {
			final vs: Array<Violation> = granted([entry], classWithMembers(51));
			Assert.equals(2, vs.length, entry);
			Assert.isTrue(vs.exists(v -> v.file == '' && v.message.contains('gives no reason')), entry);
		}
	}

	/** A ceiling at or below the rule's own threshold grants nothing, so it is refused rather than read as a tighter limit. */
	@:pin('control')
	@:killer('M-OVERSIZED-CEILING-AT-THRESHOLD')
	public function testACeilingNotAboveTheThresholdIsRefused(): Void {
		for (entry in ['C <= 50 members: r', 'C <= 60 members / 2000 lines: r']) {
			final vs: Array<Violation> = granted([entry], classWithMembers(51));
			Assert.equals(2, vs.length, entry);
			Assert.isTrue(vs.exists(v -> v.file == '' && v.message.contains('is not above')), entry);
		}
	}

	/** Two grants for one type are two ceilings for it: both are refused, not the first or the larger one taken. */
	@:pin('control')
	@:killer('M-OVERSIZED-DUPLICATE-GRANT')
	public function testTwoGrantsForOneTypeAreBothRefused(): Void {
		final vs: Array<Violation> = granted(['C <= 60 members: a', 'C <= 70 members: b'], classWithMembers(51));
		Assert.equals(2, vs.length);
		Assert.isTrue(vs.exists(v -> v.file == '' && v.message.contains('two grants name "C"')));
	}

	/** A refused entry costs only itself: a well-formed grant beside it still applies. */
	public function testARefusedGrantLeavesItsNeighboursStanding(): Void {
		final vs: Array<Violation> = granted(['C <= 60 members: one algorithm', 'D: legacy'], classWithMembers(51));
		Assert.equals(1, vs.length);
		Assert.equals('', vs[0].file);
	}

	/** A refused entry is reported ONCE per run, however many files resolve the config holding it. */
	@:pin('control')
	@:killer('M-OVERSIZED-PROBLEM-ONCE')
	public function testARefusedGrantIsReportedOncePerRun(): Void {
		final config: LintConfig = LintConfig.parse(grantConfig(['D: legacy'], ''));
		final vs: Array<Violation> = CheckFixture.violationsIn(
			new OversizedType(), [{ file: 'A.hx', source: 'class A {}' }, { file: 'B.hx', source: 'class B {}' }], null, _ -> config
		);
		Assert.equals(1, vs.length);
	}

	/** A grant naming a DIFFERENT type leaves this one alone — the list is keyed by name, not a global off switch. */
	public function testGrantIsKeyedByTypeName(): Void {
		Assert.equals(1, granted(['Other <= 60 members: not this type'], classWithMembers(51)).length);
	}

	/**
	 * The past-ceiling message keys like any other: the current size leaves the key, the
	 * CEILING stays — raising a ceiling is a configuration change the blast-radius gate must show.
	 */
	public function testMessageIdentityOfAPastCeilingFindingKeepsTheCeiling(): Void {
		final check: OversizedType = new OversizedType();
		final config: LintConfig = LintConfig.parse(grantConfig(['C <= 55 members: one algorithm'], ''));
		final message: String = CheckFixture.violationsIn(
			check,
			[{ file: 'C.hx', source: classWithMembers(56) }],
			null, _ -> config
		)[0].message;
		final identity: String = check.messageIdentity(message);
		Assert.isTrue(identity.contains("# members (max 55) — beyond its grant 'C <= 55 members'"), identity);
		Assert.equals(identity, check.messageIdentity(identity));
	}

	/**
	 * The interface carve-out, and the one arm that is RED at base: a type whose members are in the
	 * MAJORITY declared by an interface it implements is not a decomposition candidate, because a
	 * member the contract requires cannot be moved out at all. 30 dictated + 25 of its own = 55
	 * members, over the 50 cap on the raw count and silent on the carved one.
	 *
	 * The first assertion is the reachability control and PASSES at base: the identical 55-member
	 * type WITHOUT the `implements` clause is still reported, so the fixture provably reaches the
	 * walk and the second assertion fails on its own claim rather than by exception. It is also
	 * what makes this pin discriminate the CLAUSE rather than the member count.
	 *
	 * The plugin is a `CachingGrammarPlugin` carrying a resolution index, not the bare
	 * `HaxeQueryPlugin` the other cases use: the carve-out resolves the interface through
	 * `SymbolIndexHost`, so it is INERT without one — which is the same reason a `lint` run over a
	 * scope too narrow to hold the interface keeps reporting.
	 */
	public function testAMajorityDictatedTypeIsNotADecompositionCandidate(): Void {
		final iface: { file: String, source: String } = { file: 'I.hx', source: ifaceWithMethods(30) };
		Assert.equals(
			1, withIndex([iface, { file: 'C.hx', source: implementor(30, 25, false) }]).length,
			'the same 55 members with no implements clause stay reported'
		);
		Assert.equals(0, withIndex([iface, { file: 'C.hx', source: implementor(30, 25, true) }]).length);
	}

	/**
	 * The bound the carve-out must never cross, and the reason `contractFacade` asks TWO questions:
	 * a type that is also fat in its OWN members keeps its finding however much of it the contract
	 * dictates. 60 dictated + 51 of its own = 111; the dictated share is a majority, but 51 own
	 * members are over the cap by themselves.
	 *
	 * GREEN at base — it guards the new gate's own bound rather than a behaviour change. Its arm is
	 * dropping `own <= maxMembers` from `contractFacade`, which silences this fixture at once.
	 */
	public function testATypeFatInItsOwnMembersIsStillReported(): Void {
		final vs: Array<Violation> = withIndex([
			{ file: 'I.hx', source: ifaceWithMethods(60) },
			{ file: 'C.hx', source: implementor(60, 51, true) }
		]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('111 members (max 50)'), vs[0].message);
	}

	/**
	 * The other half of `contractFacade`: a MINORITY dictated share carves nothing. 5 dictated + 50
	 * of its own = 55, and 50 own members are within the cap — so without the share test this type
	 * would fall silent, which is what a plain subtraction would have done to real types of this
	 * project whose dictated share is a small minority.
	 *
	 * GREEN at base — it guards the share test. Its arm is dropping `dictated >= own`.
	 */
	public function testAMinorityDictatedTypeIsStillReported(): Void {
		final vs: Array<Violation> = withIndex([
			{ file: 'I.hx', source: ifaceWithMethods(5) },
			{ file: 'C.hx', source: implementor(5, 50, true) }
		]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('55 members (max 50)'), vs[0].message);
	}

	/**
	 * An `implements` target the scope cannot resolve carves NOTHING — the same 55-member type as
	 * the first case, with `I.hx` left out of the file set.
	 *
	 * This is the pin for the direction the reused predicate gets wrong. `MemberLookup`'s
	 * `typeProvablyLacksMember` answers "declares it OR is unresolvable", which is the SAFE union
	 * for `make-final` (a spurious true means "skip the rewrite") and the UNSAFE one here (a
	 * spurious true means "this member is dictated"). Consumed without the resolvability gate, ONE
	 * unresolvable interface makes all 55 members read as dictated, `own` falls to 0 and the type
	 * goes quiet on no evidence at all.
	 *
	 * GREEN at base — it guards the gate. Its arm is deleting the `resolveStartType` loop from
	 * `dictatedMemberCount`, which turns this fixture silent.
	 */
	public function testAnUnresolvableInterfaceCarvesNothing(): Void {
		final vs: Array<Violation> = withIndex([{ file: 'C.hx', source: implementor(30, 25, true) }]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('55 members (max 50)'), vs[0].message);
	}

	/**
	 * A CONSTANT TABLE is not a decomposition candidate (A13, the user's decision of 2026-10-18): the
	 * size of a type counts its BEHAVIOUR, so the shape of TM's `Colors` (nothing but `static inline
	 * final` colours) and `Dimensions` (142 of them plus a constructor) is one member here, not 61.
	 */
	@:pin('control')
	@:killer('M-OVERSIZED-CONST-COUNTED')
	public function testAConstantTableIsNotReported(): Void {
		final consts: Array<String> = [
			for (i in 0...60) '\tpublic static inline final C$i:UInt = 0x${i.hex(6)};'
		];
		Assert.equals(0, violations('class C {\n${consts.join('\n')}\n\tpublic function new() {}\n}').length);
	}

	/**
	 * Every shape the constant whitelist admits, each one added to a type that is exactly AT the
	 * member limit, so a shape the rule counted would tip it over: a literal of every kind, a plain
	 * string, operators and parentheses over constants, a reference to another constant of the
	 * same type, an `inline` field whose initializer only the compiler folds (`inline` is refused
	 * on anything it cannot), and the values of an `@:enum abstract`, with or without one.
	 */
	@:pin('control')
	@:killer('M-OVERSIZED-CONST-INLINE-PROOF', 'M-CONST-EXPR-NO-OPERATORS', 'M-CONST-EXPR-NO-PARENS', 'M-CONST-EXPR-NO-NAMES',
		'M-OVERSIZED-CONST-NO-ENUM-VALUES', 'M-OVERSIZED-CONST-ENUM-VALUE-NEEDS-INIT')
	public function testEveryConstantShapeIsUncounted(): Void {
		final shapes: Array<String> = [
			'static final K = 1;',
			'static final K = -2;',
			'static final K = 0xFF;',
			'static final K = 1.5;',
			'static final K = true;',
			'static final K = "s";',
			"static final K = 'plain';",
			'public static final K:Int = 3;',
			'@:keep static final K = 1;',
			'static final K = (3 + 4) * 2;',
			'static final K = 1 << 4 | 0x0F;',
			"static final K = 'a' + 'b';",
			'static final K = 1;\n\tstatic final L = K * 2;',
			'static final L = K + 1;\n\tstatic final K = 2;',
			'static inline final K = Std.int(Other.X * 1.5);',
			'#if debug\n\tstatic final K = 1;\n\t#end'
		];
		for (shape in shapes) Assert.equals(0, violations(atLimit(shape)).length, shape);
		final values: Array<String> = ['var A = 1;', 'var A;', 'final A = 2;', 'public static inline final A = 3;'];
		for (value in values) Assert.equals(0, violations(enumAtLimit(value)).length, value);
	}

	/**
	 * The whitelist is POSITIVE: everything it does not name is behaviour (or state) and counts, as
	 * before. Each shape is added to a type exactly at the limit and must tip it over, by as many
	 * members as it declares. A `static var` is state; an instance `final` is state; a property, a
	 * call, an allocation, a field access, a cast, `null`, an interpolated string and a reference to
	 * anything but a constant of the same type are not whitelisted; and outside an enum abstract a
	 * non-static field is no enum value.
	 */
	@:pin('control')
	@:killer('M-OVERSIZED-CONST-NEEDS-STATIC', 'M-OVERSIZED-CONST-STATIC-VAR', 'M-OVERSIZED-CONST-ANY-STATIC-FINAL',
		'M-OVERSIZED-CONST-ACCESSOR', 'M-OVERSIZED-CONST-ANY-ENUM-HOST', 'M-OVERSIZED-CONST-NAME-NOT-CONSTANT',
		'M-OVERSIZED-CONST-NAME-UNDECLARED', 'M-CONST-EXPR-ANY-OPERAND', 'M-CONST-EXPR-INTERPOLATED')
	public function testEveryNonConstantShapeCounts(): Void {
		final shapes: Array<String> = [
			'static var K = 1;',
			'final K = 1;',
			'static final K = Std.int(3.5);',
			'static final K = [1, 2];',
			'static final K = Other.X;',
			'static final K = cast 1;',
			'static final K = null;',
			"static final K = 'a${Other.X}';",
			'static final K = Undeclared + 1;',
			'static final K:Int;',
			'function k():Int { return 1; }',
			'static inline var K = 1;'
		];
		for (shape in shapes) {
			final vs: Array<Violation> = violations(atLimit(shape));
			Assert.equals(1, vs.length, shape);
			if (vs.length == 1) Assert.isTrue(vs[0].message.contains('51 members (max 50)'), '$shape: ${vs[0].message}');
		}
		for (pair in [
			'static var V = 1;\n\tstatic final K = V + 1;',
			'static var V = 1;\n\tstatic final K = 1 + (V);'
		]) {
			final vs: Array<Violation> = violations(atLimit(pair));
			Assert.isTrue(vs.length == 1 && vs[0].message.contains('52 members (max 50)'), pair);
		}
		for (value in ['var A(get, never):Int;', 'static var A = 1;', 'var A = Std.int(1.5);']) {
			final vs: Array<Violation> = violations(enumAtLimit(value));
			Assert.isTrue(vs.length == 1 && vs[0].message.contains('51 members (max 50)'), value);
		}
		final plain: Array<Violation> = violations(enumAtLimit('var A = 1;').replace('@:enum ', ''));
		Assert.isTrue(plain.length == 1 && plain[0].message.contains('51 members (max 50)'), 'a plain abstract has no enum values');
	}

	/**
	 * A type MIXING behaviour and constants keeps its behaviour count: 51 fields of state plus 30
	 * constants is 51 members, and the finding says so.
	 */
	@:pin('control')
	@:killer('M-OVERSIZED-CONST-COUNTED')
	public function testAMixedTypeKeepsItsBehaviourCount(): Void {
		final consts: String = [for (i in 0...30) '\tstatic inline final K$i = $i;'].join('\n');
		final vs: Array<Violation> = violations(classWithMembers(51).replace('class C {', 'class C {\n$consts'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("type 'C' has 51 members (max 50)"), vs[0].message);
	}

	/**
	 * The LINE limit follows the member count: every line of a type belongs to the member it ends
	 * (its doc, its annotations and the blank lines since the previous member), and the lines of a
	 * constant are not counted. 60 documented constants and a constructor are 123 lines and 3 of
	 * behaviour (header, constructor, closing brace).
	 */
	@:pin('control')
	@:killer('M-OVERSIZED-CONST-LINES-COUNTED', 'M-OVERSIZED-CONST-REGION-OWN-LINES')
	public function testTheLinesOfAConstantAreNotCounted(): Void {
		Assert.equals(0, granted([], documentedTable(0), LINES_50).length);
	}

	/**
	 * The lines left are the behaviour's own, counted exactly: the same table plus 49 one-line
	 * methods (and the constructor) is 172 lines, 120 of them the table's, so 52 count.
	 */
	@:pin('control')
	@:killer('M-OVERSIZED-CONST-LINES-COUNTED')
	public function testTheLinesOfBehaviourStillCount(): Void {
		final vs: Array<Violation> = granted([], documentedTable(49), LINES_50);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("type 'C' has 52 lines (max 50)"), vs[0].message);
	}

	/**
	 * A line a constant SHARES with a behaviour member counts: behaviour is on it. 48 method lines,
	 * one line holding a constant and a method, the header and the closing brace are 51.
	 */
	@:pin('control')
	@:killer('M-OVERSIZED-CONST-SHARED-LINE')
	public function testALineAConstantSharesWithBehaviourCounts(): Void {
		final methods: String = [for (i in 0...48) '\tfunction m$i():Void {}'].join('\n');
		final src: String = 'class C {\n$methods\n\tstatic inline final K = 1; function g():Void {}\n}';
		final vs: Array<Violation> = granted([], src, LINES_50);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("type 'C' has 51 lines (max 50)"), vs[0].message);
	}

	/**
	 * Run the check over `files` through a plugin that HOSTS a resolution index built from them —
	 * the shape a real `lint` run has, and the one the interface carve-out needs. The bare
	 * `HaxeQueryPlugin` every other case here uses is not a `SymbolIndexHost`, so the carve-out
	 * cannot run through it at all.
	 */
	private function withIndex(files: Array<{ file: String, source: String }>): Array<Violation> {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionIndex(CheckFixture.index(files, plugin));
		return CheckFixture.violationsIn(new OversizedType(), files, plugin);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new OversizedType(), src);
	}

	/** Like `violations`, but through `Linter.run` so inline `// noqa` suppression applies. */
	private function suppressed(src: String): Array<Violation> {
		return Linter.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin(), [new OversizedType()]);
	}

	/**
	 * Run the check on `src` under an `apqlint.json` written next to it in a fresh temp
	 * directory — the on-disk path, because a grant is a project decision and the point is that
	 * the discovered document carries it.
	 */
	private function withConfig(config: String, src: String): Array<Violation> {
		final tmp: Null<String> = Sys.getEnv('TMPDIR');
		final base: String = tmp != null && tmp.length > 0 ? tmp : '/tmp';
		final dir: String = '$base/anyparse_ot_grant_${Sys.time()}_${Std.random(1 << 24)}';
		FileSystem.createDirectory(dir);
		File.saveContent('$dir/apqlint.json', config);
		final path: String = '$dir/C.hx';
		File.saveContent(path, src);
		final out: Array<Violation> = CheckFixture.violationsIn(new OversizedType(), [{ file: path, source: src }]);
		FileSystem.deleteFile(path);
		FileSystem.deleteFile('$dir/apqlint.json');
		FileSystem.deleteDirectory(dir);
		return out;
	}

	/**
	 * Run the check on `src` (as `C.hx`) under a config whose `oversized-type` grants are
	 * `entries`, `options` spliced in ahead of them — the parsed document, without the disk walk
	 * `withConfig` pins.
	 */
	private function granted(entries: Array<String>, src: String, options: String = ''): Array<Violation> {
		final config: LintConfig = LintConfig.parse(grantConfig(entries, options));
		return CheckFixture.violationsIn(new OversizedType(), [{ file: 'C.hx', source: src }], null, _ -> config);
	}

	/** The `apqlint.json` text granting `entries`, with `options` (each followed by a comma) ahead of the list. */
	private static function grantConfig(entries: Array<String>, options: String): String {
		return '{"rules": {"oversized-type": {$options"grants": ${Json.stringify(entries)}}}}';
	}

	/** An interface named `I` declaring `n` methods `m0`… — the contract a fixture's members are dictated by. */
	private static function ifaceWithMethods(n: Int): String {
		return 'interface I {\n' + [for (i in 0...n) '\tfunction m$i():Void;'].join('\n') + '\n}';
	}

	/** A class named `C` with `methods` methods `m0`… and `fields` fields of its own, implementing `I` or not. */
	private static function implementor(methods: Int, fields: Int, implementsIface: Bool): String {
		return 'class C${implementsIface ? ' implements I' : ''} {\n'
			+ [for (i in 0...methods) '\tpublic function m$i():Void {}'].join('\n') + '\n'
			+ [for (i in 0...fields) '\tvar v$i:Int;'].join('\n') + '\n}';
	}

	/** A parseable class named `C` with exactly `n` field members, one per line. */
	private static function classWithMembers(n: Int): String {
		return 'class C {\n' + [for (i in 0...n) '\tvar v$i:Int;'].join('\n') + '\n}';
	}

	/** `n` methods in ONE blob: each calls the next two, wrapping, so hub extraction cannot cut it. */
	private static function blob(n: Int): String {
		return 'class C {\n'
			+ [
				for (i in 0...n) '\tfunction m$i():Int { return m${(i + 1) % n}() + m${(i + 2) % n}(); }'
			].join('\n') + '\n}';
	}

	/** `n` methods in TWO rings that never call across — a real member-reference seam. */
	private static function halves(n: Int): String {
		final cut: Int = Std.int(n / 2);
		return 'class C {\n'
			+ [
				for (i in 0...n) {
					final low: Int = i < cut ? 0 : cut;
					final high: Int = i < cut ? cut : n;
					'\tfunction m$i():Int { return m${low + (i - low + 1) % (high - low)}(); }';
				}
			].join('\n') + '\n}';
	}

	/** A class named `C` with exactly 50 field members — AT the member limit — and `extra` declared after them. */
	private static function atLimit(extra: String): String {
		return classWithMembers(50).replace('\n}', '\n\t$extra\n}');
	}

	/** An `@:enum abstract` named `C` with exactly 50 methods — AT the member limit — and `value` declared after them. */
	private static function enumAtLimit(value: String): String {
		final methods: String = [for (i in 0...50) '\tpublic function m$i():Int { return this; }'].join('\n');
		return '@:enum abstract C(Int) {\n$methods\n\t$value\n}';
	}

	/** A class named `C`: 60 constants, each under a one-line doc, then `methods` one-line methods. */
	private static function documentedTable(methods: Int): String {
		final consts: String = [
			for (i in 0...60) '\t/** Constant $i. */\n\tpublic static inline final K$i:Int = $i;'
		].join('\n');
		final fns: String = [for (i in 0...methods) '\n\tfunction m$i():Void {}'].join('');
		return 'class C {\n$consts$fns\n\tpublic function new() {}\n}';
	}

}
