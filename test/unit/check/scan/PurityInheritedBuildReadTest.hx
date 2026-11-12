package unit.check.scan;

import anyparse.check.common.control.JoinBranchCall;

/**
 * A member declared by an inherited `@:build` supertype is read as its declaration says, bare or through `this.`: both
 * spellings are one plain field read, so `join-branch-call` joins the branches. A name the supertype does not declare may
 * be added by the macro, may be a getter, and keeps the branches apart.
 */
class PurityInheritedBuildReadTest extends Test {

	/**
	 * A payload class, and a supertype per `@:build` spelling (and one below an `@:autoBuild` interface) declaring the field `cfg` of it.
	 */
	private static final TYPES: String = 'class Cfg { public var a:Int = 0; public function new() {} }\n'
		+ '@:build(M.b()) class B1 { public var cfg:Cfg; public function new() {} }\n#if (!macro) '
		+ '@:build(M.b()) #end class B2 { public var cfg:Cfg; public function new() {} }\n@:autoBuild(M.b()) '
		+ 'interface Mk {}\nclass B3 implements Mk { public var cfg:Cfg; public function new() {} }\n';

	@:pin('control')
	@:killer('M-PURITY-BARE-READ-NULL-NOT-GETTER')
	public function testBareReadOnBuildSupertypeIsPure(): Void {
		Assert.equals(1, violations('B1', 'cfg.a'));
	}

	@:pin('control')
	@:killer('M-MEMBER-GETTER-TRUSTS-BUILD')
	public function testThisReadOnBuildSupertypeIsPure(): Void {
		Assert.equals(1, violations('B1', 'this.cfg.a'));
	}

	@:pin('control')
	@:killer('M-PURITY-BARE-READ-NULL-NOT-GETTER')
	public function testBareReadOnConditionalBuildSupertypeIsPure(): Void {
		Assert.equals(1, violations('B2', 'cfg.a'));
	}

	@:pin('control')
	@:killer('M-MEMBER-GETTER-TRUSTS-BUILD')
	public function testThisReadOnConditionalBuildSupertypeIsPure(): Void {
		Assert.equals(1, violations('B2', 'this.cfg.a'));
	}

	@:pin('control')
	@:killer('M-MEMBER-GETTER-TRUSTS-BUILD')
	public function testThisReadBelowAutoBuildInterfaceIsPure(): Void {
		Assert.equals(1, violations('B3', 'this.cfg.a'));
	}

	@:pin('control')
	@:killer('M-PURITY-UNKNOWN-MEMBER')
	public function testUndeclaredNameOnBuildSupertypeIsNotPure(): Void {
		Assert.equals(0, violations('B1', 'this.other'));
	}

	/** The `join-branch-call` findings of a subclass of `base` whose two branches differ only after reading `read`. */
	private static function violations(base: String, read: String): Int {
		final src: String = '${TYPES}class D extends $base {\n\tstatic function h(a:Int, b:Int) {}\n'
			+ '\tpublic function f(c:Bool) { if (c) h($read, 1); else h($read, 2); }\n}';
		return CheckFixture.violations(new JoinBranchCall(), src).length;
	}

}
