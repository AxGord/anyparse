package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.OversizedType;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `oversized-type` check: a type whose member count or line extent exceeds
 * the default thresholds (50 members / 2000 lines) is flagged `Warning`; a
 * smaller one is not. Both boundaries are pinned (== max is quiet, over flags); `#if`-guarded members count; an `apqlint.json` overrides both
 * thresholds. Report-only — `fix` yields no edits.
 */
class OversizedTypeCheckTest extends Test {

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
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
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
		final vs: Array<Violation> = new OversizedType().run([{ file: path, source: src }], new HaxeQueryPlugin());
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
		final message: String = check.run(
			[{ file: 'C.hx', source: classWithMembers(51).replace('\n}', '$blanks\n}') }], new HaxeQueryPlugin()
		)[0].message;
		Assert.isTrue(message.contains('51 members (max 50)'), 'the message states both measurements');
		Assert.isTrue(message.contains('lines (max 2000)'));
		final identity: String = check.messageIdentity(message);
		// BOTH measurements leave the key, the two CONFIGURED thresholds stay. The member count
		// used to stay too, on the argument that a type crossing the limit IS the finding — but
		// crossing it is what makes the finding APPEAR, which the key already shows, while the
		// count then drifts on every unrelated member added anywhere in the type. Measured over
		// this campaign's last three blast-radius verdicts, that drift produced two of the six
		// reported lines and none of them was a real movement.
		Assert.isTrue(identity.contains('# members (max 50)'), 'the member count leaves the key - it drifts');
		Assert.isTrue(identity.contains('# lines (max 2000)'), 'so does the line extent');
		Assert.equals(identity, check.messageIdentity(identity), 'and the normalization is idempotent');
	}

	public function testMessageIdentityCollapsesAMemberCountBump(): Void {
		// The movement the mask exists to absorb: 51 members and 52 members are the same
		// finding about the same type, and the blast-radius gate must not report the growth as
		// one added plus one removed.
		final check: OversizedType = new OversizedType();
		final fiftyOne: String = check.run([{ file: 'C.hx', source: classWithMembers(51) }], new HaxeQueryPlugin())[0].message;
		final fiftyTwo: String = check.run([{ file: 'C.hx', source: classWithMembers(52) }], new HaxeQueryPlugin())[0].message;
		Assert.notEquals(fiftyOne, fiftyTwo);
		Assert.equals(check.messageIdentity(fiftyOne), check.messageIdentity(fiftyTwo));
	}

	/**
	 * The message the finding ENDS with is the T478 half of this rule: when connected
	 * components find no seam, saying "see hxq clusters" costs the reader a run of a tool that
	 * will answer "the whole type is one component". `blob(51)` is that shape by construction —
	 * every member calls the next two, wrapping, so no cut of the 10 % of members auto mode is
	 * allowed to extract as hubs disconnects it. Measured on this exact fixture: 51 members,
	 * 6 hubs, components 37 + 8, so the largest holds 37 of 45 = 82 % and clears `BLOB_SHARE`.
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
	 * a real answer for it. Measured: 51 members, 1 hub, components 25 + 25 — the largest holds
	 * 25 of 50 = 50 %, under `BLOB_SHARE`.
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
	 * The per-type grant, end to end through a discovered `apqlint.json`: a `grants` entry
	 * naming the type AND a reason clears its finding. The reason is not decoration — the arm
	 * below shows a bare name does nothing.
	 */
	public function testGrantWithAReasonClearsTheFinding(): Void {
		Assert.equals(
			0, withConfig('{"rules": {"oversized-type": {"grants": ["C: one algorithm, no seam to cut"]}}}', classWithMembers(51)).length
		);
	}

	/**
	 * A grant with no reason after the `:` — or none at all — is DROPPED, so the type keeps its
	 * finding. Without this the grant list would be `// noqa` one file further away, and the
	 * whole reason to prefer a config key over a header-line suppression is that a project
	 * decision has to be arguable by the next reader.
	 */
	public function testGrantWithoutAReasonDoesNotClearIt(): Void {
		Assert.equals(1, withConfig('{"rules": {"oversized-type": {"grants": ["C"]}}}', classWithMembers(51)).length);
		Assert.equals(1, withConfig('{"rules": {"oversized-type": {"grants": ["C:   "]}}}', classWithMembers(51)).length);
	}

	/** A grant naming a DIFFERENT type leaves this one alone — the list is keyed by name, not a global off switch. */
	public function testGrantIsKeyedByTypeName(): Void {
		Assert.equals(1, withConfig('{"rules": {"oversized-type": {"grants": ["Other: not this type"]}}}', classWithMembers(51)).length);
	}

	private function violations(src: String): Array<Violation> {
		return new OversizedType().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
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
		final out: Array<Violation> = new OversizedType().run([{ file: path, source: src }], new HaxeQueryPlugin());
		FileSystem.deleteFile(path);
		FileSystem.deleteFile('$dir/apqlint.json');
		FileSystem.deleteDirectory(dir);
		return out;
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

}
