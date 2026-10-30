package unit.check.common.members;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.RiskyFix;
import anyparse.check.Severity;
import anyparse.check.common.members.PreferAccessMeta;

/**
 * The `prefer-access-meta` check: an `@:privateAccess` expression is flagged `Info`; the fix drops the waiver and grants
 * the enclosing member `@:access(T)` for each type declaring a private member the expression reads. A public member needs
 * no grant, a grant already carried is not repeated, and a receiver the binder cannot type keeps the waiver. Default-off,
 * and its fix is risky.
 */
class PreferAccessMetaCheckTest extends Test {

	public function testWaiverFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('return @:privateAccess b.secret;'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-access-meta', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(
			'@:privateAccess waives every privacy check in its expression — grant the type it reads on the member instead', vs[0].message
		);
	}

	public function testFixGrantsDeclaringType(): Void {
		Assert.equals(wrap('return b.secret;', '@:access(Box)\n\t'), fixed(wrap('return @:privateAccess b.secret;')));
	}

	public function testConstructionGrantsItsType(): Void {
		Assert.equals(wrap('return new Box().open;', '@:access(Box)\n\t'), fixed(wrap('return @:privateAccess new Box().open;')));
	}

	/** A public member is reachable without the waiver: the fix only drops it. */
	@:pin('control')
	@:killer('M-PAM-GRANT-PUBLIC')
	public function testPublicMemberNeedsNoGrant(): Void {
		Assert.equals(wrap('return b.open;'), fixed(wrap('return @:privateAccess b.open;')));
	}

	public function testHeldGrantNotRepeated(): Void {
		final held: String = '@:access(Box)\n\t';
		Assert.equals(wrap('return b.secret;', held), fixed(wrap('return @:privateAccess b.secret;', held)));
	}

	public function testUntypedReceiverKeepsWaiver(): Void {
		Assert.equals(0, CheckFixture.edits(new PreferAccessMeta(), wrap('return @:privateAccess q.secret;')).length);
	}

	public function testDefaultOffAndRisky(): Void {
		final check: PreferAccessMeta = new PreferAccessMeta();
		Assert.isTrue(Std.isOfType(check, DefaultOff));
		Assert.isTrue(Std.isOfType(check, RiskyFix));
		Assert.notNull(Linter.byId('prefer-access-meta'));
	}

	/** An interface member written with no visibility is public: the fix only drops the waiver. */
	@:pin('control')
	@:killer('M-ACCESSIBLE-INTERFACE-PRIVATE')
	public function testInterfaceMemberNeedsNoGrant(): Void {
		Assert.equals(viaMember('interface', '', 'return i.m();'), fixed(viaMember('interface', '', 'return @:privateAccess i.m();')));
	}

	/** A class member written with no visibility is private: its type is granted. */
	public function testClassMemberWithoutVisibilityGranted(): Void {
		Assert.equals(
			viaMember('class', ' {\n\t\treturn 0;\n\t}', 'return i.m();', '@:access(I)\n\t'),
			fixed(viaMember('class', ' {\n\t\treturn 0;\n\t}', 'return @:privateAccess i.m();'))
		);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new PreferAccessMeta(), src);
	}

	private function fixed(src: String): String {
		return CheckFixture.fixedSource(new PreferAccessMeta(), src);
	}

	/** A class `C` whose method `f` runs `body`, carrying `meta` above it, beside a type `Box` with a private member. */
	private static function wrap(body: String, meta: String = ''): String {
		return 'class Box {\n\tpublic var open: Int = 0;\n\n\tprivate var secret: Int = 0;\n\n\tprivate function new() {}\n}\n\n'
			+ 'final class C {\n\tpublic function new() {}\n\n\t${meta}public function f(b: Box, q: Dynamic): Int {\n\t\t$body\n\t}\n}';
	}

	/** A type `I` (an interface or a class, by `kind`) declaring `m` with no visibility and the body `mBody`, read by `C.f`. */
	private static function viaMember(kind: String, mBody: String, body: String, meta: String = ''): String {
		final decl: String = mBody == '' ? 'function m(): Int;' : 'function m(): Int$mBody';
		return
			'$kind I {\n\t$decl\n}\n\nfinal class C {\n\tpublic function new() {}\n\n\t${meta}public function f(i: I): Int {\n\t\t$body\n'
				+ '\t}\n}';
	}

}
